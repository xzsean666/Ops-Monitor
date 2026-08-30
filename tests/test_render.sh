#!/usr/bin/env bash
# ==============================================================================
# tests/test_render.sh: TASK-007 lib/render.sh 字符渲染引擎测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_render_$$"
mkdir -p "${TMP_DIR}/data/current"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/render.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/render.sh"
echo "  [PASS] lib/render.sh bash -n 语法检查通过"

# 2. 隔离环境变量
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_DATA_DIR="${TMP_DIR}/data"
export OPS_CURRENT_DATA_DIR="${TMP_DIR}/data/current"

# shellcheck source=../lib/render.sh
source "${BASE_DIR}/lib/render.sh"

# 3. 进度条渲染测试
bar_50=$(ops_render_progress_bar 50.0 10 0)
[[ "${bar_50}" =~ █████░░░░░ ]] || { echo "  [FAIL] 50% 进度条渲染不匹配: ${bar_50}"; exit 1; }
echo "  [PASS] 进度条 50% 渲染测试通过"

# 4. Sparkline 渲染测试
spark_out=$(ops_render_sparkline "0 15 30 45 60 75 90 100" 0 100 0)
echo "  [INFO] Sparkline 输出: ${spark_out}"
[[ -n "${spark_out}" ]] || { echo "  [FAIL] Sparkline 输出为空"; exit 1; }

# 全 0 与全相同边界
spark_zero=$(ops_render_sparkline "0 0 0 0" 0 100 0)
[[ -n "${spark_zero}" ]] || { echo "  [FAIL] 全 0 Sparkline 处理异常"; exit 1; }
echo "  [PASS] Sparkline 正常及边界序列映射测试通过"

# 5. 24h 历史 ASCII 大图渲染测试
today=$(date +%Y%m%d)
target_tsv="${OPS_CURRENT_DATA_DIR}/metrics_${today}.tsv"

# 生成模拟时序数据 (从 00:00 到 23:59 模拟 100 个点)
echo -e "${OPS_TSV_HEADER}" > "${target_tsv}"
for i in {1..100}; do
    cpu_sim=$(awk -v idx="$i" 'BEGIN { print int(20 + 60 * sin(idx / 10.0)) }')
    if [[ "${cpu_sim}" -lt 0 ]]; then cpu_sim=5; fi
    echo -e "1719705${i}0\t${cpu_sim}.0\t60.0\t45.0\t100.0\t50.0" >> "${target_tsv}"
done

chart_out=$(ops_render_history_chart "cpu" "today" 80 10)
echo "${chart_out}" | grep -q "CPU 负载使用率历史" || { echo "  [FAIL] 历史大图标题缺失"; exit 1; }
echo "${chart_out}" | grep -q "100%" || { echo "  [FAIL] 历史大图 Y 轴标尺缺失 100%"; exit 1; }
echo "${chart_out}" | grep -q "00:00" || { echo "  [FAIL] 历史大图 X 轴时间刻度缺失 00:00"; exit 1; }
echo "${chart_out}" | grep -q "24:00" || { echo "  [FAIL] 历史大图 X 轴时间刻度缺失 24:00"; exit 1; }
echo "  [PASS] 24 小时历史大图坐标系与曲线渲染测试通过"

# 6. 单次紧凑体检卡片测试
status_card=$(ops_render_status_card "1719705600	45.2	68.4	52.0	120.5	45.2")
echo "${status_card}" | grep -q "Ops-Monitor 服务器健康体检报告" || { echo "  [FAIL] 体检报告卡片头部缺失"; exit 1; }
echo "${status_card}" | grep -q "CPU  使用率:" || { echo "  [FAIL] 体检卡片 CPU 指标缺失"; exit 1; }
echo "  [PASS] 紧凑健康体检报告卡片渲染测试通过"

echo "=== [TEST] lib/render.sh 所有测试通过! ==="
