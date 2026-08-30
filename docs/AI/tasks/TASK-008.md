# TASK-008: 统一 CLI 调度器与 TUI 看板 (ops.sh)

## Objective
实现 Ops-Monitor 的主入口程序 `ops.sh`，负责统一命令行路由分发、交互式全屏 TUI 实时性能看板、单次状态体检报告、历史图表调度、配置交互向导以及守护进程/归档控制。

## Scope
- CLI 选项与子命令解析：
  - `ops` / `ops dashboard`：全屏 TUI 实时看板（包含 CPU/Mem/Disk 仪表盘、网速吞吐、近期 Sparkline 曲线、告警状态；支持按 `q` 退出，支持刷新间隔调整）
  - `ops history <cpu|mem|net>`：输出指定指标过去 24 小时高精度 ASCII 大图
  - `ops status`：输出单次紧凑体检报告（适合 MOTD / 批量远程探测）
  - `ops config [get|set|list|export|import|test-alert]`：配置管理子命令
  - `ops archive --run`：手动触发一次归档与清理
  - `ops daemon <start|stop|restart|status>`：服务管理
  - 全局参数：`-c/--config`, `-h/--help`, `-v/--version`
- 软链接与环境自适应（`/usr/local/bin/ops`）

## Allowed Files
- `ops.sh`
- `tests/test_ops_cli.sh`

## Dependencies
- TASK-002: 配置管理引擎
- TASK-004: TSV 存储与生命周期归档
- TASK-007: 终端字符图表与渲染引擎

## Inputs and Outputs
- **Inputs**: 命令行参数、用户交互按键（TUI 看板中）
- **Outputs**: 终端交互界面、命令执行结果、退出码

## Acceptance Criteria
1. 执行 `ops` 默认进入 TUI 看板，正确显示当前 CPU/Mem/Disk 读数并动态刷新，按 `q` 或 `Ctrl+C` 能够干净恢复终端光标并退出。
2. 执行 `ops status` 格式规整、无多余输出，适合作为登录 MOTD。
3. 执行 `ops history cpu` 成功打印过去 24 小时大图。
4. `ops config` 所有子命令路由正确并与 `lib/config_mgr.sh` 行为一致。
5. `-h` 和 `--help` 能够打印详尽的帮助信息。

## Verification Commands
```bash
bash -n ops.sh
bash tests/test_ops_cli.sh
bash ops.sh --help
bash ops.sh status
```

## Risks and Assumptions
- TUI 退出时需确保恢复终端光标（`tput cnorm`）与原终端属性（`stty`）。

## Status
DONE
