#!/usr/bin/env bash
# cleanup.sh - 清理僵尸资源（worktree + tmux + 任务记录）
# 用法：./scripts/run.sh cleanup [--dry-run]

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"
ARCHIVE_DIR="$TASKS_DIR/archive"
WORKTREES_DIR="$CLUSTER_DIR/worktrees"
LOGS_DIR="$CLUSTER_DIR/logs"
source "$CLUSTER_DIR/scripts/lib/json.sh"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"; }

log "====== 开始清理僵尸资源 ======"
[[ "$DRY_RUN" == "true" ]] && log "【干-run 模式】不会实际删除"

# ============================================================
# 1. 清理死亡的 tmux 会话
# ============================================================
log "检查 tmux 会话..."

TMUX_SOCKET="/tmp/tmux-1000/default"
DEAD_SESSIONS=0

for session in $(tmux -S "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "^agent-" | cut -d: -f1); do
  task_id="${session#agent-}"
  task_file="$TASKS_DIR/${task_id}.json"
  
  # 检查任务是否存在
  if [[ ! -f "$task_file" ]]; then
    log "发现无主 tmux 会话：$session（无对应任务文件）"
    if [[ "$DRY_RUN" == "false" ]]; then
      tmux -S "$TMUX_SOCKET" kill-session -t "$session" 2>/dev/null && log "  → 已删除" || true
    else
      log "  → [dry-run] 将删除"
    fi
    DEAD_SESSIONS=$((DEAD_SESSIONS+1))
    continue
  fi
  
  # 检查任务状态
  status=$(jq_sanitize_file "$task_file" -r '.status')
  if [[ "$status" == "done" || "$status" == "failed" || "$status" == "cancelled" ]]; then
    log "发现已完成任务的 tmux 会话：$session（状态：$status）"
    if [[ "$DRY_RUN" == "false" ]]; then
      tmux -S "$TMUX_SOCKET" kill-session -t "$session" 2>/dev/null && log "  → 已删除" || true
    else
      log "  → [dry-run] 将删除"
    fi
    DEAD_SESSIONS=$((DEAD_SESSIONS+1))
  fi
done

log "清理完成：删除 $DEAD_SESSIONS 个 tmux 会话"

# ============================================================
# 2. 清理孤立的 worktree
# ============================================================
log "检查 worktree..."

ISOLATED_WORKTREES=0

if [[ -d "$WORKTREES_DIR" ]]; then
  for wt in "$WORKTREES_DIR"/*/; do
    [[ -d "$wt" ]] || continue
    wt_name=$(basename "$wt")
    
    # 检查是否有对应的任务
    if [[ ! -f "$TASKS_DIR/${wt_name}.json" ]]; then
      log "发现孤立 worktree: $wt_name"
      if [[ "$DRY_RUN" == "false" ]]; then
        # 尝试用 git 删除
        git -C "$CLUSTER_DIR" worktree remove "$wt" --force 2>/dev/null && log "  → 已删除" || rm -rf "$wt" && log "  → 已强制删除"
      else
        log "  → [dry-run] 将删除"
      fi
      ISOLATED_WORKTREES=$((ISOLATED_WORKTREES+1))
    fi
  done
fi

log "清理完成：删除 $ISOLATED_WORKTREES 个孤立 worktree"

# ============================================================
# 3. 清理过期的日志文件（保留最近 7 天）
# ============================================================
log "检查过期日志..."

OLD_LOGS=0
SEVEN_DAYS_AGO=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null || echo 0)

for log_file in "$LOGS_DIR"/*.log; do
  [[ -f "$log_file" ]] || continue
  
  file_mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo 0)
  
  if [[ $file_mtime -lt $SEVEN_DAYS_AGO && $SEVEN_DAYS_AGO -gt 0 ]]; then
    log "发现过期日志：$(basename "$log_file")"
    if [[ "$DRY_RUN" == "false" ]]; then
      rm "$log_file" && log "  → 已删除"
    else
      log "  → [dry-run] 将删除"
    fi
    OLD_LOGS=$((OLD_LOGS+1))
  fi
done

log "清理完成：删除 $OLD_LOGS 个过期日志"

# ============================================================
# 4. 归档旧任务（完成超过 7 天的任务移到 archive）
# ============================================================
log "检查旧任务..."

ARCHIVED_TASKS=0
SEVEN_DAYS_MS=$((SEVEN_DAYS_AGO * 1000))

for task_file in "$TASKS_DIR"/*.json; do
  [[ -f "$task_file" ]] || continue
  
  status=$(jq_sanitize_file "$task_file" -r '.status')
  
  # 只处理已完成/失败的任务
  if [[ "$status" != "done" && "$status" != "failed" ]]; then
    continue
  fi
  
  started_at=$(jq_sanitize_file "$task_file" -r '.startedAt' || echo 0)
  
  if [[ $started_at -lt $SEVEN_DAYS_MS && $SEVEN_DAYS_MS -gt 0 ]]; then
    task_id=$(jq_sanitize_file "$task_file" -r '.id')
    log "发现旧任务：$task_id（状态：$status）"
    
    if [[ "$DRY_RUN" == "false" ]]; then
      archive_name="${task_id}-$(date +%Y%m%d%H%M%S).json"
      mv "$task_file" "$ARCHIVE_DIR/$archive_name" && log "  → 已归档为：$archive_name"
    else
      log "  → [dry-run] 将归档"
    fi
    ARCHIVED_TASKS=$((ARCHIVED_TASKS+1))
  fi
done

log "清理完成：归档 $ARCHIVED_TASKS 个旧任务"

# ============================================================
# 总结
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    清理总结                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "tmux 会话：$DEAD_SESSIONS 个"
echo "孤立 worktree: $ISOLATED_WORKTREES 个"
echo "过期日志：$OLD_LOGS 个"
echo "归档任务：$ARCHIVED_TASKS 个"
echo ""
log "====== 清理完成 ======"
