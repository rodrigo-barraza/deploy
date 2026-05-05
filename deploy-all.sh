#!/bin/bash
# ============================================================
# Deploy All Services
#
# Two-phase pipeline:
#   Phase 1 — BUILD: all services build in parallel (or sequential
#             with --no-parallel). Builds across ALL tiers start
#             simultaneously so total build time ≈ slowest build.
#   Phase 2 — DEPLOY: services deploy tier-by-tier in order.
#             Each tier waits only for its own builds to finish
#             before deploying (earlier tiers may deploy while
#             later tiers are still building).
#
# Tiers are auto-derived from vault-service/services.json:
#   0. Foundation   — secret store (must be up first)
#   1. APIs         — backend services
#   2. Mid-tier     — services depending on tier-1
#   3. Clients/Bots — frontends, dashboards, bots
#
# Usage:
#   npm run deploy                         # full deploy
#   npm run deploy -- --dry-run            # validate only
#   npm run deploy -- --skip-pull          # skip git pull
#   npm run deploy -- --no-cache           # rebuild images from scratch
#   npm run deploy -- --changed-only       # only build+deploy services with git changes
#   npm run deploy -- --only=prism-service,prism-client  # deploy specific services
#   npm run deploy -- --skip=lupos-bot,lights-service  # skip specific services
#   npm run deploy -- --no-parallel        # disable parallel builds
# ============================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # sun/ parent directory
LOG_DIR="${SCRIPT_DIR}/.deploy-logs"
SERVICES_JSON="${ROOT_DIR}/vault-service/services.json"

# ── Verify services.json ──────────────────────────────────────
if [ ! -f "$SERVICES_JSON" ]; then
  echo "ERROR: services.json not found at ${SERVICES_JSON}" >&2
  exit 1
fi

# ── Dynamically load tiers from services.json ─────────────────
# Uses Node.js (always available) to parse JSON and emit bash-eval
# assignments: MAX_TIER, TIER_SERVICES[n], TIER_<n> arrays,
# and SVC_HEALTH_URL[id] for health-gating between tiers.
ALL_SERVICES=()
declare -A TIER_SERVICES  # tier -> space-separated service IDs
declare -A SVC_HEALTH_URL # service-id -> health check URL

eval "$(node -e "
  const s = require('$SERVICES_JSON');
  const host = s.defaultHost || 'localhost';
  const tiers = {};
  for (const svc of s.services) {
    (tiers[svc.deployTier] ??= []).push(svc.id);
    if (svc.port && svc.healthPath) {
      console.log('SVC_HEALTH_URL[' + svc.id + ']=\"http://' + host + ':' + svc.port + svc.healthPath + '\"');
    }
  }
  const max = Math.max(...Object.keys(tiers).map(Number));
  console.log('MAX_TIER=' + max);
  for (let t = 0; t <= max; t++) {
    const ids = (tiers[t] || []).join(' ');
    console.log('TIER_SERVICES[' + t + ']=\"' + ids + '\"');
    console.log('TIER_' + t + '=(' + ids + ')');
  }
")"

for s in "${!TIER_SERVICES[@]}"; do
  for id in ${TIER_SERVICES[$s]}; do
    ALL_SERVICES+=("$id")
  done
done

# ── Service colors (semantic per-category shades) ────────────
# Services=blue, Clients=green, Bots=yellow. Red is errors only.
# Shades rotate within each category for visual differentiation.
declare -A SVC_COLORS
for svc in "${ALL_SERVICES[@]}"; do
  SVC_COLORS[$svc]=$(svc_color "$svc")
done

# ── Flags ─────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PULL=false
NO_CACHE=false
NO_PARALLEL=false
ONLY=""
SKIP_LIST=""
CHANGED_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --skip-pull)      SKIP_PULL=true ;;
    --no-cache)       NO_CACHE=true ;;
    --no-parallel)    NO_PARALLEL=true ;;
    --changed-only)   CHANGED_ONLY=true ;;
    --only=*)         ONLY="${arg#--only=}" ;;
    --skip=*)         SKIP_LIST="${arg#--skip=}" ;;
  esac
done

# ── Colors & logging (shared) ─────────────────────────────────
source "${SCRIPT_DIR}/colors.sh"

# ── Service filter ────────────────────────────────────────────
should_deploy() {
  local svc="$1"

  # --only filter: if set, service must be in the list
  if [ -n "$ONLY" ]; then
    echo ",$ONLY," | grep -q ",$svc," && return 0 || return 1
  fi

  # --skip filter: if set, service must NOT be in the list
  if [ -n "$SKIP_LIST" ]; then
    echo ",$SKIP_LIST," | grep -q ",$svc," && return 1 || return 0
  fi

  return 0
}

# ── Change detection ──────────────────────────────────────────
# Returns 0 (true) if service has changes since last built image
has_changes() {
  local svc="$1"
  local svc_dir="${ROOT_DIR}/${svc}"

  # If --changed-only is not set, always consider changed
  if ! $CHANGED_ONLY; then
    return 0
  fi

  # Get the git SHA baked into the current :latest image label
  local last_sha
  last_sha=$(docker inspect --format '{{index .Config.Labels "git.sha"}}' "${svc}:latest" 2>/dev/null || echo "")

  if [ -z "$last_sha" ]; then
    # No previous image or no label — must build
    return 0
  fi

  # Check if there are any changes since that SHA
  if (cd "$svc_dir" && git diff --quiet "$last_sha" HEAD -- . 2>/dev/null); then
    # No changes
    return 1
  fi

  return 0
}

# ── Build deploy flags ────────────────────────────────────────
build_flags() {
  local flags=""
  $DRY_RUN   && flags="$flags --dry-run"
  $SKIP_PULL && flags="$flags --skip-pull"
  $NO_CACHE  && flags="$flags --no-cache"
  echo "$flags"
}

# ── Run a phase (build or deploy) for a single service ────────
# Generic runner — accepts the phase name and deploy.sh flag.
#   $1  svc         service directory name
#   $2  prefix      "true" to prefix output with colored service name
#   $3  phase       "build" | "deploy" (used for log/status filenames)
#   $4  phase_flag  "--build-only" | "--deploy-only"
run_phase() {
  local svc="$1"
  local prefix="$2"
  local phase="$3"
  local phase_flag="$4"
  local svc_dir="${ROOT_DIR}/${svc}"
  local log_file="${LOG_DIR}/${svc}.${phase}.log"
  local status_file="${LOG_DIR}/${svc}.${phase}.status"
  local flags
  flags=$(build_flags)

  if [ ! -f "${svc_dir}/deploy.sh" ]; then
    [ "$phase" = "build" ] && fail "${svc}: no deploy.sh found — skipping"
    echo "SKIP" > "$status_file"
    return 0
  fi

  local color="${SVC_COLORS[$svc]:-$DIM}"
  local pad_svc
  pad_svc=$(printf '%-20s' "$svc")

  if [ "$prefix" = "true" ]; then
    bash "${svc_dir}/deploy.sh" ${phase_flag} $flags 2>&1 \
      | tee "$log_file" \
      | while IFS= read -r line; do printf '%s %s%s[%s]%s %s\n' "$(ts)" "$color" "$BOLD" "$pad_svc" "$RESET" "$line"; done \
      && echo "OK" > "$status_file" \
      || echo "FAIL" > "$status_file"
  else
    bash "${svc_dir}/deploy.sh" ${phase_flag} $flags 2>&1 \
      | tee "$log_file" \
      && echo "OK" > "$status_file" \
      || echo "FAIL" > "$status_file"
  fi
}

build_service()  { run_phase "$1" "$2" "build"  "--build-only";  }
deploy_service() { run_phase "$1" "$2" "deploy" "--deploy-only"; }

# ── Fire builds for a tier (non-blocking) ─────────────────────
# Launches all build jobs as background processes and stores PIDs.
# Does NOT wait — returns immediately so the next tier can fire too.
fire_builds() {
  local tier_name="$1"
  shift
  local services=("$@")
  local svc

  # Filter to only services we should deploy
  local filtered=()
  for svc in "${services[@]}"; do
    if should_deploy "$svc"; then
      if has_changes "$svc"; then
        filtered+=("$svc")
      else
        info "Skipping ${svc} (unchanged since last build)"
        echo "SKIP" > "${LOG_DIR}/${svc}.build.status"
      fi
    else
      info "Skipping ${svc} (filtered)"
      echo "SKIP" > "${LOG_DIR}/${svc}.build.status"
    fi
  done

  if [ ${#filtered[@]} -eq 0 ]; then
    info "No services to build in ${tier_name}"
    return 0
  fi

  step "Launching builds — ${tier_name}: ${filtered[*]}"

  if $NO_PARALLEL; then
    # Sequential mode: run each build inline (blocking)
    for svc in "${filtered[@]}"; do
      build_service "$svc" "false"
      local status
      status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} built successfully"
      elif [ "$status" = "FAIL" ]; then
        fail "${svc} build failed"
        info "Log: ${LOG_DIR}/${svc}.build.log"
      fi
    done
  else
    # Parallel mode: fire all as background jobs
    for svc in "${filtered[@]}"; do
      build_service "$svc" "true" &
      echo "$!" > "${LOG_DIR}/${svc}.build.pid"
      info "  ⟶ ${svc} (PID $!)"
    done
  fi
}

# ── Wait for a tier's builds to finish ────────────────────────
# Called just before deploying a tier. Collects exit status for
# each service that was launched in fire_builds.
wait_builds() {
  local tier_name="$1"
  shift
  local services=("$@")
  local svc

  # In sequential (--no-parallel) mode, builds already completed inline
  if $NO_PARALLEL; then
    return 0
  fi

  local any_waiting=false
  for svc in "${services[@]}"; do
    if [ -f "${LOG_DIR}/${svc}.build.pid" ]; then
      any_waiting=true
      break
    fi
  done

  if ! $any_waiting; then
    return 0
  fi

  step "Waiting for ${tier_name} builds to finish"

  local any_failed=false
  for svc in "${services[@]}"; do
    local pid_file="${LOG_DIR}/${svc}.build.pid"
    if [ ! -f "$pid_file" ]; then
      continue
    fi

    local pid
    pid=$(cat "$pid_file")
    wait "$pid" || true

    local status
    status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "OK" ]; then
      ok "${svc} built successfully"
    else
      fail "${svc} build failed → ${LOG_DIR}/${svc}.build.log"
      any_failed=true
    fi
  done

  if $any_failed; then
    warn "Some builds in ${tier_name} failed — check logs in ${LOG_DIR}/"
  fi
}

# ── Deploy a tier (sequential — respect tier ordering) ────────
deploy_tier() {
  local tier_name="$1"
  shift
  local services=("$@")
  local svc

  # Wait for this tier's builds before attempting deploy
  wait_builds "$tier_name" "${services[@]}"

  # Filter to only services we should deploy
  local filtered=()
  for svc in "${services[@]}"; do
    if should_deploy "$svc"; then
      # Only deploy if build succeeded
      local build_status
      build_status=$(cat "${LOG_DIR}/${svc}.build.status" 2>/dev/null || echo "SKIP")
      if [ "$build_status" = "OK" ]; then
        filtered+=("$svc")
      elif [ "$build_status" = "FAIL" ]; then
        fail "${svc}: build failed — skipping deploy"
        echo "FAIL" > "${LOG_DIR}/${svc}.deploy.status"
      else
        echo "SKIP" > "${LOG_DIR}/${svc}.deploy.status"
      fi
    else
      echo "SKIP" > "${LOG_DIR}/${svc}.deploy.status"
    fi
  done

  if [ ${#filtered[@]} -eq 0 ]; then
    info "No services to deploy in ${tier_name}"
    return 0
  fi

  step "Deploying ${tier_name}: ${filtered[*]}"

  if $NO_PARALLEL || [ ${#filtered[@]} -eq 1 ]; then
    # Sequential deploy
    for svc in "${filtered[@]}"; do
      deploy_service "$svc" "false"
      local status
      status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} deployed successfully"
      elif [ "$status" = "FAIL" ]; then
        fail "${svc} deployment failed"
        info "Log: ${LOG_DIR}/${svc}.deploy.log"

        # Tier 0 failure is fatal — vault must succeed
        if [ "$tier_name" = "Tier 0 — Foundation" ]; then
          fail "Vault deployment failed — aborting all subsequent tiers"
          return 1
        fi
      fi
    done
  else
    # Parallel deploy within tier
    local pids=()
    for svc in "${filtered[@]}"; do
      deploy_service "$svc" "true" &
      pids+=("$!:$svc")
    done

    local any_failed=false
    for entry in "${pids[@]}"; do
      local pid="${entry%%:*}"
      local svc="${entry##*:}"
      wait "$pid" || true
      local status
      status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} deployed successfully"
      else
        fail "${svc} deployment failed → ${LOG_DIR}/${svc}.deploy.log"
        any_failed=true
      fi
    done

    if $any_failed; then
      warn "Some deploys in ${tier_name} failed — check logs in ${LOG_DIR}/"
    fi
  fi
}

# ── Health-gate: wait for a tier to become healthy ────────────
# After deploying a tier, poll health endpoints until all services
# respond 2xx or timeout. Prevents boot-order races where later
# tiers start before their dependencies are ready.
HEALTH_GATE_TIMEOUT=60    # seconds per service
HEALTH_GATE_INTERVAL=3    # seconds between polls

wait_tier_healthy() {
  local tier_name="$1"
  shift
  local services=("$@")

  # Only gate services that were actually deployed
  local to_check=()
  for svc in "${services[@]}"; do
    local deploy_status
    deploy_status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "SKIP")
    if [ "$deploy_status" = "OK" ] && [ -n "${SVC_HEALTH_URL[$svc]:-}" ]; then
      to_check+=("$svc")
    fi
  done

  if [ ${#to_check[@]} -eq 0 ]; then
    return 0
  fi

  step "Health gate — waiting for ${tier_name} services to become healthy"

  local all_healthy=true
  for svc in "${to_check[@]}"; do
    local url="${SVC_HEALTH_URL[$svc]}"
    local elapsed=0
    local healthy=false

    while [ $elapsed -lt $HEALTH_GATE_TIMEOUT ]; do
      if curl -sf --max-time 5 -o /dev/null "$url" 2>/dev/null; then
        healthy=true
        break
      fi
      sleep $HEALTH_GATE_INTERVAL
      elapsed=$((elapsed + HEALTH_GATE_INTERVAL))
    done

    if $healthy; then
      ok "${svc} healthy (${url})"
    else
      warn "${svc} not healthy after ${HEALTH_GATE_TIMEOUT}s — proceeding anyway"
      all_healthy=false
    fi
  done

  if $all_healthy; then
    ok "All ${tier_name} services healthy ✓"
  fi
}

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS

# ── Header ────────────────────────────────────────────────────
echo ""
printf '%s%s══════════════════════════════════════════════════════════════%s\n' "$MAGENTA" "$BOLD" "$RESET"
printf '%s%s  🚀  Deploy All Services%s\n' "$MAGENTA" "$BOLD" "$RESET"
printf '  %sTwo-phase pipeline: build all → deploy in order%s\n' "$DIM" "$RESET"
if $DRY_RUN; then
  printf '%s%s  ⚠  DRY RUN — no changes will be made%s\n' "$YELLOW" "$BOLD" "$RESET"
fi
if [ -n "$ONLY" ]; then
  printf '  %sOnly: %s%s\n' "$CYAN" "$ONLY" "$RESET"
fi
if [ -n "$SKIP_LIST" ]; then
  printf '  %sSkipping: %s%s\n' "$CYAN" "$SKIP_LIST" "$RESET"
fi
if $CHANGED_ONLY; then
  printf '  %sMode: changed-only (skipping unchanged services)%s\n' "$CYAN" "$RESET"
fi
printf '%s%s══════════════════════════════════════════════════════════════%s\n' "$MAGENTA" "$BOLD" "$RESET"

# ── Prepare log directory ─────────────────────────────────────
mkdir -p "$LOG_DIR"
rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/*.status "${LOG_DIR}"/*.pid 2>/dev/null

# ── Validate all services have deploy.sh ──────────────────────
step "Pre-flight check"
MISSING=()
for svc in "${ALL_SERVICES[@]}"; do
  if should_deploy "$svc"; then
    if [ -f "${ROOT_DIR}/${svc}/deploy.sh" ]; then
      ok "${svc}/deploy.sh"
    else
      fail "${svc}/deploy.sh not found"
      MISSING+=("$svc")
    fi
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  warn "Missing deploy scripts: ${MISSING[*]}"
  warn "These services will be skipped"
fi

# ── Pre-flight: prune orphaned Docker networks on NAS ─────────
# Docker has a limited pool of /16 subnets for bridge networks.
# Old/renamed services leave behind orphaned networks that exhaust
# the pool, causing "could not find an available IPv4 address pool"
# errors during deploy. Pruning unused networks prevents this.
if ! $DRY_RUN; then
  step "Pruning orphaned Docker networks on NAS"
  if ssh -o ConnectTimeout=8 -o BatchMode=yes nas "true" 2>/dev/null; then
    PRUNED=$(ssh nas "sudo /usr/local/bin/docker network prune -f 2>&1" || true)
    PRUNED_COUNT=$(echo "$PRUNED" | grep -c "Deleted Networks:" || echo "0")
    PRUNED_NAMES=$(echo "$PRUNED" | grep -v "Deleted Networks:" | grep -v "Total reclaimed" | grep -v "^$" | tr '\n' ' ' || true)
    if [ -n "$PRUNED_NAMES" ]; then
      ok "Pruned: ${PRUNED_NAMES}"
    else
      ok "No orphaned networks"
    fi
  else
    warn "Cannot reach NAS — skipping network prune (may fail later)"
  fi
fi

# ── Tier labels (descriptive names for output) ───────────────
declare -A TIER_LABELS=(
  [0]="Tier 0 — Foundation"
  [1]="Tier 1 — APIs & Services"
  [2]="Tier 2 — Clients & Bots"
)

# ══════════════════════════════════════════════════════════════
# PHASE 1 — BUILD ALL (fire all tiers simultaneously)
# ══════════════════════════════════════════════════════════════
echo ""
printf '%s%s┌──────────────────────────────────────────────────────────┐%s\n' "$CYAN" "$BOLD" "$RESET"
printf '%s%s│  PHASE 1 — BUILD                                        │%s\n' "$CYAN" "$BOLD" "$RESET"
printf '%s%s│  All services build in parallel across all tiers         │%s\n' "$CYAN" "$BOLD" "$RESET"
printf '%s%s└──────────────────────────────────────────────────────────┘%s\n' "$CYAN" "$BOLD" "$RESET"


# Fire all builds at once — no waiting between tiers
for tier in $(seq 0 "$MAX_TIER"); do
  tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
  # shellcheck disable=SC2206
  tier_svcs=(${TIER_SERVICES[$tier]})
  if [ ${#tier_svcs[@]} -gt 0 ]; then
    fire_builds "$tier_label" "${tier_svcs[@]}"
  fi
done

if ! $NO_PARALLEL; then
  echo ""
  info "All builds launched — waiting will happen per-tier before deploy"
fi

# ══════════════════════════════════════════════════════════════
# PHASE 2 — WAIT & DEPLOY IN ORDER
# ══════════════════════════════════════════════════════════════
echo ""
printf '%s%s┌──────────────────────────────────────────────────────────┐%s\n' "$GREEN" "$BOLD" "$RESET"
printf '%s%s│  PHASE 2 — DEPLOY                                       │%s\n' "$GREEN" "$BOLD" "$RESET"
printf '%s%s│  Transfer & restart tier-by-tier in dependency order     │%s\n' "$GREEN" "$BOLD" "$RESET"
printf '%s%s└──────────────────────────────────────────────────────────┘%s\n' "$GREEN" "$BOLD" "$RESET"


for tier in $(seq 0 "$MAX_TIER"); do
  tier_label="${TIER_LABELS[$tier]:-Tier $tier}"
  # shellcheck disable=SC2206
  tier_svcs=(${TIER_SERVICES[$tier]})
  if [ ${#tier_svcs[@]} -eq 0 ]; then
    continue
  fi

  header "━━━ ${tier_label} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if ! deploy_tier "$tier_label" "${tier_svcs[@]}"; then
    # Tier 0 failure is fatal — vault must succeed
    if [ "$tier" -eq 0 ]; then
      fail "Aborting deployment — foundation tier failed"
      exit 1
    fi
  fi

  # Health-gate: wait for this tier's services to become healthy
  # before deploying the next tier (skip for the last tier).
  if [ "$tier" -lt "$MAX_TIER" ] && ! $DRY_RUN; then
    wait_tier_healthy "$tier_label" "${tier_svcs[@]}"
  fi
done


# ── Summary ───────────────────────────────────────────────────
TOTAL=$((SECONDS - DEPLOY_START))

echo ""
printf '%s%s══════════════════════════════════════════════════════════════%s\n' "$MAGENTA" "$BOLD" "$RESET"
printf '%s%s  ☀️  Deploy All — Summary%s\n' "$MAGENTA" "$BOLD" "$RESET"
printf '%s%s══════════════════════════════════════════════════════════════%s\n' "$MAGENTA" "$BOLD" "$RESET"

PASS=0
FAILED=0
SKIPPED=0

for svc in "${ALL_SERVICES[@]}"; do
  local_status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "SKIP")
  local svc_clr="${SVC_COLORS[$svc]:-$DIM}"
  case "$local_status" in
    OK)   printf '  %s✔ %s%s\n' "$svc_clr" "$svc" "$RESET"; PASS=$((PASS + 1)) ;;
    FAIL) printf '  %s✖ %s%s  →  %s\n' "$RED" "$svc" "$RESET" "${LOG_DIR}/${svc}.deploy.log"; FAILED=$((FAILED + 1)) ;;
    *)    printf '  %s⊘ %s (skipped)%s\n' "$DIM" "$svc" "$RESET"; SKIPPED=$((SKIPPED + 1)) ;;
  esac
done

echo ""
printf '  %s%s passed%s  %s%s failed%s  %s%s skipped%s\n' "$GREEN" "$PASS" "$RESET" "$RED" "$FAILED" "$RESET" "$DIM" "$SKIPPED" "$RESET"
printf '  %sTotal: %ss%s\n' "$DIM" "$TOTAL" "$RESET"
echo ""
printf '%s%s══════════════════════════════════════════════════════════════%s\n' "$MAGENTA" "$BOLD" "$RESET"

# Non-zero exit if anything failed
[ "$FAILED" -eq 0 ]
