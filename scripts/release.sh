#!/usr/bin/env bash
set -euo pipefail

version=${1:?usage: scripts/release.sh <version>}
build_number=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
notary_profile=${NOTARY_PROFILE:-ghostwriter-notary}
sparkle_account=${SPARKLE_ACCOUNT:-ghostwriter}
team_id=${TEAM_ID:-7P98PG3748}

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/release/$version"
derived="$root/build/release/dd"
updates="$root/build/updates"
denylist="$root/docs/private/publish-denylist.txt"
app="$out/export/Ghostwriter.app"
dmg="$out/Ghostwriter-$version.dmg"

feed_url=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$root/Ghostwriter/Info.plist")
download_prefix=${DOWNLOAD_URL_PREFIX:-${feed_url%/*}/}

step() { printf '\n==> %s\n' "$*"; }

notarize() {
  local result status
  result=$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json)
  status=$(plutil -extract status raw -o - - <<<"$result")
  if [[ $status != Accepted ]]; then
    echo "Notarization of $1 ended with status: $status" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --keychain-profile "$notary_profile" >&2
    exit 1
  fi
}

if [[ -f "$updates/Ghostwriter-$version.dmg" ]]; then
  echo "build/updates already has Ghostwriter-$version.dmg. Pick a new version." >&2
  exit 1
fi
xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null || {
  echo "No notarytool profile \"$notary_profile\". Run: xcrun notarytool store-credentials $notary_profile" >&2
  exit 1
}

step "Generating the Xcode project"
(cd "$root" && xcodegen generate --quiet)

step "Archiving $version ($build_number)"
rm -rf "$out"
mkdir -p "$out"
xcodebuild archive -quiet \
  -project "$root/Ghostwriter.xcodeproj" -scheme Ghostwriter -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  -archivePath "$out/Ghostwriter.xcarchive" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"

step "Exporting with Developer ID signing"
cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$team_id</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet \
  -archivePath "$out/Ghostwriter.xcarchive" -exportPath "$out/export" -exportOptionsPlist "$out/ExportOptions.plist"
codesign --verify --deep --strict "$app"

if [[ -f "$denylist" ]]; then
  step "Checking the app for private content"
  if grep -rail -F -f "$denylist" "$app"; then
    echo "The files above contain text from $denylist." >&2
    exit 1
  fi
fi

step "Notarizing the app"
ditto -c -k --keepParent "$app" "$out/Ghostwriter.zip"
notarize "$out/Ghostwriter.zip"
xcrun stapler staple -q "$app"

step "Building the DMG"
mkdir "$out/dmg"
cp -R "$app" "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname Ghostwriter -srcfolder "$out/dmg" -format UDZO -ov "$dmg"
codesign --sign "Developer ID Application" --timestamp "$dmg"

step "Notarizing the DMG"
notarize "$dmg"
xcrun stapler staple -q "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
spctl --assess --type execute "$app"

step "Updating the appcast"
mkdir -p "$updates"
cp "$dmg" "$updates/"
"$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --account "$sparkle_account" --download-url-prefix "$download_prefix" "$updates"

step "Done"
cat <<EOF
DMG:      $dmg
Appcast:  $updates/appcast.xml
Publish:  see docs/RELEASING.md (files must resolve under $download_prefix)
EOF
