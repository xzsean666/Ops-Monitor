# Ops-Monitor 总体目标与产品定义

## 1. 项目定位 (Mission)
Ops-Monitor 是一套基于原生 POSIX/Bash 构建的**轻量级、无外部运行时依赖（Zero-Dependency）、极低开销**的服务器性能监控与自动化运维套件。
针对 Linux 生产服务器环境，实现分钟级内核资源采集、终端字符图表渲染、多通道 Webhook 告警、数据自动归档以及跨节点配置同步。

**核心体验目标：极简安装、极简使用、支持 DEB/APT 快速安装与平滑升级。**

---

## 2. 核心设计原则
1. **零外部依赖 (Zero Dependency)**：
   仅依赖 Linux 基础系统工具链（`bash 4.0+`、`coreutils`、`awk`、`sed`、`grep`、`curl`、`tar`、`gzip`、`openssl`），免除 Python、Node.js 等重型解释器依赖。
2. **极低资源负载 (Minimal Overhead)**：
   单次指标采集与状态评估耗时 $< 50\text{ms}$，内存驻留 $< 15\text{MB}$，平均 CPU 占用率 $< 0.1\%$。
3. **非侵入式探测 (Procfs-Driven)**：
   直接解析 `/proc/stat`、`/proc/meminfo`、`/proc/net/dev`、`df`，禁止频繁 fork 重型子进程。
4. **易安装与平滑升级 (Easy Install & Upgrade)**：
   - 支持生成标准 Debian/Ubuntu `.deb` 安装包，支持 `dpkg -i` / `apt install ./ops-monitor.deb` 以及 APT 软件源分发。
   - 提供官方一键自举脚本（`curl -fsSL ... | bash`）。
   - 遵循 Debian 配置文件保护规范（`conffiles`），在升级版本时保留用户自定义配置与历史数据。
5. **开箱即用与渐进式接管 (Zero-Config Out-of-Box)**：
   预设生产级告警阈值与数据保留策略；通过 SSH 登录感知探针实现快捷引导。
6. **数据安全性 (Security-First)**：
   配置文件强制权限校验（`0600`），敏感凭据（Token/Secret）内存级脱敏，支持跨机器 Base64 安全导入导出。

---

## 3. 功能交付范围

### 3.1 核心功能矩阵
- **系统指标采集**：CPU、内存、磁盘根分区、网络吞吐量（RX/TX）。
- **TUI 字符图表渲染**：ANSI/UTF-8 Sparklines（单行火花线）、Braille 点阵与 24 小时高精度 ASCII 坐标系图表。
- **告警引擎与状态机**：`NORMAL` -> `SUSPECTED` -> `ALERTED` -> `COOLDOWN` 连续防抖与冷却机制。
- **多通道 Webhook 适配器**：钉钉（DingTalk HMAC-SHA256 加签）、Slack（Block Kit 结构体）、飞书（Feishu）、企业微信（WeCom）。
- **配置管理中心**：加载优先级链（CLI > 本地 > 全局 > 默认）、参数校验、Base64 单行密文导入导出。
- **数据生命周期管理**：TSV 格式滚动存储（1440 点/天）、`tar.gz` 自动压缩归档与清理。
- **守护进程与登录探针**：Systemd 常驻守护进程（支持 Crontab 无缝降级）、SSH 交互式登录探针（`/etc/profile.d/ops-prompt.sh`）。
- **打包与升级工具链**：
  - `build-deb.sh`：自动化构建标准 `.deb` 安装包。
  - `debian/` 维护脚本（`postinst`, `prerm`, `postrm`, `conffiles`）：自动处理 systemd 注册、权限加固与配置保护。
  - 一键安装/卸载脚本（`install.sh`, `uninstall.sh`）。

---

## 4. 交付与验收标准
1. **纯净环境兼容性**：在 Ubuntu 20.04/22.04/24.04、Debian 11/12 等主流 Linux 系统上免安装额外运行时即可运行。
2. **打包与安装闭环**：
   - 能够通过 `dpkg -i` 或 `apt install` 顺利安装并自动启动服务。
   - 能够通过 `apt upgrade` / `dpkg -i` 升级新版本并无损继承已有配置。
   - 能够通过 `apt remove` / `apt purge` 干净卸载。
3. **性能基准**：采集脚本单次执行时长 $< 50\text{ms}$，后台 Daemon 常驻内存 $< 15\text{MB}$。
4. **自动化测试覆盖**：具备完备的单元测试与 CLI 模拟集成测试，测试通过率 100%。
