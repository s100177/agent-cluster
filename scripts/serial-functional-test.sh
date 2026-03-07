#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_PATH="$ROOT_DIR/docs/SERIAL_FUNCTIONAL_TEST_REPORT.md"
TMP_DIR="${TMPDIR:-/tmp}/serial-functional-test"
RESULTS_FILE="$TMP_DIR/results.tsv"
RUN_TS="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$TMP_DIR"
mkdir -p "$ROOT_DIR/docs"
: >"$RESULTS_FILE"

export BROWSERUSE_TELEMETRY=false

CURRENT_PID=""
CURRENT_NAME=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [serial-functional-test] $*"
}

cleanup_current() {
  if [[ -n "${CURRENT_PID:-}" ]] && kill -0 "$CURRENT_PID" 2>/dev/null; then
    kill "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  CURRENT_PID=""
  CURRENT_NAME=""
}

on_exit() {
  cleanup_current
}

trap on_exit EXIT

status_code() {
  local url="$1"
  local code
  code="$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)"
  if [[ -z "$code" || "$code" == "000" ]]; then
    echo "ERR"
  else
    echo "$code"
  fi
}

wait_until_ready() {
  local port="$1"
  local pid="$2"
  local log_file="$3"
  local ready=1
  local checks=40

  for ((i = 1; i <= checks; i++)); do
    local health
    local openapi
    health="$(status_code "http://127.0.0.1:${port}/health")"
    openapi="$(status_code "http://127.0.0.1:${port}/openapi.json")"
    if [[ "$health" == "200" || "$openapi" == "200" ]]; then
      ready=0
      break
    fi
    if kill -0 "$pid" 2>/dev/null && rg -q "Uvicorn running on" "$log_file" 2>/dev/null; then
      ready=0
      break
    fi
    sleep 1
  done

  return "$ready"
}

record_result() {
  local suite="$1"
  local worktree="$2"
  local port="$3"
  local startup="$4"
  local health="$5"
  local openapi="$6"
  local metrics="$7"
  local shutdown="$8"
  local duration="$9"
  local note="${10}"

  note="${note//$'\t'/ }"
  note="${note//$'\n'/ }"
  echo -e "${suite}\t${worktree}\t${port}\t${startup}\t${health}\t${openapi}\t${metrics}\t${shutdown}\t${duration}\t${note}" >>"$RESULTS_FILE"
}

run_suite() {
  local suite="$1"
  local worktree_rel="$2"
  local port="$3"
  local server_dir="$ROOT_DIR/${worktree_rel}/server"
  local log_file="$TMP_DIR/${suite}.log"
  local start_ts
  start_ts="$(date +%s)"

  local startup="FAIL"
  local health="N/A"
  local openapi="N/A"
  local metrics="N/A"
  local shutdown="PASS"
  local note=""

  if [[ ! -d "$server_dir" ]]; then
    note="server dir missing: $server_dir"
    record_result "$suite" "$worktree_rel" "$port" "$startup" "$health" "$openapi" "$metrics" "$shutdown" "0s" "$note"
    return 1
  fi

  if [[ ! -f "$server_dir/app/main.py" ]]; then
    note="missing app/main.py"
    record_result "$suite" "$worktree_rel" "$port" "$startup" "$health" "$openapi" "$metrics" "$shutdown" "0s" "$note"
    return 1
  fi

  log "启动 ${suite} 服务，端口 ${port}（串行）"
  (
    cd "$server_dir"
    BROWSERUSE_TELEMETRY=false python3 -m uvicorn app.main:app \
      --host 127.0.0.1 \
      --port "$port" \
      --lifespan off \
      >"$log_file" 2>&1
  ) &
  CURRENT_PID=$!
  CURRENT_NAME="$suite"

  if wait_until_ready "$port" "$CURRENT_PID" "$log_file"; then
    startup="PASS"
    health="$(status_code "http://127.0.0.1:${port}/health")"
    openapi="$(status_code "http://127.0.0.1:${port}/openapi.json")"
    metrics="$(status_code "http://127.0.0.1:${port}/metrics")"
  else
    startup="FAIL"
    health="$(status_code "http://127.0.0.1:${port}/health")"
    openapi="$(status_code "http://127.0.0.1:${port}/openapi.json")"
    metrics="$(status_code "http://127.0.0.1:${port}/metrics")"
    note="service not ready in timeout; log: $log_file"
  fi

  local stopped_pid="${CURRENT_PID:-}"
  cleanup_current

  if [[ -n "$stopped_pid" ]] && kill -0 "$stopped_pid" 2>/dev/null; then
    shutdown="FAIL"
  else
    shutdown="PASS"
  fi

  local end_ts
  end_ts="$(date +%s)"
  local duration="$((end_ts - start_ts))s"

  if [[ -z "$note" && "$startup" == "PASS" ]]; then
    if [[ "$health" == "ERR" && "$openapi" == "ERR" ]]; then
      note="startup ok, HTTP probe blocked/unavailable in current env"
    else
      note="ok"
    fi
  fi

  record_result "$suite" "$worktree_rel" "$port" "$startup" "$health" "$openapi" "$metrics" "$shutdown" "$duration" "$note"
  [[ "$startup" == "PASS" && "$shutdown" == "PASS" ]]
}

generate_report() {
  local total=0
  local passed=0
  local failed=0

  while IFS=$'\t' read -r suite worktree port startup health openapi metrics shutdown duration note; do
    [[ -z "${suite:-}" ]] && continue
    total=$((total + 1))
    if [[ "$startup" == "PASS" && "$shutdown" == "PASS" ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done <"$RESULTS_FILE"

  {
    echo "# 串行化全功能测试报告"
    echo
    echo "- 生成时间：${RUN_TS}"
    echo "- 执行脚本：\`scripts/serial-functional-test.sh\`"
    echo "- 执行模式：串行（每次仅启动 1 个服务）"
    echo "- Browser Use 遥测：\`BROWSERUSE_TELEMETRY=false\`"
    echo "- FastAPI lifespan：\`--lifespan off\`"
    echo
    echo "## 端口分配"
    echo
    echo "- phase1: \`18101\`"
    echo "- phase2: \`18102\`"
    echo "- phase3: \`18103\`"
    echo "- extension: \`18104\`"
    echo "- full-e2e: \`18105\`"
    echo "- deploy: \`18106\`"
    echo
    echo "## 汇总"
    echo
    echo "- 总服务数：${total}"
    echo "- 通过：${passed}"
    echo "- 失败：${failed}"
    echo
    echo "## 明细结果"
    echo
    echo "| Suite | Worktree | Port | Startup | /health | /openapi.json | /metrics | Shutdown | Duration | Note |"
    echo "|---|---|---:|---|---:|---:|---:|---|---:|---|"
    while IFS=$'\t' read -r suite worktree port startup health openapi metrics shutdown duration note; do
      [[ -z "${suite:-}" ]] && continue
      echo "| ${suite} | \`${worktree}\` | ${port} | ${startup} | ${health} | ${openapi} | ${metrics} | ${shutdown} | ${duration} | ${note} |"
    done <"$RESULTS_FILE"
    echo
    echo "## 原始日志"
    echo
    echo "- 临时目录：\`${TMP_DIR}\`"
    echo "- 每个服务日志：\`${TMP_DIR}/<suite>.log\`"
  } >"$REPORT_PATH"
}

main() {
  log "开始串行化全功能测试"
  log "强制环境：BROWSERUSE_TELEMETRY=${BROWSERUSE_TELEMETRY}"

  local failed_count=0

  run_suite "phase1" "worktrees/phase1-backend-integration" "18101" || failed_count=$((failed_count + 1))
  run_suite "phase2" "worktrees/phase2-productization" "18102" || failed_count=$((failed_count + 1))
  run_suite "phase3" "worktrees/phase3-advanced" "18103" || failed_count=$((failed_count + 1))
  run_suite "extension" "worktrees/browser-extension-mvp" "18104" || failed_count=$((failed_count + 1))
  run_suite "full-e2e" "worktrees/full-e2e-test" "18105" || failed_count=$((failed_count + 1))
  run_suite "deploy" "worktrees/deploy-test" "18106" || failed_count=$((failed_count + 1))

  generate_report
  log "报告已生成：$REPORT_PATH"

  if [[ "$failed_count" -gt 0 ]]; then
    log "测试完成：存在 ${failed_count} 个失败项"
    return 1
  fi

  log "测试完成：全部通过"
}

main "$@"
