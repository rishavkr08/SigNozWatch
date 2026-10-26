#!/bin/sh
# Builds SigNozWatch.app next to this script. `./build.sh --install` also copies it to /Applications and launches it.
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -n 2
APP=SigNozWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SigNozWatch "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"   # regenerate with: swift tools/icon.swift icns B AppIcon.icns
codesign --force --sign - "$APP" 2>/dev/null   # ad-hoc signature: enough for notifications and login items
if [ "$1" = "--install" ]; then
  pkill -x SigNozWatch 2>/dev/null || true
  rm -rf /Applications/SigNozWatch.app
  cp -R "$APP" /Applications/
  touch /Applications/SigNozWatch.app   # make LaunchServices and Notification Center pick up the new icon
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SigNozWatch.app
  open /Applications/SigNozWatch.app
  echo "Installed and launched /Applications/SigNozWatch.app"
else
  echo "Built ./$APP   (open it with: open $APP   or install with: ./build.sh --install)"
fi
