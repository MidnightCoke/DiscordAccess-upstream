#!/bin/bash
# Builds DiscordAccess.app under macos/build/apps/<time>/ (design 6, stage 2d).
#
# The pinned engine (macos/build/engine/sing-box, from build-engine.py) goes in unchanged: re-signing it would change the
# SHA-256 and cdhash the app pins, and a personal certificate would make them differ on every Mac. The app's signature
# seals it with everything else. The app is signed with DISCORDACCESS_SIGN_IDENTITY (a code-signing identity in the
# keychain); without one it is signed ad hoc, and macOS then forgets its Full Disk Access with every build.
#
# Earlier builds are never deleted: macOS scans a newly run executable, and deleting one mid-scan crashed its scanner.
set -euo pipefail

macos="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(dirname "$macos")"
identity="${DISCORDACCESS_SIGN_IDENTITY:--}"
engine="$macos/build/engine/sing-box"
hook="$repo/bridge/attachment-download.cjs"
agent="io.github.alpertknn.DiscordAccess.agent.plist"

fail() {
    echo "build-app: $1" >&2
    exit 1
}

[ -x "$engine" ] || fail "Motor bulunamadı: $engine. Önce macos/scripts/build-engine.py ile derleyin."
[ -f "$hook" ] || fail "Ek dosyası kancası bulunamadı: $hook."

swift build --package-path "$macos" -c release --product DiscordAccess
binary="$(swift build --package-path "$macos" -c release --show-bin-path)/DiscordAccess"
[ -x "$binary" ] || fail "Derlenen uygulama bulunamadı: $binary."

output="$macos/build/apps/$(date -u +%Y%m%d-%H%M%S)"
app="$output/DiscordAccess.app"
[ ! -e "$output" ] || fail "Çıktı klasörü zaten var: $output. Bir saniye sonra yeniden deneyin."
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
install -m 0644 "$macos/Resources/Info.plist" "$app/Contents/Info.plist"
install -m 0644 "$macos/Resources/$agent" "$app/Contents/Library/LaunchAgents/$agent"
install -m 0644 "$hook" "$app/Contents/Resources/attachment-download.cjs"
install -m 0755 "$binary" "$app/Contents/MacOS/DiscordAccess"
# cp keeps the engine's bytes, and so its linker signature, exactly.
cp "$engine" "$app/Contents/Helpers/sing-box"
chmod 0755 "$app/Contents/Helpers/sing-box"

if [ "$identity" = "-" ]; then
    echo "build-app: İmza kimliği verilmedi; uygulama ad-hoc imzalanıyor. Tam Disk Erişimi her yeni derlemede yeniden verilmelidir." >&2
fi
codesign --force --sign "$identity" --options runtime --timestamp=none "$app/Contents/MacOS/DiscordAccess"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --strict --deep --verbose=2 "$app"

# The app checks its own engine and hook against the digests it pins.
"$app/Contents/MacOS/DiscordAccess" --verify-package

echo "$app"
