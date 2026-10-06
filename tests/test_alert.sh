#!/usr/bin/env bash
# ==============================================================================
# tests/test_alert.sh: TASK-006 lib/alert.sh 告警状态机与防抖测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_alert_$$"
mkdir -p "${TMP_DIR}/state"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/alert.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/alert.sh"
echo "  [PASS] lib/alert.sh bash -n 语法检查通过"

# 2. 隔离环境变量与 Mock Webhook
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_ALERT_STATE_FILE="${TMP_DIR}/state/alert.state"
mkdir -p "${TMP_DIR}/config"
cp "${BASE_DIR}/config/ops.conf.default" "${TMP_DIR}/config/ops.conf"
export OPS_CONFIG_FILE="${TMP_DIR}/config/ops.conf"

# shellcheck source=../lib/alert.sh
source "${BASE_DIR}/lib/alert.sh"

# Mock Webhook 广播计数器
WEBHOOK_CALL_COUNT=0
LAST_WEBHOOK_TYPE=0 # 0=告警, 1=恢复
ops_webhook_broadcast() {
    WEBHOOK_CALL_COUNT=$(( WEBHOOK_CALL_COUNT + 1 ))
    LAST_WEBHOOK_TYPE="${5:-0}"
    echo "  [MOCK_WEBHOOK] 触发通知: 指标=$1, 当前值=$2, 阈值=$3, 恢复=$LAST_WEBHOOK_TYPE"
}

# 配置: CPU 阈值 85%, 需连续 3 次触发, 冷却 30 分钟
OPS_CONF["ALERT_CPU_THRESHOLD"]="85"
OPS_CONF["ALERT_CPU_CONSECUTIVE"]="3"
OPS_CONF["ALERT_MEM_THRESHOLD"]="90"
OPS_CONF["ALERT_DISK_THRESHOLD"]="85"
OPS_CONF["ALERT_COOLDOWN_MINUTES"]="30"

# 3. 测试单次毛刺防抖 (第 1 次超限 -> SUSPECTED, 未告警)
ops_alert_evaluate_all "90.0" "50.0" "40.0" 1000
status1=$(ops_alert_get_overall_status)
[[ "${status1}" == "WARN" ]] || { echo "  [FAIL] 首次超限应为 WARN 状态, 实际: ${status1}"; exit 1; }
[[ "${WEBHOOK_CALL_COUNT}" -eq 0 ]] || { echo "  [FAIL] 首次超限不应触发 Webhook"; exit 1; }
echo "  [PASS] 单次毛刺防抖成功 (状态: WARN, Webhook 未触发)"

# 4. 指标回落测试 (第 2 次正常 -> 重置回 NORMAL)
ops_alert_evaluate_all "40.0" "50.0" "40.0" 1060
status2=$(ops_alert_get_overall_status)
[[ "${status2}" == "NORMAL" ]] || { echo "  [FAIL] 指标回落应为 NORMAL 状态, 实际: ${status2}"; exit 1; }
[[ "${WEBHOOK_CALL_COUNT}" -eq 0 ]] || { echo "  [FAIL] 毛刺回落不应触发恢复 Webhook"; exit 1; }
echo "  [PASS] 状态机成功回落重置 (状态: NORMAL)"

# 5. 连续 3 次超限测试 (第 1 次 -> SUSPECTED, 第 2 次 -> SUSPECTED, 第 3 次 -> COOLDOWN + Webhook)
ops_alert_evaluate_all "92.0" "50.0" "40.0" 2000 # 次数 1
[[ "${WEBHOOK_CALL_COUNT}" -eq 0 ]] || { echo "  [FAIL] 第 1 次超限不应触发"; exit 1; }

ops_alert_evaluate_all "95.0" "50.0" "40.0" 2060 # 次数 2
[[ "${WEBHOOK_CALL_COUNT}" -eq 0 ]] || { echo "  [FAIL] 第 2 次超限不应触发"; exit 1; }

ops_alert_evaluate_all "96.0" "50.0" "40.0" 2120 # 次数 3 (触发告警)
[[ "${WEBHOOK_CALL_COUNT}" -eq 1 ]] || { echo "  [FAIL] 连续 3 次超限应触发 Webhook (当前次数: ${WEBHOOK_CALL_COUNT})"; exit 1; }
status3=$(ops_alert_get_overall_status)
[[ "${status3}" == "CRITICAL" ]] || { echo "  [FAIL] 触发告警后应为 CRITICAL 状态, 实际: ${status3}"; exit 1; }
echo "  [PASS] 连续 3 次超限成功触发告警 (状态: CRITICAL, Webhook 触发 1 次)"

# 6. 冷却期静默测试 (第 4 次仍超限，但在 30 分钟内 -> 抑制报警)
ops_alert_evaluate_all "98.0" "50.0" "40.0" 2180 # 仅过去 60 秒
[[ "${WEBHOOK_CALL_COUNT}" -eq 1 ]] || { echo "  [FAIL] 冷却期内不应重复触发 Webhook"; exit 1; }
echo "  [PASS] 冷却期内静默抑制测试通过"

# 7. 冷却期满再次超限测试 (过去 31 分钟 -> 再次触发告警)
ops_alert_evaluate_all "99.0" "50.0" "40.0" 4000 # 过去 1880 秒 (> 1800 秒)
[[ "${WEBHOOK_CALL_COUNT}" -eq 2 ]] || { echo "  [FAIL] 冷却期结束后超限应再次触发 Webhook (当前次数: ${WEBHOOK_CALL_COUNT})"; exit 1; }
echo "  [PASS] 冷却期结束后持续超限再次告警测试通过"

# 8. 恢复测试 (指标降至 30% -> 发送恢复通知)
ops_alert_evaluate_all "30.0" "50.0" "40.0" 4060
[[ "${WEBHOOK_CALL_COUNT}" -eq 3 ]] || { echo "  [FAIL] 恢复正常后应发送恢复通知 (当前次数: ${WEBHOOK_CALL_COUNT})"; exit 1; }
[[ "${LAST_WEBHOOK_TYPE}" -eq 1 ]] || { echo "  [FAIL] 恢复通知标志应为 1"; exit 1; }
status_final=$(ops_alert_get_overall_status)
[[ "${status_final}" == "NORMAL" ]] || { echo "  [FAIL] 恢复后状态应为 NORMAL"; exit 1; }
echo "  [PASS] 指标恢复正常并成功发送恢复通知 (状态: NORMAL)"

# 9. 网络流量超限告警测试 (NET_RX 阈值 50 MB/s, 连续 2 次)
OPS_CONF["ALERT_NET_RX_THRESHOLD_MB"]="50"
OPS_CONF["ALERT_NET_CONSECUTIVE"]="2"
# 60000 KB/s ≈ 58.59 MB/s > 50 MB/s
ops_alert_evaluate_all "10.0" "20.0" "30.0" "60000" "1000" 5000
[[ "${WEBHOOK_CALL_COUNT}" -eq 3 ]] || { echo "  [FAIL] 网络首次超限不应触发"; exit 1; }
ops_alert_evaluate_all "10.0" "20.0" "30.0" "60000" "1000" 5060
[[ "${WEBHOOK_CALL_COUNT}" -eq 4 ]] || { echo "  [FAIL] 网络连续 2 次超限应触发 Webhook (当前次数: ${WEBHOOK_CALL_COUNT})"; exit 1; }
echo "  [PASS] 网络入站流量超限告警触发测试通过"

# 10. 测试 ops_alert_cli 统一管理与概览
alert_out=$(ops_alert_cli show)
[[ "${alert_out}" =~ "Ops-Monitor 告警中心与阈值状态" ]] || { echo "  [FAIL] ops_alert_cli 概览输出不匹配"; exit 1; }
[[ "${alert_out}" =~ "CPU 使用率" ]] || { echo "  [FAIL] 概览应包含 CPU 指标"; exit 1; }
echo "  [PASS] ops_alert_cli 概览卡片输出测试通过"

# 11. 测试 ops_alert_cli set 设置与快捷语法
ops_alert_cli set cpu 88 >/dev/null
[[ "$(ops_config_get 'ALERT_CPU_THRESHOLD')" == "88" ]] || { echo "  [FAIL] ops alert set cpu 失败"; exit 1; }

ops_alert_cli mem 79 >/dev/null
[[ "$(ops_config_get 'ALERT_MEM_THRESHOLD')" == "79" ]] || { echo "  [FAIL] ops alert mem 快捷设置失败"; exit 1; }

ops_alert_cli cooldown 25 >/dev/null
[[ "$(ops_config_get 'ALERT_COOLDOWN_MINUTES')" == "25" ]] || { echo "  [FAIL] ops alert cooldown 快捷设置失败"; exit 1; }

ops_alert_cli webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=test" "SECRET123" >/dev/null
[[ "$(ops_config_get 'WEBHOOK_DINGTALK_SECRET')" == "SECRET123" ]] || { echo "  [FAIL] ops alert webhook 钉钉加签设置失败"; exit 1; }
echo "  [PASS] ops_alert_cli 阈值与 Webhook 极简设置测试通过"

echo "=== [TEST] lib/alert.sh 所有测试通过! ==="
