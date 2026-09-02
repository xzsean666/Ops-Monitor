# TASK-012: 告警中心统一 CLI (ops alert) 与极简管理

## 1. 任务背景与目标
用户反馈查看告警状态、阈值与守护进程启停命令分散且繁琐。
本任务旨在实现统一的 `ops alert` CLI 模块与极简操作指令：
1. 单一命令 `ops alert`（或 `ops alert status`）：一站式输出当前守护进程运行状态（Systemd/PID）、全局冷却时间、所有指标（CPU、内存、磁盘、网络 RX/TX）的实时当前值、设定阈值、防抖规则、状态机状态（NORMAL / SUSPECTED / COOLDOWN / DISABLED）及 Webhook 渠道配置状态。
2. 极简告警阈值修改指令：支持 `ops alert set <cpu|mem|disk|rx|tx|cooldown> <数值>` 及快捷语法 `ops alert cpu 90`。
3. 极简服务与通知管理：支持 `ops alert <start|stop|restart>` 启停守护进程，`ops alert test` 测试通知，`ops alert webhook <dingtalk|feishu|wecom|slack> <URL> [SECRET]` 一键配置通知渠道。
4. 多节点透明代理：当工作上下文处于远程节点时，`ops alert` 自动透明代理至远端执行。

---

## 2. 详细设计与实现范围
- **`lib/alert.sh`**:
  - 实现 `_ops_alert_set_metric`：参数映射与合法性校验。
  - 实现 `ops_alert_show_overview`：终端自适应表格与状态卡片渲染。
  - 实现 `ops_alert_cli`：统一处理 `set`、`test`、`start`、`stop`、`restart`、`webhook` 等子命令。
- **`lib/node_mgr.sh`**:
  - 实现 `ops_node_alert`：支持远程执行目标机器上的 `ops alert`。
- **`ops.sh`**:
  - 注册 `alert` / `alerts` 顶层子命令路由。
  - 完善 `--help` 帮助文档。
- **`tests/test_alert.sh` & `tests/test_ops_cli.sh`**:
  - 增加 `ops alert` 状态概览、阈值设置、快捷语法及命令路由的自动化测试。

---

## 3. 验收标准
1. `ops alert` 在本地执行时，以结构化表格输出守护进程状态、各项指标数值与阈值、状态机状态及 Webhook 配置。(PASS)
2. `ops alert set cpu 90` / `ops alert cpu 90` 能够正确写入配置文件并提示成功。(PASS)
3. `ops alert start/stop/restart` 能够正确控制守护进程。(PASS)
4. `ops alert test` 能够正常触发通知测试。(PASS)
5. 全量自动化测试套件 100% PASS。(PASS)

---

## 4. 交付总结
- 实现 `lib/alert.sh` 中的 `ops_alert_show_overview`、`_ops_alert_set_metric`、`ops_alert_cli`
- 实现 `lib/node_mgr.sh` 中的 `ops_node_alert`
- 实现 `ops.sh` 中的 `alert` 路由分发与帮助文档
- 全量自动化测试套件 11/11 全部通过。
