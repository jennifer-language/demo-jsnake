#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Print this checkout's version, SemVer-style.
#
#   on a release tag   1.2.0
#   anywhere else      1.2.0+7.gd754881      (tag, commits since, commit id)
#   no tags at all     0.0.0+12.g1a2b3c4
#   not a git checkout the version already in deck.toml
#
# The `+` makes the dev form SemVer *build metadata*, which is the right category: it is
# ignored when comparing versions, so `1.2.0+7.gabc` and `1.2.0` sort equal and a dev
# build never appears to be newer than the release it descends from. A prerelease suffix
# (`-7.gabc`) would sort *below* the tag, which is worse - a build from after 1.2.0 is not
# a candidate for it.
#
#     sh scripts/version.sh

set -u
here=$(dirname "$0")
root="$here/.."

manifest_version() {
    sed -n 's/^version = "\(.*\)"$/\1/p' "$root/deck.toml" | head -n1
}

if ! command -v git >/dev/null 2>&1 || ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    manifest_version
    exit 0
fi

tag=$(git -C "$root" describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)

if [ -z "$tag" ]; then
    count=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)
    printf '0.0.0+%s.g%s\n' "$count" "$commit"
    exit 0
fi

# Exactly on the tag, and nothing uncommitted: this is that release.
if [ "$(git -C "$root" rev-list -n1 "$tag")" = "$(git -C "$root" rev-parse HEAD)" ] &&
    [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    printf '%s\n' "$tag"
    exit 0
fi

count=$(git -C "$root" rev-list --count "$tag..HEAD" 2>/dev/null || echo 0)
printf '%s+%s.g%s\n' "$tag" "$count" "$commit"
