#!/bin/sh
# Builds a downloadable release into dist/:
#   SigNozWatch.app   universal (Apple silicon + Intel), macOS 14+
#   SigNozWatch.dmg   drag-to-Applications disk image, for the website download button
#   SigNozWatch.zip   used by install.sh
#   SHA256SUMS     checksums; install.sh verifies against it
#
# Signing: uses the first "Developer ID Application" identity in the keychain, or $DEVELOPER_ID.
#          Without one the app is ad-hoc signed and macOS asks users to approve it on first open.
# Notarizing: also set NOTARY_PROFILE to a profile saved with
#          xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#          and the DMG and app are notarized and stapled, so they open with no warning.
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)

for arch in arm64 x86_64; do
  echo "Building $arch…"
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch" 2>&1 | tail -n 1
done

rm -rf dist
APP=dist/SigNozWatch.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64/release/SigNozWatch .build/x86_64/release/SigNozWatch -output "$APP/Contents/MacOS/SigNozWatch"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"

IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -n 1 | tr -d '"')}
if [ -n "$IDENTITY" ]; then
  echo "Signing with $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID found: ad-hoc signing (users approve it once on first open)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

make_dmg() {
  staging=$(mktemp -d)
  cp -R "$APP" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -quiet -volname "SigNozWatch $VERSION" -srcfolder "$staging" -ov -format UDZO dist/SigNozWatch.dmg
  rm -rf "$staging"
  [ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" dist/SigNozWatch.dmg
  return 0
}
make_dmg

if [ -n "$IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing (usually a few minutes)…"
  xcrun notarytool submit dist/SigNozWatch.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"           # the DMG submission covers the app inside it
  make_dmg                              # rebuild the DMG around the stapled app…
  xcrun notarytool submit dist/SigNozWatch.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/SigNozWatch.dmg  # …and staple the DMG itself
  NOTARIZED=yes
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" dist/SigNozWatch.zip
(cd dist && shasum -a 256 SigNozWatch.dmg SigNozWatch.zip > SHA256SUMS)
cp install.sh dist/   # uploaded with the release so the one-line install URL always matches it

echo
echo "SigNozWatch $VERSION release in dist/ ($(lipo -archs "$APP/Contents/MacOS/SigNozWatch"), notarized: ${NOTARIZED:-no})"
ls -lh dist | tail -n +2
