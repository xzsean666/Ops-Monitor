# TASK-010: Debian/APT 打包与部署工具链

## Objective
构建 Ops-Monitor 的全套打包分发与部署工具链，支持生成标准 Debian/Ubuntu `.deb` 安装包、提供 `apt`/`dpkg` 安装升级能力、提供一键安装脚本 `install.sh` 与清理卸载脚本 `uninstall.sh`，确保系统极易安装且升级无损。

## Scope
- 编写 `build-deb.sh`：自动化构建标准 `.deb` 安装包（`ops-monitor_<version>_all.deb`）
- 编写 Debian 打包元数据：
  - `debian/control`：包名、版本、维护者、依赖（`bash (>= 4.0), coreutils, gawk | awk, sed, grep, curl, tar, gzip, openssl`）、描述
  - `debian/conffiles`：声明 `/etc/ops-monitor/ops.conf` 为配置文件，升级时不被覆盖
  - `debian/postinst`：安装后钩子（创建所需目录、安全权限设置 `chmod 0600`、软链 `/usr/local/bin/ops`、注册并启动 `ops-daemon.service`）
  - `debian/prerm`：卸载前钩子（停止并禁用 `ops-daemon.service`）
  - `debian/postrm`：卸载后钩子（清理非配置临时文件、移除软链；若 `purge` 则清理配置）
- 编写源码独立安装脚本 `install.sh`（支持一键 `curl | bash` 安装）
- 编写完全卸载脚本 `uninstall.sh`
- 编写本地 APT 仓库与 GitHub Releases 分发使用说明

## Allowed Files
- `build-deb.sh`
- `install.sh`
- `uninstall.sh`
- `debian/control`
- `debian/rules`
- `debian/conffiles`
- `debian/postinst`
- `debian/prerm`
- `debian/postrm`
- `tests/test_packaging.sh`

## Dependencies
- TASK-008: 统一 CLI 调度器与 TUI 看板
- TASK-009: 常驻守护进程与登录感知探针

## Inputs and Outputs
- **Inputs**: Ops-Monitor 源码树、目标版本号
- **Outputs**:
  - `dist/ops-monitor_<version>_all.deb` 二进制包
  - 可执行 `install.sh` 与 `uninstall.sh`

## Acceptance Criteria
1. 执行 `bash build-deb.sh` 能够成功构建出符合 Debian 规范的 `.deb` 包，且无需引入庞大的额外编译工具链（支持 `dpkg-deb -b`）。
2. 在测试环境中通过 `sudo dpkg -i dist/ops-monitor_*.deb` 或 `sudo apt install ./dist/ops-monitor_*.deb` 可一步完成安装，且服务自动上线、`ops` 命令立即可用。
3. 模拟升级场景（安装旧版本 -> 修改配置 -> 安装新版本 deb），验证用户自定义配置（`/etc/ops-monitor/ops.conf`）与历史采集数据绝对不丢失。
4. 执行 `uninstall.sh` 或 `apt purge ops-monitor` 能够干净剔除探针与服务。

## Verification Commands
```bash
bash -n build-deb.sh install.sh uninstall.sh
bash build-deb.sh
bash tests/test_packaging.sh
```

## Risks and Assumptions
- 打包目标系统为 Debian/Ubuntu 及其衍生发行版（统配 `all` 架构纯脚本包）。

## Status
DONE
