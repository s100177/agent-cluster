# Agent Cluster

自动化 Agent 集群管理系统

## 已安装 Agent

| Agent | 版本 | 用途 |
|-------|------|------|
| claude-code | latest | 前端/git 操作/速度优先（默认） |
| codex | latest | 后端/复杂逻辑/多文件重构 |
| gemini-cli | 0.32.1 | UI 设计/HTML/CSS 规范 |

## 快速开始

```bash
# 启动一个 Agent
./scripts/run.sh launch-agent <任务 ID> <仓库路径> "<任务描述>" [agent 类型]

# 查看状态
./scripts/run.sh status

# 手动触发早间扫描
./scripts/run.sh morning-scan

# 手动触发晚间扫描
./scripts/run.sh evening-scan

# 手动触发上下文提炼
./scripts/run.sh context-extract
```

## 仓库地址

https://github.com/s100177/agent-cluster
