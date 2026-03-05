#!/usr/bin/env bash
# monitor-agents.sh - 改进版 Ralph Loop 监控脚本
# 每10分钟由 cron 调用，检查所有 Agent 状态，失败则分析原因并重试
# 只检查客观事实：tmux 活着吗？PR 创建了吗？CI 状态如何？

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"
LOGS_DIR="$CLUSTER_DIR/logs"
MAX_RETRIES=3
MAX_RUN_HOURS=2  # 任务最大运行时长（超过则标记为僵尸任务）

# 钉钉配置
DINGTALK_WEBHOOK="${DINGTALK_WEBHOOK:-}"
DINGTALK_SECRET="${DINGTALK_SECRET:-}"

# ============================================================
# 工具函数
# ============================================================

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_dingtalk() {
  local msg="$1"
  [[ -z "$DINGTALK_WEBHOOK" ]] && return 0

  local webhook="$DINGTALK_WEBHOOK"

  # 如果配置了加签密钥，生成签名
  if [[ -n "$DINGTALK_SECRET" ]]; then
    local timestamp sign
    timestamp=$(date +%s%3N)
    sign=$(printf "%s\n%s" "$timestamp" "$DINGTALK_SECRET" \
      | openssl dgst -sha256 -hmac "$DINGTALK_SECRET" -binary \
      | openssl base64 \
      | tr -d '\n' \
      | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    webhook="${DINGTALK_WEBHOOK}&timestamp=${timestamp}&sign=${sign}"
  fi

  curl -s -X POST "$webhook" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"Agent 通知\",\"text\":\"${msg}\"}}" \
    > /dev/null 2>&1 || true
}

update_task() {
  local task_file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp=$(mktemp)
  jq ".$key = $value" "$task_file" > "$tmp" && mv "$tmp" "$task_file"
}

is_tmux_alive() {
  local session="$1"
  tmux -S /tmp/tmux-1000/default has-session -t "$session" 2>/dev/null
}

get_pr_url() {
  local worktree="$1"
  local branch="$2"
  # 先检查 git log 中有没有 PR 链接
  local pr_url
  pr_url=$(git -C "$worktree" log --oneline -5 2>/dev/null | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1 || true)
  if [[ -n "$pr_url" ]]; then
    echo "$pr_url"
    return
  fi
  # 用 gh 查询
  if command -v gh &>/dev/null; then
    gh pr list --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true
  fi
}

get_ci_status() {
  local pr_url="$1"
  if [[ -z "$pr_url" ]] || ! command -v gh &>/dev/null; then
    echo "unknown"
    return
  fi
  local pr_number
  pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
  gh pr checks "$pr_number" --json state --jq 'if length == 0 then "pending" elif all(.state == "SUCCESS") then "success" elif any(.state == "FAILURE") then "failure" else "pending" end' 2>/dev/null || echo "unknown"
}

relaunch_agent() {
  local task_file="$1"
  local task_id branch worktree agent description repo retries
  task_id=$(jq -r '.id' "$task_file")
  branch=$(jq -r '.branch' "$task_file")
  worktree=$(jq -r '.worktree' "$task_file")
  agent=$(jq -r '.agent' "$task_file")
  description=$(jq -r '.description' "$task_file")
  repo=$(jq -r '.repo' "$task_file")
  retries=$(jq -r '.retries' "$task_file")
  local log_file="$LOGS_DIR/${task_id}.log"

  log "重新启动 Agent: $task_id (第 $((retries+1)) 次重试)"

  # 分析失败原因（从日志末尾提取）
  local failure_context=""
  if [[ -f "$log_file" ]]; then
    failure_context=$(tail -30 "$log_file" 2>/dev/null | grep -E "error|Error|fail|FAIL|错误" | tail -5 || true)
  fi

  # 动态调整 prompt（改进版 Ralph Loop 核心）
  local improved_prompt="$description"
  if [[ -n "$failure_context" ]]; then
    improved_prompt="${description}

【上次失败分析】
${failure_context}

请特别注意以上错误，避免重复。先确认类型定义和依赖关系，再开始实现。"
  fi

  # 杀死旧会话
  local tmux_session
  tmux_session=$(jq -r '.tmuxSession' "$task_file")
  tmux -S /tmp/tmux-1000/default kill-session -t "$tmux_session" 2>/dev/null || true

  # 更新任务状态
  update_task "$task_file" "retries" "$((retries+1))"
  update_task "$task_file" "status" '"running"'
  update_task "$task_file" "startedAt" "$(date +%s%3N)"

  # 重新启动（在已有 worktree 上继续）
  local new_cmd
  case "$agent" in
    claude-code) new_cmd="claude --dangerously-skip-permissions -p $(printf '%q' "$improved_prompt")" ;;
    codex)       new_cmd="codex -p $(printf '%q' "$improved_prompt")" ;;
    *)           new_cmd="claude --dangerously-skip-permissions -p $(printf '%q' "$improved_prompt")" ;;
  esac

  tmux -S /tmp/tmux-1000/default new-session -d -s "$tmux_session" \
    -c "$worktree" \
    "exec bash -c 'echo \"[$(date)] 重试 #$((retries+1)): $description\" | tee -a $log_file; $new_cmd 2>&1 | tee -a $log_file'"

  log "Agent 已重启: $task_id"
}

# ============================================================
# 主逻辑
# ============================================================

log "====== 开始监控 Agent 状态 ======"

if [[ ! -d "$TASKS_DIR" ]]; then
  log "任务目录不存在: $TASKS_DIR"
  exit 0
fi

task_files=("$TASKS_DIR"/*.json)
if [[ ! -e "${task_files[0]}" ]]; then
  log "没有运行中的任务"
  exit 0
fi

for task_file in "$TASKS_DIR"/*.json; do
  [[ -f "$task_file" ]] || continue

  task_id=$(jq -r '.id' "$task_file")
  status=$(jq -r '.status' "$task_file")
  tmux_session=$(jq -r '.tmuxSession' "$task_file")
  branch=$(jq -r '.branch' "$task_file")
  worktree=$(jq -r '.worktree' "$task_file")
  retries=$(jq -r '.retries' "$task_file")
  pr_url=$(jq -r '.prUrl // ""' "$task_file")
  description=$(jq -r '.description' "$task_file")
  notify=$(jq -r '.notifyOnComplete' "$task_file")

  log "检查任务: $task_id (状态: $status, 重试: $retries)"

  # 跳过已完成/失败/取消的任务
  if [[ "$status" == "done" || "$status" == "failed" || "$status" == "cancelled" ]]; then
    log "  跳过 ($status)"
    continue
  fi


  # ---- 检查 0: 超时检测（僵尸任务） ----
  started_at=$(jq -r '.startedAt' "$task_file")
  now_ms=$(date +%s%3N)
  elapsed_hours=$(( (now_ms - started_at) / 1000 / 3600 ))
  
  if [[ $elapsed_hours -ge $MAX_RUN_HOURS && -z "$pr_url" ]]; then
    log "  ⚠️ 任务超时 ${elapsed_hours}h（阈值：${MAX_RUN_HOURS}h），标记为僵尸任务"
    
    # 归档任务文件
    archive_name="${task_id}-$(date +%Y%m%d%H%M%S).json"
    jq '.status = "failed" | .failureReason = "僵尸任务：运行超过 '"${MAX_RUN_HOURS}"' 小时无进展"' "$task_file" > "$CLUSTER_DIR/tasks/archive/$archive_name" 2>/dev/null || true
    rm "$task_file"
    
    send_dingtalk "### ⚠️ 僵尸任务清理\n\n**任务:** $task_id\n\n**描述:** $description\n\n运行 ${elapsed_hours}h 无进展，已自动归档。"
    log "  已归档为：tasks/archive/$archive_name"
    continue
  fi
  
  log "  运行时长：${elapsed_hours}h（阈值：${MAX_RUN_HOURS}h）"
  # ---- 检查 1: tmux 会话是否存活 ----
  if ! is_tmux_alive "$tmux_session"; then
    log "  tmux 会话已死亡: $tmux_session"

    # 检查是否已经创建了 PR（可能任务其实已完成）
    if [[ -n "$worktree" && -d "$worktree" ]]; then
      pr_url=$(get_pr_url "$worktree" "$branch")
    fi

    if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
      log "  找到 PR: $pr_url，Agent 已完成"
      update_task "$task_file" "status" '"pr_created"'
      update_task "$task_file" "prUrl" "\"$pr_url\""
    elif [[ "$retries" -lt "$MAX_RETRIES" ]]; then
      log "  未找到 PR，触发重试 ($retries/$MAX_RETRIES)"
      relaunch_agent "$task_file"
    else
      log "  已达最大重试次数，标记为失败"
      update_task "$task_file" "status" '"failed"'
      send_dingtalk "### ❌ Agent 失败\n\n**任务:** $task_id\n\n**描述:** $description\n\n已重试 $retries 次，请手动处理。"
    fi
    continue
  fi

  log "  tmux 会话存活: OK"

  # ---- 检查 2: 是否已创建 PR ----
  if [[ -z "$pr_url" || "$pr_url" == "null" ]]; then
    if [[ -n "$worktree" && -d "$worktree" ]]; then
      pr_url=$(get_pr_url "$worktree" "$branch")
    fi

    if [[ -n "$pr_url" ]]; then
      log "  发现新 PR: $pr_url"
      update_task "$task_file" "status" '"pr_created"'
      update_task "$task_file" "prUrl" "\"$pr_url\""
    else
      log "  PR 尚未创建，Agent 仍在工作"
    fi
    continue
  fi

  log "  PR 已存在: $pr_url"

  # ---- 检查 3: CI 状态 ----
  ci_status=$(get_ci_status "$pr_url")
  log "  CI 状态: $ci_status"
  update_task "$task_file" "ciStatus" "\"$ci_status\""

  case "$ci_status" in
    success)
      if [[ "$status" != "ready" && "$status" != "reviewing" ]]; then
        log "  CI 全通过！启动双重自动 Review..."
        update_task "$task_file" "status" '"reviewing"'

        # 提取 PR 编号
        pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')

        # 后台启动双重 Review（Qwen3-Coder + Claude Code）
        nohup bash "$CLUSTER_DIR/scripts/review-pr.sh" "$pr_number" "$description" \
          >> "$LOGS_DIR/review-${task_id}.log" 2>&1 &
        log "  双重 Review 已启动（PR #$pr_number），完成后会钉钉通知"

        # 更新任务状态为 reviewing（等 review 完成后由 review-pr.sh 通知用户）
        update_task "$task_file" "status" '"reviewing"'
      elif [[ "$status" == "reviewing" ]]; then
        # 检查 review 是否已完成（有两条 review 评论）
        pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
        review_count=$(gh pr view "$pr_number" --json comments \
          --jq '[.comments[].body | select(contains("Review"))] | length' 2>/dev/null || echo "0")
        if [[ "$review_count" -ge 2 ]]; then
          log "  Review 已完成，标记为 ready"
          update_task "$task_file" "status" '"ready"'
        else
          log "  Review 进行中（已有 $review_count 条评论）"
        fi
      fi
      ;;
    failure)
      log "  CI 失败"
      if [[ "$retries" -lt "$MAX_RETRIES" ]]; then
        log "  触发重试修复 CI 问题"
        # 发送修复指令给运行中的 Agent
        if is_tmux_alive "$tmux_session"; then
          tmux -S /tmp/tmux-1000/default send-keys -t "$tmux_session" "CI 测试失败了，请查看 CI 日志并修复问题，然后重新推送。" Enter
        fi
        update_task "$task_file" "retries" "$((retries+1))"
      else
        update_task "$task_file" "status" '"ci_failed"'
        send_dingtalk "### ❌ CI 持续失败\n\n**任务:** $task_id\n\n**PR:** [$pr_url]($pr_url)\n\n请手动检查。"
      fi
      ;;
    pending|unknown)
      log "  CI 仍在运行"
      ;;
  esac
done

log "====== 监控完成 ======"
