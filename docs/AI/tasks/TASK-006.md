# TASK-006: 告警规则评估与状态机 (lib/alert.sh)

## Objective
实现 Ops-Monitor 告警评估引擎与状态机 `lib/alert.sh`，支持指标阈值比对、连续超限计数防抖（Debounce）、静默冷却抑制（Cooldown）、以及状态缓存持久化（`alert.state`）。

## Scope
- 实现指标阈值与当前值比对逻辑（CPU%、Mem%、Disk%）
- 实现四状态机模型：`NORMAL` -> `SUSPECTED` -> `ALERTED` -> `COOLDOWN`
- 维护连续触发计数器（达到 `ALERT_CPU_CONSECUTIVE` 后才进入 `ALERTED` 触发通知）
- 维护冷却时间状态（进入 `COOLDOWN` 后在 `ALERT_COOLDOWN_MINUTES` 内抑制重复报警）
- 指标恢复正常后自动恢复为 `NORMAL` 并发送恢复通知（可选）
- 状态持久化文件：`$DATA_DIR/state/alert.state`

## Allowed Files
- `lib/alert.sh`
- `tests/test_alert.sh`

## Dependencies
- TASK-003: 指标采集引擎
- TASK-005: 多通道 Webhook 适配引擎

## Inputs and Outputs
- **Inputs**: 当前采集到的指标数据（CPU、Mem、Disk）、已持久化的前次状态、告警配置项
- **Outputs**: 更新后的状态机文件 `$DATA_DIR/state/alert.state`，并在满足条件时调用 `lib/webhook.sh` 发送报警

## Acceptance Criteria
1. 单次偶发毛刺（超限但未达到连续次数）仅转移到 `SUSPECTED` 状态，不触发 Webhook。
2. 连续超限达到阈值（如连续 3 次）时状态转为 `ALERTED` 并调用 Webhook，随后转入 `COOLDOWN`。
3. 冷却期内的指标超限保持静默，不重复发送消息。
4. 指标回落至阈值以下后，状态机重置回 `NORMAL`。

## Verification Commands
```bash
bash -n lib/alert.sh
bash tests/test_alert.sh
```

## Risks and Assumptions
- 状态持久化文件采用简单轻量的键值格式存储，确保 I/O 开销极小。

## Status
DONE
