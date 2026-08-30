# TASK-011: 自动化测试套件与全链路验证

## Objective
构建 Ops-Monitor 的自动化测试框架与全链路验证流水线，包括针对各子模块的单元测试、Mock procfs 虚拟环境测试、CLI 交互行为测试、以及打包安装与升级全生命周期端到端测试。

## Scope
- 编写测试运行器 `tests/run_tests.sh`
- 编写各模块单元测试：
  - `tests/test_common.sh`：基础库、锁、权限与路径
  - `tests/test_config_mgr.sh`：配置 CRUD、Base64 导入导出、安全性注入防护
  - `tests/test_collector.sh`：真实及 Mock procfs 指标计算精度
  - `tests/test_storage.sh`：TSV 追加、并发锁、轮转与 tar.gz 归档
  - `tests/test_webhook.sh`：Payload 格式化、DingTalk HMAC 签名验证、超时
  - `tests/test_alert.sh`：告警状态机跃迁、防抖与冷却
  - `tests/test_render.sh`：Sparklines 映射与 24h ASCII 历史图表重采样
  - `tests/test_ops_cli.sh`：CLI 子命令分发与帮助文档
  - `tests/test_packaging.sh`：Debian 包打包解包结构校验
- 实现全自动化 CI 测试指令

## Allowed Files
- `tests/run_tests.sh`
- `tests/test_*.sh`
- `tests/mock_proc/` (Mock 虚拟数据)

## Dependencies
- TASK-001 ~ TASK-010

## Inputs and Outputs
- **Inputs**: 整个代码库及测试用例
- **Outputs**: 测试结果输出报告、返回码 0 (全部通过) 或非 0 (存在失败用例)

## Acceptance Criteria
1. 执行 `bash tests/run_tests.sh` 能够并发或顺序执行所有子测试并统一汇总。
2. 在没有任何外部环境干扰下测试用例 100% 通过。
3. 覆盖正常流程与典型异常边界场景（如除零、缺失网卡、恶意输入、并发锁冲突）。

## Verification Commands
```bash
bash tests/run_tests.sh
```

## Risks and Assumptions
- 测试脚本均使用纯 Bash 编写，保持零外部依赖。

## Status
DONE
