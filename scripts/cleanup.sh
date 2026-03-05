#!/usr/bin/env bash
# cleanup.sh - 清理已完成任务的 worktree 和 tmux 会话
# 用法: ./cleanup.sh [任务ID]  （不传则清理所有已完成任务）

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"
ARCHIVE_DIR="$CLUSTER_DIR/tasks/archive"

mkdir -p "$ARCHIVE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cleanup_task() {
  local task_file="$1"
  local task_id status worktree tmux_session repo

  task_id=$(jq -r '.id' "$task_file")
  status=$(jq -r '.status' "$task_file")
  worktree=$(jq -r '.worktree' "$task_file")
  tmux_session=$(jq -r '.tmuxSession' "$task_file")
  repo=$(jq -r '.repo' "$task_file")

  log "清理任务: $task_id (状态: $status)"

  # 杀死 tmux 会话
  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux -S /tmp/tmux-1000/default kill-session -t "$tmux_session"
    log "  已关闭 tmux 会话: $tmux_session"
  fi

  # 移除 git worktree
  if [[ -d "$worktree" ]]; then
    if [[ -d "$repo/.git" ]]; then
      git -C "$repo" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
    else
      rm -rf "$worktree"
    fi
    log "  已移除 worktree: $worktree"
  fi

  # 归档任务记录
  local archive_file="$ARCHIVE_DIR/${task_id}-$(date +%Y%m%d%H%M%S).json"
  mv "$task_file" "$archive_file"
  log "  任务已归档: $archive_file"
}

# 确定要清理的任务
if [[ -n "${1:-}" ]]; then
  # 清理指定任务
  task_file="$TASKS_DIR/${1}.json"
  if [[ ! -f "$task_file" ]]; then
    echo "任务不存在: $1"
    exit 1
  fi
  cleanup_task "$task_file"
else
  # 清理所有已完成/失败任务
  cleaned=0
  for task_file in "$TASKS_DIR"/*.json; do
    [[ -f "$task_file" ]] || continue
    status=$(jq -r '.status' "$task_file")
    if [[ "$status" == "done" || "$status" == "failed" || "$status" == "cancelled" || "$status" == "ci_failed" ]]; then
      cleanup_task "$task_file"
      ((cleaned++))
    fi
  done
  log "共清理 $cleaned 个任务"
fi
