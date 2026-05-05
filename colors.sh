#!/bin/bash
# ============================================================
# Deploy Kit — Shared Colors & Logging
#
# Source this file from any deploy-kit script:
#   source "$(dirname "$0")/colors.sh"
#
# Provides:
#   Colors : BOLD, DIM, RED, RESET
#   Category palettes (ANSI-256):
#     BLUE_SHADES[]   — services
#     GREEN_SHADES[]  — clients
#     YELLOW_SHADES[] — bots
#   Logging: header(), step(), info(), ok(), warn(), fail()
#   Helpers: svc_category(), svc_color()
#
# Color Rules:
#   🔵 Services → blue shades (randomized per project)
#   🟢 Clients  → green shades (randomized per project)
#   🟡 Bots     → yellow/amber shades (randomized per project)
#   🔴 Red      → errors ONLY (never used for project labels)
#
# Uses ANSI-C quoting ($'\033') so variables contain real ESC
# bytes. This means they work everywhere — echo, printf, sed,
# tee, pipes — without relying on echo -e interpretation.
# ============================================================

# ── Base styles ───────────────────────────────────────────────
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
RESET=$'\033[0m'

# ── Category shade palettes (ANSI 256-color) ─────────────────
# Each category has multiple distinct shades so that projects
# within the same category are visually distinguishable.
#
# Services: blue spectrum
BLUE_SHADES=(
  $'\033[38;5;33m'    # DodgerBlue2
  $'\033[38;5;39m'    # DeepSkyBlue1
  $'\033[38;5;69m'    # SteelBlue1
  $'\033[38;5;75m'    # SteelBlue1 (light)
  $'\033[38;5;111m'   # SkyBlue2
  $'\033[38;5;27m'    # DodgerBlue3
  $'\033[38;5;63m'    # RoyalBlue1
  $'\033[38;5;105m'   # SlateBlue1
  $'\033[38;5;32m'    # DeepSkyBlue3
  $'\033[38;5;68m'    # SteelBlue
)
# Clients: green spectrum
GREEN_SHADES=(
  $'\033[38;5;34m'    # Green3
  $'\033[38;5;42m'    # SpringGreen2
  $'\033[38;5;78m'    # DarkSeaGreen
  $'\033[38;5;114m'   # DarkSeaGreen2
  $'\033[38;5;48m'    # SpringGreen1
  $'\033[38;5;71m'    # DarkSeaGreen4
  $'\033[38;5;84m'    # SeaGreen1
  $'\033[38;5;35m'    # SpringGreen3
  $'\033[38;5;40m'    # Green3 (bright)
  $'\033[38;5;82m'    # Chartreuse2
)
# Bots: yellow/amber spectrum
YELLOW_SHADES=(
  $'\033[38;5;220m'   # Gold1
  $'\033[38;5;214m'   # Orange1
  $'\033[38;5;178m'   # Gold3
  $'\033[38;5;186m'   # Khaki1
  $'\033[38;5;222m'   # LightGoldenrod2
  $'\033[38;5;228m'   # Khaki1 (light)
  $'\033[38;5;208m'   # DarkOrange
  $'\033[38;5;179m'   # LightGoldenrod3
)

# ── Category detection ────────────────────────────────────────
# Derives category from service ID suffix.
# Returns: "service", "client", or "bot"
svc_category() {
  local id="$1"
  case "$id" in
    *-bot)     echo "bot" ;;
    *-client)  echo "client" ;;
    *)         echo "service" ;;
  esac
}

# ── Per-category shade counters ───────────────────────────────
declare -g _BLUE_IDX=0
declare -g _GREEN_IDX=0
declare -g _YELLOW_IDX=0

# ── Color assignment for a service ────────────────────────────
# Returns the next shade from the appropriate category palette.
# Call once per service during initialization, store the result.
svc_color() {
  local id="$1"
  local cat
  cat=$(svc_category "$id")
  case "$cat" in
    service)
      local color="${BLUE_SHADES[$_BLUE_IDX % ${#BLUE_SHADES[@]}]}"
      _BLUE_IDX=$((_BLUE_IDX + 1))
      echo "$color"
      ;;
    client)
      local color="${GREEN_SHADES[$_GREEN_IDX % ${#GREEN_SHADES[@]}]}"
      _GREEN_IDX=$((_GREEN_IDX + 1))
      echo "$color"
      ;;
    bot)
      local color="${YELLOW_SHADES[$_YELLOW_IDX % ${#YELLOW_SHADES[@]}]}"
      _YELLOW_IDX=$((_YELLOW_IDX + 1))
      echo "$color"
      ;;
  esac
}

# ── Timestamp helper ──────────────────────────────────────────
ts() { printf '%s%s%s' "$DIM" "$(date +%H:%M:%S)" "$RESET"; }

# ── Logging functions ─────────────────────────────────────────
# Use printf so colors work correctly even when piped through
# sed, tee, or redirected to log files and back.
# Each line is prefixed with a local HH:MM:SS timestamp.
header()  { printf '\n%s %s%s%s%s\n' "$(ts)" "$MAGENTA" "$BOLD" "$1" "$RESET"; }
step()    { printf '\n%s %s%s▸ %s%s\n' "$(ts)" "$CYAN" "$BOLD" "$1" "$RESET"; }
info()    { printf '%s   %s%s%s\n' "$(ts)" "$DIM" "$1" "$RESET"; }
ok()      { printf '%s   %s✔ %s%s\n' "$(ts)" "$GREEN" "$1" "$RESET"; }
warn()    { printf '%s   %s⚠ %s%s\n' "$(ts)" "$YELLOW" "$1" "$RESET"; }
fail()    { printf '%s   %s✖ %s%s\n' "$(ts)" "$RED" "$1" "$RESET"; }
