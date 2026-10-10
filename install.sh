#!/bin/zsh
# Builds Supernote Viewer and Supernote Preview Bridge, installs both to ~/Applications and
# refreshes Launch Services, Finder services and Quick Look. Never changes the default app.
set -euo pipefail
cd "$(dirname "$0")"

APPS=("Supernote Viewer" "Supernote Preview Bridge")
SCHEMES=("SupernoteViewer" "SupernotePreviewBridge")
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodegen generate --quiet
for scheme in "${SCHEMES[@]}"; do
  xcodebuild -project SupernoteViewer.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/DerivedData build -quiet
done

mkdir -p ~/Applications
for app in "${APPS[@]}"; do
  # Quit a running copy so open requests don't go to the old version.
  pkill -f "$app.app/Contents/MacOS/$app" || true
  rm -rf ~/Applications/"$app.app"
  cp -R "build/DerivedData/Build/Products/Release/$app.app" ~/Applications/
  "$LSREGISTER" -f ~/Applications/"$app.app"
  # Unregister the build copy so Finder's "Open with" menu lists each app once.
  "$LSREGISTER" -u "build/DerivedData/Build/Products/Release/$app.app" 2>/dev/null || true
  echo "Installed ~/Applications/$app.app"
done

/System/Library/CoreServices/pbs -update  # refresh Finder services
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
pluginkit -m -p com.apple.quicklook.preview | grep -i supernote || echo "warning: Quick Look extension not registered yet; open Supernote Viewer once"
