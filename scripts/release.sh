#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Write this checkout's version into `src/release.j`, `deck.toml` and `man/jsnake.1`.
#
#     sh scripts/release.sh
#
# Run by CI on every tagged release so a published tarball says which commit it came
# from. Safe to run by hand; it is idempotent and touches only those three files.
#
# `deck.toml` gets the bare SemVer without build metadata, because jvc resolves deck
# versions against a registry and a `+7.gabc` suffix is not something a constraint can
# usefully match. `src/release.j` keeps the full string, which is what a person reading a
# bug report needs. The man page's `.TH` line gets the bare version and the commit date,
# because that line is what `man` prints in the footer of every page.

set -eu
here=$(dirname "$0")
root="$here/.."

version=$(sh "$here/version.sh")
bare=${version%%+*}
release=false
case "$version" in
*+*) commit=${version##*.g} ;;
*) commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)
   release=true ;;
esac

sed -i.bak \
    -e "s|^export def const VERSION as string init \".*\";|export def const VERSION as string init \"$version\";|" \
    -e "s|^export def const COMMIT as string init \".*\";|export def const COMMIT as string init \"$commit\";|" \
    -e "s|^export def const RELEASE as bool init .*;|export def const RELEASE as bool init $release;|" \
    "$root/src/release.j"
rm -f "$root/src/release.j.bak"

sed -i.bak -e "s|^version = \".*\"$|version = \"$bare\"|" "$root/deck.toml"
rm -f "$root/deck.toml.bak"

# `[provides]` names the concrete version this app offers, so it tracks the manifest.
sed -i.bak -e "s|^jsnake = \".*\"$|jsnake = \"$bare\"|" "$root/deck.toml"
rm -f "$root/deck.toml.bak"

# The man page's `.TH` line: version in the footer, and the date the version was made
# rather than the date this ran, so running it twice on one commit changes nothing.
date=$(git -C "$root" log -1 --format=%cd --date=short 2>/dev/null || date +%F)
sed -i.bak \
    -e "s|^\.TH JSNAKE 1 \".*\" \".*\" \"Games\"$|.TH JSNAKE 1 \"$date\" \"jsnake $bare\" \"Games\"|" \
    "$root/man/jsnake.1"
rm -f "$root/man/jsnake.1.bak"

printf 'release: version %s (commit %s, release=%s)\n' "$version" "$commit" "$release"
