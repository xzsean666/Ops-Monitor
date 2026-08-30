# TASK-001: 项目骨架与公共基础库

## Objective
搭建 Ops-Monitor 项目的基础目录结构，建立公共环境变量、错误处理、文件锁、ANSI 颜色代码以及配置加载解析的基础库 `lib/common.sh`，并提供默认配置文件模板 `config/ops.conf.default`。

## Scope
- 创建标准目录：`config/`, `lib/`, `data/current/`, `data/state/`, `systemd/`, `tests/`
- 实现 `lib/common.sh`：定义公共常量（目录定位、退出码、颜色常量、日志函数、`ops_lock_acquire` / `ops_lock_release` 锁机制、非 root 路径自适应）
- 创建 `config/ops.conf.default` 模板文件，遵循架构设计中的配置规范
- 提供基础环境检测与路径解析函数

## Allowed Files
- `lib/common.sh`
- `config/ops.conf.default`
- `.gitignore`

## Dependencies
无（初始任务）

## Inputs and Outputs
- **Inputs**: 系统环境变量、当前执行用户 UID、安装目录配置
- **Outputs**:
  - `lib/common.sh` 可供所有后续模块 `source`
  - 标准化默认配置模板 `config/ops.conf.default`

## Acceptance Criteria
1. `lib/common.sh` 能够在 Bash 4.0+ 环境下被安全 `source` 且无语法错误（`bash -n`）。
2. 在 root 用户与非 root 用户下能够正确解析默认数据目录（`/var/log/ops-monitor` vs `~/.local/share/ops-monitor`）与配置目录。
3. `config/ops.conf.default` 包含所有必需参数（`COLLECT_INTERVAL`, `RETENTION_DAYS`, `ARCHIVE_DIR`, `ALERT_*_THRESHOLD`, `ALERT_COOLDOWN_MINUTES`, `WEBHOOK_*`）。
4. 文件锁机制（`flock`）在多进程竞争时能准确返回成功或失败状态。

## Verification Commands
```bash
bash -n lib/common.sh
bash -c "source lib/common.sh && echo 'BASE_DIR='\$OPS_BASE_DIR && echo 'DATA_DIR='\$OPS_DATA_DIR"
```

## Risks and Assumptions
- 假定运行环境为 Linux 并支持 `flock` 与基础 Bash 4.0+ 内建功能。

## Status
DONE
