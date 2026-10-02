# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Grid geometry for the snake field: a `Point` cell, the four directions as
 * named string constants, and the pure operations the game rules, the wire
 * protocol, and the renderer all share.
 *
 * The field is a `width` by `height` grid of cells, 0-based with the origin at
 * the top-left - the same convention the `screen` module uses, so a field cell
 * maps to a screen cell by adding the field's offset and nothing else. `y`
 * grows downwards, which is why `UP` decrements it.
 *
 * A direction is a lowercase string rather than an enum on purpose: it is the
 * value that travels over the wire, so keeping one representation end to end
 * removes a conversion (and a class of bug) from every layer above.
 * @module geom
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./geom.j" as geom;
 * def head as geom.Point init geom.step(geom.at(3, 3), geom.UP);   # (3, 2)
 * def onField as bool init geom.inBounds($head, 20, 10);           # true
 */

use strings;
use convert;

/**
 * The upward direction: towards row zero, so it decrements `y`.
 */
export def const UP as string init "up";

/**
 * The downward direction: away from row zero, so it increments `y`.
 */
export def const DOWN as string init "down";

/**
 * The leftward direction: towards column zero, so it decrements `x`.
 */
export def const LEFT as string init "left";

/**
 * The rightward direction: away from column zero, so it increments `x`.
 */
export def const RIGHT as string init "right";

/**
 * The four directions in clockwise order, starting at `UP`. Handy for a
 * deterministic scan over every neighbour of a cell.
 */
export def const DIRECTIONS as list of string init [UP, RIGHT, DOWN, LEFT];

/**
 * The separator between the two coordinates of a cell key, chosen so a key
 * never collides with the protocol's own field separators.
 */
export def const KEY_SEPARATOR as string init ".";

/**
 * One cell of the playing field. Value-semantic like every Jennifer struct, so
 * a `Point` can be copied around freely without aliasing.
 * @field x {int} the column, 0-based, growing rightwards
 * @field y {int} the row, 0-based, growing downwards
 */
export def struct Point {
    x as int,
    y as int
};

/**
 * The cell at `(x, y)`. The constructor exists so callers need not name the
 * struct's fields at every use site.
 * @param x {int} the column
 * @param y {int} the row
 * @return {Point} the cell
 */
export func at(x as int, y as int) {
    return Point{x: $x, y: $y};
}

/**
 * Whether two cells are the same cell.
 * @param a {Point} the first cell
 * @param b {Point} the second cell
 * @return {bool} true when both coordinates match
 */
export func equals(a as Point, b as Point) {
    return $a.x == $b.x and $a.y == $b.y;
}

/**
 * Whether `dir` is one of the four directions this module defines. Guard
 * anything arriving from the network with this before acting on it.
 * @param dir {string} the candidate direction
 * @return {bool} true when `dir` is `UP`, `DOWN`, `LEFT`, or `RIGHT`
 */
export func isDirection(dir as string) {
    return $dir == UP or $dir == DOWN or $dir == LEFT or $dir == RIGHT;
}

/**
 * The cell one step from `p` in direction `dir`. An unknown direction leaves
 * the cell where it is, so a corrupt wire value stalls a snake rather than
 * teleporting it.
 * @param p {Point} the starting cell
 * @param dir {string} the direction to move in
 * @return {Point} the neighbouring cell
 */
export func step(p as Point, dir as string) {
    match ($dir) {
        when UP { return at($p.x, $p.y - 1); }
        when DOWN { return at($p.x, $p.y + 1); }
        when LEFT { return at($p.x - 1, $p.y); }
        when RIGHT { return at($p.x + 1, $p.y); }
        else { return $p; }
    }
}

/**
 * The direction facing the other way. An unknown direction has no opposite and
 * is returned unchanged.
 * @param dir {string} the direction to reverse
 * @return {string} the reversed direction
 */
export func opposite(dir as string) {
    match ($dir) {
        when UP { return DOWN; }
        when DOWN { return UP; }
        when LEFT { return RIGHT; }
        when RIGHT { return LEFT; }
        else { return $dir; }
    }
}

/**
 * Whether the two directions face each other - the turn a snake may not make,
 * since it would drive the head straight into its own neck.
 * @param a {string} the current direction
 * @param b {string} the requested direction
 * @return {bool} true when `b` reverses `a`
 */
export func isReverse(a as string, b as string) {
    return isDirection($a) and $b == opposite($a);
}

/**
 * Whether `p` lies inside a `width` by `height` field.
 * @param p {Point} the cell to test
 * @param width {int} the field width in cells
 * @param height {int} the field height in cells
 * @return {bool} true when the cell is on the field
 */
export func inBounds(p as Point, width as int, height as int) {
    return $p.x >= 0 and $p.x < $width and $p.y >= 0 and $p.y < $height;
}

/**
 * The index of `p` in `cells`, or `-1` when it does not occur. Linear, which is
 * what a snake body wants; use a `key`-based map for whole-field occupancy.
 * @param cells {list of Point} the cells to search
 * @param p {Point} the cell to find
 * @return {int} the 0-based index, or -1
 */
export func indexOf(cells as list of Point, p as Point) {
    for (def i as int init 0; $i < len($cells); $i = $i + 1) {
        if (equals($cells[$i], $p)) {
            return $i;
        }
    }
    return -1;
}

/**
 * Whether `cells` holds `p`.
 * @param cells {list of Point} the cells to search
 * @param p {Point} the cell to find
 * @return {bool} true when the cell occurs in the list
 */
export func contains(cells as list of Point, p as Point) {
    return indexOf($cells, $p) >= 0;
}

/**
 * The cell `p` brought back onto a `width` by `height` field by wrapping: a step off one
 * edge arrives at the opposite one. A cell already on the field is returned unchanged.
 *
 * Jennifer's `%` is floored, so a negative coordinate wraps to the far edge without a
 * sign correction - `-1 % 20` is 19, not -1.
 * @param p {Point} the cell, possibly off the field
 * @param width {int} the field width in cells
 * @param height {int} the field height in cells
 * @return {Point} the equivalent cell on the field
 */
export func wrap(p as Point, width as int, height as int) {
    if ($width <= 0 or $height <= 0) {
        return $p;
    }
    return at($p.x % $width, $p.y % $height);
}

/**
 * The cell's index in a row-major field of `width` columns - `y * width + x`. An
 * integer key for an occupancy set, which a flood fill visits thousands of times
 * a second and where a string key would be the dominant cost.
 * @param p {Point} the cell
 * @param width {int} the field width in cells
 * @return {int} the row-major index
 */
export func index(p as Point, width as int) {
    return $p.y * $width + $p.x;
}

/**
 * The cell at a row-major `index` in a field of `width` columns - the inverse of
 * `index`.
 * @param i {int} the row-major index
 * @param width {int} the field width in cells
 * @return {Point} the cell
 */
export func fromIndex(i as int, width as int) {
    return at($i % $width, $i // $width);
}

/**
 * The number of cells between two points counted in steps along the grid - the
 * Manhattan distance, which is the true number of moves a snake needs to get
 * from one to the other.
 * @param a {Point} the first cell
 * @param b {Point} the second cell
 * @return {int} the step distance
 */
export func distance(a as Point, b as Point) {
    return absOf($a.x - $b.x) + absOf($a.y - $b.y);
}

# absOf is the integer absolute value, local so geom keeps its tiny import list.
func absOf(n as int) {
    if ($n < 0) {
        return -$n;
    }
    return $n;
}

/**
 * The canonical string key for a cell, `"<x>.<y>"`. This is both the map key
 * an occupancy set is built on and the on-the-wire spelling of a cell, so the
 * two can never drift apart.
 * @param p {Point} the cell
 * @return {string} the cell key
 */
export func key(p as Point) {
    return convert.toString($p.x) + KEY_SEPARATOR + convert.toString($p.y);
}

/**
 * The cell a `key` names. A malformed key decodes to the origin rather than
 * throwing, because the only producer of keys is `key` itself and the only
 * other source is an untrusted peer, which must not be able to crash a host.
 * @param s {string} the cell key, as `key` spells it
 * @return {Point} the decoded cell, or `(0, 0)` when `s` is malformed
 */
export func fromKey(s as string) {
    def parts as list of string init strings.split($s, KEY_SEPARATOR);
    if (len($parts) != 2) {
        return at(0, 0);
    }
    return at(toIntOrZero($parts[0]), toIntOrZero($parts[1]));
}

# toIntOrZero parses a decimal integer, answering 0 for anything it cannot read.
# Every integer on the wire goes through here, so a peer sending "abc" where a
# coordinate belongs is a harmless 0 rather than a thrown error in a game loop.
func toIntOrZero(s as string) {
    try {
        return convert.toInt($s);
    } catch (e) {
        return 0;
    }
}

/**
 * Parse a decimal integer, falling back to `fallback` when `s` is not one.
 * The tolerant reader every layer that touches untrusted text shares.
 * @param s {string} the text to parse
 * @param fallback {int} the value to use when `s` is not an integer
 * @return {int} the parsed integer, or `fallback`
 */
export func toIntOr(s as string, fallback as int) {
    try {
        return convert.toInt($s);
    } catch (e) {
        return $fallback;
    }
}
