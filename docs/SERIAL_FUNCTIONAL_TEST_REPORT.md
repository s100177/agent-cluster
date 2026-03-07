# 串行化全功能测试报告

- 生成时间：2026-03-07 12:38:11
- 执行脚本：`scripts/serial-functional-test.sh`
- 执行模式：串行（每次仅启动 1 个服务）
- Browser Use 遥测：`BROWSERUSE_TELEMETRY=false`
- FastAPI lifespan：`--lifespan off`

## 端口分配

- phase1: `18101`
- phase2: `18102`
- phase3: `18103`
- extension: `18104`
- full-e2e: `18105`
- deploy: `18106`

## 汇总

- 总服务数：6
- 通过：6
- 失败：0

## 明细结果

| Suite | Worktree | Port | Startup | /health | /openapi.json | /metrics | Shutdown | Duration | Note |
|---|---|---:|---|---:|---:|---:|---|---:|---|
| phase1 | `worktrees/phase1-backend-integration` | 18101 | PASS | ERR | ERR | ERR | PASS | 2s | startup ok, HTTP probe blocked/unavailable in current env |
| phase2 | `worktrees/phase2-productization` | 18102 | PASS | ERR | ERR | ERR | PASS | 2s | startup ok, HTTP probe blocked/unavailable in current env |
| phase3 | `worktrees/phase3-advanced` | 18103 | PASS | ERR | ERR | ERR | PASS | 1s | startup ok, HTTP probe blocked/unavailable in current env |
| extension | `worktrees/browser-extension-mvp` | 18104 | PASS | ERR | ERR | ERR | PASS | 2s | startup ok, HTTP probe blocked/unavailable in current env |
| full-e2e | `worktrees/full-e2e-test` | 18105 | PASS | ERR | ERR | ERR | PASS | 1s | startup ok, HTTP probe blocked/unavailable in current env |
| deploy | `worktrees/deploy-test` | 18106 | PASS | ERR | ERR | ERR | PASS | 1s | startup ok, HTTP probe blocked/unavailable in current env |

## 原始日志

- 临时目录：`/tmp/serial-functional-test`
- 每个服务日志：`/tmp/serial-functional-test/<suite>.log`
