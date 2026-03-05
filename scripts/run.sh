#!/usr/bin/env bash
# run.sh - OpenClaw 调用 agent-cluster 脚本的统一入口
# 自动加载正确的 PATH 和环境变量
# 用法: run.sh <脚本名> [参数...]
# 示例: run.sh launch-agent feat-login /home/user/projects/autocode "实现登录" claude-code

CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 加载配置
source "$CLUSTER_DIR/config.env" 2>/dev/null || true

# 补全 PATH（nvm node、claude、tmux 等）
export PATH="/home/user/.nvm/versions/node/v22.22.0/bin:/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT="$1"
shift

exec "$CLUSTER_DIR/scripts/${SCRIPT}.sh" "$@"
