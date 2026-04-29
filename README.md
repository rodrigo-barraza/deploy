# Sun Deploy Kit

Shared deployment infrastructure for all services. Contains:

- **`lib.sh`** — Shared deploy library sourced by each service's `deploy.sh`
- **`deploy-all.sh`** — Orchestrator that deploys all services in dependency order

## How It Works

Each service repo has a thin `deploy.sh` wrapper that sets its config and sources `lib.sh`:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="prism"
DISPLAY_NAME="🔷 Prism"
source "${SCRIPT_DIR}/../deploy-kit/lib.sh"
```

The library handles the full pipeline: flag parsing, git pull, Docker build, SSH transfer, container restart, image pruning, and SMB fallback.

## Hook Points

Services with special needs define functions before sourcing:

| Hook | Purpose | Used by |
|---|---|---|
| `EXTRA_VALIDATE()` | Additional file checks | vault |
| `PRE_BUILD()` | Set `BUILD_ARGS` before Docker build | portal, retina, rod-dev |
| `EXTRA_SSH_SYNC()` | Sync extra files during SSH deploy | vault, rod-dev |
| `EXTRA_SMB_SYNC()` | Sync extra files during SMB fallback | vault |

## Config Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `IMAGE_NAME` | ✅ | — | Docker image name |
| `DISPLAY_NAME` | ❌ | `IMAGE_NAME` | Header label with emoji |
| `BUILD_ARGS` | ❌ | `""` | Extra `--build-arg` flags |
| `BUILD_EXTRA_FLAGS` | ❌ | `""` | Extra Docker build flags (e.g. `--network=host`) |
| `BUILD_TAIL_LINES` | ❌ | `5` | Lines of build output to show |
| `SKIP_ENV_DEPLOY` | ❌ | `false` | Skip `.env.deploy` validation |

## Usage

```bash
# Single service (from service dir)
npm run deploy
npm run deploy -- --dry-run

# All services (from sun/ root)
npm run deploy
npm run deploy:dry
npm run deploy -- --only=prism,retina
npm run deploy -- --skip=lupos
```
