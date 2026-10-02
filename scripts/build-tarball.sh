#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Build the release tarball: the runtime tree and nothing else.
#
#     sh scripts/build-tarball.sh [outdir]
#
# Produces `jsnake-<version>.tar.gz` plus a `.sha256` sidecar. What goes in is what an
# installed app needs to run - `bin/`, `src/` without its test overlays, `deck.toml`,
# `README.md`, the licence texts, the man page, and the terminal diagnostic. What stays out
# is everything
# only a developer wants: the overlays, the packaging, the CI config, the scripts that build
# releases.
#
# The licence texts are not optional extras: the LGPL asks that the terms travel with the
# work, and LGPL-3.0 is additional permissions over GPL-3.0, so both files ship.
#
# The tree unpacks to `jsnake-<version>/` with `bin/` and `src/` as siblings, which is what
# the launcher's `import "../src/cli.j"` needs and the same layout `jvc app install` leaves
# behind. jvc itself installs from a git tag, not from this archive; this is what distro
# packaging builds on and what a by-hand install unpacks.

set -eu
here=$(dirname "$0")
root=$(cd "$here/.." && pwd)
out=${1:-$root/dist}

# The version comes from the generated module, never from git directly - see
# `release-version.sh` for why that distinction matters once `release.sh` has run.
version=$(sh "$here/release-version.sh")
name="jsnake-$version"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$name/bin" "$stage/$name/src" "$stage/$name/scripts" "$stage/$name/man"
cp "$root/bin/jsnake" "$stage/$name/bin/"
cp "$root/deck.toml" "$root/README.md" "$stage/$name/"
cp "$root/LICENSE" "$root/LICENSE.GPL-3.0" "$stage/$name/"
cp "$root/scripts/terminal.j" "$stage/$name/scripts/"
cp "$root/man/jsnake.1" "$stage/$name/man/"
for f in "$root"/src/*.j; do
    case "$f" in
    *_test.j) continue ;;
    esac
    cp "$f" "$stage/$name/src/"
done
chmod 755 "$stage/$name/bin/jsnake" "$stage/$name/scripts/terminal.j"

mkdir -p "$out"
tar -czf "$out/$name.tar.gz" -C "$stage" "$name"
( cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )

printf 'built %s\n' "$out/$name.tar.gz"
printf '  %s\n' "$(cut -d' ' -f1 < "$out/$name.tar.gz.sha256")"
printf '  %s files, %s\n' \
    "$(tar -tzf "$out/$name.tar.gz" | grep -vc '/$')" \
    "$(du -h "$out/$name.tar.gz" | cut -f1)"
