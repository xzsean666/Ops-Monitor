#!/usr/bin/env bash
# ==============================================================================
# tests/test_common.sh: TASK-001 lib/common.sh 单元测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# 创建临时测试环境
TMP_TEST_DIR="/tmp/ops_test_common_$$"
mkdir -p "${TMP_TEST_DIR}"

cleanup() {
    rm -rf "${TMP_TEST_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/common.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/common.sh"
echo "  [PASS] lib/common.sh bash -n 语法检查通过"

# 2. Source 测试与路径解析
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_RUN_DIR="${TMP_TEST_DIR}/run"
export OPS_LOCK_FILE="${TMP_TEST_DIR}/ops.lock"
export OPS_DATA_DIR="${TMP_TEST_DIR}/data"

# shellcheck source=../lib/common.sh
source "${BASE_DIR}/lib/common.sh"

[[ "${OPS_VERSION}" == "1.0.0" ]] || { echo "  [FAIL] OPS_VERSION 不匹配"; exit 1; }
[[ -n "${OPS_BASE_DIR}" ]] || { echo "  [FAIL] OPS_BASE_DIR 为空"; exit 1; }
echo "  [PASS] 基本常量与路径推导验证通过 (OPS_BASE_DIR=${OPS_BASE_DIR})"

# 3. 目录创建与权限安全
ops_ensure_dirs
[[ -d "${OPS_CURRENT_DATA_DIR}" ]] || { echo "  [FAIL] OPS_CURRENT_DATA_DIR 未创建"; exit 1; }
[[ -d "${OPS_STATE_DATA_DIR}" ]] || { echo "  [FAIL] OPS_STATE_DATA_DIR 未创建"; exit 1; }
echo "  [PASS] ops_ensure_dirs 目录初始化正常"

# 4. 文件权限校验与修复测试
TEST_SECRET_FILE="${TMP_TEST_DIR}/secret.conf"
echo "KEY=SECRET" > "${TEST_SECRET_FILE}"
chmod 0644 "${TEST_SECRET_FILE}"

if ops_check_file_permission "${TEST_SECRET_FILE}"; then
    echo "  [FAIL] 0644 权限文件未被识别为不安全"; exit 1
fi
echo "  [PASS] ops_check_file_permission 成功拦截宽松权限 (0644)"

ops_secure_file "${TEST_SECRET_FILE}"
if ! ops_check_file_permission "${TEST_SECRET_FILE}"; then
    echo "  [FAIL] ops_secure_file 修复后仍未能通过 0600 校验"; exit 1
fi
echo "  [PASS] ops_secure_file 成功修复权限为 0600"

# 5. 文件排他锁测试 (flock)
if ! ops_lock_acquire 1; then
    echo "  [FAIL] 主进程未能获取文件锁"; exit 1
fi
echo "  [PASS] 主进程成功获取文件锁"

# 子进程尝试非阻塞获取锁应失败
if (
    source "${BASE_DIR}/lib/common.sh"
    ops_lock_acquire 0 2>/dev/null
); then
    echo "  [FAIL] 并发子进程未能被排他锁阻断"; exit 1
else
    echo "  [PASS] 并发子进程被排他锁正确阻断"
fi

ops_lock_release
echo "  [PASS] 主进程成功释放文件锁"

# 6. 默认配置文件检查
[[ -f "${OPS_TEMPLATE_CONFIG}" ]] || { echo "  [FAIL] 缺少默认配置模版 ${OPS_TEMPLATE_CONFIG}"; exit 1; }
grep -q "COLLECT_INTERVAL=" "${OPS_TEMPLATE_CONFIG}" || { echo "  [FAIL] 模版缺少 COLLECT_INTERVAL"; exit 1; }
grep -q "ALERT_CPU_THRESHOLD=" "${OPS_TEMPLATE_CONFIG}" || { echo "  [FAIL] 模版缺少 ALERT_CPU_THRESHOLD"; exit 1; }
grep -q "WEBHOOK_DINGTALK_SECRET=" "${OPS_TEMPLATE_CONFIG}" || { echo "  [FAIL] 模版缺少 WEBHOOK_DINGTALK_SECRET"; exit 1; }
echo "  [PASS] 默认配置模版完整性检查通过"

echo "=== [TEST] lib/common.sh 所有测试通过! ==="
