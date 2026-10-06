#!/usr/bin/env bash
# ==============================================================================
# tests/test_service_health.sh: lib/service_health.sh 业务服务健康探活与自愈测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_srv_health_$$"
mkdir -p "${TMP_DIR}/state"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/service_health.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/service_health.sh"
echo "  [PASS] lib/service_health.sh bash -n 语法检查通过"

# 2. 隔离环境变量与测试目录
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_SERVICE_STATE_FILE="${TMP_DIR}/state/service_health.state"

# shellcheck source=../lib/service_health.sh
source "${BASE_DIR}/lib/service_health.sh"

# Mock Webhook 广播计数器与自愈命令执行记录
SERVICE_WEBHOOK_CALLS=0
LAST_SERVICE_RECOVERED=0
LAST_SERVICE_NAME=""
LAST_SERVICE_CODE=""

ops_webhook_broadcast_service() {
    SERVICE_WEBHOOK_CALLS=$(( SERVICE_WEBHOOK_CALLS + 1 ))
    LAST_SERVICE_NAME="$1"
    LAST_SERVICE_CODE="$3"
    LAST_SERVICE_RECOVERED="${5:-0}"
    echo "  [MOCK_WEBHOOK] 服务通知触发: 服务=$1, URL=$2, Code=$3, 恢复=$LAST_SERVICE_RECOVERED"
}

RESTART_CMD_TRIGGER_COUNT=0
mock_restart_command() {
    RESTART_CMD_TRIGGER_COUNT=$(( RESTART_CMD_TRIGGER_COUNT + 1 ))
    echo "  [MOCK_RESTART] 执行自愈动作 (次数: ${RESTART_CMD_TRIGGER_COUNT})"
}

# 3. 正常服务探活测试 (使用 mock curl 模拟 200 OK)
# 重载 curl 模拟健康服务
curl() {
    echo "200"
}

ops_service_health_check_one "Test-Service-A" "http://127.0.0.1:8080/health" "mock_restart_command" 2 10 2

_ops_service_load_state
key=$(_ops_service_sanitize_key "Test-Service-A")
state="${OPS_SERVICE_STATE[${key}_STATE]:-}"
[[ "${state}" == "NORMAL" ]] || { echo "  [FAIL] 初始探测 200 应为 NORMAL 状态, 实际: ${state}"; exit 1; }
[[ "${SERVICE_WEBHOOK_CALLS}" -eq 0 ]] || { echo "  [FAIL] 正常服务不应触发 Webhook"; exit 1; }
[[ "${RESTART_CMD_TRIGGER_COUNT}" -eq 0 ]] || { echo "  [FAIL] 正常服务不应触发自愈重启"; exit 1; }
echo "  [PASS] 正常服务探活测试通过 (状态: NORMAL, 无告警无重启)"

# 4. 单次失败防抖测试 (返回 000 错误，连续阈值为 2)
curl() {
    echo "000"
}

ops_service_health_check_one "Test-Service-A" "http://127.0.0.1:8080/health" "mock_restart_command" 2 10 2
_ops_service_load_state
state="${OPS_SERVICE_STATE[${key}_STATE]:-}"
fail_count="${OPS_SERVICE_STATE[${key}_FAIL_COUNT]:-0}"
[[ "${state}" == "SUSPECTED" ]] || { echo "  [FAIL] 首次失败应为 SUSPECTED 状态, 实际: ${state}"; exit 1; }
[[ "${fail_count}" -eq 1 ]] || { echo "  [FAIL] 首次失败计数应为 1, 实际: ${fail_count}"; exit 1; }
[[ "${SERVICE_WEBHOOK_CALLS}" -eq 0 ]] || { echo "  [FAIL] 防抖期内不应触发 Webhook"; exit 1; }
[[ "${RESTART_CMD_TRIGGER_COUNT}" -eq 0 ]] || { echo "  [FAIL] 防抖期内不应触发自愈重启"; exit 1; }
echo "  [PASS] 单次探活失败防抖测试通过 (状态: SUSPECTED, 计数: 1/2, 未触发告警与自愈)"

# 5. 连续失败达到阈值测试 (再次失败 -> 触发告警并执行自愈动作)
ops_service_health_check_one "Test-Service-A" "http://127.0.0.1:8080/health" "mock_restart_command" 2 10 2
_ops_service_load_state
state="${OPS_SERVICE_STATE[${key}_STATE]:-}"
[[ "${state}" == "COOLDOWN" ]] || { echo "  [FAIL] 连续超限应进入 COOLDOWN 状态, 实际: ${state}"; exit 1; }
[[ "${SERVICE_WEBHOOK_CALLS}" -eq 1 ]] || { echo "  [FAIL] 连续超限应触发 1 次 Webhook, 实际: ${SERVICE_WEBHOOK_CALLS}"; exit 1; }
[[ "${LAST_SERVICE_RECOVERED}" -eq 0 ]] || { echo "  [FAIL] 告警类型应为 0 (故障告警)"; exit 1; }
[[ "${RESTART_CMD_TRIGGER_COUNT}" -eq 1 ]] || { echo "  [FAIL] 应执行 1 次自愈重启命令, 实际: ${RESTART_CMD_TRIGGER_COUNT}"; exit 1; }
echo "  [PASS] 连续探测失败触发告警与自愈执行成功 (状态: COOLDOWN, 告警发送, 重启执行)"

# 6. 冷却期静默抑制测试 (处于 COOLDOWN 中再次探测失败，不应重复触发重启)
ops_service_health_check_one "Test-Service-A" "http://127.0.0.1:8080/health" "mock_restart_command" 2 10 2
[[ "${SERVICE_WEBHOOK_CALLS}" -eq 1 ]] || { echo "  [FAIL] 冷却期内不应重复发送 Webhook"; exit 1; }
[[ "${RESTART_CMD_TRIGGER_COUNT}" -eq 1 ]] || { echo "  [FAIL] 冷却期内不应重复执行自愈动作"; exit 1; }
echo "  [PASS] 冷却期静默抑制验证通过 (防止高频重启死循环)"

# 7. 服务恢复测试 (探测恢复为 200 OK -> 发送恢复通知并重置为 NORMAL)
curl() {
    echo "200"
}
ops_service_health_check_one "Test-Service-A" "http://127.0.0.1:8080/health" "mock_restart_command" 2 10 2
_ops_service_load_state
state="${OPS_SERVICE_STATE[${key}_STATE]:-}"
[[ "${state}" == "NORMAL" ]] || { echo "  [FAIL] 恢复后应为 NORMAL 状态, 实际: ${state}"; exit 1; }
[[ "${SERVICE_WEBHOOK_CALLS}" -eq 2 ]] || { echo "  [FAIL] 恢复时应触发恢复通知"; exit 1; }
[[ "${LAST_SERVICE_RECOVERED}" -eq 1 ]] || { echo "  [FAIL] 恢复通知标志应为 1, 实际: ${LAST_SERVICE_RECOVERED}"; exit 1; }
echo "  [PASS] 服务恢复正常并发送恢复通知测试通过"

# 8. 多服务配置解析测试 (ops_service_health_evaluate_all)
OPS_CONF["SERVICE_HEALTH_CHECKS"]="Srv1|http://127.0.0.1:8001/health|echo r1;Srv2|http://127.0.0.1:8002/health|echo r2"
ops_service_health_evaluate_all
_ops_service_load_state
k1=$(_ops_service_sanitize_key "Srv1")
k2=$(_ops_service_sanitize_key "Srv2")
[[ -n "${OPS_SERVICE_STATE[${k1}_STATE]:-}" ]] || { echo "  [FAIL] Srv1 状态未保存"; exit 1; }
[[ -n "${OPS_SERVICE_STATE[${k2}_STATE]:-}" ]] || { echo "  [FAIL] Srv2 状态未保存"; exit 1; }
echo "  [PASS] 多服务分号/换行分隔配置全量解析测试通过"

# 9. CLI 输出测试
ops_service_health_cli >/dev/null
echo "  [PASS] ops_service_health_cli 格式化输出正常"

echo "=== [TEST] lib/service_health.sh 所有测试通过! ==="
