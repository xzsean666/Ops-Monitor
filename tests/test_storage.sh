#!/usr/bin/env bash
# ==============================================================================
# tests/test_storage.sh: TASK-004 lib/storage.sh 单元与归档测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_storage_$$"
mkdir -p "${TMP_DIR}/data/current" "${TMP_DIR}/archive"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/storage.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/storage.sh"
echo "  [PASS] lib/storage.sh bash -n 语法检查通过"

# 2. 隔离环境变量
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_DATA_DIR="${TMP_DIR}/data"
export OPS_CURRENT_DATA_DIR="${TMP_DIR}/data/current"
export OPS_LOCK_FILE="${TMP_DIR}/storage.lock"

# shellcheck source=../lib/storage.sh
source "${BASE_DIR}/lib/storage.sh"

# 3. 基础写入与自动表头测试
today=$(date +%Y%m%d)
target_tsv="${OPS_CURRENT_DATA_DIR}/metrics_${today}.tsv"

line1="1719705600	12.4	64.8	48.0	128.5	45.2"
ops_storage_append "${line1}"

[[ -f "${target_tsv}" ]] || { echo "  [FAIL] 目标 TSV 未创建: ${target_tsv}"; exit 1; }

first_line=$(head -n 1 "${target_tsv}")
echo "${first_line}" | grep -q "^#timestamp" || { echo "  [FAIL] TSV 表头缺失: ${first_line}"; exit 1; }
echo "  [PASS] TSV 表头自动创建正常"

line2="1719705660	15.1	65.0	48.0	340.2	112.8"
ops_storage_append "${line2}"

total_lines=$(wc -l < "${target_tsv}")
[[ "${total_lines}" -eq 3 ]] || { echo "  [FAIL] 行数应为 3 (1 表头 + 2 数据), 实际为 ${total_lines}"; exit 1; }
echo "  [PASS] TSV 追加写入正常"

# 4. 数据读取函数测试
records=$(ops_storage_read_records "today" 10)
records_count=$(echo "${records}" | wc -l)
[[ "${records_count}" -eq 2 ]] || { echo "  [FAIL] 读取有效记录行数不为 2: ${records_count}"; exit 1; }
echo "${records}" | grep -q "^#" && { echo "  [FAIL] ops_storage_read_records 未能过滤表头注释"; exit 1; }
echo "  [PASS] ops_storage_read_records 数据提取正常"

# 5. 并发安全测试 (10 个并行进程同时写入)
for i in {1..10}; do
    (
        ops_storage_append "1719705700	${i}.0	50.0	40.0	10.0	10.0"
    ) &
done
wait

total_after_concurrent=$(wc -l < "${target_tsv}")
[[ "${total_after_concurrent}" -eq 13 ]] || { echo "  [FAIL] 并发写入后行数不匹配: ${total_after_concurrent}"; exit 1; }
echo "  [PASS] 10 个并发进程同时写入未发生竞争与丢失 (总行数: 13)"

# 6. 跨天归档与压缩测试
OLD_DATE="20260101"
OLD_TSV="${OPS_CURRENT_DATA_DIR}/metrics_${OLD_DATE}.tsv"
echo -e "${OPS_TSV_HEADER}\n1767225600\t10.0\t20.0\t30.0\t40.0\t50.0" > "${OLD_TSV}"

# 设置归档配置
OPS_CONF["ARCHIVE_DIR"]="${TMP_DIR}/archive"
ops_storage_archive 0

ARCHIVE_TAR="${TMP_DIR}/archive/metrics_${OLD_DATE}.tar.gz"
[[ -f "${ARCHIVE_TAR}" ]] || { echo "  [FAIL] 归档压缩包未生成: ${ARCHIVE_TAR}"; exit 1; }
[[ ! -f "${OLD_TSV}" ]] || { echo "  [FAIL] 归档后原始 TSV 文件未删除"; exit 1; }

# 验证压缩包完整性与解压内容
tar -tzf "${ARCHIVE_TAR}" | grep -q "metrics_${OLD_DATE}.tsv" || { echo "  [FAIL] 压缩包内文件损坏或丢失"; exit 1; }
echo "  [PASS] 历史指标成功打包压缩为 tar.gz 并释放原目录"

# 7. 无归档目录时的过期清理测试
OLD_DATE_2="20260102"
OLD_TSV_2="${OPS_CURRENT_DATA_DIR}/metrics_${OLD_DATE_2}.tsv"
echo -e "${OPS_TSV_HEADER}\n1767312000\t10.0\t20.0\t30.0\t40.0\t50.0" > "${OLD_TSV_2}"

OPS_CONF["ARCHIVE_DIR"]=""
ops_storage_archive 0
[[ ! -f "${OLD_TSV_2}" ]] || { echo "  [FAIL] 无归档目录时旧文件未被清理"; exit 1; }
echo "  [PASS] 无归档目录时旧文件安全清理测试通过"

echo "=== [TEST] lib/storage.sh 所有测试通过! ==="
