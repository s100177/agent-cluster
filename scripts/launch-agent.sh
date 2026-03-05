#!/usr/bin/env bash
# launch-agent.sh - 启动一个 Agent（git worktree + tmux + 任务记录）
# 用法: ./launch-agent.sh <任务ID> <仓库路径> <任务描述> [agent类型] [模型]
# 示例: ./launch-agent.sh feat-login /home/user/projects/myapp "实现登录功能" claude-code

set -uo pipefail  # 去掉 -e，改用显式错误检查，避免 git 操作失败时脚本静默退出

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"
WORKTREES_DIR="$CLUSTER_DIR/worktrees"
LOGS_DIR="$CLUSTER_DIR/logs"
source "$CLUSTER_DIR/scripts/lib/json.sh"

# 参数
TASK_ID="${1:-}"
REPO_PATH="${2:-}"
DESCRIPTION="${3:-}"
AGENT="${4:-claude-code}"   # claude-code | codex | gemini
MODEL="${5:-}"               # 留空则用默认

if [[ -z "$TASK_ID" || -z "$REPO_PATH" || -z "$DESCRIPTION" ]]; then
  echo "用法: $0 <任务ID> <仓库路径> <任务描述> [agent] [模型]"
  echo ""
  echo "Agent 类型:"
  echo "  claude-code  - 前端/git操作/速度优先 (默认)"
  echo "  codex        - 后端/复杂逻辑/多文件重构"
  echo "  gemini       - UI设计/HTML/CSS规范"
  exit 1
fi

if [[ ! -d "$REPO_PATH" ]]; then
  echo "错误: 仓库路径不存在: $REPO_PATH"
  exit 1
fi

TASK_FILE="$TASKS_DIR/${TASK_ID}.json"
if [[ -f "$TASK_FILE" ]]; then
  STATUS=$(jq_sanitize_file "$TASK_FILE" -r '.status' || echo "")
  if [[ "$STATUS" == "running" ]]; then
    echo "错误: 任务 $TASK_ID 已在运行中"
    exit 1
  fi
fi

# 确定模型
if [[ -z "$MODEL" ]]; then
  case "$AGENT" in
    codex)       MODEL="gpt-5.3-codex" ;;
    gemini)      MODEL="gemini-2.0-flash" ;;
    claude-code) MODEL="claude-sonnet-4-6" ;;
    *)           MODEL="claude-sonnet-4-6" ;;
  esac
fi

BRANCH="feat/${TASK_ID}"
WORKTREE_PATH="$WORKTREES_DIR/${TASK_ID}"
TMUX_SESSION="agent-${TASK_ID}"
LOG_FILE="$LOGS_DIR/${TASK_ID}.log"
STARTED_AT=$(date +%s%3N)

echo "============================================"
echo "启动 Agent: $TASK_ID"
echo "描述: $DESCRIPTION"
echo "Agent: $AGENT ($MODEL)"
echo "仓库: $REPO_PATH"
echo "分支: $BRANCH"
echo "Worktree: $WORKTREE_PATH"
echo "============================================"

# 1. 创建 git worktree（隔离的分支环境）
if [[ -d "$WORKTREE_PATH" ]]; then
  echo "清理已存在的 worktree..."
  git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || rm -rf "$WORKTREE_PATH"
fi

# 分支已存在时先删除（可能是上次失败残留）
if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "删除残留分支: $BRANCH"
  git -C "$REPO_PATH" branch -D "$BRANCH"
fi

echo "创建 git worktree..."
if ! git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$BRANCH" origin/main 2>/dev/null; then
  if ! git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$BRANCH" HEAD; then
    echo "错误: 无法创建 git worktree，请检查仓库状态"
    exit 1
  fi
fi

# 2. 记录任务 JSON（用 python 做 JSON 转义，避免控制字符/引号导致 jq 解析失败）
python3 - "$TASK_FILE" "$TASK_ID" "$TMUX_SESSION" "$AGENT" "$MODEL" "$DESCRIPTION" "$REPO_PATH" "$WORKTREE_PATH" "$BRANCH" "$STARTED_AT" "$LOG_FILE" <<'PY'
import json
import sys

(
    task_file,
    task_id,
    tmux_session,
    agent,
    model,
    description,
    repo,
    worktree,
    branch,
    started_at,
    log_file,
) = sys.argv[1:]

data = {
    "id": task_id,
    "tmuxSession": tmux_session,
    "agent": agent,
    "model": model,
    "description": description,
    "repo": repo,
    "worktree": worktree,
    "branch": branch,
    "startedAt": int(started_at),
    "status": "running",
    "retries": 0,
    "prUrl": None,
    "ciStatus": None,
    "notifyOnComplete": True,
    "log": log_file,
}

with open(task_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "任务记录已保存: $TASK_FILE"

# 3. 构建 Agent 启动命令
build_agent_cmd() {
  local worktree="$1"
  local description="$2"
  local agent="$3"

  case "$agent" in
    claude-code)
      echo "claude --dangerously-skip-permissions -p $(printf '%q' "$description")"
      ;;
    codex)
      # codex 不支持 -p 参数，prompt 直接跟在后面
      echo "codex $(printf '%q' "$description")"
      ;;
    gemini)
      echo "gemini-cli -p $(printf '%q' "$description")"
      ;;
    *)
      echo "claude --dangerously-skip-permissions -p $(printf '%q' "$description")"
      ;;
  esac
}

AGENT_CMD=$(build_agent_cmd "$WORKTREE_PATH" "$DESCRIPTION" "$AGENT")

# 4. 启动 tmux 会话，在 worktree 目录中运行 Agent
# 注意：必须 unset CLAUDECODE，否则 claude 拒绝在嵌套会话中启动
TMUX_SOCKET="/tmp/tmux-$(id -u)/default"
echo "启动 tmux 会话: $TMUX_SESSION"
tmux -S "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" \
  -c "$WORKTREE_PATH" \
  "exec bash -c 'unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; export PATH=\"$PATH\"; echo \"[$(date)] 启动 Agent: $DESCRIPTION\" | tee -a $LOG_FILE; $AGENT_CMD 2>&1 | tee -a $LOG_FILE; echo \"[$(date)] Agent 退出: \$?\" >> $LOG_FILE'"

echo ""
echo "Agent 已启动!"
echo "查看实时日志: tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION"
echo "发送指令:     tmux -S $TMUX_SOCKET send-keys -t $TMUX_SESSION '你的指令' Enter"
echo "查看日志文件: tail -f $LOG_FILE"
echo ""
