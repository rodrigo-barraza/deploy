#!/bin/bash
# ============================================================
# Sun Ecosystem — Deploy All Services
#
# Orchestrates `npm run deploy` across all services with
# proper dependency ordering and parallelism.
#
# Tiers (sequential between tiers, parallel within):
#   0. Foundation   — vault (secret store, must be up first)
#   1. APIs         — tools-api, api, lights
#   2. Gateway      — prism (depends on tools-api)
#   3. Clients/Bots — retina, portal, rod-dev, lupos
#
# Usage:
#   npm run deploy                         # full deploy
#   npm run deploy -- --dry-run            # validate only
#   npm run deploy -- --skip-pull          # skip git pull
#   npm run deploy -- --no-cache           # rebuild images from scratch
#   npm run deploy -- --only=prism,retina  # deploy specific services
#   npm run deploy -- --skip=lupos,lights  # skip specific services
#   npm run deploy -- --no-parallel        # disable parallel builds
# ============================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # sun/ parent directory
LOG_DIR="${SCRIPT_DIR}/.deploy-logs"

# Deployment tiers — sequential between tiers, parallel within
TIER_0=(vault)
TIER_1=(tools-api api lights)
TIER_2=(prism)
TIER_3=(retina portal rod-dev lupos)

ALL_SERVICES=("${TIER_0[@]}" "${TIER_1[@]}" "${TIER_2[@]}" "${TIER_3[@]}")

# ── Service colors (for prefixed output in parallel mode) ─────
# Each service gets a unique color so interleaved output is readable
declare -A SVC_COLORS=(
  [vault]="\033[33m"      # yellow
  [prism]="\033[36m"      # cyan
  [tools-api]="\033[35m"  # magenta
  [api]="\033[34m"        # blue
  [lights]="\033[32m"     # green
  [lupos]="\033[91m"      # bright red
  [rod-dev]="\033[93m"    # bright yellow
  [retina]="\033[95m"     # bright magenta
  [portal]="\033[96m"     # bright cyan
)

# ── Flags ─────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PULL=false
NO_CACHE=false
NO_PARALLEL=false
ONLY=""
SKIP_LIST=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=true ;;
    --skip-pull)    SKIP_PULL=true ;;
    --no-cache)     NO_CACHE=true ;;
    --no-parallel)  NO_PARALLEL=true ;;
    --only=*)       ONLY="${arg#--only=}" ;;
    --skip=*)       SKIP_LIST="${arg#--skip=}" ;;
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

# ── Build deploy flags ────────────────────────────────────────
build_flags() {
  local flags=""
  $DRY_RUN   && flags="$flags --dry-run"
  $SKIP_PULL && flags="$flags --skip-pull"
  $NO_CACHE  && flags="$flags --no-cache"
  echo "$flags"
}

# ── Deploy a single service (streams output live) ─────────────
deploy_service() {
  local svc="$1"
  local prefix="$2"   # "true" to prefix lines with service name
  local svc_dir="${ROOT_DIR}/${svc}"
  local log_file="${LOG_DIR}/${svc}.log"
  local flags
  flags=$(build_flags)

  if [ ! -f "${svc_dir}/deploy.sh" ]; then
    fail "${svc}: no deploy.sh found — skipping"
    echo "SKIP" > "${LOG_DIR}/${svc}.status"
    return 0
  fi

  local color="${SVC_COLORS[$svc]:-$DIM}"
  local pad_svc
  # Pad service name to 10 chars for aligned output
  pad_svc=$(printf '%-10s' "$svc")

  if [ "$prefix" = "true" ]; then
    # Stream live with service-name prefix + tee to log
    bash "${svc_dir}/deploy.sh" $flags 2>&1 \
      | tee "$log_file" \
      | sed -u "s/^/${color}${BOLD}[${pad_svc}]${RESET} /" \
      && echo "OK" > "${LOG_DIR}/${svc}.status" \
      || echo "FAIL" > "${LOG_DIR}/${svc}.status"
  else
    # Stream live without prefix (single service) + tee to log
    bash "${svc_dir}/deploy.sh" $flags 2>&1 \
      | tee "$log_file" \
      && echo "OK" > "${LOG_DIR}/${svc}.status" \
      || echo "FAIL" > "${LOG_DIR}/${svc}.status"
  fi
}

# ── Deploy a tier (parallel or sequential) ────────────────────
deploy_tier() {
  local tier_name="$1"
  shift
  local services=("$@")
  local pids=()
  local svc

  # Filter to only services we should deploy
  local filtered=()
  for svc in "${services[@]}"; do
    if should_deploy "$svc"; then
      filtered+=("$svc")
    else
      info "Skipping ${svc} (filtered)"
      echo "SKIP" > "${LOG_DIR}/${svc}.status"
    fi
  done

  if [ ${#filtered[@]} -eq 0 ]; then
    info "No services to deploy in this tier"
    return 0
  fi

  step "Deploying ${tier_name}: ${filtered[*]}"

  if $NO_PARALLEL || [ ${#filtered[@]} -eq 1 ]; then
    # Sequential — stream directly, no prefix needed
    for svc in "${filtered[@]}"; do
      deploy_service "$svc" "false"
      local status
      status=$(cat "${LOG_DIR}/${svc}.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} deployed successfully"
      elif [ "$status" = "FAIL" ]; then
        fail "${svc} deployment failed"
        info "Log: ${LOG_DIR}/${svc}.log"

        # Tier 0 failure is fatal — vault must succeed
        if [ "$tier_name" = "Tier 0 — Foundation" ]; then
          fail "Vault deployment failed — aborting all subsequent tiers"
          return 1
        fi
      fi
    done
  else
    # Parallel — stream with service-name prefixes
    for svc in "${filtered[@]}"; do
      deploy_service "$svc" "true" &
      pids+=("$!:$svc")
    done

    # Wait for all background jobs
    local any_failed=false
    for entry in "${pids[@]}"; do
      local pid="${entry%%:*}"
      local svc="${entry##*:}"
      wait "$pid" || true
      local status
      status=$(cat "${LOG_DIR}/${svc}.status" 2>/dev/null || echo "UNKNOWN")
      if [ "$status" = "OK" ]; then
        ok "${svc} deployed successfully"
      else
        fail "${svc} deployment failed → ${LOG_DIR}/${svc}.log"
        any_failed=true
      fi
    done

    if $any_failed; then
      warn "Some services in this tier failed — check logs in ${LOG_DIR}/"
    fi
  fi
}

# ── Timer ─────────────────────────────────────────────────────
DEPLOY_START=$SECONDS

# ── Header ────────────────────────────────────────────────────
echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${MAGENTA}${BOLD}  ☀️  Sun Ecosystem — Deploy All Services${RESET}"
if $DRY_RUN; then
  echo -e "${YELLOW}${BOLD}  ⚠  DRY RUN — no changes will be made${RESET}"
fi
if [ -n "$ONLY" ]; then
  echo -e "${CYAN}  Only: ${ONLY}${RESET}"
fi
if [ -n "$SKIP_LIST" ]; then
  echo -e "${CYAN}  Skipping: ${SKIP_LIST}${RESET}"
fi
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"

# ── Prepare log directory ─────────────────────────────────────
mkdir -p "$LOG_DIR"
rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/*.status 2>/dev/null

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

# ── Deploy tiers sequentially ─────────────────────────────────

header "━━━ TIER 0 — Foundation ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ! deploy_tier "Tier 0 — Foundation" "${TIER_0[@]}"; then
  fail "Aborting deployment — foundation tier failed"
  exit 1
fi

header "━━━ TIER 1 — APIs & Services ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
deploy_tier "Tier 1 — APIs & Services" "${TIER_1[@]}"

header "━━━ TIER 2 — Gateway ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
deploy_tier "Tier 2 — Gateway" "${TIER_2[@]}"

header "━━━ TIER 3 — Clients & Bots ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
deploy_tier "Tier 3 — Clients & Bots" "${TIER_3[@]}"

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
  local_status=$(cat "${LOG_DIR}/${svc}.status" 2>/dev/null || echo "SKIP")
  case "$local_status" in
    OK)   echo -e "  ${GREEN}✔ ${svc}${RESET}"; PASS=$((PASS + 1)) ;;
    FAIL) echo -e "  ${RED}✖ ${svc}${RESET}  →  ${LOG_DIR}/${svc}.log"; FAILED=$((FAILED + 1)) ;;
    *)    echo -e "  ${DIM}⊘ ${svc} (skipped)${RESET}"; SKIPPED=$((SKIPPED + 1)) ;;
  esac
done

echo ""
echo -e "  ${GREEN}${PASS} passed${RESET}  ${RED}${FAILED} failed${RESET}  ${DIM}${SKIPPED} skipped${RESET}  ⏱ ${TOTAL}s"
echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}"

# Non-zero exit if anything failed
[ "$FAILED" -eq 0 ]
