#!/usr/bin/env bash
# Fails if the built .app is missing Info.plist keys App Store Connect (and the
# app itself) depend on. Guards against the project generator replacing
# Shiro/Info.plist with a default one.
set -euo pipefail
APP="$1"
PLIST="$APP/Info.plist"
fail=0
for key in UILaunchScreen UISupportedInterfaceOrientations "UISupportedInterfaceOrientations~ipad" \
           NSLocalNetworkUsageDescription NSMicrophoneUsageDescription \
           GCSupportsControllerUserInteraction ITSAppUsesNonExemptEncryption \
           CFBundleShortVersionString CFBundleVersion; do
  if ! /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    echo "::error::Built Info.plist is missing $key"
    fail=1
  fi
done
if [ ! -f "$APP/PrivacyInfo.xcprivacy" ]; then
  echo "::error::PrivacyInfo.xcprivacy is missing from the app bundle"
  fail=1
fi
[ $fail -eq 0 ] && echo "Info.plist and privacy manifest OK ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST"))"
exit $fail
