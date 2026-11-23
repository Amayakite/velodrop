#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-.dist/VeloDrop.app}"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    [[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]] || brew install --cask google-chrome
    [[ -x "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" ]] || brew install --cask microsoft-edge
    [[ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ]] || brew install --cask firefox
    command -v geckodriver >/dev/null || brew install geckodriver
fi

VELODROP_BROWSER=chrome node Scripts/smoke-test.mjs "$app"
VELODROP_BROWSER=edge node Scripts/smoke-test.mjs "$app"
node Scripts/firefox-smoke.mjs "$app"
