#!/usr/bin/env bash
# ==============================================================================
# tests/test_ops_cli.sh: TASK-008 ops.sh CLI 入口与子命令分发测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_cli_$$"
mkdir -p "${TMP_DIR}/config" "${TMP_DIR}/data"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 ops.sh 主入口 ==="

# 1. 语法检查
bash -n "${BASE_DIR}/ops.sh"
echo "  [PASS] ops.sh bash -n 语法检查通过"

# 2. 帮助与版本信息
help_out=$(bash "${BASE_DIR}/ops.sh" --help)
echo "${help_out}" | grep -q "Ops-Monitor v" || { echo "  [FAIL] --help 输出缺少版本标题"; exit 1; }
echo "${help_out}" | grep -q "ops dashboard" || { echo "  [FAIL] --help 输出缺少 dashboard 子命令"; exit 1; }
echo "  [PASS] ops --help 帮助文档输出正常"

ver_out=$(bash "${BASE_DIR}/ops.sh" -v)
echo "${ver_out}" | grep -q "Ops-Monitor v1.0.0" || { echo "  [FAIL] -v 输出版本不匹配: ${ver_out}"; exit 1; }
echo "  [PASS] ops -v 版本号输出正常"

# 3. ops status 单次体检测试
export OPS_CONFIG_FILE="${TMP_DIR}/config/ops.conf"
export OPS_DATA_DIR="${TMP_DIR}/data"
touch "${OPS_CONFIG_FILE}"

status_out=$(bash "${BASE_DIR}/ops.sh" status)
echo "${status_out}" | grep -q "Ops-Monitor 服务器健康体检报告" || { echo "  [FAIL] ops status 输出异常: ${status_out}"; exit 1; }
echo "  [PASS] ops status 执行正常"

# 4. ops history 历史大图测试
history_out=$(bash "${BASE_DIR}/ops.sh" history cpu)
echo "${history_out}" | grep -q "CPU 负载使用率历史" || { echo "  [FAIL] ops history cpu 输出异常: ${history_out}"; exit 1; }
echo "  [PASS] ops history cpu 执行正常"

# 5. ops config 配置管理测试
bash "${BASE_DIR}/ops.sh" config set ALERT_CPU_THRESHOLD 78
val_out=$(bash "${BASE_DIR}/ops.sh" config get ALERT_CPU_THRESHOLD)
[[ "${val_out}" == "78" ]] || { echo "  [FAIL] ops config get 不等于设置的 78: ${val_out}"; exit 1; }
echo "  [PASS] ops config set/get 路由测试通过"

list_out=$(bash "${BASE_DIR}/ops.sh" config list)
echo "${list_out}" | grep -q "ALERT_CPU_THRESHOLD" || { echo "  [FAIL] ops config list 输出缺失"; exit 1; }
echo "  [PASS] ops config list 输出测试通过"

b64_out=$(bash "${BASE_DIR}/ops.sh" config export --base64)
[[ -n "${b64_out}" ]] || { echo "  [FAIL] ops config export --base64 结果为空"; exit 1; }
echo "  [PASS] ops config export --base64 测试通过"

# 6. ops archive 归档测试
archive_out=$(bash "${BASE_DIR}/ops.sh" archive --run 2>&1)
echo "${archive_out}" | grep -q "手动归档执行完成" || { echo "  [FAIL] ops archive --run 输出异常: ${archive_out}"; exit 1; }
echo "  [PASS] ops archive --run 执行正常"

echo "=== [TEST] ops.sh 所有测试通过! ==="
