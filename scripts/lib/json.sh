#!/usr/bin/env bash

_json_cluster_dir() {
  if [[ -n "${CLUSTER_DIR:-}" ]]; then
    echo "$CLUSTER_DIR"
    return
  fi

  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$this_dir/../.." && pwd)
}

_json_sanitize_log_file() {
  local cluster_dir
  cluster_dir="$(_json_cluster_dir)"
  echo "${JSON_SANITIZE_LOG_FILE:-$cluster_dir/logs/json-sanitize.log}"
}

json_log_error() {
  local msg="$*"
  local log_file
  log_file="$(_json_sanitize_log_file)"

  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  printf '[%s] [json] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$log_file" 2>/dev/null || true
  printf '[%s] [json] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >&2
}

json_raw_snippet() {
  local file="$1"
  local max_bytes="${2:-200}"

  python3 - "$file" "$max_bytes" <<'PY'
import os
import sys

path = sys.argv[1]
max_bytes = int(sys.argv[2])

try:
    size = os.path.getsize(path)
except OSError:
    size = -1

try:
    with open(path, "rb") as f:
        data = f.read(max_bytes)
except OSError as e:
    print(f"<read_failed size={size} err={e}>")
    raise SystemExit(0)

text_preview = data.decode("utf-8", "replace")
# Use repr() so control chars render as \x00/\n etc.
print(f"size={size}B head_utf8={repr(text_preview)} head_hex={data.hex()}")
PY
}

sanitize_json() {
  if ! command -v python3 >/dev/null 2>&1; then
    # Best-effort fallback (may not handle NUL well).
    sed -E 's/[\x00-\x1F]//g'
    return
  fi

  python3 -c 'import re,sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(re.sub(rb"[\x00-\x1f]", b"", data))'
}

sanitize_json_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    json_log_error "sanitize_json_file: file not found: $file"
    return 1
  fi

  sanitize_json <"$file"
}

jq_sanitize_file() {
  local file="$1"
  shift

  local err_file rc
  err_file="$(mktemp)"

  sanitize_json_file "$file" | jq "$@" 2>"$err_file"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    local jq_args
    jq_args="$(printf '%q ' "$@")"

    local raw_preview jq_err_preview
    raw_preview="$(json_raw_snippet "$file" 160 2>/dev/null || echo "<snippet_failed>")"
    jq_err_preview="$(head -c 800 "$err_file" 2>/dev/null || true)"

    json_log_error "jq failed (rc=$rc) file=$file args=[$jq_args] jq_err=$(printf %q "$jq_err_preview") raw=[$raw_preview]"

    # Keep jq original stderr for interactive runs.
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2
    fi
  fi

  rm -f "$err_file" 2>/dev/null || true
  return $rc
}
