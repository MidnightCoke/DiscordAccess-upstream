#!/bin/bash
# Packages an already-built DiscordAccess.app for installation in /Applications.
#
# macOS may add FinderInfo metadata to bundles stored in a File Provider workspace,
# invalidating their code signatures. Copying without metadata into TMPDIR gives
# productbuild a clean bundle. This script never changes the source app or replaces
# an existing output package.
set -euo pipefail

fail() {
    echo "build-installer: $1" >&2
    exit 1
}

if [ "$#" -ne 2 ]; then
    echo "Usage: macos/scripts/build-installer.sh DiscordAccess.app output.pkg" >&2
    exit 64
fi

source_app="$1"
output_pkg="$2"

[ -d "$source_app" ] && [ "${source_app##*/}" = "DiscordAccess.app" ] || fail "Expected an existing DiscordAccess.app bundle: $source_app"
[ "${output_pkg##*.}" = "pkg" ] || fail "Output must end in .pkg: $output_pkg"
[ -d "$(dirname "$output_pkg")" ] || fail "Output directory does not exist: $(dirname "$output_pkg")"
[ ! -e "$output_pkg" ] && [ ! -L "$output_pkg" ] || fail "Output already exists: $output_pkg"

temporary_root="${TMPDIR:-/private/tmp}"
[ -d "$temporary_root" ] || fail "Temporary directory does not exist: $temporary_root"
stage="$(mktemp -d "${temporary_root%/}/discordaccess-installer.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

staged_app="$stage/DiscordAccess.app"
candidate_pkg="$stage/DiscordAccess-Installer.pkg"

# Do not carry FinderInfo, resource forks, ACLs, quarantine or other xattrs from
# the workspace into the code-signed bundle sealed inside the installer.
ditto --norsrc --noextattr --noqtn --noacl "$source_app" "$staged_app"
codesign --verify --strict --deep --verbose=2 "$staged_app" || fail "Staged app signature is invalid"

productbuild --component "$staged_app" /Applications "$candidate_pkg"
pkgutil --expand "$candidate_pkg" "$stage/expanded" || fail "Installer package could not be expanded"
[ -f "$stage/expanded/Distribution" ] || fail "Installer package has no Distribution metadata"

# A Developer ID Installer identity is not available in the default local build.
# Report its signature status without treating an unsigned package as corrupt.
if ! pkgutil --check-signature "$candidate_pkg"; then
    echo "build-installer: Installer package is unsigned; macOS may require Open Anyway." >&2
fi

# -n prevents replacing a file another process placed at the output path while
# this package was being built. A skipped move leaves candidate_pkg in place.
mv -n "$candidate_pkg" "$output_pkg"
[ ! -e "$candidate_pkg" ] || fail "Output appeared during packaging; existing file was not replaced: $output_pkg"
echo "$output_pkg"
