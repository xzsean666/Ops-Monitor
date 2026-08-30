# Ops-Monitor 系统架构设计说明书

## 1. 系统定位与设计原则
Ops-Monitor 是一套基于原生 POSIX/Bash 构建的轻量级、无外部运行时依赖（Zero-Dependency）的服务器性能监控与自动化运维套件。系统针对 Linux 生产环境设计，通过直接采集内核虚拟文件系统（procfs / sysfs），实现分钟级资源指标采集、终端字符图表渲染、多通道 Webhook 告警、数据自动归档以及跨节点配置同步。

### 核心设计原则
- **零外部依赖 (Zero Dependency)**：仅依赖 Linux 基础系统工具链（`bash 4.0+`、`coreutils`、`awk`、`sed`、`grep`、`curl`、`tar`、`gzip`、`openssl`），免除 Python/Node.js 等解释器依赖。
- **极低资源负载 (Minimal Overhead)**：单次指标采集与状态评估耗时 $< 50\text{ms}$，内存驻留 $< 15\text{MB}$，平均 CPU 占用率 $< 0.1\%$。
- **非侵入式探测 (Procfs-Driven)**：直接解析 `/proc/stat`、`/proc/meminfo`、`/proc/net/dev`，禁止频繁 fork 重型子进程（如 top / vmstat）。
- **极简安装与 APT/DEB 原生支持 (Easy Install & Upgrade)**：原生提供 Debian/Ubuntu `.deb` 打包体系与一键安装器，适配 APT 生态，升级平滑无感。
- **开箱即用与渐进式接管 (Zero-Config Out-of-Box)**：预设生产级告警阈值与数据保留策略；通过 SSH 登录探针实现零接触引导。
- **数据安全性 (Security-First)**：配置文件强制权限校验（0600），敏感凭据内存级脱敏，支持跨机器 Base64 安全导入导出。

---

## 2. 总体架构与数据流拓扑

```text
+-----------------------------------------------------------------------------------------+
|                                    1. 用户交互 / 接入层                                  |
|  +-------------------------------------+       +-------------------------------------+  |
|  |     SSH 登录感知探针 (Profile Hook)  |       |        统一 CLI 终端入口 (ops)       |  |
|  |    (/etc/profile.d/ops-prompt.sh)   |       |   (TUI 仪表盘 / 历史大图 / 配置管理)   |  |
|  +------------------+------------------+       +------------------+------------------+  |
+---------------------|---------------------------------------------|---------------------+
                      |                                             |
                      v                                             v
+-----------------------------------------------------------------------------------------+
|                                    2. 核心引擎层                                         |
|  +---------------------+  +---------------------+  +---------------------------------+  |
|  |     配置管理中心    |  |     指标采集引擎    |  |           告警评估引擎          |  |
|  |  (优先级/导入/导出) |  | (/proc 解析/1min周期) |  |   (阈值比对/连续防抖/静默冷却)  |  |
|  +----------+----------+  +----------+----------+  +----------------+----------------+  |
|             |                        |                              |                   |
|             v                        v                              v                   |
|  +---------------------+  +---------------------+  +---------------------------------+  |
|  |    字符图表渲染器   |  |    数据生命周期引擎 |  |        Webhook 适配管道         |  |
|  | (Sparkline/Braille) |  |  (24h 轮转 / Gzip)  |  |  (Slack / 钉钉加签 / 飞书 / 企微) |  |
|  +---------------------+  +----------+----------+  +---------------------------------+  |
+--------------------------------------|--------------------------------------------------+
                                       |
                                       v
+-----------------------------------------------------------------------------------------+
|                                    3. 数据与存储层                                       |
|  +-----------------------------------+   +-------------------------------------------+  |
|  |  内存缓冲区 (/dev/shm/ops-monitor)|   |  历史指标库 (/var/log/ops-monitor/current)|  |
|  |  (瞬时状态/环形队列/文件排他锁)    |   |  (TSV 结构化存储，保留 1440 个采样点)     |  |
|  +-----------------------------------+   +-------------------------------------------+  |
|                                          |                                              |
|                                          v (若配置 ARCHIVE_DIR)                         |
|                                  +-------------------------------------------+          |
|                                  |  冷数据归档池 (${ARCHIVE_DIR}/metrics_*.gz) |         |
|                                  +-------------------------------------------+          |
+-----------------------------------------------------------------------------------------+
```

---

## 3. 目录架构与模块分工

```text
/opt/ops-monitor/
├── ops.sh                  # [CLI 调度入口] 统一命令行路由、子命令分发 (软链至 /usr/local/bin/ops)
├── install.sh              # [安装部署器] 环境校验、Systemd 注册、SSH 探针注入
├── uninstall.sh            # [卸载清理器] 服务注销、探针剔除、数据清理
├── build-deb.sh            # [打包工具] 快速生成 Debian .deb 安装包
├── debian/                 # [Debian 打包元数据]
│   ├── control             # 架构、元数据与依赖定义 (bash, coreutils, awk, sed, grep, curl, openssl)
│   ├── rules               # 构建规则
│   ├── conffiles           # 声明升级保留配置文件 (/etc/ops-monitor/ops.conf)
│   ├── postinst            # 安装后钩子 (创建运行用户/目录、赋权0600、配置并启动 systemd)
│   ├── prerm               # 卸载前钩子 (停止 systemd 服务)
│   └── postrm              # 卸载后钩子 (清理服务软链与临时数据)
├── config/
│   ├── ops.conf.default    # 默认出厂模版（只读）
│   └── ops.conf            # 当前生效的全局配置（权限 0600，软链至 /etc/ops-monitor/ops.conf）
├── lib/
│   ├── collector.sh        # 指标采集核心（procfs 与 df 解析）
│   ├── render.sh           # ANSI / UTF-8 字符图形渲染（Sparklines、Braille 点阵图）
│   ├── alert.sh            # 告警规则评估、连续触发计数器、冷却抑制
│   ├── webhook.sh          # Webhook 适配器（DingTalk HMAC 加签、Slack Payload 封装）
│   ├── storage.sh          # TSV 写入、24h 滚动淘汰与 Tar.Gz 归档流水线
│   └── config_mgr.sh       # 配置 CRUD、语法校验、Base64 导入导出引擎
├── data/
│   ├── current/            # 当天滚动指标文件 (metrics_YYYYMMDD.tsv)
│   └── state/              # 告警状态机缓存 (alert.state)
└── systemd/
    └── ops-daemon.service  # 守护进程定义文件 (每 60 秒常驻调度)
```

---

## 4. 核心子系统详细设计

### 4.1 登录感知与自举安装机制
在 `/etc/profile.d/ops-prompt.sh` 注入探针，接管 SSH 交互式会话：
```text
用户发起 SSH 登录
       │
       ▼
/etc/profile.d/ops-prompt.sh 执行
       │
       ├──> 检测 [ -t 0 ] (是否为 TTY 交互终端?) ──[ 否 ]──> 静默退出 (不影响 SCP/SFTP)
       │
       └──> [ 是 ] ──> 检测 /usr/local/bin/ops 或 /opt/ops-monitor/ops.sh 是否存在?
                          ├── [ 存在 ] ──> 打印快捷提示: "输入 'ops' 查看系统仪表盘"
                          └── [ 不存在 ] ──> 触发自举引导对话:
                                              "检测到本机未安装 Ops-Monitor，是否立即安装？[Y/n]"
                                              ├── [ 选择 Y ] ──> 执行安装 ──> 进入仪表盘
                                              └── [ 选择 n ] ──> 写入 ~/.ops_ignore 抑制下次提示
```

### 4.2 极轻量指标采集引擎 (`lib/collector.sh`)
绕过重型外部命令，直接计算内核参数，确保单次采集时间 $< 50\text{ms}$。

#### 指标计算逻辑与数学模型
1. **CPU 使用率**：读取两次采样间隔（$\Delta t = 1\text{s}$）的 `/proc/stat` 第一行：
   $$\text{Total} = \text{user} + \text{nice} + \text{system} + \text{idle} + \text{iowait} + \text{irq} + \text{softirq} + \text{steal}$$
   $$\text{IdleAll} = \text{idle} + \text{iowait}$$
   $$\text{CPU\%} = \left(1 - \frac{\Delta\text{IdleAll}}{\Delta\text{Total}}\right) \times 100$$
2. **内存使用率**：读取 `/proc/meminfo`：
   $$\text{Mem\%} = \left(1 - \frac{\text{MemAvailable}}{\text{MemTotal}}\right) \times 100$$
3. **磁盘使用率**：执行 `df -P /`，提取使用百分比及挂载点。
4. **网络吞吐量**：解析 `/proc/net/dev`，对非 `lo` 网卡的 `rx_bytes` 与 `tx_bytes` 计算时间差分：
   $$\text{Throughput (KB/s)} = \frac{\Delta\text{Bytes}}{1024 \times \Delta t}$$

### 4.3 命令行字符图表渲染引擎 (`lib/render.sh`)
无需 X11 或 Web UI，在纯 ANSI 终端环境下通过字符编码映射实现高精度趋势图。

1. **单行趋势曲线 (Sparkline 算法)**：
   用于主仪表盘，将一维时序数据归一化映射到 UTF-8 阶梯字符块：
   `SPARK_MAP=(" " " " "▂" "▃" "▄" "▅" "▆" "▇" "█")`（8 个分阶）。
   ```text
   时序数据数组: [ 10, 25, 45, 60, 85, 95, 70, 30 ]
   归一化计算:   Index = (Value - Min) * 8 / (Max - Min)
   渲染输出:      ▂▄▅▇█▆▃
   ```

2. **多行高精度历史大图 (Braille 点阵与 ASCII 坐标系)**：
   用于 `ops history [cpu|mem|net]`，在终端构建 $80 \times 15$ 的字符矩阵：
   - **重采样算法**：将过去 24 小时（1440 个点）降采样聚合至终端列宽 $W$（如 80 列），聚合窗口 $K = \lfloor 1440 / W \rfloor$。
   - **Y 轴自适应标尺**：自动标定 $0\% \sim 100\%$（或网络自适应量程），并以虚线绘制告警阈值线。
   ```text
   100% |                                      ╭─╮
    90% |                                  ╭───╯ │
    80% | [CPU 告警线] --------------------│-----│----------------------------
    70% |                              ╭───╯     ╰──╮
    60% |                          ╭───╯            ╰╮
    50% |            ╭─╮          ╭╯                 ╰─╮
    40% |        ╭───╯ ╰──╮    ╭──╯                    ╰──╮
    30% |     ╭──╯        ╰────╯                          ╰─╮
    20% |  ╭──╯                                             ╰──────╮
    10% |──╯                                                       ╰──────────
     0% +-------------------------------------------------------------------->
        00:00    04:00    08:00    12:00    16:00    20:00    24:00 (时间)
   ```

### 4.4 数据生命周期与归档子系统 (`lib/storage.sh`)
```text
+-------------------------------------------------------------------------------+
|                            数据生命周期状态机                                 |
|                                                                               |
|  [采集器写入] ──> /var/log/ops-monitor/current/metrics_YYYYMMDD.tsv           |
|                          │                                                    |
|                          ▼ (每日 00:00 轮转检测)                              |
|                   检查文件修改时间 (mtime > 24h)                              |
|                          │                                                    |
|            +-------------+-------------+                                      |
|            │                           │                                      |
|            ▼ [ARCHIVE_DIR 为空]        ▼ [ARCHIVE_DIR 有效]                   |
|     +---------------+          +------------------------------------+         |
|     |  rm -f 删除   |          |  tar -czf metrics_YYYYMMDD.tar.gz  |         |
|     |  (释放磁盘)   |          |  mv 至 ${ARCHIVE_DIR}/             |         |
|     +---------------+          +------------------------------------+         |
+-------------------------------------------------------------------------------+
```
- **实时存储格式**：制表符分隔（TSV），单行大小 $< 64\text{B}$，24 小时产生 1440 行（约 $90\text{KB}$/天）。
- **自动清理机制**：守护进程在每个采样周期执行轻量级清理判定：`find /var/log/ops-monitor/current/ -name "metrics_*.tsv" -mtime +1`。
- **归档压缩流水线**：若 `ARCHIVE_DIR` 配置有效，旧指标文件被原子打包为 `metrics_YYYYMMDD.tar.gz` 后移入归档目录。

### 4.5 告警引擎与 Webhook 调度中心 (`lib/alert.sh`, `lib/webhook.sh`)
```text
告警状态机模型:
           [指标 <= 阈值]
         +----------------+
         |                |
         v                |
   +-----------+  超限   +-----------+ 达到连续次数   +-------------+
   |   NORMAL  | ------> | SUSPECTED | -----------> |   ALERTED   |
   +-----------+         +-----------+              +------+------+
         ^                     |                           |
         |                     | 恢复                      | 触发 Webhook
         +---------------------+                           v
                                                    +-------------+
                                                    |  COOLDOWN   | (静默 30m)
                                                    +-------------+
```

#### Webhook 协议与加签算法
- **Slack 适配**：向 `WEBHOOK_SLACK_URL` 投递 Block Kit 结构体，支持颜色标注（危险红/警告黄）。
- **钉钉 (DingTalk) 签名适配**：使用 OpenSSL 计算 HMAC-SHA256：
  ```bash
  timestamp=$(date +%s%3N)
  string_to_sign="${timestamp}\n${WEBHOOK_DINGTALK_SECRET}"
  sign=$(echo -ne "$string_to_sign" | openssl dgst -sha256 -hmac "$WEBHOOK_DINGTALK_SECRET" -binary | base64)
  sign_encoded=$(curl -s -o /dev/null -w "%{url_effective}" --data-urlencode "sign=${sign}" "" | cut -c 6-)
  target_url="${WEBHOOK_DINGTALK_URL}&timestamp=${timestamp}&sign=${sign_encoded}"
  ```
- **飞书 / 企业微信**：标准化 JSON Payload 投递，包含主机名、触发指标、当前数值、阈值及报警时间。

### 4.6 配置管理与迁移子系统 (`lib/config_mgr.sh`)
1. **配置加载优先级链**：
   $$\text{Active Config} = \text{CLI Flags} \succ \text{Local (\~/.ops.conf)} \succ \text{Server Global (/etc/ops-monitor/ops.conf)} \succ \text{Defaults}$$
2. **跨机器导入与导出流程**：
   ```text
   [源服务器]                                             [目标服务器]
       │                                                      │
    1. ops config export --base64                             │
       │ (去除注释/空白，Base64 编码)                          │
       │                                                      │
    2. 复制密文 ──────────────── (SSH / 剪贴板) ──────────────>│
                                                              │
                                               3. ops config import --base64 "eyNB..."
                                                              │
                                                              ├── a. 解码写入临时文件
                                                              ├── b. 语法与数值范围验证
                                                              ├── c. 原子覆盖 ops.conf
                                                              ├── d. chmod 600 权限加固
                                                              └── e. systemctl reload 守护进程
   ```

### 4.7 Debian/APT 打包与升级子系统
为了满足“易安装、易升级、支持 DEB/APT”的需求，系统设计了原生的打包与版本维护流水线：
1. **Debian 包规范 (`ops-monitor_*.deb`)**：
   - 依赖清单：`bash (>= 4.0), coreutils, gawk | awk, sed, grep, curl, tar, gzip, openssl`。
   - 包内文件分布：
     - `/opt/ops-monitor/`：核心库与可执行文件
     - `/etc/ops-monitor/ops.conf`：配置文件（纳入 `conffiles` 保护列表）
     - `/usr/local/bin/ops`：软链接指向 `/opt/ops-monitor/ops.sh`
     - `/etc/systemd/system/ops-daemon.service`：系统服务配置
     - `/etc/profile.d/ops-prompt.sh`：SSH 登录探针
   - 升级行为（`postinst`）：自动检测并升级已有二进制文件，触发 `systemctl daemon-reload && systemctl restart ops-daemon`，但决不覆盖已有 `/etc/ops-monitor/ops.conf` 与 `/var/log/ops-monitor/` 历史数据。
2. **一键构建脚本 (`build-deb.sh`)**：
   - 纯 Bash 编写，利用 `dpkg-deb -b` 构建标准 `.deb` 安装包，无需安装复杂的 `dpkg-buildpackage` 依赖链。
3. **分发与升级支持**：
   - 本地/离线：`sudo dpkg -i ops-monitor_1.0.0_all.deb` 或 `sudo apt install ./ops-monitor_1.0.0_all.deb`。
   - 远程在线仓库：支持发布至 GitHub Releases 或 APT Repo，执行 `apt update && apt upgrade ops-monitor` 即可实现一键无缝热升级。

---

## 5. 数据规范与配置契约

### 5.1 指标存储格式规范 (`metrics_YYYYMMDD.tsv`)
```tsv
#timestamp	cpu_usage_pct	mem_usage_pct	disk_usage_pct	net_rx_kbps	net_tx_kbps
1719705600	12.4	64.8	48.0	128.5	45.2
1719705660	15.1	65.0	48.0	340.2	112.8
```

### 5.2 全局配置文件规范 (`ops.conf`)
```ini
# ==============================================================================
# Ops-Monitor 生产配置文件 (权限必须为 0600)
# ==============================================================================

# --- 采集与保留策略 ---
COLLECT_INTERVAL=60                     # 采样周期 (秒)
RETENTION_DAYS=1                        # 本地分钟级指标保留天数
ARCHIVE_DIR="/var/log/ops_archive"      # 归档目录 (为空则不归档直接删除)

# --- 默认告警阈值 ---
ALERT_CPU_THRESHOLD=85                  # CPU 告警阈值 (%)
ALERT_CPU_CONSECUTIVE=3                 # CPU 连续超限触发次数 (防抖)
ALERT_MEM_THRESHOLD=90                  # 内存告警阈值 (%)
ALERT_DISK_THRESHOLD=85                 # 磁盘主分区告警阈值 (%)
ALERT_COOLDOWN_MINUTES=30               # 告警抑制冷却周期 (分钟)

# --- Webhook 通信渠道 ---
WEBHOOK_SLACK_URL=""
WEBHOOK_DINGTALK_URL=""
WEBHOOK_DINGTALK_SECRET=""
WEBHOOK_FEISHU_URL=""
```

### 5.3 CLI 命令行规范全集
```text
用法: ops [选项] <子命令> [参数...]

监控与可视化:
  ops                     [默认] 启动全屏 TUI 实时性能看板 (支持 CPU/MEM 实时曲线)
  ops dashboard           同上
  ops history <cpu|mem|net>
                          以高精度 ASCII 坐标系绘制过去 24 小时的历史指标大图
  ops status              输出紧凑的单次健康体检报告 (适合 MOTD / 批量探测)

配置管理 (服务端/本地复用):
  ops config              进入 TUI 交互式问答配置向导
  ops config list [--raw] 打印当前生效的所有配置项 (默认对 Webhook Secret 脱敏)
  ops config get <KEY>    获取指定配置项的当前值
  ops config set <KEY> <VAL>
                          修改指定配置项 (自动校验参数有效性)
  ops config export [-f <file> | --base64 | --template]
                          导出配置：支持文件、Base64 单行密文或脱敏模板
  ops config import [-f <file> | --base64 <str> | -]
                          导入配置：支持文件、Base64 字符串或标准输入流
  ops config test-alert   向当前启用的 Webhook 通道发送一条模拟告警卡片

生命周期与服务控制:
  ops archive --run       立即执行一次过期数据扫描与压缩归档
  ops daemon <start|stop|restart|status>
                          管理后台采集与告警守护进程

全局选项:
  -c, --config <path>     显式指定配置文件路径 (优先于默认配置)
  -h, --help              打印帮助信息
  -v, --version           打印套件版本信息
```

---

## 6. 异常处理、安全性与并发控制

### 6.1 并发冲突与锁机制 (Concurrency Control)
后台守护进程与 CLI 手动归档/写入之间通过 `flock` 文件锁进行互斥保护：
```bash
exec 200>/var/run/ops-monitor.lock
if ! flock -n 200; then
    echo "[WARN] 采集或归档任务正在执行中，跳过本次调度。" >&2
    exit 0
fi
```

### 6.2 安全加固与凭据保护
- **权限沙箱**：安装脚本自动对配置文件执行 `chmod 600`。CLI 启动时若检测到配置权限高于 0600，强制告警或自动修复。
- **命令注入防御**：配置导入解析模块严格禁止 `eval` 执行，仅通过严格的白名单键值校验与参数清洗。
- **非 root 降级运行**：若非 root 用户执行 `ops`，系统自动将数据与配置落盘目录平滑降级至 `~/.config/ops-monitor/` 与 `~/.local/share/ops-monitor/`。

### 6.3 网络容灾与超时隔离
所有 Webhook 请求均设置强超时约束：`curl --connect-timeout 3 --max-time 5 -s -f`，避免因网络抖动或目标网关阻塞挂起后台采集主线程。

---

## 7. 部署模型与守护进程

### 7.1 Systemd 模式
```ini
# /etc/systemd/system/ops-daemon.service
[Unit]
Description=Ops-Monitor Metrics Collection and Alerting Daemon
After=network.target

[Service]
Type=simple
ExecStart=/opt/ops-monitor/lib/collector.sh --daemon
Restart=always
RestartSec=10s
StandardOutput=null
StandardError=journal
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

### 7.2 Crontab 降级模式 (适用于 Docker / 精简 Alpine)
在不支持 Systemd 的精简系统上，自动无缝降级为标准 Crontab 任务调度模式：
```cron
* * * * * /opt/ops-monitor/lib/collector.sh --cron
```
