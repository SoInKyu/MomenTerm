#!/bin/bash
# End-to-end MomenTerm release: archive → notarize-ready .zip → sign → appcast → GitHub Release.
# Designed to be re-run idempotently for the same tag; outputs are placed in build/release/.
#
# Prerequisites (one-time):
#   1. tools/sparkle_tools.sh        — builds sign_update from the Sparkle submodule.
#   2. Generate keys once:
#         build/sparkle-tools/generate_keys
#      then paste the printed base64 public key into plists/release-iTerm2.plist's
#      <key>SUPublicEDKey</key>. The matching private key lives in your login keychain
#      (Sparkle stores it under service "https://sparkle-project.org").
#   3. gh CLI authenticated:  gh auth login
#
# Usage:
#   tools/release.sh <version>            # e.g. 0.4.0 → tag "momenterm-v0.4.0"
#
# Outputs:
#   build/release/MomenTerm-<version>.zip
#   build/release/appcast.xml
#   GitHub release tagged "momenterm-v<version>" with both files attached.

set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <version>"
  exit 2
fi

VERSION="$1"
# Reject anything that isn't strict semver — sed substitutions below trust
# this value, so a hostile argument like "0.4|foo" would corrupt appcast.xml.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._A-Za-z0-9-]*)?$ ]]; then
  echo "error: version must look like X.Y.Z (got: $VERSION)" >&2
  exit 2
fi
TAG="momenterm-v$VERSION"
# BUILD is a strictly monotonic 12-digit timestamp (YYYYMMDDHHMM, local TZ).
# It is stamped into the bundle's CFBundleVersion AND the appcast's
# <sparkle:version>; Sparkle's SUStandardVersionComparator compares those
# two via NSNumericSearch, so they MUST share the same scheme or
# update-already-installed comparisons go wrong. The Xcode build phase
# "Rewrite version number in plist file" otherwise stamps "3.6.YYYYMMDD"
# from version.txt — that prefix "3.6" loses to a 12-digit timestamp under
# NSNumericSearch, which would put every freshly-installed v0.9.2+ bundle
# back into "update available" every hour. Computing BUILD once at the top
# guarantees the post-archive plist patch and the appcast substitution
# share the same value.
BUILD="$(date "+%Y%m%d%H%M")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/build/release"
APP_NAME="MomenTerm"
SPARKLE_BIN="$REPO_ROOT/build/sparkle-tools"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT_DIR="$OUT/export"
ZIP="$OUT/$APP_NAME-$VERSION.zip"
APPCAST="$OUT/appcast.xml"

mkdir -p "$OUT"

# -- Sanity checks ----------------------------------------------------------

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "error: $SPARKLE_BIN/sign_update missing. Run tools/sparkle_tools.sh first." >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not on PATH." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not on PATH." >&2
  exit 1
fi

REPO_SLUG=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
RELEASE_URL="https://github.com/$REPO_SLUG/releases/tag/$TAG"
ZIP_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$APP_NAME-$VERSION.zip"

# -- Build & export ---------------------------------------------------------

# The Deployment configuration's INFOPLIST_FILE points at plists/iTerm2.plist,
# which Makefile targets overwrite by copying one of plists/{dev,beta,nightly,
# preview,release}-iTerm2.plist on top of it. If the most recent `make` target
# was `make run` (dev), a release cut would silently inherit dev-iTerm2.plist
# — empty SUFeedURL, wrong SUPublicEDKey — and ship a bundle that can never
# self-update. Force the release plist here so cuts are reproducible regardless
# of prior make state. v0.9.0 shipped broken because of this.
echo "[release] applying release-iTerm2.plist as Info.plist source..."
cp "$REPO_ROOT/plists/release-iTerm2.plist" "$REPO_ROOT/plists/iTerm2.plist"

echo "[release] xcodebuild archive (Deployment / iTerm2 scheme)..."
# The Deployment build config still references the upstream iTerm2 author's
# Developer ID. Until we sign up for our own Apple Developer cert, override
# with ad-hoc so the archive succeeds. Sparkle still verifies via EdDSA,
# users see the unidentified-developer warning once on first launch (same
# as the share.sh hand-off path).
xcodebuild -project "$REPO_ROOT/iTerm2.xcodeproj" \
           -scheme iTerm2 \
           -configuration Deployment \
           -archivePath "$ARCHIVE" \
           -quiet \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGN_STYLE=Manual \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO \
           DEVELOPMENT_TEAM= \
           ARCHS=arm64 \
           ONLY_ACTIVE_ARCH=YES \
           archive

# Locate the produced .app inside the archive.
APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  # Fallback: look for any .app inside the archive
  APP_PATH=$(find "$ARCHIVE/Products/Applications" -name "*.app" -maxdepth 1 -type d | head -n 1)
fi
if [ ! -d "$APP_PATH" ]; then
  echo "error: no .app inside $ARCHIVE" >&2
  exit 1
fi

echo "[release] zipping $APP_PATH..."
rm -rf "$EXPORT_DIR" && mkdir -p "$EXPORT_DIR"
cp -R "$APP_PATH" "$EXPORT_DIR/"
# The Deployment build setting still emits iTerm2.app as the bundle dir
# name even though CFBundleName/Executable inside are MomenTerm. Rename
# so end users see MomenTerm.app in Finder/Dock.
APP_LOCAL="$EXPORT_DIR/$(basename "$APP_PATH")"
APP_FINAL="$EXPORT_DIR/$APP_NAME.app"
if [ "$APP_LOCAL" != "$APP_FINAL" ]; then
  mv "$APP_LOCAL" "$APP_FINAL"
fi

# Bundle rename leaves Contents/MacOS/iTerm2 mismatched with Info.plist's
# CFBundleExecutable (=MomenTerm). LaunchServices reads the plist and looks
# for a binary by that exact name; if missing, it rejects the bundle with
# "application is damaged or incomplete and can't be opened." Rename the
# main binary to match. Helpers (iterm2-*-adapter, iTermServer, ShellLauncher,
# iTerm2ImportStatus.app) keep their names — main app spawns them by literal
# string. Guarded so a second run is a no-op.
MAIN_EXPECTED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_FINAL/Contents/Info.plist")"
if [ -n "$MAIN_EXPECTED" ] \
   && [ -e "$APP_FINAL/Contents/MacOS/iTerm2" ] \
   && [ ! -e "$APP_FINAL/Contents/MacOS/$MAIN_EXPECTED" ]; then
  mv "$APP_FINAL/Contents/MacOS/iTerm2" "$APP_FINAL/Contents/MacOS/$MAIN_EXPECTED"
fi

# Overwrite the Xcode build phase's "3.6.YYYYMMDD" stamping with the values
# Sparkle will actually compare against the appcast. CFBundleVersion = BUILD
# (12-digit timestamp matching <sparkle:version> in appcast.template.xml) so
# SUStandardVersionComparator sees "same version" after install instead of
# treating every check as "appcast newer than 3.6.…" and looping reinstalls
# every hour. CFBundleShortVersionString = VERSION ("0.9.3") for the human
# Finder/About-window display. v0.9.2 shipped without this and would have
# loop-installed once SUAutomaticallyUpdate=YES kicked in.
echo "[release] stamping bundle CFBundleVersion=$BUILD CFBundleShortVersionString=$VERSION ..."
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_FINAL/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_FINAL/Contents/Info.plist"

# Inject the Discord crash-report webhook URL into the bundle's Info.plist.
# UKCrashReporter (ThirdParty/UKCrashReporter/UKCrashReporter.m) prefers this
# Info.plist key over the placeholder URL committed in UKCrashReporter.strings,
# so the secret URL only ever lives in the built bundle — never in git.
#
# Required for crash reports to actually reach the developer. If the env var
# is unset, the build still succeeds and the placeholder URL ships (POSTs
# fail silently on crash, which is the same behavior as upstream iTerm2's
# unreachable iterm2.com endpoint).
if [ -n "${MOMENTERM_CRASH_WEBHOOK_URL:-}" ]; then
  echo "[release] injecting MOMENTERM_CRASH_WEBHOOK_URL into Info.plist..."
  # Add or Set — PlistBuddy errors out on Set if the key is missing.
  /usr/libexec/PlistBuddy -c "Add :MOMENTERM_CRASH_WEBHOOK_URL string $MOMENTERM_CRASH_WEBHOOK_URL" "$APP_FINAL/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :MOMENTERM_CRASH_WEBHOOK_URL $MOMENTERM_CRASH_WEBHOOK_URL" "$APP_FINAL/Contents/Info.plist"
else
  echo "[release] WARNING: MOMENTERM_CRASH_WEBHOOK_URL not set — crash reports will not be delivered." >&2
fi

# Last-line defense: read the keys that just got embedded and refuse to ship
# if they don't match release-iTerm2.plist. Catches "wrong plist got copied
# in" and "someone rotated SUPublicEDKey in one place but not the other".
# Keep EXPECT_KEY synced with plists/release-iTerm2.plist:398-399.
# Auto-install keys (autocheck/interval/autoupdate) must also be present so
# friends on v0.9.2+ get background updates without a dialog.
echo "[release] verifying Info.plist sparkle keys..."
EXPECT_KEY="zhZBg6HvG2DqeH4pTnwqnC+0Ti4euC4tvDqawrn43pw="
EXPECT_FEED="https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
EXPECT_AUTOCHECK="true"
EXPECT_INTERVAL="3600"
EXPECT_AUTOUPDATE="true"
EXPECT_BUNDLE_VERSION="$BUILD"
EXPECT_BUNDLE_SHORT="$VERSION"
GOT_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_AUTOCHECK="$(/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_INTERVAL="$(/usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_AUTOUPDATE="$(/usr/libexec/PlistBuddy -c "Print :SUAutomaticallyUpdate" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
GOT_BUNDLE_SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_FINAL/Contents/Info.plist" 2>/dev/null || true)"
if [ "$GOT_KEY" != "$EXPECT_KEY" ] \
   || [ "$GOT_FEED" != "$EXPECT_FEED" ] \
   || [ "$GOT_AUTOCHECK" != "$EXPECT_AUTOCHECK" ] \
   || [ "$GOT_INTERVAL" != "$EXPECT_INTERVAL" ] \
   || [ "$GOT_AUTOUPDATE" != "$EXPECT_AUTOUPDATE" ] \
   || [ "$GOT_BUNDLE_VERSION" != "$EXPECT_BUNDLE_VERSION" ] \
   || [ "$GOT_BUNDLE_SHORT" != "$EXPECT_BUNDLE_SHORT" ]; then
  echo "error: Info.plist sparkle keys mismatch — aborting before zip/publish." >&2
  echo "  SUPublicEDKey:              got='$GOT_KEY'              expected='$EXPECT_KEY'" >&2
  echo "  SUFeedURL:                  got='$GOT_FEED'             expected='$EXPECT_FEED'" >&2
  echo "  SUEnableAutomaticChecks:    got='$GOT_AUTOCHECK'        expected='$EXPECT_AUTOCHECK'" >&2
  echo "  SUScheduledCheckInterval:   got='$GOT_INTERVAL'         expected='$EXPECT_INTERVAL'" >&2
  echo "  SUAutomaticallyUpdate:      got='$GOT_AUTOUPDATE'       expected='$EXPECT_AUTOUPDATE'" >&2
  echo "  CFBundleVersion:            got='$GOT_BUNDLE_VERSION'   expected='$EXPECT_BUNDLE_VERSION'" >&2
  echo "  CFBundleShortVersionString: got='$GOT_BUNDLE_SHORT'     expected='$EXPECT_BUNDLE_SHORT'" >&2
  exit 1
fi

# Re-seal the bundle with an ad-hoc signature BEFORE zipping. Reason:
# the plist swap + executable rename + CFBundleVersion stamp above all
# invalidate whatever code seal Xcode produced during archive, leaving
# Contents/_CodeSignature/CodeResources stale-or-missing. The bundle still
# runs (ad-hoc Mach-O signatures are loose at launchd-level), but Sparkle's
# sandboxed installer XPC verifies codesign strictly after extraction and
# refuses to swap in a bundle whose seal doesn't match its contents —
# surfaced to the user as "An error occurred while extracting the archive."
# v0.9.0..v0.9.5 all shipped with this defect; every Sparkle silent-install
# attempt failed quietly. `--force --deep` re-seals the main bundle *and*
# every nested bundle (Frameworks/*.framework, XPCServices/*.xpc, the
# helper iTerm2ImportStatus.app, Sparkle's own .framework). Without --deep
# only the outer bundle gets a valid seal and nested ones still trip
# codesign --verify --deep.
echo "[release] re-signing bundle ad-hoc (force --deep)..."
codesign --force --deep --sign - "$APP_FINAL"

# Verify the re-seal locally before paying the cost of zipping. Same
# command Sparkle's installer XPC effectively runs; if this fails, no point
# uploading.
if ! codesign --verify --verbose=2 "$APP_FINAL" 2>&1 | grep -q "satisfies its Designated Requirement"; then
  echo "error: codesign verification failed on $APP_FINAL after re-seal — aborting before zip." >&2
  codesign --verify --verbose=2 "$APP_FINAL" >&2 || true
  exit 1
fi

# --sequesterRsrc is critical. Without it, ditto on an HFS+/APFS source
# tree writes AppleDouble (`._*`) sidecar files alongside every entry with
# extended attributes. The resulting zip carries ~1100 phantom files inside
# the bundle (e.g. Contents/MacOS/._iterm2-keeper-adapter). Finder's
# Archive Utility silently strips them on first-install drag, masking the
# damage — but Sparkle preserves every entry on extract, polluting the new
# bundle with sidecars that violate the just-applied codesign seal. With
# --sequesterRsrc, ditto packs the metadata into a single __MACOSX/ branch
# that gets discarded on re-extract, leaving the bundle byte-identical to
# the source.
ditto -c -k --sequesterRsrc --keepParent "$APP_FINAL" "$ZIP"

# Final gate: round-trip the zip through ditto -x and re-verify codesign
# on the extracted bundle. This is exactly the path Sparkle's installer
# takes; if this passes, Sparkle silent-install will pass too. Hardcoded
# checks since the cost of catching a regression here is far lower than
# shipping another broken auto-update cycle.
echo "[release] verifying zip round-trips with codesign intact..."
RTROUNDTRIP_DIR="$(mktemp -d)"
trap 'rm -rf "$RTROUNDTRIP_DIR"' EXIT
ditto -x -k "$ZIP" "$RTROUNDTRIP_DIR"
if ! codesign --verify --verbose=2 "$RTROUNDTRIP_DIR/$APP_NAME.app" 2>&1 | grep -q "satisfies its Designated Requirement"; then
  echo "error: codesign verification failed AFTER zip round-trip — Sparkle will reject this update." >&2
  codesign --verify --verbose=2 "$RTROUNDTRIP_DIR/$APP_NAME.app" >&2 || true
  exit 1
fi
APPLE_DOUBLE_COUNT=$(find "$RTROUNDTRIP_DIR" -name "._*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$APPLE_DOUBLE_COUNT" != "0" ]; then
  echo "error: $APPLE_DOUBLE_COUNT AppleDouble sidecars survived extraction — ditto needs --sequesterRsrc." >&2
  exit 1
fi
rm -rf "$RTROUNDTRIP_DIR"
trap - EXIT

ZIP_LENGTH=$(stat -f%z "$ZIP")

# -- Sign with EdDSA --------------------------------------------------------

echo "[release] signing zip..."
# This Sparkle vintage's sign_update wants the base64(privKey+pubKey) as
# arg 2. generate_keys stashes that blob in the login keychain under
# service=https://sparkle-project.org, account=ed25519. Pull it out at
# call time so we never have to write the secret to disk.
SPARKLE_KEY="$(security find-generic-password -s "https://sparkle-project.org" -a "ed25519" -w 2>/dev/null)"
if [ -z "$SPARKLE_KEY" ]; then
  echo "error: no Sparkle ed25519 key in keychain. Run build/sparkle-tools/generate_keys first." >&2
  exit 1
fi
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP" "$SPARKLE_KEY")"
if [ -z "$SIGNATURE" ]; then
  echo "error: sign_update produced no signature." >&2
  exit 1
fi

# -- Render appcast ---------------------------------------------------------

# LC_ALL=C forces English month/day names; otherwise a Korean LC_TIME locale
# renders "금, 15  5 2026 ..." which is not RFC 822 — Sparkle's RSS parser
# drops the item silently. v0.9.0's appcast hit exactly this.
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD|g" \
    -e "s|__PUBDATE__|$PUBDATE|g" \
    -e "s|__ZIP_URL__|$ZIP_URL|g" \
    -e "s|__ZIP_LENGTH__|$ZIP_LENGTH|g" \
    -e "s|__SIGNATURE__|$SIGNATURE|g" \
    -e "s|__RELEASE_URL__|$RELEASE_URL|g" \
    "$REPO_ROOT/tools/appcast.template.xml" > "$APPCAST"

echo "[release] appcast written to $APPCAST"

# -- Render Korean release notes for the GitHub Release page ----------------

ZIP_SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
NOTES_FILE="$OUT/release_notes.md"
CHANGELOG_FILE="$OUT/changelog.txt"
# Human-readable build descriptor for the release notes header. Falls back to
# the tag name if we are not in a tagged commit (e.g. building from a dirty
# tree). `set -u` at the top would otherwise crash the sed substitution below.
GIT_DESCRIBE="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo "$TAG")"
PREV_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --exclude="$TAG" 2>/dev/null || echo "")"
if [ -n "$PREV_TAG" ]; then
  git -C "$REPO_ROOT" log "$PREV_TAG"..HEAD --pretty='- %s' | head -n 50 > "$CHANGELOG_FILE"
else
  git -C "$REPO_ROOT" log -1 --pretty='- %s' > "$CHANGELOG_FILE"
fi

# sed for scalar fields; awk reads CHANGELOG from a file because `awk -v
# cl=...` chokes on newlines in the assignment.
sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__GIT_DESCRIBE__|$GIT_DESCRIBE|g" \
    -e "s|__PUBDATE__|$PUBDATE|g" \
    -e "s|__ZIP_NAME__|$(basename "$ZIP")|g" \
    -e "s|__SHA256__|$ZIP_SHA256|g" \
    "$REPO_ROOT/tools/RELEASE_BODY.md.template" \
  | awk -v clfile="$CHANGELOG_FILE" '
      BEGIN {
        cl = ""
        while ((getline line < clfile) > 0) {
          cl = (cl == "") ? line : cl "\n" line
        }
        close(clfile)
      }
      { gsub(/__CHANGELOG__/, cl); print }
    ' \
  > "$NOTES_FILE"

echo "[release] release notes written to $NOTES_FILE"

# -- Publish to GitHub ------------------------------------------------------

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "[release] tag $TAG already exists — uploading assets only."
  gh release upload "$TAG" "$ZIP" "$APPCAST" --clobber
  gh release edit "$TAG" --notes-file "$NOTES_FILE"
else
  echo "[release] creating GitHub release $TAG..."
  gh release create "$TAG" \
     --title "MomenTerm $VERSION" \
     --notes-file "$NOTES_FILE" \
     "$ZIP" "$APPCAST"
fi

echo
echo "Done. Sparkle clients will see this release at:"
echo "  $RELEASE_URL"
echo "Appcast feed (latest):"
echo "  https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
