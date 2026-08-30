# TASK-009: 常驻守护进程与登录感知探针

## Objective
实现 Ops-Monitor 的后台常驻采集守护进程（Systemd 服务定义与 Crontab 降级调度）以及 SSH 交互式登录感知探针（`/etc/profile.d/ops-prompt.sh`）。

## Scope
- 创建 `systemd/ops-daemon.service` 服务单元文件（包含自动重启、开机自启、文件描述符限制）
- 在 `lib/collector.sh` 中完善 `--daemon` 常驻循环与 `--cron` 模式支持
- 实现 SSH 登录感知脚本 `systemd/ops-prompt.sh`（安装时部署至 `/etc/profile.d/ops-prompt.sh`）：
  - 检测 `[ -t 0 ]` 终端模式（非交互如 SCP/SFTP 立即静默退出）
  - 已安装时显示登录快捷提示
  - 未安装时触发自举引导安装交互（支持 `~/.ops_ignore` 抑制机制）

## Allowed Files
- `systemd/ops-daemon.service`
- `systemd/ops-prompt.sh`
- `tests/test_daemon_prompt.sh`

## Dependencies
- TASK-003: 指标采集引擎
- TASK-008: 统一 CLI 调度器与 TUI 看板

## Inputs and Outputs
- **Inputs**: Systemd 信号、SSH 登录事件、用户 TTY 输入
- **Outputs**: 后台定时采集、SSH 交互式欢迎信息与引导

## Acceptance Criteria
1. `ops-daemon.service` 语法符合 `systemd-analyze verify` 规范。
2. 守护进程以固定周期（默认 60 秒）稳定执行采集、TSV 写入、告警评估与归档判定，进程常驻内存 $< 15\text{MB}$。
3. `ops-prompt.sh` 在非交互式 Shell（如 `ssh host 'ls'` 或 SCP）中保持 100% 静默，绝不破坏远程自动化脚本。
4. 在交互式终端登录时能够优雅输出提示，且支持忽略策略。

## Verification Commands
```bash
bash -n systemd/ops-prompt.sh
bash tests/test_daemon_prompt.sh
```

## Risks and Assumptions
- 假定生产环境多为 Systemd，但在 Alpine/Docker 等环境提供 Crontab 备用方案。

## Status
DONE
