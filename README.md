# Deploy Kit

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

## Usage

```bash
# Full deploy (all services)
npm run deploy

# Dry run (validate only)
npm run deploy:dry

# Deploy only changed services
npm run deploy:changed
```

### Group Deploy

Deploy by category — services are classified by their ID suffix (`-service`, `-client`, `-bot`):

```bash
# By category
npm run deploy:clients          # all *-client services
npm run deploy:services         # all *-service services (excludes vault)
npm run deploy:bots             # all *-bot services
npm run deploy:vault            # vault-service only

# Combine groups
npm run deploy -- --clients --bots         # clients + bots
npm run deploy -- --group=client,service   # clients + services

# Groups compose with other flags
npm run deploy:clients -- --changed-only   # only changed clients
npm run deploy:services -- --no-cache      # rebuild all service images
npm run deploy:clients -- --skip=rod-dev-client  # all clients except rod-dev
```

### Individual Deploy

```bash
# From deploy-kit/
npm run deploy:prism-service
npm run deploy:prism-client
npm run deploy:lupos-bot
# ... etc (see package.json for full list)

# Specific services via flag
npm run deploy -- --only=prism-service,prism-client

# Skip specific services
npm run deploy -- --skip=lupos-bot,lights-service
```

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Validate only, no changes |
| `--skip-pull` | Skip git pull |
| `--no-cache` | Rebuild images from scratch |
| `--no-parallel` | Disable parallel builds |
| `--changed-only` | Only build+deploy services with git changes |
| `--only=a,b` | Deploy only these specific services |
| `--skip=a,b` | Skip these specific services |
| `--clients` | Deploy all `*-client` services |
| `--services` | Deploy all `*-service` services (excl. vault) |
| `--bots` | Deploy all `*-bot` services |
| `--vault` | Deploy `vault-service` only |
| `--group=x,y` | Deploy by category (`client`, `service`, `bot`, `vault`) |

## Hook Points

Services with special needs define functions before sourcing:

| Hook | Purpose | Used by |
|---|---|---|
| `EXTRA_VALIDATE()` | Additional file checks | vault |
| `PRE_BUILD()` | Set `BUILD_ARGS` before Docker build | portal, prism-client, rod-dev |
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
