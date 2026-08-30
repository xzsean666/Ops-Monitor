#!/usr/bin/env bash
# ==============================================================================
# tests/test_packaging.sh: TASK-010 Debian 打包与部署工具链测试
# ==============================================================================
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${TEST_DIR}/.." && pwd)"

echo "=== [TEST] 开始测试 Debian 打包与部署脚本 ==="

# 1. 语法检查
bash -n "${BASE_DIR}/build-deb.sh" "${BASE_DIR}/install.sh" "${BASE_DIR}/uninstall.sh"
echo "  [PASS] build-deb.sh / install.sh / uninstall.sh bash -n 语法检查通过"

# 2. 执行打包构建
bash "${BASE_DIR}/build-deb.sh"

TARGET_DEB="${BASE_DIR}/dist/ops-monitor_1.0.0_all.deb"
[[ -f "${TARGET_DEB}" ]] || { echo "  [FAIL] 未找到打包产物: ${TARGET_DEB}"; exit 1; }
[[ -s "${TARGET_DEB}" ]] || { echo "  [FAIL] 打包产物大小为 0: ${TARGET_DEB}"; exit 1; }
echo "  [PASS] Debian 安装包构建成功: $(ls -lh "${TARGET_DEB}" | awk '{print $5, $9}')"

# 3. 检查包内文件结构与目录清单
if command -v dpkg-deb >/dev/null 2>&1; then
    contents=$(dpkg-deb -c "${TARGET_DEB}")
    
    echo "${contents}" | grep -q "./opt/ops-monitor/ops.sh" || { echo "  [FAIL] 包内缺少 /opt/ops-monitor/ops.sh"; exit 1; }
    echo "${contents}" | grep -q "./opt/ops-monitor/lib/common.sh" || { echo "  [FAIL] 包内缺少 lib/common.sh"; exit 1; }
    echo "${contents}" | grep -q "./etc/ops-monitor/ops.conf" || { echo "  [FAIL] 包内缺少 /etc/ops-monitor/ops.conf"; exit 1; }
    echo "${contents}" | grep -q "./etc/profile.d/ops-prompt.sh" || { echo "  [FAIL] 包内缺少 SSH 探针"; exit 1; }
    echo "  [PASS] 包内文件目录结构检查通过"

    # 4. 检查控制信息与 conffiles 保护
    info_output=$(dpkg-deb -I "${TARGET_DEB}")
    echo "${info_output}" | grep -q "Package: ops-monitor" || { echo "  [FAIL] control 元数据 Package 字段异常"; exit 1; }
    echo "${info_output}" | grep -q "Version: 1.0.0" || { echo "  [FAIL] control 元数据 Version 字段异常"; exit 1; }

    # 检查 conffiles 是否声明保护
    dpkg_conffiles=$(dpkg-deb -e "${TARGET_DEB}" /tmp/deb_control_$$ && cat /tmp/deb_control_$$/conffiles && rm -rf /tmp/deb_control_$$)
    echo "${dpkg_conffiles}" | grep -q "/etc/ops-monitor/ops.conf" || {
        echo "  [FAIL] conffiles 缺少 /etc/ops-monitor/ops.conf 配置文件保护声明"; exit 1;
    }
    echo "  [PASS] Debian conffiles 配置文件无损升级保护验证通过"
fi

echo "=== [TEST] Debian 打包与部署工具链所有测试通过! ==="
