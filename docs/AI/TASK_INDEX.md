# Ops-Monitor 任务索引 (TASK_INDEX)

## 1. 任务概览与依赖关系图

```text
[TASK-001: 项目骨架与公共库]
      │
      ├───> [TASK-002: 配置管理引擎 lib/config_mgr.sh]
      │           │
      │           v
      ├───> [TASK-003: 指标采集引擎 lib/collector.sh]
      │           │
      │           v
      ├───> [TASK-004: TSV存储与归档 lib/storage.sh]
      │
      ├───> [TASK-005: Webhook适配引擎 lib/webhook.sh]
      │           │
      │           v
      └───> [TASK-006: 告警状态机 lib/alert.sh] (依赖 003, 005)
                  │
                  v
            [TASK-007: 字符图表渲染器 lib/render.sh] (依赖 004)
                  │
                  v
            [TASK-008: CLI 入口与 TUI 仪表盘 ops.sh] (依赖 002, 003, 004, 007)
                  │
                  v
            [TASK-009: Daemon 服务与 SSH 探针] (依赖 003, 008)
                  │
                  v
            [TASK-010: Debian 打包与 APT/一键安装器] (依赖 008, 009)
                  │
                  v
             [TASK-011: 自动化测试套件与端到端验证] (依赖 001-010)
                   │
                   v
              [TASK-012: 告警中心统一 CLI (ops alert) 与极简管理] (依赖 006, 008)
                    │
                    v
              [TASK-013: Docker 容器实时资源监控 (ops docker)] (依赖 008, 007)
```

---

## 2. 任务清单 (Task Matrix)

| 任务 ID | 任务名称 | 目标说明 | 状态 | 依赖 |
| :--- | :--- | :--- | :--- | :--- |
| [TASK-001](tasks/TASK-001.md) | 项目骨架与公共基础库 | 初始化目录结构、公共函数库 `lib/common.sh`、默认配置文件 | `DONE` | 无 |
| [TASK-002](tasks/TASK-002.md) | 配置管理引擎 | 实现 `lib/config_mgr.sh` (CRUD、校验、Base64 导入导出、0600 权限) | `DONE` | TASK-001 |
| [TASK-003](tasks/TASK-003.md) | 指标采集引擎 | 实现 `lib/collector.sh` (procfs CPU/Mem/Net 及 Disk 解析) | `DONE` | TASK-001, TASK-002 |
| [TASK-004](tasks/TASK-004.md) | TSV 存储与生命周期归档 | 实现 `lib/storage.sh` (TSV 写入、排他锁、滚动检测、Gzip 归档) | `DONE` | TASK-001, TASK-003 |
| [TASK-005](tasks/TASK-005.md) | 多通道 Webhook 适配引擎 | 实现 `lib/webhook.sh` (Slack/DingTalk 加签/飞书/企微/超时保护) | `DONE` | TASK-001, TASK-002 |
| [TASK-006](tasks/TASK-006.md) | 告警规则评估与状态机 | 实现 `lib/alert.sh` (连续超限防抖、冷却静默、状态缓存) | `DONE` | TASK-003, TASK-005 |
| [TASK-007](tasks/TASK-007.md) | 终端字符图表与渲染引擎 | 实现 `lib/render.sh` (Sparkline 火花线、24h ASCII/Braille 大图) | `DONE` | TASK-001, TASK-004 |
| [TASK-008](tasks/TASK-008.md) | 统一 CLI 调度器与 TUI 看板 | 实现主入口 `ops.sh` (子命令路由、TUI 动态看板、单次状态体检) | `DONE` | TASK-002, TASK-004, TASK-007 |
| [TASK-009](tasks/TASK-009.md) | 常驻守护进程与登录感知探针 | 实现 `ops-daemon.service`、Cron 降级调度及 `ops-prompt.sh` | `DONE` | TASK-003, TASK-008 |
| [TASK-010](tasks/TASK-010.md) | Debian/APT 打包与部署工具链 | 实现 `debian/` 维护结构、`build-deb.sh`、`install.sh`、`uninstall.sh` | `DONE` | TASK-008, TASK-009 |
| [TASK-011](tasks/TASK-011.md) | 自动化测试与全链路验证 | 构建单元测试与 Mock procfs 测试集，验证安装、采集、渲染与升级闭环 | `DONE` | TASK-001 ~ TASK-010 |
| [TASK-012](tasks/TASK-012.md) | 告警中心统一 CLI 与极简管理 | 统一 `ops alert` 综合状态卡片、快捷阈值设置、Webhook 配置与守护控制 | `DONE` | TASK-006, TASK-008 |
| [TASK-013](tasks/TASK-013.md) | Docker 容器实时资源监控 | 实现 `lib/docker.sh` (ops docker 实时快照、Live 刷新、未安装优雅降级) | `DONE` | TASK-008, TASK-007 |


