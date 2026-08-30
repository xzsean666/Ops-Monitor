# TASK-005: 多通道 Webhook 适配引擎 (lib/webhook.sh)

## Objective
实现多渠道告警通知分发引擎 `lib/webhook.sh`，支持 Slack、钉钉（DingTalk 加签安全模式）、飞书（Feishu）、企业微信（WeCom），具备强网络超时控制与安全脱敏机制。

## Scope
- 实现通用 HTTP POST 请求发送器，设置强超时参数（`--connect-timeout 3 --max-time 5 -s -f`）
- 实现 Slack Block Kit 格式卡片生成与发送
- 实现钉钉 (DingTalk) 签名适配：使用 `openssl` 计算 `HMAC-SHA256` 并进行 URL 编码
- 实现飞书 (Feishu) 互动卡片 / 富文本 JSON 发送
- 实现企业微信 (WeCom) Markdown / Text 消息发送
- 实现模拟测试消息发送功能（`ops_webhook_test_alert`）

## Allowed Files
- `lib/webhook.sh`
- `tests/test_webhook.sh`

## Dependencies
- TASK-001: 项目骨架与公共基础库
- TASK-002: 配置管理引擎

## Inputs and Outputs
- **Inputs**: 主机名、告警指标名、当前数值、告警阈值、触发时间、Webhook 配置 URL 与 Secret
- **Outputs**: HTTP 请求至各目标 Webhook 网关，返回发送成功或错误日志

## Acceptance Criteria
1. 在配置有效 URL 时，能够构造符合各平台规范的 JSON Payload。
2. 钉钉签名计算算法符合官方规范（时间戳 + 密钥的 HMAC-SHA256 Base64 编码与 URL 转义）。
3. 发生网络连接超时或目标服务端不可达时，不阻塞调用者超过 5 秒，并返回非零错误码。
4. 提供 `test-alert` 辅助函数，方便运维人员验证各 Webhook 通道连通性。

## Verification Commands
```bash
bash -n lib/webhook.sh
bash tests/test_webhook.sh
```

## Risks and Assumptions
- 假定系统中安装有 `curl` 与 `openssl`。

## Status
DONE
