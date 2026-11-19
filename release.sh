#!/bin/zsh
# Produces everything one GitHub Release needs, into a single output directory:
#   MeetingCaption-<version>.dmg          drag-to-Applications installer (app + /Applications link)
#   MeetingCaption-<version>.dmg.sha256   its SHA-256, for the release notes
#   MeetingCaption-<version>.zip          Sparkle update archive (EdDSA-signed in the appcast)
#   appcast.xml                           Sparkle feed for this version, itself EdDSA-signed
#
# A release is only produced with the GitHub feed, the real bundle identifier and the pinned
# self-signed code-signing certificate below; local update tests use build-meeting.sh's
# MEETINGCAPTION_TEST_* settings instead. Private keys stay in the Keychain: Sparkle's sign_update
# and codesign read them there, and this script never writes them out.
set -euo pipefail
root="${0:A:h}"

cert_name="MeetingCaption Release Signing"
# SHA-1 of the self-signed certificate every release is signed with. macOS ties privacy permissions
# and Keychain access to the designated requirement (bundle identifier + this certificate), so a
# different certificate makes every user re-approve them once. Change it only deliberately.
release_cert_sha1="CC849466C28820FE9E0E8C3F6DA779478118D6A7"
release_feed='^https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*)/releases/latest/download/appcast\.xml$'

usage() {
    cat <<'EOF'
Usage: ./release.sh --version 1.5.0 --build 9 --feed-url URL [options]
       ./release.sh --create-signing-identity [--keychain FILE]

  --version X.Y[.Z]          CFBundleShortVersionString of the release
  --build N                  CFBundleVersion (integer; must increase with every release)
  --feed-url URL             https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
                             (required; baked into the app as SUFeedURL)
  --notes FILE               Korean release notes (.md, .html or .txt); shown by default
  --notes-en FILE            optional English release notes (.md, .html or .txt)
  --output DIR               output directory, must be new or empty and outside any .app
                             (default: dist/<version>)
  --keychain FILE            keychain holding the signing certificate (default: login keychain)
  --create-signing-identity  one-time: create the self-signed certificate "MeetingCaption Release
                             Signing" in the keychain (refuses if one already exists)

Environment: SPARKLE_KEY_ACCOUNT  Keychain account of the EdDSA key (default: ed25519)
EOF
}

fail() { print -u2 "release.sh: $*"; exit 1; }

# True if the path or any of its ancestors is an .app bundle (same check as build-meeting.sh).
inside_app_bundle() {
    local p="$1"
    while [[ "$p" != "/" ]]; do
        [[ "${(L)p:t}" == *.app ]] && return 0
        p="${p:h}"
    done
    return 1
}

cert_sha1() {
    security find-certificate -a -c "$cert_name" -Z "$keychain" 2>/dev/null | awk '/^SHA-1 hash:/ { print $3 }'
}

create_signing_identity() {
    [[ -z "$(cert_sha1)" ]] \
        || fail "'$cert_name' already exists in $keychain. Keep and back it up: a new certificate changes the app's code identity for every user."
    local tmp p12_pass sha1
    tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/meetingcaption-identity.XXXXXX")"
    trap "rm -rf -- ${(q)tmp}" EXIT
    p12_pass="$(openssl rand -hex 24)"
    # The private key leaves openssl only through this pipe and inside a PKCS#12 file encrypted
    # with a one-time password that is never stored; the file is deleted right after the import.
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 -subj "/CN=$cert_name" \
            -addext 'basicConstraints=critical,CA:FALSE' \
            -addext 'keyUsage=critical,digitalSignature' \
            -addext 'extendedKeyUsage=critical,codeSigning' \
            -keyout /dev/stdout -out /dev/stdout 2>/dev/null \
        | P12_PASS="$p12_pass" openssl pkcs12 -export -name "$cert_name" -passout env:P12_PASS -out "$tmp/identity.p12"
    security import "$tmp/identity.p12" -k "$keychain" -f pkcs12 -P "$p12_pass" -T /usr/bin/codesign >/dev/null
    rm -P "$tmp/identity.p12"
    sha1="$(cert_sha1)"
    print "Created '$cert_name' (SHA-1 $sha1) in $keychain."
    [[ "$sha1" == "$release_cert_sha1" ]] || print "Set release_cert_sha1=\"$sha1\" in release.sh so releases are signed with it."
    print "Back it up now (README: 코드 서명 인증서). If macOS asks the first time codesign uses the key, enter the keychain password and choose 'Always Allow'."
}

mode=release
version="" build="" feed="" notes="" notes_en="" out=""
keychain="${HOME:A}/Library/Keychains/login.keychain-db"
account="${SPARKLE_KEY_ACCOUNT:-ed25519}"
while (( $# )); do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --build) build="${2:?--build needs a value}"; shift 2 ;;
        --feed-url) feed="${2:?--feed-url needs a value}"; shift 2 ;;
        --notes) notes="${2:?--notes needs a file}"; shift 2 ;;
        --notes-en) notes_en="${2:?--notes-en needs a file}"; shift 2 ;;
        --output) out="${2:?--output needs a directory}"; shift 2 ;;
        --keychain) keychain="${2:?--keychain needs a file}"; shift 2 ;;
        --create-signing-identity) mode=create; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done
keychain="${keychain:A}"
[[ -f "$keychain" ]] || fail "keychain not found: $keychain"
if [[ "$mode" == create ]]; then
    create_signing_identity
    exit 0
fi

# build-meeting.sh reads MEETINGCAPTION_* settings; a leftover one (e.g. a test bundle identifier or
# feed) must not silently change what ships, so this script passes every setting itself.
leftover=(${(k)parameters[(I)MEETINGCAPTION_*]})
(( ${#leftover} == 0 )) || fail "unset these test/build settings before releasing: ${leftover[*]}"
[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || fail "--version must look like 1.5.0 (got '${version}')"
[[ "$build" =~ '^[0-9]+$' ]] || fail "--build must be an integer (got '${build}')"
[[ "$feed" =~ $release_feed ]] \
    || fail "--feed-url must be https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml (got '${feed}')"
prefix="https://github.com/${match[1]}/${match[2]}/releases/download/v${version}/"
for f in "$notes" "$notes_en"; do
    [[ -z "$f" || -f "$f" ]] || fail "release notes file not found: $f"
done

# Output directory: everything this script writes goes below it (plus SwiftPM's .build cache).
out="${${out:-$root/dist/$version}:A}"
inside_app_bundle "$out" && fail "refusing to write inside an app bundle: $out"
[[ "$out" != "/" && "$out" != "${HOME:A}" && "$out" != "$root" ]] || fail "refusing to use $out as output directory"
if [[ -e "$out" ]]; then
    [[ -d "$out" && -z "$(ls -A "$out")" ]] || fail "output directory must be new or empty: $out"
fi

# The stable code identity: without the pinned certificate there is no release (an ad-hoc or
# different signature would reset every user's permissions).
[[ "$(security find-identity -p codesigning "$keychain")" == *"$release_cert_sha1"* ]] \
    || fail "signing certificate $release_cert_sha1 ('$cert_name') with its private key is not in $keychain (README: 코드 서명 인증서)"

# The Keychain EdDSA key must be the one whose public half ships in the app.
swift package --scratch-path "$root/.build" resolve
sparkle_bin="$root/.build/artifacts/sparkle/Sparkle/bin"
key_public="$("$sparkle_bin/generate_keys" --account "$account" -p)" \
    || fail "no Sparkle EdDSA key for account '$account' in the Keychain (see README: 업데이트 서명 키)"
plist_public="$(plutil -extract SUPublicEDKey raw "$root/MeetingInfo.plist")"
[[ "$key_public" == "$plist_public" ]] \
    || fail "Keychain key ($key_public) does not match SUPublicEDKey in MeetingInfo.plist ($plist_public)"

mkdir -p "$out"
work="$out/.work"
mountpoint="$work/mnt"
dmg="$out/MeetingCaption-$version.dmg"
zip="$out/MeetingCaption-$version.zip"
appcast="$out/appcast.xml"
cleanup() {
    [[ -d "$mountpoint" ]] && hdiutil detach -quiet "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$work"
app="$work/MeetingCaption.app"
MEETINGCAPTION_APP_PATH="$app" MEETINGCAPTION_FEED_URL="$feed" \
MEETINGCAPTION_VERSION="$version" MEETINGCAPTION_BUILD="$build" \
MEETINGCAPTION_SIGN_IDENTITY="$release_cert_sha1" MEETINGCAPTION_SIGN_KEYCHAIN="$keychain" \
    zsh "$root/build-meeting.sh"

# What ships must be exactly the release configuration.
plist="$app/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$root/MeetingInfo.plist")"
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == "$bundle_id" ]] || fail "built app has the wrong bundle identifier"
[[ "$(plutil -extract SUFeedURL raw "$plist")" == "$feed" ]] || fail "built app has the wrong SUFeedURL"
! plutil -extract MeetingCaptionLocalTestFeed raw "$plist" >/dev/null 2>&1 || fail "built app is a local test build"
expected_dr="identifier \"$bundle_id\" and certificate leaf = H\"${(L)release_cert_sha1}\""
actual_dr="$(codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => //p')"
[[ "$actual_dr" == "$expected_dr" ]] || fail "unexpected designated requirement: $actual_dr (expected $expected_dr)"

# Sparkle update archive.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# Drag-to-Applications disk image.
mkdir -p "$work/dmg"
ditto "$app" "$work/dmg/MeetingCaption.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname "MeetingCaption $version" -srcfolder "$work/dmg" -fs HFS+ -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"
mkdir -p "$mountpoint"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mountpoint" "$dmg"
codesign --verify --strict --deep "$mountpoint/MeetingCaption.app"
[[ -L "$mountpoint/Applications" ]] || fail "DMG lacks the Applications link"
hdiutil detach -quiet "$mountpoint"
# Same format as `shasum -a 256`, so users can check the download with `shasum -a 256 -c`.
dmg_sha256="$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
print -r -- "$dmg_sha256  ${dmg:t}" > "$dmg.sha256"

# Appcast.
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    print -r -- "$s"
}
notes_format() {
    case "${1:e:l}" in
        md|markdown) print markdown ;;
        html|htm) print html ;;
        *) print plain-text ;;
    esac
}
description() { # <lang or empty> <file>
    local body lang_attr=""
    body="$(<"$2")"
    [[ "$body" != *']]>'* ]] || fail "release notes must not contain ']]>': $2"
    [[ -n "$1" ]] && lang_attr=" xml:lang=\"$1\""
    print -r -- "      <description${lang_attr} sparkle:format=\"$(notes_format "$2")\"><![CDATA[${body}]]></description>"
}
signature="$("$sparkle_bin/sign_update" --account "$account" -p "$zip")"
length="$(stat -f %z "$zip")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw "$plist")"
archs="$(lipo -archs "$app/Contents/MacOS/MeetingCaption")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
{
    print -r -- '<?xml version="1.0" encoding="utf-8"?>'
    print -r -- '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
    print -r -- '  <channel>'
    print -r -- '    <title>MeetingCaption</title>'
    print -r -- "    <link>$(xml_escape "$feed")</link>"
    print -r -- '    <language>ko</language>'
    print -r -- '    <item>'
    print -r -- "      <title>MeetingCaption $version</title>"
    print -r -- "      <pubDate>$pub_date</pubDate>"
    print -r -- "      <sparkle:version>$build</sparkle:version>"
    print -r -- "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>"
    print -r -- "      <sparkle:minimumSystemVersion>$(xml_escape "$minimum_os")</sparkle:minimumSystemVersion>"
    [[ "$archs" == "arm64" ]] && print -r -- '      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
    # Korean notes are the default (no xml:lang), so every UI language gets them unless
    # English notes are provided as the localized alternative.
    if [[ -n "$notes" ]]; then
        description "" "$notes"
    else
        print -r -- "      <description sparkle:format=\"plain-text\"><![CDATA[MeetingCaption $version 버전이 출시되었습니다.]]></description>"
    fi
    [[ -n "$notes_en" ]] && description en "$notes_en"
    print -r -- "      <enclosure url=\"$(xml_escape "${prefix}MeetingCaption-$version.zip")\" type=\"application/octet-stream\" sparkle:edSignature=\"$signature\" length=\"$length\"/>"
    print -r -- '    </item>'
    print -r -- '  </channel>'
    print -r -- '</rss>'
} > "$appcast"
xmllint --noout "$appcast"
"$sparkle_bin/sign_update" --account "$account" "$appcast"
"$sparkle_bin/sign_update" --account "$account" --verify "$appcast"
"$sparkle_bin/sign_update" --account "$account" --verify "$zip" "$signature"

rm -rf -- "$work"
print "
Release $version ($build) ready in $out:
  ${dmg:t}
  ${dmg:t}.sha256
  ${zip:t}
  appcast.xml
Upload all four to the GitHub Release tagged v$version and publish it as the latest release.
Put the DMG checksum in the release notes:
  SHA-256 (${dmg:t}) = $dmg_sha256
Feed:      $feed
Downloads: ${prefix}MeetingCaption-$version.zip
Signed by: $cert_name ($release_cert_sha1)"
