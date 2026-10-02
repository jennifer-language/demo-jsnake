# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * What this build is: the version, and where it came from.
 *
 * **Generated.** `scripts/release.sh` rewrites this file from git, and CI runs it on
 * every tagged release so a published tarball says exactly which commit it was cut from.
 * A working checkout keeps whatever was last written here, which is why the committed
 * copy is a real, valid version rather than a placeholder - `jsnake --version` has to
 * work before anyone has run a script.
 *
 * It is a module of its own rather than a constant in `cli` so that regenerating it
 * touches one small file with no logic in it: a generator that rewrites a source file
 * full of behaviour is a generator that will eventually eat some.
 * @module release
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 */

/**
 * This build's version. A release tag is bare SemVer (`1.2.0`); any other build carries
 * the tag it descends from plus build metadata naming the distance and the commit
 * (`1.2.0+7.gd754881`). Build metadata is ignored when versions are compared, so a dev
 * build never sorts above the release it came after.
 */
export def const VERSION as string init "0.1.0";

/**
 * The commit this build was cut from, short form, or `"unknown"` outside a checkout.
 */
export def const COMMIT as string init "unknown";

/**
 * Whether this build is exactly a release tag, with nothing uncommitted on top.
 */
export def const RELEASE as bool init false;
