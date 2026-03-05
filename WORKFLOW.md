# Agent 集群工作流规范

## 总体架构

```
用户（钉钉）
    ↓ 下达需求
OpenClaw（编排层）
    ↓ 分析 → 拆解 → 选 Agent → 构建 prompt
launch-agent.sh
    ↓ git worktree + tmux
Claude Code / Codex（执行层）
    ↓ 开发 → 提交 → 推送 → 创建 PR
GitHub CI/CD
    ↓ lint → 类型检查 → 单元测试 → E2E
monitor-agents.sh（每10分钟）
    ↓ CI 全绿
钉钉通知 → 用户 Review → 合并
```

---

## 分支生命周期

```
origin/main
    │
    ├─ git worktree add → feat/xxx（隔离环境）
    │       │
    │       ├─ commit: feat(xxx): 实现 A
    │       ├─ commit: test(xxx): 补充测试
    │       ├─ commit: fix(xxx): 修复边界情况
    │       │
    │       ├─ git rebase origin/main（同步主干）
    │       ├─ git push
    │       └─ gh pr create --fill
    │
    │  [CI 通过 + 人工 Review]
    │
    └─ Squash Merge → main（一个功能一个 commit）
         │
         └─ cleanup.sh（删除 worktree + tmux 会话）
```

---

## OpenClaw 编排决策树

### 收到新需求时

```
收到需求
    │
    ├─ 是否有足够上下文？
    │       ├─ 否 → 向用户追问，不要猜
    │       └─ 是 ↓
    │
    ├─ 拆解任务（一个 PR = 一件事）
    │       ├─ 大需求 → 拆成多个独立任务，并行启动多个 Agent
    │       └─ 小需求 → 单个 Agent
    │
    ├─ 选择 Agent 类型
    │       ├─ 后端/复杂逻辑/多文件 → codex
    │       ├─ 前端/简单改动/git操作 → claude-code
    │       └─ UI设计/HTML/CSS → gemini
    │
    └─ 启动：launch-agent.sh
```

### 监控阶段（每10分钟）

```
monitor-agents.sh
    │
    ├─ tmux 存活？
    │       ├─ 否，且无 PR → 重试（最多3次，每次动态调整 prompt）
    │       ├─ 否，但有 PR → 标记 pr_created，继续检查 CI
    │       └─ 是 → 继续
    │
    ├─ PR 已创建？
    │       ├─ 否 → 等待（Agent 还在开发）
    │       └─ 是 ↓
    │
    ├─ CI 状态？
    │       ├─ pending → 等待
    │       ├─ success → 标记 ready，钉钉通知用户
    │       └─ failure → 告知 Agent 修复 CI，重试计数+1
    │
    └─ 超过最大重试 → 标记 failed，钉钉通知用户介入
```

### 人工 Review 阶段

```
收到钉钉通知「PR 可以 Review」
    │
    ├─ 快速检查（5分钟内）：
    │       ├─ CI 全绿？（看 GitHub Actions）
    │       ├─ PR 描述完整？（做了什么 / 为什么 / 测试方法）
    │       ├─ 有 UI 改动 → 必须有截图
    │       └─ 改动范围合理？（不能一个 PR 改几十个文件）
    │
    ├─ 深度 Review（如需要）：
    │       ├─ 核心逻辑是否正确
    │       ├─ 有无安全漏洞（SQL注入/未授权访问）
    │       └─ 有无性能隐患（N+1 查询/大循环）
    │
    ├─ 通过 → Squash Merge（保持 main 历史干净）
    │
    └─ 打回 → 钉钉告诉 OpenClaw 问题，OpenClaw 发指令给 Agent
               tmux send-keys -t "agent-xxx" "修复：[具体问题]" Enter
```

---

## 推送决策（Agent 视角）

| 场景 | 操作 |
|------|------|
| 完成一个逻辑单元，测试通过 | `git push` |
| 任务完成，准备 PR | `git rebase origin/main && git push && gh pr create --fill` |
| review 反馈已修复 | `git push`（不要 amend，新建 commit） |
| rebase 之后 | `git push --force-with-lease`（仅此场景允许） |
| 代码跑不起来 | **不推送** |
| 有调试代码残留 | **不推送** |
| 要推 main | **禁止** |

---

## 合并决策（人工视角）

| 条件 | 操作 |
|------|------|
| CI 全绿 + Review 通过 | Squash Merge → 删除分支 |
| CI 失败 | 打回 Agent 修复，不合并 |
| PR 描述不完整 | 要求补充，不合并 |
| 有 UI 改动但无截图 | 打回，必须附截图 |
| 改动超出任务范围 | 拆分 PR，不合并 |
| 有未解决的讨论 | 解决后再合并 |

**合并命令（人工执行）：**
```bash
gh pr merge <PR编号> --squash --delete-branch
```

---

## 并行任务管理

可以同时运行多个 Agent，注意：

- **相互独立的任务**：完全并行，各自 worktree 互不干扰
- **有依赖的任务**：先完成被依赖的任务，合并后再启动下一个
- **修改同一文件的任务**：串行执行，避免冲突
- **RAM 限制**：每个 Agent 约占 400-700MB，根据机器内存控制并行数量

```bash
# 查看当前并行 Agent 数量
/home/user/projects/agent-cluster/scripts/run.sh status
```

---

## 异常处理

### Agent 走偏了方向

```bash
# 不需要重启，直接发指令纠正
tmux send-keys -t "agent-<任务ID>" "停一下。[纠正内容]" Enter
```

### CI 反复失败

1. 查看 CI 日志：`gh run view --log`
2. 判断是 Agent 的问题还是环境问题
3. 如果是环境问题（如缺少 secret），人工处理，不算 Agent 失败

### 分支冲突

```bash
# 帮 Agent 解决冲突
cd /home/user/projects/agent-cluster/worktrees/<任务ID>
git fetch origin
git rebase origin/main
# 解决冲突...
git rebase --continue
git push --force-with-lease
```

### 紧急回滚

```bash
# 如果错误的代码合并进了 main
git revert <commit-hash>     # 生成回滚 commit
git push origin main         # 需要临时关闭分支保护
# 或者直接 revert PR：
gh pr revert <PR编号>
```
