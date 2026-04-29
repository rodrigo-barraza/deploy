#!/bin/bash
# ============================================================
# Sun Deploy Kit — Shared Library
#
# Source this file from a per-service deploy.sh after setting:
#
#   IMAGE_NAME       (required)  e.g. "prism-service"
#   DISPLAY_NAME     (optional)  e.g. "🔷 Prism Service"     — defaults to IMAGE_NAME
#   BUILD_ARGS       (optional)  extra --build-arg flags
#   BUILD_EXTRA_FLAGS(optional)  e.g. "--network=host"
#   BUILD_TAIL_LINES (optional)  lines of build output to show (default: 5)
#   SKIP_ENV_DEPLOY  (optional)  set "true" to skip .env.deploy validation
#
# Hook functions (define before sourcing):
#   EXTRA_VALIDATE()   — additional file checks
#   PRE_BUILD()        — runs before docker build (set BUILD_ARGS here)
#   EXTRA_SSH_SYNC()   — sync extra files during SSH deploy
#   EXTRA_SMB_SYNC()   — sync extra files during SMB fallback
#
# Usage:
#   npm run deploy              # full deploy
#   npm run deploy -- --dry-run # validate without deploying
#   npm run deploy -- --skip-pull
#   npm run deploy -- --no-cache
# ============================================================

# ── Guard ─────────────────────────────────────────────────────
if [ -z "${IMAGE_NAME:-}" ]; then
  echo "ERROR: IMAGE_NAME must be set before sourcing lib.sh" >&2
  exit 1
fi
if [ -z "${SCRIPT_DIR:-}" ]; then
  echo "ERROR: SCRIPT_DIR must be set before sourcing lib.sh" >&2
  exit 1
fi

# ── Defaults ──────────────────────────────────────────────────
DISPLAY_NAME="${DISPLAY_NAME:-$IMAGE_NAME}"
BUILD_ARGS="${BUILD_ARGS:-}"
BUILD_EXTRA_FLAGS="${BUILD_EXTRA_FLAGS:-}"
BUILD_TAIL_LINES="${BUILD_TAIL_LINES:-5}"
SKIP_ENV_DEPLOY="${SKIP_ENV_DEPLOY:-false}"

NAS_HOST="nas"                                        # SSH config alias
NAS_COMPOSE_DIR="/volume1/docker/${IMAGE_NAME}"       # Synology path
NAS_SMB_DIR="/mnt/k/${IMAGE_NAME}"                    # SMB fallback
DOCKER_BIN="/usr/local/bin/docker"                    # Synology docker path

# ── Flags ─────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PULL=false
NO_CACHE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --skip-pull)  SKIP_PULL=true ;;
    --no-cache)   NO_CACHE="--no-cache" ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

step()  { echo -e "\n${CYAN}${BOLD}▸ $1${RESET}"; }
info()  { echo -e "  ${DIM}$1${RESET}"; }
ok()    { echo -e "  ${GREEN}✔ $1${RESET}"; }
warn()  { echo -e "  ${YELLOW}⚠ $1${RESET}"; }
fail()  { echo -e "  ${RED}✖ $1${RESET}"; exit 1; }

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS

# ── Header ────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}  ${DISPLAY_NAME} — Deploy to Synology${RESET}"
if $DRY_RUN; then
  echo -e "${YELLOW}${BOLD}  ⚠  DRY RUN — no changes will be made${RESET}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"

# ── Validate required files ──────────────────────────────────
step "Validating deployment files"

DEPLOY_ENV="${SCRIPT_DIR}/.env.deploy"
if [ "$SKIP_ENV_DEPLOY" != "true" ]; then
  if [ ! -f "$DEPLOY_ENV" ]; then
    fail ".env.deploy not found at ${DEPLOY_ENV} — create it with runtime env vars (VAULT_SERVICE_URL, VAULT_SERVICE_TOKEN, etc.)"
  fi
  ok ".env.deploy found ($(wc -l < "$DEPLOY_ENV") lines)"
fi

# Call optional extra validation hook
if type EXTRA_VALIDATE &>/dev/null; then
  EXTRA_VALIDATE
fi

# ── Git info ──────────────────────────────────────────────────
cd "$SCRIPT_DIR"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
info "Branch: ${GIT_BRANCH} @ ${GIT_SHA}"
info "Time:   ${BUILD_TIME}"

# ── Detect SSH access (retry with jittered backoff for parallel tiers) ──
HAS_SSH=false
for _ssh_attempt in 1 2; do
  if ssh -o ConnectTimeout=8 -o BatchMode=yes "$NAS_HOST" "true" 2>/dev/null; then
    HAS_SSH=true
    ok "SSH access to ${NAS_HOST} confirmed"
    break
  fi
  if [ "$_ssh_attempt" -eq 1 ]; then
    # Jittered backoff: 2-5s random delay before retry (avoids thundering herd)
    _jitter=$(( (RANDOM % 4) + 2 ))
    info "SSH probe failed — retrying in ${_jitter}s..."
    sleep "$_jitter"
  fi
done
if ! $HAS_SSH; then
  warn "SSH to '${NAS_HOST}' unavailable after 2 attempts — will fall back to SMB export"
fi

# ── 1. Pull latest ────────────────────────────────────────────
if ! $SKIP_PULL; then
  step "Pulling latest changes"
  if $DRY_RUN; then
    info "(skipped — dry run)"
  else
    git pull --ff-only 2>&1 | sed 's/^/  /'
    GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    ok "Now at ${GIT_SHA}"
  fi
else
  info "Skipping git pull (--skip-pull)"
fi

# ── 2. Build image ────────────────────────────────────────────
TAG_LATEST="${IMAGE_NAME}:latest"
TAG_SHA="${IMAGE_NAME}:${GIT_SHA}"

# Call optional pre-build hook (sets BUILD_ARGS, etc.)
if type PRE_BUILD &>/dev/null; then
  PRE_BUILD
fi

step "Building Docker image"
info "Tags: ${TAG_LATEST}, ${TAG_SHA}"

if $DRY_RUN; then
  info "(skipped — dry run)"
else
  BUILD_START=$SECONDS
  docker build \
    $NO_CACHE \
    $BUILD_EXTRA_FLAGS \
    $BUILD_ARGS \
    --label "git.sha=${GIT_SHA}" \
    --label "git.branch=${GIT_BRANCH}" \
    --label "build.time=${BUILD_TIME}" \
    -t "$TAG_LATEST" \
    -t "$TAG_SHA" \
    . 2>&1 | tail -${BUILD_TAIL_LINES} | sed 's/^/  /'
  ok "Built in $((SECONDS - BUILD_START))s"
fi

# ── 3. Deploy ─────────────────────────────────────────────────
if $HAS_SSH; then
  # ── SSH path: pipe image + copy env + restart ──────────────
  step "Deploying via SSH → ${NAS_HOST}"

  if $DRY_RUN; then
    info "(skipped — dry run)"
  else
    # Ensure compose directory exists on NAS
    ssh "$NAS_HOST" "mkdir -p '${NAS_COMPOSE_DIR}' 2>/dev/null || sudo mkdir -p '${NAS_COMPOSE_DIR}'"

    # Copy docker-compose.yml
    info "Syncing docker-compose.yml..."
    cat "${SCRIPT_DIR}/docker-compose.yml" | ssh "$NAS_HOST" "cat > '${NAS_COMPOSE_DIR}/docker-compose.yml'"

    # Copy .env.deploy → .env on NAS (unless skipped)
    if [ "$SKIP_ENV_DEPLOY" != "true" ] && [ -f "$DEPLOY_ENV" ]; then
      info "Syncing .env.deploy → .env..."
      cat "$DEPLOY_ENV" | ssh "$NAS_HOST" "cat > '${NAS_COMPOSE_DIR}/.env'"
      ok ".env synced"
    fi

    # Call optional extra SSH sync hook
    if type EXTRA_SSH_SYNC &>/dev/null; then
      EXTRA_SSH_SYNC
    fi

    # Pipe image directly — no temp file, no SMB
    TRANSFER_START=$SECONDS
    info "Piping image over SSH (this may take a moment)..."
    docker save "$TAG_LATEST" | gzip | ssh "$NAS_HOST" "gunzip | sudo ${DOCKER_BIN} load"
    ok "Image transferred in $((SECONDS - TRANSFER_START))s"

    # Restart container
    info "Restarting container..."
    ssh "$NAS_HOST" "cd '${NAS_COMPOSE_DIR}' && sudo ${DOCKER_BIN} compose down --remove-orphans && sudo ${DOCKER_BIN} compose up -d"
    ok "Container restarted"

    # Clean up old SHA-tagged images (keeps only :latest)
    info "Pruning old images..."
    ssh "$NAS_HOST" "sudo ${DOCKER_BIN} images '${IMAGE_NAME}' --format '{{.Tag}} {{.ID}}' \
      | grep -v 'latest' \
      | awk '{print \$2}' \
      | xargs -r sudo ${DOCKER_BIN} rmi 2>/dev/null || true"
    ssh "$NAS_HOST" "sudo ${DOCKER_BIN} image prune -f" 2>/dev/null | sed 's/^/  /' || true
  fi

else
  # ── SMB fallback: export tarball to K: ─────────────────────
  step "Exporting via SMB → ${NAS_SMB_DIR}"

  if $DRY_RUN; then
    info "(skipped — dry run)"
  else
    TARBALL="${IMAGE_NAME}.tar.gz"

    info "Saving image..."
    docker save "$TAG_LATEST" | gzip > "/tmp/${TARBALL}"

    info "Copying to NAS..."
    if ! mkdir -p "${NAS_SMB_DIR}" 2>/dev/null; then
      rm -f "/tmp/${TARBALL}"
      echo -e "  ${RED}✖ Cannot create ${NAS_SMB_DIR} — is /mnt/k mounted? Check permissions.${RESET}" >&2
      exit 1
    fi

    if ! cp "/tmp/${TARBALL}" "${NAS_SMB_DIR}/${TARBALL}"; then
      rm -f "/tmp/${TARBALL}"
      echo -e "  ${RED}✖ Failed to copy image tarball to ${NAS_SMB_DIR}${RESET}" >&2
      exit 1
    fi

    if ! cp "${SCRIPT_DIR}/docker-compose.yml" "${NAS_SMB_DIR}/docker-compose.yml"; then
      rm -f "/tmp/${TARBALL}"
      echo -e "  ${RED}✖ Failed to copy docker-compose.yml to ${NAS_SMB_DIR}${RESET}" >&2
      exit 1
    fi

    if [ "$SKIP_ENV_DEPLOY" != "true" ] && [ -f "$DEPLOY_ENV" ]; then
      if ! cp "$DEPLOY_ENV" "${NAS_SMB_DIR}/.env"; then
        rm -f "/tmp/${TARBALL}"
        echo -e "  ${RED}✖ Failed to copy .env to ${NAS_SMB_DIR}${RESET}" >&2
        exit 1
      fi
    fi

    # Call optional extra SMB sync hook
    if type EXTRA_SMB_SYNC &>/dev/null; then
      EXTRA_SMB_SYNC
    fi

    rm -f "/tmp/${TARBALL}"

    ok "Image exported to ${NAS_SMB_DIR}/${TARBALL}"
    echo ""
    warn "Manual steps required in Synology Container Manager:"
    info "  1. Image → Add → From File → select ${TARBALL}"
    info "  2. Project → ${IMAGE_NAME} → Stop → Start"
  fi
fi

# ── Summary ───────────────────────────────────────────────────
TOTAL=$((SECONDS - DEPLOY_START))
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✅ Deploy complete in ${TOTAL}s${RESET}"
echo -e "${DIM}  ${GIT_BRANCH}@${GIT_SHA} → ${NAS_HOST} (${BUILD_TIME})${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
