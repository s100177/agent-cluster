#!/usr/bin/env bash
# status.sh - 查看所有 Agent 任务状态（人类友好的输出）

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"

if [[ ! -d "$TASKS_DIR" ]]; then
  echo "没有任务记录"
  exit 0
fi

task_files=("$TASKS_DIR"/*.json)
if [[ ! -e "${task_files[0]}" ]]; then
  echo "没有运行中的任务"
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Agent 集群状态                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for task_file in "$TASKS_DIR"/*.json; do
  [[ -f "$task_file" ]] || continue

  task_id=$(jq -r '.id' "$task_file")
  status=$(jq -r '.status' "$task_file")
  agent=$(jq -r '.agent' "$task_file")
  description=$(jq -r '.description' "$task_file")
  tmux_session=$(jq -r '.tmuxSession' "$task_file")
  branch=$(jq -r '.branch' "$task_file")
  retries=$(jq -r '.retries' "$task_file")
  pr_url=$(jq -r '.prUrl // "无"' "$task_file")
  ci_status=$(jq -r '.ciStatus // "未知"' "$task_file")
  started_at=$(jq -r '.startedAt' "$task_file")

  # 状态图标
  case "$status" in
    running)    icon="🔄" ;;
    pr_created) icon="📬" ;;
    ready)      icon="✅" ;;
    failed)     icon="❌" ;;
    ci_failed)  icon="🔴" ;;
    done)       icon="✔️" ;;
    *)          icon="❓" ;;
  esac

  # tmux 存活检查
  tmux_alive="死亡"
  if tmux -S /tmp/tmux-1000/default has-session -t "$tmux_session" 2>/dev/null; then
    tmux_alive="存活"
  fi

  # 运行时长
  now_ms=$(date +%s%3N)
  elapsed_s=$(( (now_ms - started_at) / 1000 ))
  elapsed="${elapsed_s}s"
  if [[ $elapsed_s -gt 60 ]]; then elapsed="$((elapsed_s/60))m$((elapsed_s%60))s"; fi
  if [[ $elapsed_s -gt 3600 ]]; then elapsed="$((elapsed_s/3600))h$((elapsed_s%3600/60))m"; fi

  echo "$icon [$task_id] $description"
  echo "   Agent: $agent  |  分支: $branch  |  运行: $elapsed  |  重试: $retries"
  echo "   tmux: $tmux_alive ($tmux_session)"
  echo "   PR: $pr_url"
  echo "   CI: $ci_status"
  echo ""
done
