#!/usr/bin/env bash
# stats.sh - Agent 集群统计报表
# 用法：./scripts/run.sh stats [--today|--week|--all]

set -uo pipefail

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_DIR="$CLUSTER_DIR/tasks"
ARCHIVE_DIR="$TASKS_DIR/archive"
LOGS_DIR="$CLUSTER_DIR/logs"
source "$CLUSTER_DIR/scripts/lib/json.sh"

MODE="${1:---all}"
case "$MODE" in
  --today)  HOURS=24 ;;
  --week)   HOURS=168 ;;
  --all)    HOURS=99999 ;;
  *)        HOURS=24 ;;
esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [stats] $*"; }

log "====== Agent 集群统计报表（最近 ${HOURS}h）======"

# ============================================================
# 1. 任务统计
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      任务统计                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"

TOTAL=0
DONE=0
FAILED=0
RUNNING=0
PR_CREATED=0

shopt -s nullglob
for f in "$TASKS_DIR"/*.json; do
  TOTAL=$((TOTAL+1))
  status=$(jq_sanitize_file "$f" -r '.status')
  case "$status" in
    done) DONE=$((DONE+1)) ;;
    failed) FAILED=$((FAILED+1)) ;;
    running) RUNNING=$((RUNNING+1)) ;;
    pr_created|ready|reviewing) PR_CREATED=$((PR_CREATED+1)) ;;
  esac
done

for f in "$ARCHIVE_DIR"/*.json; do
  TOTAL=$((TOTAL+1))
  status=$(jq_sanitize_file "$f" -r '.status')
  case "$status" in
    done) DONE=$((DONE+1)) ;;
    failed) FAILED=$((FAILED+1)) ;;
  esac
done
shopt -u nullglob

echo "总任务数：$TOTAL"
echo "✅ 完成：$DONE"
echo "📬 PR 待 Review: $PR_CREATED"
echo "🔄 运行中：$RUNNING"
echo "❌ 失败：$FAILED"

if [[ $TOTAL -gt 0 ]]; then
  SUCCESS_RATE=$((DONE*100/TOTAL))
  echo "成功率：${SUCCESS_RATE}%"
fi

# ============================================================
# 2. Agent 类型分布
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Agent 类型分布                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

CLAUDE_COUNT=0
CODEX_COUNT=0
GEMINI_COUNT=0
OTHER_COUNT=0

shopt -s nullglob
for f in "$TASKS_DIR"/*.json "$ARCHIVE_DIR"/*.json; do
  agent=$(jq_sanitize_file "$f" -r '.agent')
  case "$agent" in
    claude-code) CLAUDE_COUNT=$((CLAUDE_COUNT+1)) ;;
    codex) CODEX_COUNT=$((CODEX_COUNT+1)) ;;
    gemini) GEMINI_COUNT=$((GEMINI_COUNT+1)) ;;
    *) OTHER_COUNT=$((OTHER_COUNT+1)) ;;
  esac
done
shopt -u nullglob

echo "claude-code: $CLAUDE_COUNT"
echo "codex:       $CODEX_COUNT"
echo "gemini:      $GEMINI_COUNT"
echo "其他：$OTHER_COUNT"

# ============================================================
# 3. 执行时长统计
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    执行时长统计                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

TOTAL_DURATION=0
COUNT=0

shopt -s nullglob
for log_file in "$LOGS_DIR"/*.log; do
  [[ -f "$log_file" ]] || continue
  
  start_line=$(grep -n "启动 Agent" "$log_file" 2>/dev/null | head -1 | cut -d: -f1)
  end_line=$(grep -n "任务完成\|Agent 退出" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1)
  
  if [[ -n "$start_line" && -n "$end_line" ]]; then
    start_time=$(sed -n "${start_line}p" "$log_file" | grep -oE '\[.+\]' | tr -d '[]')
    end_time=$(sed -n "${end_line}p" "$log_file" | grep -oE '\[.+\]' | tr -d '[]')
    
    if [[ -n "$start_time" && -n "$end_time" ]]; then
      start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
      end_epoch=$(date -d "$end_time" +%s 2>/dev/null || echo 0)
      
      if [[ $start_epoch -gt 0 && $end_epoch -gt 0 ]]; then
        duration=$((end_epoch - start_epoch))
        if [[ $duration -gt 0 && $duration -lt 86400 ]]; then
          TOTAL_DURATION=$((TOTAL_DURATION+duration))
          COUNT=$((COUNT+1))
        fi
      fi
    fi
  fi
done
shopt -u nullglob

if [[ $COUNT -gt 0 ]]; then
  AVG_DURATION=$((TOTAL_DURATION/COUNT))
  AVG_MIN=$((AVG_DURATION/60))
  AVG_SEC=$((AVG_DURATION%60))
  TOTAL_HOURS=$((TOTAL_DURATION/3600))
  
  echo "有效样本：$COUNT 个任务"
  echo "总执行时长：${TOTAL_HOURS}h"
  echo "平均执行时长：${AVG_MIN}m${AVG_SEC}s"
else
  echo "暂无足够的时长数据"
fi

# ============================================================
# 4. 成本估算
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    成本估算（参考）                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"

EST_INPUT_TOKENS=$((TOTAL*50000))
EST_OUTPUT_TOKENS=$((TOTAL*10000))

EST_COST_INPUT=$(echo "scale=2; $EST_INPUT_TOKENS*3/1000000" | bc 2>/dev/null || echo "N/A")
EST_COST_OUTPUT=$(echo "scale=2; $EST_OUTPUT_TOKENS*15/1000000" | bc 2>/dev/null || echo "N/A")
EST_COST_TOTAL=$(echo "scale=2; $EST_COST_INPUT+$EST_COST_OUTPUT" | bc 2>/dev/null || echo "N/A")

echo "假设每个任务平均：50k input tokens + 10k output tokens"
echo ""
echo "估算成本（Claude Code）:"
echo "  Input:  \$${EST_COST_INPUT:-N/A}"
echo "  Output: \$${EST_COST_OUTPUT:-N/A}"
echo "  总计：\$${EST_COST_TOTAL:-N/A}"
echo ""
echo "注：实际成本取决于任务复杂度，此为粗略估算"

# ============================================================
# 5. 最近任务列表
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    最近 5 个任务                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

shopt -s nullglob
task_files=("$TASKS_DIR"/*.json)
shopt -u nullglob

if [[ ${#task_files[@]} -gt 0 ]]; then
  for f in $(ls -t "${task_files[@]}" 2>/dev/null | head -5); do
    [[ -f "$f" ]] || continue
    task_id=$(jq_sanitize_file "$f" -r '.id')
    status=$(jq_sanitize_file "$f" -r '.status')
    agent=$(jq_sanitize_file "$f" -r '.agent')
    desc=$(jq_sanitize_file "$f" -r '.description' | head -c 40)
    
    case "$status" in
      done) icon="✅" ;;
      failed) icon="❌" ;;
      running) icon="🔄" ;;
      *) icon="📋" ;;
    esac
    
    echo "$icon [$task_id] $desc... ($agent)"
  done
else
  echo "暂无任务记录"
fi

echo ""
echo "====== 统计完成 ======"
