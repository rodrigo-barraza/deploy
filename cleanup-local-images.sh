#!/bin/bash
# ============================================================
# Sun Deploy Kit — Local Image Cleanup
#
# Removes stale SHA-tagged images and legacy-named images to
# reclaim disk space. Only keeps :latest for current services.
#
# Usage:
#   npm run cleanup              # interactive cleanup
#   npm run cleanup -- --force   # skip confirmation
# ============================================================

set -euo pipefail

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

# ── Config ────────────────────────────────────────────────────
# Current service image names (the ones deploy-all.sh builds)
CURRENT_SERVICES=(
  vault-service
  prism-service
  tools-service
  portal-service
  lights-service
  clock-crew-service
  messages-service
  prism-client
  portal-client
  rod-dev-client
  lupos-bot
  clock-crew-client
  messages-client
  lights-client
)

# Legacy image names from the old naming scheme — safe to remove entirely
LEGACY_NAMES=(
  vault
  prism
  tools-api
  api
  lights
  lupos
  retina
  retina-client
  portal
  rod-dev
  clock-crew
)

# ── Flags ─────────────────────────────────────────────────────
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
  esac
done

# ── Header ────────────────────────────────────────────────────
echo ""
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${MAGENTA}${BOLD}  🧹 Sun — Local Image Cleanup${RESET}"
echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════${RESET}"

# ── Phase 1: Remove old SHA-tagged images (keep only :latest) ─
step "Scanning for stale SHA-tagged images"

STALE_IDS=()
STALE_COUNT=0

for svc in "${CURRENT_SERVICES[@]}"; do
  old_tags=$(docker images "$svc" --format '{{.Tag}} {{.ID}}' 2>/dev/null | grep -v 'latest' || true)
  if [ -n "$old_tags" ]; then
    count=$(echo "$old_tags" | wc -l)
    STALE_COUNT=$((STALE_COUNT + count))
    info "${svc}: ${count} old tags"
    while IFS= read -r line; do
      id=$(echo "$line" | awk '{print $2}')
      STALE_IDS+=("$id")
    done <<< "$old_tags"
  fi
done

if [ ${#STALE_IDS[@]} -eq 0 ]; then
  ok "No stale SHA-tagged images found"
else
  warn "${STALE_COUNT} stale images across ${#CURRENT_SERVICES[@]} services"
fi

# ── Phase 2: Identify legacy-named images ─────────────────────
step "Scanning for legacy-named images"

LEGACY_IDS=()
LEGACY_COUNT=0

for name in "${LEGACY_NAMES[@]}"; do
  legacy_images=$(docker images "$name" --format '{{.Tag}} {{.ID}}' 2>/dev/null || true)
  if [ -n "$legacy_images" ]; then
    count=$(echo "$legacy_images" | wc -l)
    LEGACY_COUNT=$((LEGACY_COUNT + count))
    info "${name}: ${count} images"
    while IFS= read -r line; do
      id=$(echo "$line" | awk '{print $2}')
      LEGACY_IDS+=("$id")
    done <<< "$legacy_images"
  fi
done

if [ ${#LEGACY_IDS[@]} -eq 0 ]; then
  ok "No legacy-named images found"
else
  warn "${LEGACY_COUNT} legacy images to remove"
fi

# ── Summary before action ─────────────────────────────────────
TOTAL=$((${#STALE_IDS[@]} + ${#LEGACY_IDS[@]}))

if [ "$TOTAL" -eq 0 ]; then
  echo ""
  ok "Nothing to clean up — already tidy! 🎉"
  exit 0
fi

# Estimate disk savings
ESTIMATED_SAVINGS=$(docker images --format '{{.Repository}} {{.Tag}} {{.Size}}' 2>/dev/null \
  | grep -v 'latest' \
  | grep -E "^($(IFS='|'; echo "${CURRENT_SERVICES[*]}")|($(IFS='|'; echo "${LEGACY_NAMES[*]}")) " \
  || true)

echo ""
echo -e "${CYAN}${BOLD}  Summary:${RESET}"
echo -e "  ${DIM}Stale SHA tags:  ${STALE_COUNT}${RESET}"
echo -e "  ${DIM}Legacy images:   ${LEGACY_COUNT}${RESET}"
echo -e "  ${DIM}Total to remove: ${TOTAL}${RESET}"

# ── Confirmation ──────────────────────────────────────────────
if ! $FORCE; then
  echo ""
  echo -en "  ${YELLOW}Proceed with cleanup? [y/N] ${RESET}"
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Aborted"
    exit 0
  fi
fi

# ── Execute cleanup ───────────────────────────────────────────
step "Removing stale SHA-tagged images"
REMOVED=0
FAILED=0

for id in "${STALE_IDS[@]}"; do
  if docker rmi "$id" &>/dev/null; then
    REMOVED=$((REMOVED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done
ok "Removed ${REMOVED} stale images (${FAILED} skipped — in use or shared layers)"

step "Removing legacy-named images"
REMOVED_LEGACY=0
FAILED_LEGACY=0

for id in "${LEGACY_IDS[@]}"; do
  if docker rmi "$id" &>/dev/null; then
    REMOVED_LEGACY=$((REMOVED_LEGACY + 1))
  else
    FAILED_LEGACY=$((FAILED_LEGACY + 1))
  fi
done
ok "Removed ${REMOVED_LEGACY} legacy images (${FAILED_LEGACY} skipped)"

# ── Prune dangling images ─────────────────────────────────────
step "Pruning dangling images"
docker image prune -f 2>/dev/null | sed 's/^/  /' || true

# ── Final summary ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✅ Cleanup complete${RESET}"
echo -e "${DIM}  Removed: $((REMOVED + REMOVED_LEGACY)) images${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
