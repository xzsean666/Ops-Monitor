#!/usr/bin/env bash
# ==============================================================================
# tests/test_config_mgr.sh: TASK-002 lib/config_mgr.sh 单元与安全测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_config_$$"
mkdir -p "${TMP_DIR}"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/config_mgr.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/config_mgr.sh"
echo "  [PASS] lib/config_mgr.sh bash -n 语法检查通过"

# 2. 隔离环境变量测试
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_CONFIG_DIR="${TMP_DIR}/config"
export OPS_CONFIG_FILE="${TMP_DIR}/config/ops.conf"
export OPS_DATA_DIR="${TMP_DIR}/data"

# shellcheck source=../lib/config_mgr.sh
source "${BASE_DIR}/lib/config_mgr.sh"

# 3. 默认值读取测试
ops_config_load
cpu_thresh=$(ops_config_get "ALERT_CPU_THRESHOLD")
[[ "${cpu_thresh}" == "85" ]] || { echo "  [FAIL] 默认 ALERT_CPU_THRESHOLD 应为 85, 实际为 '${cpu_thresh}'"; exit 1; }
echo "  [PASS] ops_config_get 默认值读取正确 (${cpu_thresh})"

# 4. 配置修改与校验测试
# 设置合法值
ops_config_set "ALERT_CPU_THRESHOLD" "75" "${OPS_CONFIG_FILE}"
new_val=$(ops_config_get "ALERT_CPU_THRESHOLD")
[[ "${new_val}" == "75" ]] || { echo "  [FAIL] 设置后的值未生效, 实际为 '${new_val}'"; exit 1; }
echo "  [PASS] ops_config_set 合法值修改成功"

# 拦截非法键
if ops_config_set "MALICIOUS_KEY" "123" "${OPS_CONFIG_FILE}" 2>/dev/null; then
    echo "  [FAIL] ops_config_set 未能拦截非法键 MALICIOUS_KEY"; exit 1
fi
echo "  [PASS] ops_config_set 成功拦截非白名单键"

# 拦截数值越界 (CPU 阈值 150%)
if ops_config_set "ALERT_CPU_THRESHOLD" "150" "${OPS_CONFIG_FILE}" 2>/dev/null; then
    echo "  [FAIL] ops_config_set 未能拦截越界数值 150"; exit 1
fi
echo "  [PASS] ops_config_set 成功拦截数值越界"

# 拦截恶意命令注入
if ops_config_set "ALERT_CPU_THRESHOLD" "80; rm -rf /" "${OPS_CONFIG_FILE}" 2>/dev/null; then
    echo "  [FAIL] ops_config_set 未能拦截命令注入字符"; exit 1
fi
echo "  [PASS] ops_config_set 成功防御命令注入参数"

# 5. 权限加固检查 (0600)
if ! ops_check_file_permission "${OPS_CONFIG_FILE}"; then
    echo "  [FAIL] 配置文件 ${OPS_CONFIG_FILE} 权限未达到 0600"; exit 1
fi
echo "  [PASS] 写入后配置文件保持 0600 权限"

# 6. Webhook 脱敏展示测试
ops_config_set "WEBHOOK_DINGTALK_SECRET" "SEC123456789ABCDEF" "${OPS_CONFIG_FILE}"
masked_list=$(ops_config_list 0)
echo "${masked_list}" | grep -q "SEC\*\*\*\*\*\*DEF" || { echo "  [FAIL] 敏感凭据脱敏未按预期展示: ${masked_list}"; exit 1; }
echo "  [PASS] ops_config_list 凭据脱敏掩码验证通过"

# 7. Base64 导出与导入测试
b64_str=$(ops_config_export base64)
[[ -n "${b64_str}" ]] || { echo "  [FAIL] Base64 导出的字符串为空"; exit 1; }
echo "  [PASS] ops_config_export base64 导出成功: ${b64_str:0:30}..."

# 在全新文件上导入
NEW_CONFIG_FILE="${TMP_DIR}/imported_ops.conf"
ops_config_import base64 "${b64_str}" "${NEW_CONFIG_FILE}"
imported_val=$(OPS_CONFIG_FILE="${NEW_CONFIG_FILE}" bash -c "source ${BASE_DIR}/lib/config_mgr.sh && ops_config_get ALERT_CPU_THRESHOLD")
[[ "${imported_val}" == "75" ]] || { echo "  [FAIL] 导入后的配置值不匹配: '${imported_val}'"; exit 1; }
echo "  [PASS] ops_config_import base64 成功还原并生效配置"

# 8. 恶意 Base64 载荷注入测试 (模拟攻击)
ATTACK_PAYLOAD=$(echo -n 'EVIL_KEY="$(touch /tmp/pwned)"' | base64 | tr -d '\n')
if ops_config_import base64 "${ATTACK_PAYLOAD}" "${NEW_CONFIG_FILE}" 2>/dev/null; then
    echo "  [FAIL] 恶意 Base64 导入未被拦截"; exit 1
fi
[[ ! -f "/tmp/pwned" ]] || { echo "  [FAIL] 发现命令注入漏洞: /tmp/pwned 被创建"; rm -f /tmp/pwned; exit 1; }
echo "  [PASS] 恶意 Base64 载荷被安全拦截，无 eval 漏洞"

echo "=== [TEST] lib/config_mgr.sh 所有测试通过! ==="
