# Agent Cluster 故障排查指南

## 常见问题

### 1. Agent 启动后立即退出

**症状**: tmux 会话创建但马上死亡，日志为空

**可能原因**:
- `CLAUDECODE` 环境变量未 unset
- PATH 中缺少 claude/codex 命令
- 工作目录不存在

**解决**:
```bash
# 检查环境变量
echo $CLAUDECODE
echo $CLAUDE_CODE_ENTRYPOINT

# 检查命令是否存在
which claude codex

# 手动启动测试
cd /home/user/projects/agent-cluster/worktrees/<任务 ID>
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
claude --dangerously-skip-permissions -p "test"
```

---

### 2. monitor-agents 报告"未找到 PR"但 PR 已存在

**症状**: 任务状态为 `pr_created`，但监控脚本说找不到 PR

**可能原因**:
- `get_pr_url` 函数从 git log 提取失败
- gh CLI 未登录或权限不足

**解决**:
```bash
# 手动检查 PR
gh pr view <PR 编号> --json url

# 手动更新任务状态
python3 << 'PYEOF'
import json
with open("tasks/<任务 ID>.json") as f:
    data = json.load(f)
data["prUrl"] = "https://github.com/.../pull/<编号>"
with open("tasks/<任务 ID>.json", "w") as f:
    json.dump(data, f, indent=2)
PYEOF
```

---

### 3. 钉钉通知收不到

**症状**: 脚本执行成功，但钉钉没有消息

**可能原因**:
- Webhook URL 过期或配置错误
- 加签密钥不匹配

**解决**:
```bash
# 测试 webhook
source config.env
curl -X POST "$DINGTALK_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{"msgtype":"text","text":{"content":"测试"}}'

# 检查返回值，errcode 应为 0
```

---

### 4. Git worktree 创建失败

**症状**: `git worktree add` 报错

**可能原因**:
- worktree 目录已存在
- 分支名冲突

**解决**:
```bash
# 清理残留
git worktree prune
rm -rf worktrees/<任务 ID>

# 检查分支
git branch -a | grep <分支名>
git branch -D <分支名>  # 删除冲突分支
```

---

### 5. context-extract 提取 0 条消息

**症状**: 日志显示"提取到 00 条用户消息"

**可能原因**:
- sessions 目录路径变更
- JSONL 格式变化
- 时间过滤逻辑问题

**解决**:
```bash
# 检查 sessions 目录
ls -la /home/user/.openclaw/agents/main/sessions/*.jsonl

# 手动测试提取
grep '"role":"user"' /home/user/.openclaw/agents/main/sessions/*.jsonl | wc -l

# 检查时间戳格式
tail -1 /home/user/.openclaw/agents/main/sessions/*.jsonl | python3 -m json.tool
```

---

### 6. stats.sh 显示成功率 0%

**症状**: 任务统计显示成功率 0%，但实际有完成任务

**可能原因**:
- 任务状态未正确更新为 `done`
- 任务文件 JSON 格式损坏

**解决**:
```bash
# 检查任务状态
jq '.status' tasks/*.json

# 修复损坏的 JSON
python3 -m json.tool tasks/<任务 ID>.json > /dev/null

# 手动更新状态
jq '.status = "done"' tasks/<任务 ID>.json > /tmp/fixed.json
mv /tmp/fixed.json tasks/<任务 ID>.json
```

---

## 实用命令

### 查看所有运行中的 tmux 会话
```bash
tmux -S /tmp/tmux-1000/default list-sessions
```

### 查看 Agent 实时日志
```bash
tail -f /home/user/projects/agent-cluster/logs/<任务 ID>.log
```

### 手动发送指令给 Agent
```bash
tmux -S /tmp/tmux-1000/default send-keys -t agent-<任务 ID> "你的指令" Enter
```

### 强制清理所有资源
```bash
./scripts/run.sh cleanup  # 正常清理
./scripts/run.sh cleanup --dry-run  # 预览
```

### 重置任务状态
```bash
# 删除任务记录（不影响 worktree 和代码）
rm tasks/<任务 ID>.json

# 重新创建任务
./scripts/run.sh launch-agent <任务 ID> <仓库路径> "<描述>"
```

---

## 联系支持

如遇到未列出的问题：
1. 检查日志：`logs/` 目录
2. 查看监控：`./scripts/run.sh status`
3. 查看统计：`./scripts/run.sh stats --all`
