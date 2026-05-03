#!/bin/bash
# ============================================================
# Sun — Deploy All Services
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
# Tiers (sequential between tiers for deploy, parallel builds):
#   0. Foundation   — vault-service (secret store, must be up first)
#   1. APIs         — prism-service, tools-service, portal-service, lights-service, clock-crew-service
#   2. Clients/Bots — prism-client, portal-client, rod-dev-client, lupos-bot, clock-crew-client
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

# Deployment tiers — sequential between tiers, parallel within
TIER_0=(vault-service)
TIER_1=(prism-service tools-service portal-service lights-service clock-crew-service messages-service)
TIER_2=(prism-client portal-client rod-dev-client lupos-bot clock-crew-client messages-client lights-client classic-whitemane-client)

ALL_SERVICES=("${TIER_0[@]}" "${TIER_1[@]}" "${TIER_2[@]}")

# ── Service colors (for prefixed output in parallel mode) ─────
# Each service gets a unique color so interleaved output is readable
declare -A SVC_COLORS=(
  [vault-service]="\033[33m"          # yellow
  [prism-service]="\033[36m"          # cyan
  [tools-service]="\033[35m"          # magenta
  [portal-service]="\033[34m"         # blue
  [lights-service]="\033[32m"         # green
  [clock-crew-service]="\033[94m"     # bright blue
  [lupos-bot]="\033[91m"              # bright red
  [rod-dev-client]="\033[93m"         # bright yellow
  [prism-client]="\033[95m"          # bright magenta
  [portal-client]="\033[96m"          # bright cyan
  [clock-crew-client]="\033[96m"      # bright cyan
  [messages-service]="\033[92m"        # bright green
  [messages-client]="\033[33;1m"       # bold yellow
  [lights-client]="\033[32;1m"         # bold green
  [classic-whitemane-client]="\033[34;1m" # bold blue
)

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

# ── Colors ────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
MAGENTA="\033[35m"
RESET="\033[0m"

header()  { echo -e "\n${MAGENTA}${BOLD}$1${RESET}"; }
step()    { echo -e "\n${CYAN}${BOLD}▸ $1${RESET}"; }
info()    { echo -e "  ${DIM}$1${RESET}"; }
ok()      { echo -e "  ${GREEN}✔ $1${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${RESET}"; }
fail()    { echo -e "  ${RED}✖ $1${RESET}"; }

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
      | sed -u "s/^/${color}${BOLD}[${pad_svc}]${RESET} /" \
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

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS

# ── Header ────────────────────────────────────────────────────
echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${MAGENTA}${BOLD}  ☀️  Sun — Deploy All Services${RESET}"
echo -e "${DIM}  Two-phase pipeline: build all → deploy in order${RESET}"
if $DRY_RUN; then
  echo -e "${YELLOW}${BOLD}  ⚠  DRY RUN — no changes will be made${RESET}"
fi
if [ -n "$ONLY" ]; then
  echo -e "${CYAN}  Only: ${ONLY}${RESET}"
fi
if [ -n "$SKIP_LIST" ]; then
  echo -e "${CYAN}  Skipping: ${SKIP_LIST}${RESET}"
fi
if $CHANGED_ONLY; then
  echo -e "${CYAN}  Mode: changed-only (skipping unchanged services)${RESET}"
fi
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"

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

# ══════════════════════════════════════════════════════════════
# PHASE 1 — BUILD ALL (fire all tiers simultaneously)
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}${BOLD}│  PHASE 1 — BUILD                                        │${RESET}"
echo -e "${CYAN}${BOLD}│  All services build in parallel across all tiers         │${RESET}"
echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────────────┘${RESET}"


# Fire all builds at once — no waiting between tiers
fire_builds "Tier 0 — Foundation" "${TIER_0[@]}"
fire_builds "Tier 1 — APIs & Services" "${TIER_1[@]}"
fire_builds "Tier 2 — Clients & Bots" "${TIER_2[@]}"

if ! $NO_PARALLEL; then
  echo ""
  info "All builds launched — waiting will happen per-tier before deploy"
fi

# ══════════════════════════════════════════════════════════════
# PHASE 2 — WAIT & DEPLOY IN ORDER
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}┌──────────────────────────────────────────────────────────┐${RESET}"
echo -e "${GREEN}${BOLD}│  PHASE 2 — DEPLOY                                       │${RESET}"
echo -e "${GREEN}${BOLD}│  Transfer & restart tier-by-tier in dependency order     │${RESET}"
echo -e "${GREEN}${BOLD}└──────────────────────────────────────────────────────────┘${RESET}"


header "━━━ TIER 0 — Foundation ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ! deploy_tier "Tier 0 — Foundation" "${TIER_0[@]}"; then
  fail "Aborting deployment — foundation tier failed"
  exit 1
fi

header "━━━ TIER 1 — APIs & Services ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
deploy_tier "Tier 1 — APIs & Services" "${TIER_1[@]}"

header "━━━ TIER 2 — Clients & Bots ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
deploy_tier "Tier 2 — Clients & Bots" "${TIER_2[@]}"


# ── Summary ───────────────────────────────────────────────────
TOTAL=$((SECONDS - DEPLOY_START))

echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${MAGENTA}${BOLD}  ☀️  Deploy All — Summary${RESET}"
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"

PASS=0
FAILED=0
SKIPPED=0

for svc in "${ALL_SERVICES[@]}"; do
  local_status=$(cat "${LOG_DIR}/${svc}.deploy.status" 2>/dev/null || echo "SKIP")
  case "$local_status" in
    OK)   echo -e "  ${GREEN}✔ ${svc}${RESET}"; PASS=$((PASS + 1)) ;;
    FAIL) echo -e "  ${RED}✖ ${svc}${RESET}  →  ${LOG_DIR}/${svc}.deploy.log"; FAILED=$((FAILED + 1)) ;;
    *)    echo -e "  ${DIM}⊘ ${svc} (skipped)${RESET}"; SKIPPED=$((SKIPPED + 1)) ;;
  esac
done

echo ""
echo -e "  ${GREEN}${PASS} passed${RESET}  ${RED}${FAILED} failed${RESET}  ${DIM}${SKIPPED} skipped${RESET}"
echo -e "  ${DIM}Total: ${TOTAL}s${RESET}"
echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"

# Non-zero exit if anything failed
[ "$FAILED" -eq 0 ]
