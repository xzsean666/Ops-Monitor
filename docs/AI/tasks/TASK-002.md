# TASK-002: 配置管理引擎 (lib/config_mgr.sh)

## Objective
实现 Ops-Monitor 的配置管理核心模块 `lib/config_mgr.sh`，支持配置按优先级加载、参数 CRUD、白名单有效性校验、0600 权限强制修复、以及无 `eval` 注入风险的 Base64 导入导出。

## Scope
- 实现配置加载优先级链：`CLI Flags > ~/.ops.conf > /etc/ops-monitor/ops.conf > /opt/ops-monitor/config/ops.conf > config/ops.conf.default`
- 实现配置读写函数：`ops_config_get`, `ops_config_set`, `ops_config_list`
- 实现参数校验器（数值范围检查、URL 合法性检查、合法键白名单）
- 实现 Base64 编码导出与导入安全解析（使用 `awk`/`sed` 严格清洗，杜绝 `eval`）
- 敏感配置（如 Webhook Token / Secret）脱敏掩码输出

## Allowed Files
- `lib/config_mgr.sh`
- `tests/test_config_mgr.sh`

## Dependencies
- TASK-001: 项目骨架与公共基础库

## Inputs and Outputs
- **Inputs**: 命令行参数、配置文件路径、Base64 字符串、键值对
- **Outputs**: 标准化内存变量、生效的 `ops.conf` 文件、脱敏的文本输出或 Base64 密文

## Acceptance Criteria
1. `ops_config_get <KEY>` 正确返回对应值；未设置时回退至默认配置。
2. `ops_config_set <KEY> <VAL>` 仅允许修改白名单内的有效键，且数值必须在合法范围（如阈值 1-100）。
3. 配置文件写入后自动执行 `chmod 600`。
4. `ops config export --base64` 输出去除注释与空行的 Base64 串；`ops config import --base64` 能够安全解码、校验并原子替换配置文件。
5. 带有恶意的输入（如包含 `; rm -rf /` 或 `$(...)` 的字符串）在导入和设置时被严格拒绝或安全转义。

## Verification Commands
```bash
bash -n lib/config_mgr.sh
bash tests/test_config_mgr.sh
```

## Risks and Assumptions
- 假定系统中安装有 `base64` 命令（GNU coreutils 标配）。

## Status
DONE
