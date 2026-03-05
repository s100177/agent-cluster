#!/usr/bin/env bash
# morning-scan.sh - 主动编排：早晨扫描，自动发现任务并启动 Agent
# 由 cron 每天早上 8:30 调用
# 扫描内容：GitHub Issues（bug标签）→ 自动启动修复 Agent

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CLUSTER_DIR/config.env" 2>/dev/null || true
export PATH="/home/user/.nvm/versions/node/v22.22.0/bin:/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG_FILE="$CLUSTER_DIR/logs/morning-scan.log"
TASKS_DIR="$CLUSTER_DIR/tasks"
MAX_AUTO_AGENTS=2   # 每次最多自动启动几个 Agent（防止失控）

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [morning-scan] $*" | tee -a "$LOG_FILE"; }

send_dingtalk() {
  local msg="$1"
  [[ -z "${DINGTALK_WEBHOOK:-}" ]] && return 0
  local webhook="$DINGTALK_WEBHOOK"
  if [[ -n "${DINGTALK_SECRET:-}" ]]; then
    local timestamp sign
    timestamp=$(date +%s%3N)
    sign=$(printf "%s\n%s" "$timestamp" "$DINGTALK_SECRET" \
      | openssl dgst -sha256 -hmac "$DINGTALK_SECRET" -binary \
      | openssl base64 | tr -d '\n' \
      | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    webhook="${DINGTALK_WEBHOOK}&timestamp=${timestamp}&sign=${sign}"
  fi
  curl -s -X POST "$webhook" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"早间巡检\",\"text\":\"${msg}\"}}" \
    > /dev/null 2>&1 || true
}

# ============================================================
# 检查当前有多少 Agent 在运行
# ============================================================
count_running_agents() {
  local count=0
  for f in "$TASKS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local s
    s=$(jq -r '.status' "$f" 2>/dev/null)
    [[ "$s" == "running" || "$s" == "reviewing" || "$s" == "pr_created" ]] && count=$((count+1))
  done
  echo $count
}

# ============================================================
# 任务是否已存在（防止重复启动）
# ============================================================
task_exists() {
  local task_id="$1"
  [[ -f "$TASKS_DIR/${task_id}.json" ]] && \
    [[ "$(jq -r '.status' "$TASKS_DIR/${task_id}.json")" != "done" ]] && \
    [[ "$(jq -r '.status' "$TASKS_DIR/${task_id}.json")" != "failed" ]]
}

log "====== 早间巡检开始 ======"

RUNNING=$(count_running_agents)
log "当前运行中的 Agent: $RUNNING 个"

AVAILABLE_SLOTS=$((MAX_AUTO_AGENTS - RUNNING))
if [[ $AVAILABLE_SLOTS -le 0 ]]; then
  log "Agent 槽位已满（$RUNNING 个运行中），跳过自动启动"
  exit 0
fi

# ============================================================
# 扫描 1: GitHub Issues（bug 标签，未分配，最近 7 天内）
# ============================================================
log "扫描 GitHub Issues（bug 标签）..."

ISSUES_JSON=$(gh issue list \
  --label "bug" \
  --state "open" \
  --limit 10 \
  --json number,title,body,createdAt,assignees \
  2>/dev/null || echo "[]")

BUG_COUNT=$(echo "$ISSUES_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
log "发现 $BUG_COUNT 个开放的 bug issue"

LAUNCHED=0
LAUNCH_SUMMARY=""

while IFS= read -r issue; do
  [[ $LAUNCHED -ge $AVAILABLE_SLOTS ]] && break

  NUMBER=$(echo "$issue" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['number'])" 2>/dev/null)
  TITLE=$(echo "$issue" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['title'])" 2>/dev/null)
  BODY=$(echo "$issue" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('body','')[:500])" 2>/dev/null)
  ASSIGNEES=$(echo "$issue" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('assignees',[])))" 2>/dev/null)

  # 跳过已分配的 issue
  [[ "$ASSIGNEES" -gt 0 ]] && continue

  TASK_ID="fix-issue-${NUMBER}"

  # 跳过已在处理的任务
  if task_exists "$TASK_ID"; then
    log "Issue #$NUMBER 已有任务 $TASK_ID，跳过"
    continue
  fi

  # 找到一个仓库路径（优先用 autocode）
  REPO_PATH="/home/user/projects/autocode"
  [[ ! -d "$REPO_PATH" ]] && REPO_PATH=$(find /home/user/projects -name ".git" -maxdepth 3 -type d | head -1 | xargs dirname 2>/dev/null || echo "")

  if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    log "未找到可用的仓库路径，跳过"
    break
  fi

  PROMPT="修复 GitHub Issue #${NUMBER}：${TITLE}

## Issue 描述
${BODY}

## 要求
1. 仔细阅读 issue 描述，理解 bug 的根本原因
2. 找到相关代码，实现最小化修复
3. 补充/更新对应的测试用例
4. 不要引入不相关的改动

## 完成步骤（必须按顺序执行）
1. 运行测试确认 bug 可复现
2. 修复 bug
3. 运行测试确认修复有效
4. git add -A && git commit -m \"fix: resolve issue #${NUMBER} - ${TITLE}\"
5. git push -u origin feat/${TASK_ID}
6. gh pr create --fill --body \"Fixes #${NUMBER}\"
7. openclaw system event --text \"PR已就绪：fix issue #${NUMBER} ${TITLE}\" --mode now"

  log "启动 Agent 修复 Issue #$NUMBER: $TITLE"
  bash "$CLUSTER_DIR/scripts/launch-agent.sh" \
    "$TASK_ID" "$REPO_PATH" "$PROMPT" "claude-code" \
    >> "$LOG_FILE" 2>&1

  if [[ $? -eq 0 ]]; then
    LAUNCHED=$((LAUNCHED + 1))
    LAUNCH_SUMMARY="${LAUNCH_SUMMARY}\n- Issue #${NUMBER}: ${TITLE}"
    log "✅ 已启动: $TASK_ID"

    # 在 GitHub 上 assign 自己，标记已处理
    gh issue edit "$NUMBER" --add-assignee "@me" 2>/dev/null || true
  else
    log "⚠️ 启动失败: $TASK_ID"
  fi

done < <(echo "$ISSUES_JSON" | python3 -c "
import json, sys
issues = json.load(sys.stdin)
for i in issues:
    print(json.dumps(i))
" 2>/dev/null)

# ============================================================
# 扫描 2: 检查是否有 stale PR（超过 24 小时未合并的 ready 任务）
# ============================================================
log "扫描 stale 任务..."
STALE_SUMMARY=""
NOW_MS=$(date +%s%3N)

for task_file in "$TASKS_DIR"/*.json; do
  [[ -f "$task_file" ]] || continue
  STATUS=$(jq -r '.status' "$task_file")
  [[ "$STATUS" != "ready" ]] && continue

  STARTED_AT=$(jq -r '.startedAt' "$task_file")
  AGE_HOURS=$(( (NOW_MS - STARTED_AT) / 3600000 ))
  TASK_ID=$(jq -r '.id' "$task_file")
  PR_URL=$(jq -r '.prUrl // ""' "$task_file")

  if [[ $AGE_HOURS -gt 24 ]]; then
    STALE_SUMMARY="${STALE_SUMMARY}\n- ${TASK_ID} (等待 ${AGE_HOURS}h) [PR](${PR_URL})"
    log "⚠️ Stale PR: $TASK_ID 已等待 ${AGE_HOURS} 小时"
  fi
done

# ============================================================
# 汇总通知
# ============================================================
if [[ $LAUNCHED -gt 0 ]] || [[ -n "$STALE_SUMMARY" ]]; then
  MSG="### 🌅 早间巡检报告\n\n"

  if [[ $LAUNCHED -gt 0 ]]; then
    MSG="${MSG}**🤖 自动启动了 ${LAUNCHED} 个修复 Agent：**\n${LAUNCH_SUMMARY}\n\n"
  else
    MSG="${MSG}**✅ 无新 bug 需要处理**\n\n"
  fi

  if [[ -n "$STALE_SUMMARY" ]]; then
    MSG="${MSG}**⚠️ 以下 PR 等待超过 24 小时，请处理：**\n${STALE_SUMMARY}\n\n"
  fi

  MSG="${MSG}*当前运行中：$((RUNNING + LAUNCHED)) 个 Agent*"
  send_dingtalk "$MSG"
else
  log "无需通知，一切正常"
fi

log "====== 早间巡检完成，启动了 $LAUNCHED 个 Agent ======"
