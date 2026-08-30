# Ops-Monitor 架构决策记录 (ADR)

## ADR-001: 采用纯 POSIX/Bash 构建零外部运行时依赖系统
- **状态**：ACCEPTED
- **背景**：传统的服务器监控探针（如 Node Exporter、Prometheus Agent、Python 脚本或 Go 编译产物）在目标机器上可能面临环境缺失、glibc 版本不匹配、体积庞大或占用内存过高的问题。
- **决策**：完全采用 Linux 基础环境自带的 Bash 4.0+ 和标准工具链（`coreutils`、`awk`、`sed`、`grep`、`curl`、`tar`、`gzip`、`openssl`），不引入任何语言运行时。
- **影响与后果**：
  - 优点：真正做到开箱即用，可在任何 Linux 发行版上单文件/单包运行；内存占用 $< 15\text{MB}$。
  - 权衡：需严格控制复杂数据结构的解析与边界处理，避免 Bash 脚本常见的兼容性陷阱。

---

## ADR-002: 基于 /proc 虚拟文件系统直接计算指标
- **状态**：ACCEPTED
- **背景**：执行 `top`、`vmstat`、`iostat` 等外部工具每次都会 fork 独立进程并初始化终端环境，高频周期性采集会造成 CPU 抖动与性能开销。
- **决策**：采集引擎直接通过 `/proc/stat`、`/proc/meminfo`、`/proc/net/dev` 计算 CPU 使用率、内存空闲率与网络 I/O 速率，磁盘使用率通过单次 `df -P /` 提取。
- **影响与后果**：
  - 优点：单次采集时间 $< 50\text{ms}$，平均 CPU 占用率 $< 0.1\%$，非侵入式探测。
  - 权衡：需准确处理 CPU 时间片两次采样的差分计算以及网络字节溢出/重置边界。

---

## ADR-003: 采用 TSV 结构化滚动存储与 Gzip 归档
- **状态**：ACCEPTED
- **背景**：监控数据需要轻量、高读写性能且方便 Shell 原生工具（`awk`/`cut`）解析，不宜使用 SQLite 或重型数据库。
- **决策**：
  - 当日实时数据以制表符分隔格式（TSV）存储于 `/var/log/ops-monitor/current/metrics_YYYYMMDD.tsv`。
  - 每日 1440 行，单文件约 $90\text{KB}$。
  - 超过保留天数（默认 1 天）的历史文件自动通过 `tar -czf` 移入 `ARCHIVE_DIR` 压缩归档或安全删除。
- **影响与后果**：
  - 优点：TSV 格式天然契合 `awk` 高速重采样；存储占用极低；生命周期管理清晰。

---

## ADR-004: ANSI Sparkline 与 Braille 点阵字符渲染
- **状态**：ACCEPTED
- **背景**：系统需要向运维人员提供直观的趋势图表，但受限于 SSH 纯文本终端，无法依赖 Web 页面或图形库。
- **决策**：
  - 仪表盘实时简图使用单行 UTF-8 阶梯块（Sparklines: ` ▂▃▄▅▆▇█`）。
  - 历史大图使用 Braille 点阵或 ASCII 坐标系，在终端生成自适应标尺与告警虚线。
- **影响与后果**：
  - 优点：无需 X11 或前端服务器，SSH 终端内即可获得高辨识度的可视化效果。

---

## ADR-005: Debian Package (.deb) 与 APT 生态打包及平滑升级策略
- **状态**：ACCEPTED
- **背景**：用户要求极简安装、易升级，且优先支持 Debian/Ubuntu 环境下的 `.deb` 包或 `apt` 仓库安装。
- **决策**：
  - 建立标准 `debian/` 维护结构，提供 `build-deb.sh` 构建脚本，支持生成 `ops-monitor_<version>_all.deb`。
  - 在 `debian/conffiles` 中保护 `/etc/ops-monitor/ops.conf`，确保在 `apt upgrade` 时不被出厂默认配置覆盖。
  - `postinst` 钩子负责软链接 `/usr/local/bin/ops`、设置 `0600` 权限及无缝重启 `ops-daemon.service`。
- **影响与后果**：
  - 优点：完全融入 Linux 官方包管理流程，支持离线 deb 安装、PPA/APT 仓库分发以及无损平滑热升级。

---

## ADR-006: 文件排他锁 (flock) 并发控制与 0600 权限沙箱
- **状态**：ACCEPTED
- **背景**：后台常驻采集守护进程与前台用户手动触发的 CLI 归档或配置变更可能产生写竞争；且配置文件中可能包含 Webhook Token 等敏感凭据。
- **决策**：
  - 数据写入与归档操作通过 `/var/run/ops-monitor.lock` 加 `flock -n` 互斥保护。
  - 配置文件强制权限校验（`chmod 0600`），CLI 交互与导出的敏感 Token 默认内存级脱敏掩码。
- **影响与后果**：
  - 优点：杜绝并发写入导致的文件损坏与敏感配置泄露风险。

---

## ADR-007: 安全 Base64 配置迁移（杜绝 eval 注入）
- **状态**：ACCEPTED
- **背景**：跨节点迁移配置时需要简单且安全，直接执行远程脚本或通过 `eval` 解析配置具有极高的安全隐患。
- **决策**：
  - 配置导出为单行 Base64 编码密文。
  - 导入解析时采用严格白名单参数键值校验与参数清洗，绝对禁止使用 `eval` 动态执行代码。
- **影响与后果**：
  - 优点：跨机器部署一键导入导出，且从架构层面杜绝任意命令注入风险。
