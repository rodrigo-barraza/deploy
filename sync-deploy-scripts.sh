#!/bin/bash
# ============================================================
# Sun Deploy Kit — Sync Deploy Scripts
#
# Reads vault-service/services.json and regenerates the
# deploy:* entries in package.json so individual deploy
# shortcuts stay in sync automatically.
#
# Usage:
#   npm run deploy:sync
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICES_JSON="${ROOT_DIR}/vault-service/services.json"
PACKAGE_JSON="${SCRIPT_DIR}/package.json"

source "${SCRIPT_DIR}/colors.sh"

if [ ! -f "$SERVICES_JSON" ]; then
  echo "ERROR: services.json not found at ${SERVICES_JSON}" >&2
  exit 1
fi

step "Syncing deploy shortcuts from services.json"

node -e "
  const fs = require('fs');
  const services = require('${SERVICES_JSON}');
  const ids = services.services.map(s => s.id).sort();

  const scripts = {
    'deploy':        'bash deploy-all.sh',
    'deploy:dry':    'bash deploy-all.sh --dry-run',
    'deploy:changed':'bash deploy-all.sh --changed-only',
    'cleanup':       'bash cleanup-local-images.sh',
    'cleanup:force': 'bash cleanup-local-images.sh --force',
    'deploy:sync':   'bash sync-deploy-scripts.sh',
  };

  for (const id of ids) {
    scripts['deploy:' + id] = 'bash ../' + id + '/deploy.sh';
  }

  const pkg = JSON.parse(fs.readFileSync('${PACKAGE_JSON}', 'utf8'));
  pkg.scripts = scripts;
  fs.writeFileSync('${PACKAGE_JSON}', JSON.stringify(pkg, null, 2) + '\n');

  console.log('  ✔ Wrote ' + ids.length + ' deploy shortcuts');
  ids.forEach(id => console.log('    deploy:' + id));
"

echo ""
ok "Done — package.json is in sync with services.json"
