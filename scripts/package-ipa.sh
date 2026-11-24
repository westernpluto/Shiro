#!/usr/bin/env bash
# Packages an unsigned .app into a fakesigned .ipa that AltStore, SideStore,
# Feather, TrollStore etc. can re-sign and install.
set -euo pipefail
APP="$1"
IPA="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
APP_NAME="$(basename "$APP")"
BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$STAGE/Payload/$APP_NAME/Info.plist")"
# Remove any leftover signatures, then fakesign with our entitlements so the
# installer knows which entitlements the app wants.
find "$STAGE/Payload/$APP_NAME" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
if command -v ldid >/dev/null 2>&1; then
  ldid -S"$ROOT/Shiro/Shiro.entitlements" "$STAGE/Payload/$APP_NAME/$BIN"
fi
mkdir -p "$(dirname "$IPA")"
IPA_ABS="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
rm -f "$IPA_ABS"
(cd "$STAGE" && zip -qry "$IPA_ABS" Payload)
rm -rf "$STAGE"
echo "Packaged $IPA_ABS ($(du -h "$IPA_ABS" | cut -f1))"
