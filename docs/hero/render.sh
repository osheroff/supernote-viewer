#!/bin/zsh
# Renders hero.html to docs/images/hero.png (2560x1280) with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1280,640 --force-device-scale-factor=2 --virtual-time-budget=5000 \
  --screenshot="$PWD/../images/hero.png" "file://$PWD/hero.html" 2>/dev/null
echo "wrote docs/images/hero.png"
