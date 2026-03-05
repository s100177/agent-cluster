#!/usr/bin/env bash
# review-pr.sh - 双重自动 Code Review
# 用法: ./review-pr.sh <PR编号> <任务描述>
# 流程: Qwen3-Coder（API）+ Claude Code（PTY）并行审查，各自发 PR 评论，完成后钉钉通知

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CLUSTER_DIR/config.env" 2>/dev/null || true
export PATH="/home/user/.nvm/versions/node/v22.22.0/bin:/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PR_NUMBER="${1:-}"
DESCRIPTION="${2:-代码变更}"

if [[ -z "$PR_NUMBER" ]]; then
  echo "用法: $0 <PR编号> [任务描述]"
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [review-pr] $*"; }

# ============================================================
# 钉钉通知（复用 config.env 里的配置）
# ============================================================
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
    -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"Review 通知\",\"text\":\"${msg}\"}}" \
    > /dev/null 2>&1 || true
}

# ============================================================
# 获取 PR 信息和 diff
# ============================================================
log "获取 PR #$PR_NUMBER 信息..."

PR_URL=$(gh pr view "$PR_NUMBER" --json url --jq '.url' 2>/dev/null || echo "")
if [[ -z "$PR_URL" ]]; then
  log "错误: 无法获取 PR #$PR_NUMBER"
  exit 1
fi

PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq '.title' 2>/dev/null || echo "$DESCRIPTION")
PR_DIFF=$(gh pr diff "$PR_NUMBER" 2>/dev/null | head -c 25000)
PR_FILES=$(gh pr view "$PR_NUMBER" --json files --jq '[.files[].path] | join(", ")' 2>/dev/null || echo "未知")

log "PR: $PR_TITLE"
log "改动文件: $PR_FILES"
log "Diff 大小: ${#PR_DIFF} 字节"

REVIEW_DIR=$(mktemp -d)
log "工作目录: $REVIEW_DIR"

# 克隆仓库并检出 PR 分支（Claude Code 需要真实文件）
REPO_FULL=$(gh pr view "$PR_NUMBER" --json headRepositoryOwner,headRepository \
  --jq '"\(.headRepositoryOwner.login)/\(.headRepository.name)"' 2>/dev/null || echo "")

if [[ -n "$REPO_FULL" ]]; then
  log "克隆仓库 $REPO_FULL..."
  git clone --quiet "https://github.com/${REPO_FULL}.git" "$REVIEW_DIR" 2>/dev/null \
    && gh pr checkout "$PR_NUMBER" --repo "https://github.com/${REPO_FULL}.git" \
       --force 2>/dev/null || true
fi

# ============================================================
# Review 1: Qwen3-Coder（API 直接调用，同步，速度快）
# ============================================================
log "▶ 启动 Qwen3-Coder Review..."

QWEN_PROMPT="你是一个资深代码审查员，擅长发现安全漏洞、性能问题和逻辑缺陷。

## 任务
审查 PR #${PR_NUMBER}：${PR_TITLE}
改动文件：${PR_FILES}

## Diff
\`\`\`diff
${PR_DIFF}
\`\`\`

## 输出格式（Markdown，简洁有力）

### 总体评价
（✅ 通过 / ⚠️ 有问题 / ❌ 不能合并 — 一句话说明原因）

### 发现的问题
（列出具体文件和行号；如无则写"无明显问题"）

### 安全风险
（SQL注入、未授权访问、敏感信息泄露等；如无则写"无"）

### 性能建议
（N+1查询、大循环、内存泄漏等；如无则写"无"）

要求：只输出有价值的内容，不要泛泛而谈。"

QWEN_REVIEW=$(curl -s -X POST \
  "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions" \
  -H "Authorization: Bearer ${DASHSCOPE_API_KEY}" \
  -H "Content-Type: application/json" \
  --max-time 60 \
  -d "$(python3 -c "
import json, sys
prompt = sys.argv[1]
print(json.dumps({
  'model': '${REVIEW_MODEL:-qwen3-coder-plus}',
  'messages': [
    {'role': 'system', 'content': '你是资深代码审查员，输出简洁、可操作的 review 反馈。'},
    {'role': 'user', 'content': prompt}
  ],
  'max_tokens': 2000
}))
" "$QWEN_PROMPT")" \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print(f'解析失败: {e}')
    print(sys.stdin.read()[:500] if hasattr(sys.stdin, 'read') else '')
" 2>/dev/null)

if [[ -n "$QWEN_REVIEW" ]] && [[ "$QWEN_REVIEW" != *"解析失败"* ]]; then
  QWEN_COMMENT="## 🤖 Qwen3-Coder Review

${QWEN_REVIEW}

---
*自动审查 by Qwen3-Coder-Plus via OpenClaw*"

  gh pr comment "$PR_NUMBER" --body "$QWEN_COMMENT" 2>/dev/null \
    && log "✅ Qwen3-Coder review 已发布" \
    || log "⚠️ 发布 Qwen review 评论失败"
else
  log "⚠️ Qwen3-Coder review 返回为空或失败"
fi

# ============================================================
# Review 2: Claude Code（PTY 后台，自主阅读代码并评论）
# ============================================================
log "▶ 启动 Claude Code Review..."

CC_PROMPT="你是一个严格的代码审查员。

## 任务
审查 PR #${PR_NUMBER}：${PR_TITLE}
改动文件：${PR_FILES}

## 审查重点
1. 逻辑正确性 — 核心路径有没有 bug，边界情况有没有处理
2. 测试覆盖 — 关键路径是否有测试，有没有漏掉的 case
3. 代码质量 — 命名、复杂度、可维护性
4. 与已有代码风格是否一致

可以用 git diff HEAD~1 或直接阅读改动文件来分析。

## 输出格式（Markdown）

### 总体评价
（✅ 通过 / ⚠️ 有问题 / ❌ 不能合并 — 一句话）

### 发现的问题
（具体文件和行号；如无则写"无"）

### 测试覆盖
（哪些 case 还缺测试；如无则写"覆盖充分"）

### 建议
（可选，具体可操作的改进建议）

## 完成后必须执行（将 review 发布到 PR）：
gh pr comment ${PR_NUMBER} --body \"\$(cat <<'REVIEW_EOF'
## 🤖 Claude Code Review

[在这里填入你的 review 内容]

---
*自动审查 by Claude Code via OpenClaw*
REVIEW_EOF
)\"

重要：review 内容必须发布到 PR，这是你任务的最后一步。"

# 在 worktree 目录里启动 Claude Code（后台 PTY）
CC_LOG="/tmp/cc-review-${PR_NUMBER}.log"
tmux -S /tmp/tmux-$(id -u)/default new-session -d \
  -s "review-cc-${PR_NUMBER}" \
  -c "${REVIEW_DIR}" \
  "exec bash -c 'unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; export PATH=\"${PATH}\"; echo \"[$(date)] 启动 Claude Code Review for PR #${PR_NUMBER}\" | tee ${CC_LOG}; claude --dangerously-skip-permissions -p $(printf '%q' "$CC_PROMPT") 2>&1 | tee -a ${CC_LOG}; echo \"[$(date)] Claude Code Review 结束\" >> ${CC_LOG}'" \
  2>/dev/null \
  && log "✅ Claude Code Review 已在后台启动 (tmux: review-cc-${PR_NUMBER})" \
  || log "⚠️ Claude Code Review 启动失败"

# ============================================================
# 等待 Claude Code Review 完成（最多 8 分钟）
# ============================================================
log "等待 Claude Code Review 完成（最多 8 分钟）..."
WAIT=0
MAX_WAIT=480
CC_DONE=false

while [[ $WAIT -lt $MAX_WAIT ]]; do
  sleep 15
  WAIT=$((WAIT + 15))

  # 检查 tmux 会话是否还活着
  if ! tmux -S /tmp/tmux-$(id -u)/default has-session -t "review-cc-${PR_NUMBER}" 2>/dev/null; then
    log "Claude Code Review 会话已退出 (${WAIT}s)"
    CC_DONE=true
    break
  fi

  # 检查 PR 是否已经有 Claude Code 的评论
  CC_COMMENT_CHECK=$(gh pr view "$PR_NUMBER" --json comments \
    --jq '[.comments[].body | select(contains("Claude Code Review"))] | length' 2>/dev/null || echo "0")
  if [[ "$CC_COMMENT_CHECK" -gt 0 ]]; then
    log "Claude Code Review 评论已发布 (${WAIT}s)"
    CC_DONE=true
    break
  fi

  log "等待中... ${WAIT}/${MAX_WAIT}s"
done

# 超时清理
tmux -S /tmp/tmux-$(id -u)/default kill-session -t "review-cc-${PR_NUMBER}" 2>/dev/null || true

# ============================================================
# 最终通知
# ============================================================
CC_STATUS="✅ 完成"
[[ "$CC_DONE" == "false" ]] && CC_STATUS="⏱️ 超时（检查 ${CC_LOG}）"

QWEN_STATUS="✅ 完成"
[[ -z "$QWEN_REVIEW" ]] || [[ "$QWEN_REVIEW" == *"解析失败"* ]] && QWEN_STATUS="⚠️ 失败"

send_dingtalk "### 🔍 双重 Review 完成，可以做最终决策！

**PR #${PR_NUMBER}:** ${PR_TITLE}
**PR 地址:** [点击查看](${PR_URL})

**Review 状态:**
- Qwen3-Coder Review: ${QWEN_STATUS}
- Claude Code Review: ${CC_STATUS}

**CI:** 全部通过 ✓

请在 PR 里查看 review 评论，然后决定是否合并。"

# 清理
rm -rf "$REVIEW_DIR"
log "====== review-pr.sh 完成 ======"
