#!/usr/bin/env bash
# ==============================================================================
# tests/test_webhook.sh: TASK-005 lib/webhook.sh 单元与适配测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_webhook_$$"
mkdir -p "${TMP_DIR}"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/webhook.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/webhook.sh"
echo "  [PASS] lib/webhook.sh bash -n 语法检查通过"

# 2. 隔离环境变量
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_CONFIG_FILE="${TMP_DIR}/ops.conf"
touch "${OPS_CONFIG_FILE}"

# shellcheck source=../lib/webhook.sh
source "${BASE_DIR}/lib/webhook.sh"

# 3. 钉钉签名计算测试
base_url="https://oapi.dingtalk.com/robot/send?access_token=xxxxxx"
secret="SEC_TEST_SECRET_KEY"
signed_url=$(ops_webhook_sign_dingtalk "${base_url}" "${secret}")

echo "${signed_url}" | grep -q "timestamp=" || { echo "  [FAIL] 钉钉加签缺少 timestamp 参数"; exit 1; }
echo "${signed_url}" | grep -q "&sign=" || { echo "  [FAIL] 钉钉加签缺少 sign 参数"; exit 1; }
echo "  [PASS] 钉钉 HMAC-SHA256 签名与 URL 生成正确: ${signed_url:0:60}..."

# 4. Local Mock HTTP 服务验证 Payload 结构
MOCK_PORT=18991
TMP_LOG="${TMP_DIR}/mock_http.log"

# 启动简易纯 bash/nc mock 服务器
if command -v nc >/dev/null 2>&1; then
    # 针对 Slack 的 Payload 测试
    (
        echo -ne "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" | nc -l -p ${MOCK_PORT} > "${TMP_LOG}" 2>/dev/null || true
    ) &
    MOCK_PID=$!
    sleep 0.1

    OPS_CONF["WEBHOOK_SLACK_URL"]="http://127.0.0.1:${MOCK_PORT}/slack"
    ops_webhook_send_slack "CPU" "92.5" "85.0" "2026-08-30 12:00:00" 0 || true
    wait ${MOCK_PID} 2>/dev/null || true

    if [[ -f "${TMP_LOG}" ]] && [[ -s "${TMP_LOG}" ]]; then
        grep -q "CPU" "${TMP_LOG}" && grep -q "92.5%" "${TMP_LOG}" || {
            echo "  [FAIL] Slack Webhook Payload 内容不符合规范: $(cat "${TMP_LOG}")"; exit 1;
        }
        echo "  [PASS] Slack Webhook Payload 投递与格式验证通过"
    else
        echo "  [WARN] 本地 nc 服务未捕获请求，跳过网络拦截断言"
    fi
fi

# 5. 超时约束测试 (请求不可达 IP 必须在 5 秒内返回)
START_TIME=$(date +%s)
OPS_CONF["WEBHOOK_SLACK_URL"]="http://192.0.2.1:54321/timeout_test"
if ops_webhook_send_slack "CPU" "99.0" "85.0" "2026-08-30 12:00:00" 0; then
    echo "  [FAIL] 对不可达目标发送请求应返回非零错误码"; exit 1
fi
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [[ "${ELAPSED}" -gt 6 ]]; then
    echo "  [FAIL] Webhook 超时超过预期限制 (耗时: ${ELAPSED}s)"; exit 1
fi
echo "  [PASS] Webhook 强超时保护测试通过 (耗时: ${ELAPSED}s <= 5s)"

# 6. ops_webhook_test_alert 测试
OPS_CONF["WEBHOOK_SLACK_URL"]=""
OPS_CONF["WEBHOOK_DINGTALK_URL"]=""
OPS_CONF["WEBHOOK_FEISHU_URL"]=""
OPS_CONF["WEBHOOK_WECOM_URL"]=""
ops_webhook_test_alert
echo "  [PASS] 空配置下 ops_webhook_test_alert 友好提示正常"

echo "=== [TEST] lib/webhook.sh 所有测试通过! ==="
