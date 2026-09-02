#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 统一测试套件运行器 (tests/run_tests.sh)
# 自动执行所有单元测试、Mock 模拟测试与打包全链路验证
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# 终端着色支持
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN="\e[32m"
    C_RED="\e[31m"
    C_YELLOW="\e[33m"
    C_CYAN="\e[36m"
    C_BOLD="\e[1m"
    C_RESET="\e[0m"
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_CYAN=""
    C_BOLD=""
    C_RESET=""
fi

echo -e "${C_BOLD}================================================================================${C_RESET}"
echo -e "${C_BOLD}       Ops-Monitor 自动化测试套件与全链路验证流水线       ${C_RESET}"
echo -e "${C_BOLD}================================================================================${C_RESET}\n"

TEST_FILES=(
    "test_common.sh"
    "test_config_mgr.sh"
    "test_collector.sh"
    "test_storage.sh"
    "test_webhook.sh"
    "test_alert.sh"
    "test_render.sh"
    "test_docker.sh"
    "test_ops_cli.sh"
    "test_packaging.sh"
    "test_daemon_prompt.sh"
    "test_node_mgr.sh"
)

TOTAL_COUNT=${#TEST_FILES[@]}
PASSED_COUNT=0
FAILED_COUNT=0
FAILED_TESTS=()

START_ALL=$(date +%s)

for tfile in "${TEST_FILES[@]}"; do
    tpath="${TEST_DIR}/${tfile}"
    if [[ ! -f "${tpath}" ]]; then
        echo -e "${C_YELLOW}[SKIP] 未找到测试文件: ${tfile}${C_RESET}"
        continue
    fi

    echo -e "${C_CYAN}>>> 正在运行: ${tfile}...${C_RESET}"
    t_start=$(date +%s%N 2>/dev/null || date +%s)
    
    if bash "${tpath}"; then
        t_end=$(date +%s%N 2>/dev/null || date +%s)
        # 计算耗时毫秒
        if [[ ${#t_start} -gt 10 ]]; then
            dur_ms=$(( (t_end - t_start) / 1000000 ))
            echo -e "${C_GREEN}✔ [PASS] ${tfile} (${dur_ms}ms)${C_RESET}\n"
        else
            dur_s=$(( t_end - t_start ))
            echo -e "${C_GREEN}✔ [PASS] ${tfile} (${dur_s}s)${C_RESET}\n"
        fi
        PASSED_COUNT=$(( PASSED_COUNT + 1 ))
    else
        echo -e "${C_RED}✘ [FAIL] ${tfile}${C_RESET}\n"
        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
        FAILED_TESTS+=("${tfile}")
    fi
done

END_ALL=$(date +%s)
TOTAL_DUR=$(( END_ALL - START_ALL ))

echo -e "${C_BOLD}================================================================================${C_RESET}"
echo -e "${C_BOLD}                               测试汇总报告                                     ${C_RESET}"
echo -e "${C_BOLD}================================================================================${C_RESET}"
echo -e "总用例套件: ${TOTAL_COUNT}"
echo -e "成功通过  : ${C_GREEN}${PASSED_COUNT}${C_RESET}"
echo -e "失败用例  : ${C_RED}${FAILED_COUNT}${C_RESET}"
echo -e "总计耗时  : ${TOTAL_DUR} 秒"

if [[ "${FAILED_COUNT}" -eq 0 ]]; then
    echo -e "\n${C_BOLD}${C_GREEN}🎉 全部测试 100% 顺利通过！Ops-Monitor 代码质量符合验收标准。${C_RESET}\n"
    exit 0
else
    echo -e "\n${C_BOLD}${C_RED}❌ 以下测试未通过: ${FAILED_TESTS[*]}${C_RESET}\n"
    exit 1
fi
