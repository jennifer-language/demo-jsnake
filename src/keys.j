# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * What a keypress means to jsnake: the one place a `screen.Key` becomes an
 * intention. Both the host and the guest read the keyboard, and a game where
 * `w` steered on one screen and not the other would be a bug nobody could see
 * in either file alone - so the mapping lives here once.
 *
 * Every function is pure and total over `screen.Key`, which makes the keyboard
 * testable without a terminal: `screen.decodeKey` turns raw bytes into a `Key`,
 * and these turn a `Key` into an intention, so a test can press a real arrow key
 * by its escape sequence and check what the game would have done.
 * @module keys
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./keys.j" as keys;
 * def k as screen.Key init screen.pollKey($input);
 * if (keys.isBack($k) or keys.isAbort($k)) {
 *     return 0;
 * }
 */

import "screen.j" as screen;
import "./geom.j" as geom;

/**
 * The sentinel `screen.pollKey` returns when no key is waiting.
 */
export def const NONE as string init "none";

/**
 * The direction a keypress asks for - an arrow key, or WASD in either case - or
 * an empty string for any other key. WASD is offered because some terminals and
 * multiplexers swallow arrow keys, and a player should not be stuck.
 * @param k {screen.Key} the key pressed
 * @return {string} a `geom` direction, or ""
 */
export func directionOf(k as screen.Key) {
    match ($k.name) {
        when "up" { return geom.UP; }
        when "down" { return geom.DOWN; }
        when "left" { return geom.LEFT; }
        when "right" { return geom.RIGHT; }
        else { return letterDirection($k); }
    }
}

# letterDirection is the WASD half of the mapping.
func letterDirection(k as screen.Key) {
    if ($k.name != "char") {
        return "";
    }
    match ($k.char) {
        when "w", "W" { return geom.UP; }
        when "s", "S" { return geom.DOWN; }
        when "a", "A" { return geom.LEFT; }
        when "d", "D" { return geom.RIGHT; }
        else { return ""; }
    }
}

/**
 * Whether Escape takes two presses to reach the program, or one.
 *
 * One: `screen.nextKey` waits 50 ms (`term.readByteTimeout`) for the byte after an `ESC` -
 * to tell a bare Escape from the start of an arrow-key sequence - so a lone press arrives
 * as `escape`. A keyboard layer that reads that byte with no timeout cannot deliver a lone
 * press, only a pair decoded as one `escape`; on such a layer this is true.
 *
 * It is what `ESCAPE_LABEL` is built from, and that is what every key legend in the game
 * prints, so the instructions on screen follow the keyboard layer underneath.
 */
export def const ESCAPE_NEEDS_TWO as bool init false;

/**
 * How a key legend names the Escape key - `esc esc` when a single press is swallowed,
 * plain `esc` when it arrives. See `ESCAPE_NEEDS_TWO`.
 */
export def const ESCAPE_LABEL as string init escapeLabelFor(ESCAPE_NEEDS_TWO);

# escapeLabelFor spells the key the way a player has to press it. A legend reading `esc`
# while one press does nothing is worse than no legend: it makes the game look broken rather
# than the key look awkward.
#
# It takes the flag rather than reading it so that both answers can be tested, including
# the one the current setting does not use: an untested switch is not a switch.
func escapeLabelFor(needsTwo as bool) {
    if ($needsTwo) {
        return "esc esc";
    }
    return "esc";
}

/**
 * Whether a keypress means "back out of where I am": Escape.
 *
 * Escape is the only key the game navigates with, and what backing out *means* depends on
 * where you are - a host playing a round returns to its title screen, a host already on
 * the title screen has nothing behind it and leaves, a client has no screen of its own to
 * go back to and so leaves too. Each caller decides that; this only reports the press.
 *
 * One key that always means "back" is why there is no table of exit keys to remember.
 *
 * Two Escapes inside `nextKey`'s 50 ms window decode as one `escape`, so a nervous double
 * press is one step back, not two.
 * @param k {screen.Key} the key pressed
 * @return {bool} true when the player wants out of this screen
 */
export func isBack(k as screen.Key) {
    return $k.name == "escape";
}

/**
 * Whether a keypress means "stop now, wherever I am": Ctrl-C, or the end of input.
 *
 * Not a game key and not in any legend except the one on the field - it is the terminal's
 * own convention, and a program that ignored it would be the only one on the system that
 * did. Raw mode delivers Ctrl-C as a byte rather than as a signal, so it has to be handled
 * rather than trapped.
 *
 * End of input belongs here for a different reason: there is no keyboard left to ask, so
 * carrying on would mean spinning until killed.
 *
 * It is deliberately reachable after a swallowed Escape - `ESC` then Ctrl-C decodes as
 * `ctrl-c` - so a player who pressed Escape once and saw nothing happen is never stuck.
 * @param k {screen.Key} the key pressed
 * @return {bool} true when the program should stop
 */
export func isAbort(k as screen.Key) {
    return $k.name == "ctrl-c" or $k.name == "eof";
}

/**
 * Whether a keypress asks for a list to be refreshed: `r` or F5.
 * @param k {screen.Key} the key pressed
 * @return {bool} true when the player wants another look
 */
export func isRefresh(k as screen.Key) {
    return $k.name == "f5" or isChar($k, "r") or isChar($k, "R");
}

/**
 * Whether a keypress is a confirmation: Enter or the space bar.
 * @param k {screen.Key} the key pressed
 * @return {bool} true when the player said yes
 */
export func isConfirm(k as screen.Key) {
    return $k.name == "enter" or isChar($k, " ");
}

/**
 * Whether there was no key at all - the `pollKey` sentinel, or a key that decoded
 * to nothing recognizable.
 * @param k {screen.Key} the key polled
 * @return {bool} true when nothing was pressed
 */
export func isNothing(k as screen.Key) {
    return $k.name == NONE or $k.name == "unknown";
}

/**
 * The digit a keypress names, `1` to `9`, or `0` for any other key. Used to pick
 * a host out of the discovery menu, which is why `0` is "no choice" rather than a
 * digit in its own right.
 * @param k {screen.Key} the key pressed
 * @return {int} the digit pressed, or 0
 */
export func digitValue(k as screen.Key) {
    if ($k.name != "char") {
        return 0;
    }
    for (def d as int init 1; $d <= 9; $d = $d + 1) {
        if ($k.char == DIGITS[$d]) {
            return $d;
        }
    }
    return 0;
}

# The digit characters, indexed by their own value so digitValue reads directly.
def const DIGITS as list of string init ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

# isChar tests for one printable character key.
func isChar(k as screen.Key, ch as string) {
    return $k.name == "char" and $k.char == $ch;
}
