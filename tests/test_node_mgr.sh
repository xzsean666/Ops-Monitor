#!/usr/bin/env bash
# ==============================================================================
# tests/test_node_mgr.sh: 远程 SSH 节点管理模块测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TMP_DIR="/tmp/ops_test_nodes_$$"
mkdir -p "${TMP_DIR}/config"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/node_mgr.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/node_mgr.sh"
echo "  [PASS] lib/node_mgr.sh bash -n 语法检查通过"

# 2. 隔离环境变量
export OPS_BASE_DIR="${BASE_DIR}"
export OPS_CONFIG_DIR="${TMP_DIR}/config"
export OPS_NODES_FILE="${TMP_DIR}/config/nodes.conf"

# shellcheck source=../lib/node_mgr.sh
source "${BASE_DIR}/lib/node_mgr.sh"

# 3. 注册节点测试 (标准格式)
ops_node_add "aws-prod" root@35.78.207.248 -i ~/ssh/sean -p 22 --no-deploy

[[ -f "${OPS_NODES_FILE}" ]] || { echo "  [FAIL] 节点配置文件未生成: ${OPS_NODES_FILE}"; exit 1; }
grep -q "^aws-prod|root@35.78.207.248|" "${OPS_NODES_FILE}" || {
    echo "  [FAIL] 节点记录不匹配: $(cat "${OPS_NODES_FILE}")"; exit 1;
}
echo "  [PASS] 标准格式节点注册成功"

# 4. 注册节点测试 (完整 ssh 命令格式)
ops_node_add "hk-server" "ssh -i /path/to/key -p 2222 ubuntu@1.2.3.4" --no-deploy
grep -q "^hk-server|ubuntu@1.2.3.4|" "${OPS_NODES_FILE}" || {
    echo "  [FAIL] SSH 命令格式节点解析失败: $(cat "${OPS_NODES_FILE}")"; exit 1;
}
echo "  [PASS] SSH 完整命令格式节点注册解析成功"

# 5. 权限加固检查 (0600)
if ! ops_check_file_permission "${OPS_NODES_FILE}"; then
    echo "  [FAIL] nodes.conf 文件权限未达到 0600"; exit 1;
fi
echo "  [PASS] nodes.conf 保持 0600 安全权限"

# 6. 列出节点
list_out=$(ops_node_list)
echo "${list_out}" | grep -q "aws-prod" || { echo "  [FAIL] ops_node_list 缺少 aws-prod"; exit 1; }
echo "${list_out}" | grep -q "hk-server" || { echo "  [FAIL] ops_node_list 缺少 hk-server"; exit 1; }
echo "  [PASS] ops_node_list 列表格式化正常"

# 8. 上下文切换测试 (ops_node_use & ops_node_get_active)
[[ "$(ops_node_get_active)" == "local" ]] || { echo "  [FAIL] 初始状态 active node 应为 local"; exit 1; }
ops_node_use "aws-prod"
[[ "$(ops_node_get_active)" == "aws-prod" ]] || { echo "  [FAIL] ops_node_use 切换到 aws-prod 失败"; exit 1; }
ops_node_use "local"
[[ "$(ops_node_get_active)" == "local" ]] || { echo "  [FAIL] ops_node_use 切换回 local 失败"; exit 1; }
echo "  [PASS] ops_node_use 上下文切换测试通过"

# 9. 免起名自动命名测试
ops_node_add root@8.8.8.8 -i /path/key --no-deploy
grep -q "^node-8-8-8-8|root@8.8.8.8|" "${OPS_NODES_FILE}" || {
    echo "  [FAIL] 免起名自动生成别名失败: $(cat "${OPS_NODES_FILE}")"; exit 1;
}
echo "  [PASS] 免起名自动推导命名测试通过"

# 10. ops.sh CLI 路由测试
cli_out=$(bash "${BASE_DIR}/ops.sh" node list)
echo "${cli_out}" | grep -q "aws-prod" || { echo "  [FAIL] ops node list CLI 输出异常"; exit 1; }
cli_use=$(bash "${BASE_DIR}/ops.sh" current)
echo "${cli_use}" | grep -q "local" || { echo "  [FAIL] ops current CLI 输出异常"; exit 1; }
echo "  [PASS] ops node / ops use / ops current 命令行路由测试通过"

# 11. ops update 语法及逻辑测试
bash -n "${BASE_DIR}/ops.sh"
echo "  [PASS] ops update / ops node update-all 语法检查通过"

echo "=== [TEST] lib/node_mgr.sh 所有测试通过! ==="
