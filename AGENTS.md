# AI Agent 项目开发规范与工作流

本文档是 AI 辅助开发与工程代理（Engineering Agent）在本项目中工作的事实来源与行为准则。

## 1. 核心工作原则
1. **单任务聚焦**：一次只处理一个 Goal 和一个当前 Task。一个 session 默认最多完成一个 Task。
2. **严格范围限制**：不实现当前 Task 之外的功能，不修改与任务无关的文件。
3. **保护用户资产**：不删除、覆盖或回滚用户已有修改；不执行 reset、checkout、递归删除等破坏性操作；不主动提交、推送或发布生产环境。
4. **最小依赖原则**：保持 Ops-Monitor 原生 POSIX/Bash 零运行时依赖设计；不随意引入重型第三方包。
5. **实证驱动**：所有结论与报告必须基于实际文件读取或实际运行命令的结果，未运行的测试不得声称通过。
6. **发现额外工作**：记录为新 Task（写入 `docs/AI/TASK_INDEX.md`），不在当前 Task 中顺带实现。

---

## 2. 事实来源 (Single Source of Truth)
- 项目规则：`AGENTS.md`
- 总目标与产品定义：`docs/AI/GOAL.md`
- 架构设计说明书：`docs/AI/ARCHITECTURE.md`
- 架构决策记录：`docs/AI/DECISIONS.md`
- 任务索引与依赖图：`docs/AI/TASK_INDEX.md`
- 当前会话状态：`docs/AI/SESSION_STATE.md`
- 具体任务卡：`docs/AI/tasks/TASK-xxx.md`

---

## 3. Session 启动与执行流
1. **环境与状态检查**：确认当前位于项目根目录，检查 `git status --short`。
2. **读取核心文档**：按顺序读取 `GOAL.md`、`TASK_INDEX.md`、`SESSION_STATE.md`。
3. **选定任务**：优先恢复 `IN_PROGRESS` 任务；若无，选择第一个依赖满足的 `TODO` 任务。
4. **输出修改前计划**：
   - Request Type
   - Goal
   - Current Behavior
   - Current Task
   - Dependencies
   - Files To Read / Modify / Create
   - Implementation Approach
   - Acceptance Criteria
   - Verification Method
   - Risks and Assumptions
5. **编码实现**：遵循 POSIX/Bash 编码规范、权限隔离（0600）、非侵入式 procfs 解析、轻量级与错误处理要求。
6. **验证执行**：执行测试脚本或验证命令，记录实际输出。
7. **更新状态与交接**：更新 `SESSION_STATE.md` 及对应 `TASK-xxx.md` 状态，按标准交接模板输出结果。
