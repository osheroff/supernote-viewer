#!/bin/zsh
# Builds Supernote Viewer, installs it to ~/Applications and refreshes Quick Look.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project SupernoteViewer.xcodeproj -scheme SupernoteViewer -configuration Release \
  -derivedDataPath build/DerivedData build -quiet

APP="build/DerivedData/Build/Products/Release/Supernote Viewer.app"
mkdir -p ~/Applications
rm -rf ~/Applications/"Supernote Viewer.app"
cp -R "$APP" ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"Supernote Viewer.app"
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
echo "Installed ~/Applications/Supernote Viewer.app"
pluginkit -m -p com.apple.quicklook.preview | grep -i supernote || echo "warning: extension not registered yet; open the app once"
