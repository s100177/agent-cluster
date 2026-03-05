#!/usr/bin/env bash
# evening-scan.sh - 主动编排：晚间扫描 git log，自动更新 CHANGELOG 和 README
# 由 cron 每晚 21:30 调用
# 逻辑：收集今日所有已合并 PR + commit → 启动 Claude Code Agent 更新文档

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CLUSTER_DIR/config.env" 2>/dev/null || true
export PATH="/home/user/.nvm/versions/node/v22.22.0/bin:/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG_FILE="$CLUSTER_DIR/logs/evening-scan.log"
TASKS_DIR="$CLUSTER_DIR/tasks"
TODAY=$(date +%Y-%m-%d)
TODAY_DISPLAY=$(date +"%Y年%m月%d日")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [evening-scan] $*" | tee -a "$LOG_FILE"; }

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
    -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"晚间更新\",\"text\":\"${msg}\"}}" \
    > /dev/null 2>&1 || true
}

log "====== 晚间巡检开始（$TODAY）======"

# ============================================================
# 找仓库（支持多仓库扫描）
# ============================================================
REPOS=()

# 主仓库
[[ -d "/home/user/projects/autocode/.git" ]] && REPOS+=("/home/user/projects/autocode")

# 扫描 agent-cluster worktrees 里出现过的仓库
if [[ -f "$TASKS_DIR"/*.json ]] 2>/dev/null; then
  while IFS= read -r repo; do
    [[ -d "$repo/.git" ]] && REPOS+=("$repo")
  done < <(jq -r '.repo' "$TASKS_DIR"/*.json 2>/dev/null | sort -u)
fi

# 去重
mapfile -t REPOS < <(printf '%s\n' "${REPOS[@]}" | sort -u)

if [[ ${#REPOS[@]} -eq 0 ]]; then
  log "未找到可用仓库，退出"
  exit 0
fi

log "扫描仓库：${REPOS[*]}"

# ============================================================
# 为每个仓库收集今日活动
# ============================================================
TOTAL_LAUNCHED=0
TOTAL_SUMMARY=""

for REPO_PATH in "${REPOS[@]}"; do
  REPO_NAME=$(basename "$REPO_PATH")
  log "--- 处理仓库: $REPO_NAME ---"

  # ---- 收集今日 merged PR ----
  MERGED_PRS=$(gh pr list \
    --repo "$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]//' | sed 's/\.git$//')" \
    --state merged \
    --limit 20 \
    --json number,title,body,mergedAt,labels \
    --jq ".[] | select(.mergedAt > \"${TODAY}T00:00:00Z\")" \
    2>/dev/null || echo "")

  PR_COUNT=$(echo "$MERGED_PRS" | python3 -c "
import json, sys
data = sys.stdin.read().strip()
if not data:
    print(0)
else:
    # gh 每行一个 JSON 对象
    items = [json.loads(line) for line in data.splitlines() if line.strip()]
    print(len(items))
" 2>/dev/null || echo "0")

  # ---- 收集今日所有 commit（包含非 PR 的直接 push）----
  COMMITS=$(git -C "$REPO_PATH" log \
    --since="${TODAY} 00:00:00" \
    --format="%h|%s|%an" \
    2>/dev/null | head -30)

  COMMIT_COUNT=0
  if [[ -n "$COMMITS" ]]; then
    COMMIT_COUNT=$(echo "$COMMITS" | grep -c '|' 2>/dev/null || echo "0")
    COMMIT_COUNT="${COMMIT_COUNT//[^0-9]/}"
    COMMIT_COUNT="${COMMIT_COUNT:-0}"
  fi

  log "今日：$PR_COUNT 个 PR 合并，$COMMIT_COUNT 个 commit"

  # 没有任何活动则跳过
  if [[ "$PR_COUNT" -eq 0 && "$COMMIT_COUNT" -eq 0 ]]; then
    log "今日无活动，跳过 $REPO_NAME"
    continue
  fi

  # ---- 构建活动摘要（供 Agent 使用）----
  ACTIVITY_SUMMARY=""

  if [[ "$PR_COUNT" -gt 0 ]]; then
    ACTIVITY_SUMMARY="### 今日合并的 PR\n"
    ACTIVITY_SUMMARY+=$(echo "$MERGED_PRS" | python3 -c "
import json, sys
data = sys.stdin.read().strip()
if not data:
    exit()
items = [json.loads(line) for line in data.splitlines() if line.strip()]
for item in items:
    labels = ', '.join([l['name'] for l in item.get('labels', [])])
    label_str = f' [{labels}]' if labels else ''
    body_preview = (item.get('body') or '')[:150].replace('\n', ' ')
    print(f\"- PR #{item['number']}: {item['title']}{label_str}\")
    if body_preview:
        print(f\"  {body_preview}\")
" 2>/dev/null)
    ACTIVITY_SUMMARY+="\n"
  fi

  if [[ -n "$COMMITS" ]]; then
    ACTIVITY_SUMMARY+="\n### 今日所有 Commit\n"
    while IFS='|' read -r hash subject author; do
      [[ -z "$hash" ]] && continue
      ACTIVITY_SUMMARY+="- \`$hash\` $subject ($author)\n"
    done <<< "$COMMITS"
  fi

  # ---- 检查是否已有今日文档更新任务 ----
  TASK_ID="docs-update-${REPO_NAME}-${TODAY}"
  if [[ -f "$TASKS_DIR/${TASK_ID}.json" ]]; then
    STATUS=$(jq -r '.status' "$TASKS_DIR/${TASK_ID}.json" 2>/dev/null)
    if [[ "$STATUS" != "done" && "$STATUS" != "failed" ]]; then
      log "今日文档任务已存在（状态: $STATUS），跳过"
      continue
    fi
  fi

  # ---- 构建 Agent Prompt ----
  PROMPT="你是一个技术文档维护员，负责根据今日开发活动更新项目文档。

## 今日开发活动（${TODAY_DISPLAY}）

$(echo -e "$ACTIVITY_SUMMARY")

## 你的任务

### 1. 更新或创建 CHANGELOG.md

如果 CHANGELOG.md 不存在，创建它。
在文件顶部添加今日条目，格式如下：

\`\`\`markdown
## [${TODAY}]

### 新增
- （从今日 PR/commit 中提取新功能）

### 修复
- （从今日 PR/commit 中提取 bug 修复）

### 改进
- （从今日 PR/commit 中提取优化项）
\`\`\`

规则：
- 只记录有意义的变更（跳过 docs、chore、ci 类型的 commit）
- 用用户视角描述，不要写内部实现细节
- 如果某类别没有内容，省略该小节

### 2. 检查是否需要更新 README.md

对比今日新增功能和 README 现有内容：
- 新增了用户可见的功能 → 在 README 的功能列表里补充
- 新增了新的 API 端点 → 在 README 的 API 说明里补充
- 有重大架构变化 → 更新相关章节

如果 README 已经准确反映了当前状态，不需要修改，不要为改而改。

### 3. 提交变更

\`\`\`bash
git add CHANGELOG.md README.md
git diff --staged --stat
git commit -m \"docs: update CHANGELOG and README for ${TODAY}\" 2>/dev/null || echo '无需提交（文件未变更）'
git push origin HEAD 2>/dev/null || echo '推送完成或无需推送'
\`\`\`

完成后执行：
\`\`\`bash
openclaw system event --text \"文档更新完成：${REPO_NAME} ${TODAY_DISPLAY}\" --mode now
\`\`\`

重要提示：
- 只改 CHANGELOG.md 和 README.md，不要改其他文件
- commit message 固定用 docs: update CHANGELOG and README for ${TODAY}
- 如果没有需要记录的变更，直接输出'今日无需更新文档'并退出"

  log "启动文档更新 Agent: $TASK_ID"
  bash "$CLUSTER_DIR/scripts/launch-agent.sh" \
    "$TASK_ID" "$REPO_PATH" "$PROMPT" "claude-code" \
    >> "$LOG_FILE" 2>&1

  if [[ $? -eq 0 ]]; then
    TOTAL_LAUNCHED=$((TOTAL_LAUNCHED + 1))
    TOTAL_SUMMARY="${TOTAL_SUMMARY}\n- **${REPO_NAME}**: ${PR_COUNT} 个 PR，${COMMIT_COUNT} 个 commit"
    log "✅ 文档更新 Agent 已启动: $TASK_ID"
  else
    log "⚠️ 启动失败: $TASK_ID"
  fi
done

# ============================================================
# 通知
# ============================================================
if [[ $TOTAL_LAUNCHED -gt 0 ]]; then
  send_dingtalk "### 🌙 晚间文档更新已启动

**日期:** ${TODAY_DISPLAY}
**处理仓库:**
${TOTAL_SUMMARY}

Agent 正在自动更新 CHANGELOG 和 README，完成后会再通知你。"

  log "已通知用户，$TOTAL_LAUNCHED 个文档更新 Agent 运行中"
else
  log "今日无活动需要记录，跳过通知"
fi

log "====== 晚间巡检完成 ======"
