#!/bin/bash
# ============================================================
# Deploy Kit — Shared Colors & Logging
#
# Source this file from any deploy-kit script:
#   source "$(dirname "$0")/colors.sh"
#
# Provides:
#   Colors : BOLD, DIM, CYAN, GREEN, YELLOW, RED, MAGENTA, RESET
#   Logging: header(), step(), info(), ok(), warn(), fail()
#
# Uses ANSI-C quoting ($'\033') so variables contain real ESC
# bytes. This means they work everywhere — echo, printf, sed,
# tee, pipes — without relying on echo -e interpretation.
# ============================================================

# ── Colors (ANSI-C quoted — real ESC bytes) ───────────────────
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'
RESET=$'\033[0m'

# ── Logging functions ─────────────────────────────────────────
# Use printf so colors work correctly even when piped through
# sed, tee, or redirected to log files and back.
header()  { printf '\n%s%s%s%s\n' "$MAGENTA" "$BOLD" "$1" "$RESET"; }
step()    { printf '\n%s%s▸ %s%s\n' "$CYAN" "$BOLD" "$1" "$RESET"; }
info()    { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
ok()      { printf '  %s✔ %s%s\n' "$GREEN" "$1" "$RESET"; }
warn()    { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }
fail()    { printf '  %s✖ %s%s\n' "$RED" "$1" "$RESET"; }
