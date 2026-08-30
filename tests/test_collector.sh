#!/usr/bin/env bash
# ==============================================================================
# tests/test_collector.sh: TASK-003 lib/collector.sh 单元与 Mock 测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_collector_$$"
mkdir -p "${TMP_DIR}/mock_proc/net"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/collector.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/collector.sh"
echo "  [PASS] lib/collector.sh bash -n 语法检查通过"

# 2. 真实系统真实 procfs 采集测试
source "${BASE_DIR}/lib/collector.sh"

metrics_line=$(ops_collect_metrics 0.2)
echo "  [INFO] 真实采集输出: ${metrics_line}"
fields_count=$(echo "${metrics_line}" | awk -F'\t' '{print NF}')
[[ "${fields_count}" -eq 6 ]] || { echo "  [FAIL] 指标列数应为 6, 实际为 ${fields_count}"; exit 1; }

IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${metrics_line}"
[[ "${ts}" =~ ^[0-9]+$ ]] || { echo "  [FAIL] 时间戳非整数: '${ts}'"; exit 1; }
[[ "${cpu}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "  [FAIL] CPU 百分比格式错误: '${cpu}'"; exit 1; }
[[ "${mem}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "  [FAIL] 内存百分比格式错误: '${mem}'"; exit 1; }
[[ "${disk}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "  [FAIL] 磁盘百分比格式错误: '${disk}'"; exit 1; }
[[ "${rx}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "  [FAIL] RX 格式错误: '${rx}'"; exit 1; }
[[ "${tx}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "  [FAIL] TX 格式错误: '${tx}'"; exit 1; }
echo "  [PASS] 真实 procfs 采集数据格式与列值校验通过"

# 3. 命令行模式测试 (--json, --kv)
json_out=$(bash "${BASE_DIR}/lib/collector.sh" --json 0.1)
echo "${json_out}" | grep -q '"cpu_usage_pct":' || { echo "  [FAIL] --json 输出格式异常: ${json_out}"; exit 1; }
echo "  [PASS] --json 格式化输出正常"

kv_out=$(bash "${BASE_DIR}/lib/collector.sh" --kv 0.1)
echo "${kv_out}" | grep -q 'CPU_USAGE_PCT=' || { echo "  [FAIL] --kv 输出格式异常: ${kv_out}"; exit 1; }
echo "  [PASS] --kv 格式化输出正常"

# 4. Mock procfs 场景模拟测试
export OPS_PROC_ROOT="${TMP_DIR}/mock_proc"

# 4.1 Mock 内存计算: MemTotal=1000000 kB, MemAvailable=250000 kB -> Usage = 75.0%
cat << 'EOF' > "${OPS_PROC_ROOT}/meminfo"
MemTotal:        1000000 kB
MemFree:          100000 kB
MemAvailable:     250000 kB
Buffers:           50000 kB
Cached:           100000 kB
EOF

mock_mem=$(ops_collect_mem)
[[ "${mock_mem}" == "75.0" ]] || { echo "  [FAIL] Mock 内存计算错误, 期望 75.0, 实际 '${mock_mem}'"; exit 1; }
echo "  [PASS] Mock 内存计算精准度验证通过 (75.0%)"

# 4.2 Mock CPU 计算: Total delta = 1000, Idle delta = 200 -> CPU% = 80.0%
cat << 'EOF' > "${OPS_PROC_ROOT}/stat"
cpu  1000 0 0 1000 0 0 0 0 0 0
EOF

# 异步在 0.1 秒后写入第二点数据
(
    sleep 0.05
    cat << 'EOF' > "${OPS_PROC_ROOT}/stat"
cpu  1800 0 0 1200 0 0 0 0 0 0
EOF
) &

mock_cpu=$(ops_collect_cpu 0.1)
[[ "${mock_cpu}" == "80.0" ]] || { echo "  [FAIL] Mock CPU 计算错误, 期望 80.0, 实际 '${mock_cpu}'"; exit 1; }
echo "  [PASS] Mock CPU 计算精准度验证通过 (80.0%)"

# 4.3 Mock 网络计算: RX delta = 1048576 (1MB over 0.1s -> 10240.0 KB/s)
cat << 'EOF' > "${OPS_PROC_ROOT}/net/dev"
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 999999        0    0    0    0     0          0         0   999999        0    0    0    0     0       0          0
  eth0: 1000000       0    0    0    0     0          0         0  1000000        0    0    0    0     0       0          0
EOF

(
    sleep 0.05
    cat << 'EOF' > "${OPS_PROC_ROOT}/net/dev"
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 999999        0    0    0    0     0          0         0   999999        0    0    0    0     0       0          0
  eth0: 2048576       0    0    0    0     0          0         0  1524288        0    0    0    0     0       0          0
EOF
) &

mock_net=$(ops_collect_net 0.1)
mock_rx=$(echo "${mock_net}" | awk '{print $1}')
mock_tx=$(echo "${mock_net}" | awk '{print $2}')
[[ "${mock_rx}" == "10240.0" ]] || { echo "  [FAIL] Mock 网络 RX 计算错误, 期望 10240.0, 实际 '${mock_rx}'"; exit 1; }
[[ "${mock_tx}" == "5120.0" ]] || { echo "  [FAIL] Mock 网络 TX 计算错误, 期望 5120.0, 实际 '${mock_tx}'"; exit 1; }
echo "  [PASS] Mock 网络 RX/TX 计算精准度验证通过 (RX: 10240.0 KB/s, TX: 5120.0 KB/s)"

echo "=== [TEST] lib/collector.sh 所有测试通过! ==="
