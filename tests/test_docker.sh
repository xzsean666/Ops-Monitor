#!/usr/bin/env bash
# ==============================================================================
# tests/test_docker.sh: TASK-013 lib/docker.sh 单元测试与 CLI 模拟测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# 创建临时测试环境
TMP_TEST_DIR="/tmp/ops_test_docker_$$"
mkdir -p "${TMP_TEST_DIR}"

cleanup() {
    rm -rf "${TMP_TEST_DIR}"
}
trap cleanup EXIT

echo "=== [TEST] 开始测试 lib/docker.sh ==="

# 1. 语法检查
bash -n "${BASE_DIR}/lib/docker.sh"
echo "  [PASS] lib/docker.sh bash -n 语法检查通过"

# 2. Source 测试
export OPS_BASE_DIR="${BASE_DIR}"
# shellcheck source=../lib/common.sh
source "${BASE_DIR}/lib/common.sh"
# shellcheck source=../lib/render.sh
source "${BASE_DIR}/lib/render.sh"
# shellcheck source=../lib/docker.sh
source "${BASE_DIR}/lib/docker.sh"

# 3. 未安装 Docker 环境 Mock 测试
output_not_installed=$(OPS_DOCKER_MOCK=not_installed ops_docker_check_environment 2>&1 || true)
if echo "${output_not_installed}" | grep -q "未检测到 Docker 环境 (未安装 Docker)"; then
    echo "  [PASS] 未安装 Docker 环境下友好提示输出正确"
else
    echo "  [FAIL] 未安装 Docker 环境下输出不符合预期: ${output_not_installed}"
    exit 1
fi

# 4. Docker 守护进程未启动 / 权限异常 Mock 测试
output_denied=$(OPS_DOCKER_MOCK=permission_denied ops_docker_check_environment 2>&1 || true)
if echo "${output_denied}" | grep -q "无法连接到 Docker 守护进程"; then
    echo "  [PASS] Docker 服务未运行/无权限状态诊断提示正确"
else
    echo "  [FAIL] Docker 服务未运行/无权限输出不符合预期: ${output_denied}"
    exit 1
fi

# 5. Mock 容器数据解析与表格渲染测试
# 创建 Mock docker 脚本
MOCK_DOCKER_BIN="${TMP_TEST_DIR}/mock_docker"
cat << 'EOF' > "${MOCK_DOCKER_BIN}"
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
    exit 0
elif [[ "$1" == "ps" ]]; then
    echo -e "c101\tweb-frontend\tUp 3 hours\tnginx:alpine"
    echo -e "c102\tapi-backend\tUp 5 hours\tnode:18"
    echo -e "c103\tdb-postgres\tUp 10 hours\tpostgres:15"
    echo -e "c104\told-worker\tExited (0) 2 hours ago\tworker:latest"
elif [[ "$1" == "stats" ]]; then
    echo -e "c101\tweb-frontend\t1.50%\t45.2MiB / 2GiB\t2.21%\t120kB / 85kB\t12MB / 4MB\t8"
    echo -e "c102\tapi-backend\t12.80%\t280.5MiB / 2GiB\t13.70%\t2.4MB / 1.8MB\t45MB / 18MB\t24"
    echo -e "c103\tdb-postgres\t4.20%\t512.0MiB / 4GiB\t12.50%\t850kB / 3.2MB\t120MB / 80MB\t16"
fi
EOF
chmod +x "${MOCK_DOCKER_BIN}"

output_stats=$(OPS_DOCKER_CMD="${MOCK_DOCKER_BIN}" ops_docker_show_overview)
if echo "${output_stats}" | grep -q "web-frontend" && \
   echo "${output_stats}" | grep -q "api-backend" && \
   echo "${output_stats}" | grep -q "db-postgres" && \
   echo "${output_stats}" | grep -q "Docker CPU 总计: 18.50%" && \
   echo "${output_stats}" | grep -q "3 运行中 / 1 已停止 / 共 4 个容器"; then
    echo "  [PASS] Mock 容器数据与统计汇总指标计算正确"
else
    echo "  [FAIL] Mock 容器表格渲染或汇总不符合预期:"
    echo "${output_stats}"
    exit 1
fi

# 6. Mock 0 个容器场景测试
MOCK_DOCKER_EMPTY="${TMP_TEST_DIR}/mock_docker_empty"
cat << 'EOF' > "${MOCK_DOCKER_EMPTY}"
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
    exit 0
fi
EOF
chmod +x "${MOCK_DOCKER_EMPTY}"

output_empty=$(OPS_DOCKER_CMD="${MOCK_DOCKER_EMPTY}" ops_docker_show_overview)
if echo "${output_empty}" | grep -q "0 运行中 / 共 0 个容器"; then
    echo "  [PASS] 0 个容器场景下友好提示输出正确"
else
    echo "  [FAIL] 0 个容器场景输出不符合预期: ${output_empty}"
    exit 1
fi

# 7. CLI 命令与别名测试
output_cli_docker=$(bash "${BASE_DIR}/ops.sh" docker -h)
if echo "${output_cli_docker}" | grep -q "ops docker" && echo "${output_cli_docker}" | grep -q "ops ps"; then
    echo "  [PASS] ops docker -h 帮助信息与别名文档正常"
else
    echo "  [FAIL] ops docker -h 输出不符合预期"
    exit 1
fi

echo "=== [TEST] lib/docker.sh 所有测试通过! ==="
