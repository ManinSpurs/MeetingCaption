#!/bin/zsh
# Builds MeetingCaption.app (release) with Sparkle embedded and code-signs it.
#
# Environment (all optional):
#   MEETINGCAPTION_APP_PATH       destination bundle (default: ../MeetingCaption.app). Must be named
#                                 MeetingCaption.app, must not exist and must not lie inside any .app
#                                 bundle; a relative path is resolved against the caller's directory.
#   MEETINGCAPTION_FEED_URL       Sparkle appcast written to SUFeedURL. Only the GitHub release form
#                                 https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
#                                 is accepted. Unset: the app runs normally with updates disabled.
#   MEETINGCAPTION_VERSION        CFBundleShortVersionString for this bundle (default: MeetingInfo.plist)
#   MEETINGCAPTION_BUILD          CFBundleVersion for this bundle (default: MeetingInfo.plist)
#   MEETINGCAPTION_SIGN_IDENTITY  SHA-1 of the code-signing certificate to sign with (release.sh passes
#                                 its pinned self-signed certificate). Unset: ad-hoc signature, whose
#                                 code identity changes with every build - fine for building from source.
#   MEETINGCAPTION_SIGN_KEYCHAIN  keychain file holding that identity (default: keychain search list)
#
# Local update testing only (release.sh refuses these):
#   MEETINGCAPTION_TEST_FEED_URL   loopback feed, e.g. http://127.0.0.1:8765/appcast.xml
#   MEETINGCAPTION_TEST_BUNDLE_ID  required with it and different from the real bundle identifier, so a
#                                  test app never shares the installed app's settings or permissions
set -euo pipefail
root="${0:A:h}"
fail() { print -u2 "build-meeting.sh: $*"; exit 1; }

# Same patterns as UpdateConfiguration in Sources/MeetingCaption/AppUpdater.swift and release.sh.
release_feed='^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*/releases/latest/download/appcast\.xml$'
local_test_feed='^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?/[A-Za-z0-9_./-]+$'

# True if the path or any of its ancestors is an .app bundle: writing there would modify (and
# re-sign) another app, e.g. …/Other.app/Contents/MeetingCaption.app.
inside_app_bundle() {
    local p="$1"
    while [[ "$p" != "/" ]]; do
        [[ "${(L)p:t}" == *.app ]] && return 0
        p="${p:h}"
    done
    return 1
}

real_bundle_id="$(plutil -extract CFBundleIdentifier raw "$root/MeetingInfo.plist")"
bundle_id="$real_bundle_id"
feed="${MEETINGCAPTION_FEED_URL:-}"
test_feed="${MEETINGCAPTION_TEST_FEED_URL:-}"
test_bundle_id="${MEETINGCAPTION_TEST_BUNDLE_ID:-}"
version="${MEETINGCAPTION_VERSION:-}"
build="${MEETINGCAPTION_BUILD:-}"
identity="${MEETINGCAPTION_SIGN_IDENTITY:-}"
keychain="${MEETINGCAPTION_SIGN_KEYCHAIN:-}"

if [[ -n "$feed" && ! "$feed" =~ $release_feed ]]; then
    fail "MEETINGCAPTION_FEED_URL must be https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml: $feed"
fi
if [[ -n "$test_feed$test_bundle_id" ]]; then
    [[ -z "$feed" ]] || fail "MEETINGCAPTION_FEED_URL cannot be combined with MEETINGCAPTION_TEST_* settings"
    [[ "$test_feed" =~ $local_test_feed ]] \
        || fail "MEETINGCAPTION_TEST_FEED_URL must be a loopback http feed such as http://127.0.0.1:8765/appcast.xml: ${test_feed:-unset}"
    [[ "$test_bundle_id" =~ '^[A-Za-z0-9.-]+$' && "${(L)test_bundle_id}" != "${(L)real_bundle_id}" ]] \
        || fail "MEETINGCAPTION_TEST_BUNDLE_ID must be a bundle identifier other than $real_bundle_id: ${test_bundle_id:-unset}"
    feed="$test_feed"
    bundle_id="$test_bundle_id"
fi
if [[ -n "$version" && ! "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
    fail "MEETINGCAPTION_VERSION must look like 1.5.0: $version"
fi
if [[ -n "$build" && ! "$build" =~ '^[0-9]+$' ]]; then
    fail "MEETINGCAPTION_BUILD must be an integer: $build"
fi
if [[ -n "$identity" && ! "$identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
    fail "MEETINGCAPTION_SIGN_IDENTITY must be a certificate SHA-1 (40 hex digits): $identity"
fi
[[ -z "$keychain" || -n "$identity" ]] || fail "MEETINGCAPTION_SIGN_KEYCHAIN needs MEETINGCAPTION_SIGN_IDENTITY"

# Resolve every caller-supplied path before changing directory.
app="${MEETINGCAPTION_APP_PATH:-${root:h}/MeetingCaption.app}"
app="${app:A}"
[[ "${app:t}" == "MeetingCaption.app" ]] || fail "Destination must be named MeetingCaption.app: $app"
inside_app_bundle "${app:h}" && fail "refusing to write inside an app bundle: $app"
[[ ! -e "$app" && ! -L "$app" ]] || fail "Destination already exists; choose a fresh folder: $app"
sign=(--force --timestamp=none --sign "${identity:--}")
if [[ -n "$keychain" ]]; then
    [[ -f "${keychain:A}" ]] || fail "MEETINGCAPTION_SIGN_KEYCHAIN not found: $keychain"
    sign+=(--keychain "${keychain:A}")
fi
cd "$root"

swift build --scratch-path .build -c release --product MeetingCaption -j 1
bin="$(swift build --scratch-path .build -c release --show-bin-path)"
sparkle_src="$bin/Sparkle.framework"
if [[ ! -d "$sparkle_src" ]]; then
    print -u2 "Sparkle.framework missing from build output: $sparkle_src"
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$bin/MeetingCaption" "$app/Contents/MacOS/MeetingCaption"
cp MeetingInfo.plist "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
[[ -n "$feed" ]] && plutil -replace SUFeedURL -string "$feed" "$plist"
# The app accepts a loopback feed only from a bundle carrying this marker (AppUpdater.swift).
[[ -n "$test_feed" ]] && plutil -replace MeetingCaptionLocalTestFeed -bool YES "$plist"
[[ -n "$version" ]] && plutil -replace CFBundleShortVersionString -string "$version" "$plist"
[[ -n "$build" ]] && plutil -replace CFBundleVersion -string "$build" "$plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
plutil -lint -s "$plist"

# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$sparkle_src" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
       "$app/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
       "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Modules"
rm -f "$app/Contents/Frameworks/Sparkle.framework/Headers" \
      "$app/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
      "$app/Contents/Frameworks/Sparkle.framework/Modules"

# Inside-out signing. Sparkle's helpers keep their identifiers, entitlements
# (Downloader.xpc is sandboxed) and hardened-runtime flag; the app itself is signed last.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$sparkle/XPCServices/Installer.xpc" "$sparkle/XPCServices/Downloader.xpc" \
              "$sparkle/Autoupdate" "$sparkle/Updater.app" "$app/Contents/Frameworks/Sparkle.framework"; do
    codesign "${sign[@]}" --preserve-metadata=identifier,entitlements,flags "$nested"
done
codesign "${sign[@]}" --identifier "$bundle_id" "$app"
codesign --verify --strict --deep "$app"
print "Built: $app (version $(plutil -extract CFBundleShortVersionString raw "$plist") build $(plutil -extract CFBundleVersion raw "$plist"), feed: ${feed:-none}, signature: ${identity:-ad-hoc})"
