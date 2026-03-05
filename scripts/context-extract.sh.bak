#!/usr/bin/env bash
# context-extract.sh - 业务上下文自动提炼
# 从今日所有会话 transcript 中提取用户消息，用 Qwen 分析业务价值，写入 MEMORY.md
# 每晚 22:00 由 cron 触发

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CLUSTER_DIR/config.env" 2>/dev/null || true
export PATH="/home/user/.nvm/versions/node/v22.22.0/bin:/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SESSIONS_DIR="/home/user/.openclaw/agents/main/sessions"
MEMORY_FILE="/home/user/.openclaw/workspace/memory/MEMORY.md"
TODAY=$(date +%Y-%m-%d)
TODAY_DISPLAY=$(date +"%Y年%m月%d日")
LOG_FILE="$CLUSTER_DIR/logs/context-extract.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [context-extract] $*" | tee -a "$LOG_FILE"; }

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
    -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"上下文提炼\",\"text\":\"${msg}\"}}" \
    > /dev/null 2>&1 || true
}

log "====== 业务上下文提炼开始（$TODAY）======"

# ============================================================
# 第一步：从所有 JSONL transcript 提取今日用户消息
# ============================================================
MESSAGES=$(python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone, timedelta

sessions_dir = "/home/user/.openclaw/agents/main/sessions"
today = datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m-%d")

# 噪音过滤词（这些消息没有业务价值）
NOISE_PATTERNS = [
    "Read HEARTBEAT.md",
    "Pre-compaction memory flush",
    "Post-Compaction Audit",
    "Conversation info (untrusted metadata)",
    "openclaw system event",
    "HEARTBEAT_OK",
    "System: [",
    "session was started via /new",
    "Execute your Session Startup",
]

messages = []

for fname in os.listdir(sessions_dir):
    if not fname.endswith(".jsonl"):
        continue
    fpath = os.path.join(sessions_dir, fname)

    # 只处理今日修改的文件（快速过滤）
    mtime = os.path.getmtime(fpath)
    fdate = datetime.fromtimestamp(mtime, timezone(timedelta(hours=8))).strftime("%Y-%m-%d")
    if fdate != today:
        continue

    try:
        with open(fpath) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except:
                    continue

                if d.get("type") != "message":
                    continue

                msg = d.get("message", {})
                if msg.get("role") != "user":
                    continue

                # 提取文本内容
                content = msg.get("content", "")
                text = ""
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            text += c.get("text", "")
                elif isinstance(content, str):
                    text = content

                if not text.strip():
                    continue

                # 过滤噪音
                is_noise = any(p in text for p in NOISE_PATTERNS)
                if is_noise:
                    continue

                # 从钉钉消息中提取实际用户输入（去掉 metadata wrapper）
                if "```json" in text and "sender_id" in text:
                    # 找到 JSON 块之后的实际内容
                    parts = text.split("```")
                    # 找最后一个 ``` 之后的文本
                    actual_text = ""
                    in_json = False
                    for i, part in enumerate(parts):
                        if i % 2 == 0 and i > 0:  # 奇数 index 是代码块外
                            actual_text += part
                    text = actual_text.strip()

                if not text.strip() or len(text.strip()) < 5:
                    continue

                # 记录消息（带时间戳）
                ts = d.get("timestamp", "")
                if ts:
                    try:
                        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        dt_local = dt.astimezone(timezone(timedelta(hours=8)))
                        ts_str = dt_local.strftime("%H:%M")
                        # 只要今日的
                        if dt_local.strftime("%Y-%m-%d") != today:
                            continue
                    except:
                        ts_str = ""
                else:
                    ts_str = ""

                messages.append(f"[{ts_str}] {text.strip()[:300]}")

    except Exception as e:
        print(f"Error reading {fname}: {e}", file=sys.stderr)

# 去重 + 排序
seen = set()
unique_messages = []
for m in messages:
    if m not in seen:
        seen.add(m)
        unique_messages.append(m)

print("\n".join(unique_messages[:80]))  # 最多80条
PYEOF
)

MSG_COUNT=$(echo "$MESSAGES" | grep -c '^\[' 2>/dev/null | tr -d '\n' || echo "0")
log "提取到 $MSG_COUNT 条用户消息"

if [[ "${MSG_COUNT:-0}" -lt 2 ]]; then
  log "今日消息过少，无需提炼，退出"
  exit 0
fi

# ============================================================
# 第二步：用 Qwen 分析业务价值
# ============================================================
log "调用 Qwen3 分析业务上下文..."

ANALYSIS=$(
  # 把消息写到临时文件，避免 heredoc 中的特殊字符问题
  TMP_MSG=$(mktemp)
  TMP_PAYLOAD=$(mktemp)
  echo "$MESSAGES" > "$TMP_MSG"

  python3 - "$TMP_MSG" "$TODAY_DISPLAY" "$DASHSCOPE_API_KEY" << 'PYEOF'
import json, sys, subprocess

msg_file   = sys.argv[1]
today_disp = sys.argv[2]
api_key    = sys.argv[3]

messages = open(msg_file).read()

prompt = (
    "你是一个业务上下文分析员。以下是今日（" + today_disp + "）用户与 AI 助手的对话消息（已去除系统消息和噪音）：\n\n"
    "<messages>\n" + messages + "\n</messages>\n\n"
    "请从中提炼有业务价值的信息，用于更新项目长期记忆。\n\n"
    "## 输出格式（Markdown，只输出有实质内容的章节）\n\n"
    "### 新需求 / 功能要求\n"
    "（用户明确提出的功能需求、改进要求；如无则省略此节）\n\n"
    "### 技术决策\n"
    "（架构选择、技术方案、工具选型等决策；如无则省略此节）\n\n"
    "### 项目方向\n"
    "（产品定位、优先级变化、业务目标等；如无则省略此节）\n\n"
    "### 重要上下文\n"
    "（客户信息、背景知识、需要记住的约束条件等；如无则省略此节）\n\n"
    "## 规则\n"
    "- 如果今日对话没有业务价值（只有闲聊或技术操作），输出：无有效业务信息\n"
    "- 每条信息要具体，不要模糊概括\n"
    "- 不超过 300 字"
)

payload = json.dumps({
    "model": "qwen3-coder-plus",
    "messages": [
        {"role": "system", "content": "你是一个精准的业务分析员，只提炼真正有价值的信息。"},
        {"role": "user", "content": prompt}
    ],
    "max_tokens": 1000
})

result = subprocess.run([
    "curl", "-s", "-X", "POST",
    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    "-H", "Authorization: Bearer " + api_key,
    "-H", "Content-Type: application/json",
    "--max-time", "60",
    "-d", payload
], capture_output=True, text=True)

try:
    d = json.loads(result.stdout)
    print(d["choices"][0]["message"]["content"])
except Exception as e:
    print("解析失败: " + str(e))
PYEOF

  rm -f "$TMP_MSG" "$TMP_PAYLOAD"
)

log "Qwen 分析完成"

# 判断是否有有效内容
if [[ -z "$ANALYSIS" ]] || echo "$ANALYSIS" | grep -q "无有效业务信息"; then
  log "今日无有效业务信息，不更新 MEMORY.md"
  exit 0
fi

# ============================================================
# 第三步：追加到 MEMORY.md
# ============================================================
log "更新 MEMORY.md..."

mkdir -p "$(dirname "$MEMORY_FILE")"

# 如果 MEMORY.md 不存在，创建基本结构
if [[ ! -f "$MEMORY_FILE" ]]; then
  cat > "$MEMORY_FILE" << 'EOF'
# MEMORY.md - 长期业务记忆

本文件由 context-extract.sh 自动维护，记录每日提炼的业务上下文。

---
EOF
fi

# 追加今日内容（避免重复：检查今日日期是否已存在）
if grep -q "## $TODAY" "$MEMORY_FILE" 2>/dev/null; then
  log "$TODAY 已有记录，追加新内容（标记为补充）"
  cat >> "$MEMORY_FILE" << EOF

### 补充（$(date '+%H:%M')）
$ANALYSIS
EOF
else
  cat >> "$MEMORY_FILE" << EOF

---

## $TODAY 业务上下文

$ANALYSIS

*自动提炼自 $MSG_COUNT 条对话消息 · $(date '+%H:%M')*
EOF
fi

log "MEMORY.md 更新完成"

# ============================================================
# 第四步：发钉钉通知（简短）
# ============================================================
# 提取第一行作为摘要
SUMMARY=$(echo "$ANALYSIS" | grep -v '^$' | grep -v '^#' | head -3 | tr '\n' ' ')

send_dingtalk "### 🧠 今日业务上下文已提炼

**日期:** ${TODAY_DISPLAY}
**消息量:** ${MSG_COUNT} 条对话
**摘要:** ${SUMMARY:0:100}...

MEMORY.md 已自动更新。"

log "====== 上下文提炼完成 ======"
