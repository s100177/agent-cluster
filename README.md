# Agent Cluster

自动化 Agent 集群管理系统

## 已安装 Agent

| Agent | 版本 | 用途 |
|-------|------|------|
| claude-code | latest | 前端/git 操作/速度优先（默认） |
| codex | latest | 后端/复杂逻辑/多文件重构 |
| gemini-cli | 0.32.1 | UI 设计/HTML/CSS 规范 |

## 快速开始

### 启动 Agent
```bash
# 启动一个 Agent
./scripts/run.sh launch-agent <任务 ID> <仓库路径> "<任务描述>" [agent 类型]

# 示例
./scripts/run.sh launch-agent feat-login /home/user/projects/myapp "实现登录功能" claude-code
```

### 查看状态
```bash
# 查看所有 Agent 状态
./scripts/run.sh status

# 查看统计报表
./scripts/run.sh stats --all
./scripts/run.sh stats --today
./scripts/run.sh stats --week
```

### 清理资源
```bash
# 清理僵尸资源（tmux/worktree/日志/旧任务）
./scripts/run.sh cleanup

# 预览清理（不实际删除）
./scripts/run.sh cleanup --dry-run
```

### 自动化扫描
```bash
# 手动触发早间扫描（GitHub Issues）
./scripts/run.sh morning-scan

# 手动触发晚间扫描（文档更新）
./scripts/run.sh evening-scan

# 手动触发上下文提炼（钉钉消息→MEMORY.md）
./scripts/run.sh context-extract
```

### 监控与干预
```bash
# 手动触发监控（通常由 cron 每 10 分钟执行）
./scripts/run.sh monitor-agents

# 查看实时日志
tail -f logs/<任务 ID>.log

# 发送指令给运行中的 Agent
tmux -S /tmp/tmux-1000/default send-keys -t agent-<任务 ID> "你的指令" Enter
```

## 文档

- [WORKFLOW.md](WORKFLOW.md) - 完整工作流规范
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - 故障排查指南

## 仓库地址

https://github.com/s100177/agent-cluster

## 核心特性

- ✅ **git worktree 隔离** - 每个任务独立分支，互不干扰
- ✅ **tmux 会话管理** - 后台运行，可随时干预
- ✅ **自动监控重试** - 10 分钟轮询，失败自动重试（最多 3 次）
- ✅ **双重 Code Review** - Qwen3-Coder API + Claude Code PTY
- ✅ **钉钉通知** - 任务启动/完成/失败自动通知
- ✅ **业务上下文注入** - 钉钉消息自动提炼到 MEMORY.md
- ✅ **统计报表** - 任务统计/成本估算/执行时长
