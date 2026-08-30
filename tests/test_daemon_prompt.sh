#!/usr/bin/env bash
# ==============================================================================
# tests/test_daemon_prompt.sh: TASK-009 守护进程与 SSH 探针测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_daemon_$$"
mkdir -p "${TMP_DIR}/config" "${TMP_DIR}/data"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试守护进程与 SSH 探针 ==="

# 1. 语法检查
bash -n "${BASE_DIR}/systemd/ops-prompt.sh"
echo "  [PASS] systemd/ops-prompt.sh bash -n 语法检查通过"

# 2. 非交互模式 100% 静默测试 (模拟 SCP/SFTP/远程管道)
prompt_output=$(echo "" | bash "${BASE_DIR}/systemd/ops-prompt.sh" 2>&1)
[[ -z "${prompt_output}" ]] || { echo "  [FAIL] 非交互终端下探针输出了非空内容: '${prompt_output}'"; exit 1; }
echo "  [PASS] 非交互终端环境下探针 100% 静默验证通过"

# 3. 忽略标记 (~/.ops_ignore) 抑制测试
export HOME="${TMP_DIR}/fake_home"
mkdir -p "${HOME}"
touch "${HOME}/.ops_ignore"

ignore_output=$(bash -c "TERM=xterm source ${BASE_DIR}/systemd/ops-prompt.sh" 2>&1 || true)
[[ -z "${ignore_output}" ]] || { echo "  [FAIL] 存在 ~/.ops_ignore 时探针仍输出内容: '${ignore_output}'"; exit 1; }
echo "  [PASS] ~/.ops_ignore 抑制机制验证通过"

# 4. systemd 服务单元语法与参数检查
SERVICE_FILE="${BASE_DIR}/systemd/ops-daemon.service"
[[ -f "${SERVICE_FILE}" ]] || { echo "  [FAIL] 缺少 systemd 服务文件: ${SERVICE_FILE}"; exit 1; }
grep -q "ExecStart=" "${SERVICE_FILE}" || { echo "  [FAIL] 缺少 ExecStart 声明"; exit 1; }
grep -q "Restart=always" "${SERVICE_FILE}" || { echo "  [FAIL] 缺少 Restart=always 声明"; exit 1; }
grep -q "LimitNOFILE=65535" "${SERVICE_FILE}" || { echo "  [FAIL] 缺少 LimitNOFILE 声明"; exit 1; }
echo "  [PASS] ops-daemon.service 服务单元结构检查通过"

# 5. ops cron-run 单周期全链路调度测试
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_CONFIG_FILE="${TMP_DIR}/config/ops.conf"
export OPS_DATA_DIR="${TMP_DIR}/data"
export OPS_LOCK_FILE="${TMP_DIR}/ops.lock"
touch "${OPS_CONFIG_FILE}"

bash "${BASE_DIR}/ops.sh" cron-run

today=$(date +%Y%m%d)
target_tsv="${OPS_DATA_DIR}/current/metrics_${today}.tsv"
[[ -f "${target_tsv}" ]] || { echo "  [FAIL] cron-run 未能生成当日 TSV 数据: ${target_tsv}"; exit 1; }

lines_count=$(wc -l < "${target_tsv}")
[[ "${lines_count}" -ge 2 ]] || { echo "  [FAIL] TSV 文件中未写入指标数据 (行数: ${lines_count})"; exit 1; }
echo "  [PASS] ops cron-run 全链路单步调度落盘验证通过"

echo "=== [TEST] 守护进程与 SSH 探针所有测试通过! ==="
