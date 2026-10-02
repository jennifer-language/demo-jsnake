#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Print the version `src/release.j` carries - the one a built artefact is labelled with.
#
#     sh scripts/release-version.sh
#
# This is deliberately not `version.sh`. That one asks *git* what this checkout is, and is
# the right answer before anything has been injected. Once `release.sh` has run, git is the
# wrong place to ask: writing the version into the tree makes the tree dirty, so `version.sh`
# then reports a dev version for a build that is exactly a release tag.
#
# So: `version.sh` decides what the version *should* be, `release.sh` writes it down, and
# this reads back what was written. Anything naming or checking an artefact wants this one.

set -eu
here=$(dirname "$0")
root=$(cd "$here/.." && pwd)

version=$(sed -n 's|^export def const VERSION as string init "\(.*\)";$|\1|p' \
    "$root/src/release.j" | head -n1)
if [ -z "$version" ]; then
    echo "cannot read the version from src/release.j" >&2
    exit 1
fi
printf '%s\n' "$version"
