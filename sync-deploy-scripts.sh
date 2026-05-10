#!/bin/bash
# ============================================================
# Deploy Kit — Sync Deploy Scripts
#
# Reads vault-service/projects.json and regenerates the
# deploy:* entries in package.json so individual deploy
# shortcuts stay in sync automatically.
#
# Usage:
#   npm run deploy:sync
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECTS_JSON="${ROOT_DIR}/vault-service/projects.json"
PACKAGE_JSON="${SCRIPT_DIR}/package.json"

source "${SCRIPT_DIR}/colors.sh"

if [ ! -f "$PROJECTS_JSON" ]; then
  echo "ERROR: projects.json not found at ${PROJECTS_JSON}" >&2
  exit 1
fi

step "Syncing deploy shortcuts from projects.json"

node -e "
  const fs = require('fs');
  const services = require('${PROJECTS_JSON}');
  const ids = services.projects.map(s => s.id).sort();

  const scripts = {
    'deploy':        'bash deploy-all.sh',
    'deploy:dry':    'bash deploy-all.sh --dry-run',
    'deploy:changed':'bash deploy-all.sh --changed-only',
    'deploy:clients':'bash deploy-all.sh --clients',
    'deploy:services':'bash deploy-all.sh --services',
    'deploy:bots':   'bash deploy-all.sh --bots',
    'deploy:vault':  'bash deploy-all.sh --vault',
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
ok "Done — package.json is in sync with projects.json"
