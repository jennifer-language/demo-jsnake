# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Drawing a game onto a terminal, over the `screen` module's cell buffer.
 *
 * Nothing here writes to the terminal. Every function takes a state and returns
 * a `screen.Buffer`, which the caller paints with `screen.diff` against the
 * previous frame. Two things follow from that, and both are the reason it is
 * built this way: the renderer is **pure**, so a test can assert what is in a
 * given cell without a terminal anywhere, and the paint loop is flicker-free
 * because only the cells that actually changed are rewritten.
 *
 * The field is drawn inside a single-line box one row below the header, so field
 * cell `(0, 0)` lands at buffer cell `(FIELD_X, FIELD_Y)`. Each player gets a
 * glyph and a colour from a fixed palette indexed by player id, so the same
 * player looks the same on every screen in the room without the colour having to
 * travel over the wire.
 *
 * Drawing past the edge of the buffer is clipped by `screen` rather than being an
 * error, so a terminal that is merely *snug* still renders - and one that is too
 * small to be playable gets `message` instead of a corrupted field.
 * @module view
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./view.j" as view;
 * import "screen.j" as screen;
 * def frame as screen.Buffer init view.render($game, 1, "connected", 24, 80);
 * io.printf("%s", screen.render($frame));
 */

use io;
use convert;

import "screen.j" as screen;
import "./geom.j" as geom;
import "./rules.j" as rules;
import "./keys.j" as keys;

/**
 * The glyph a snake's body is drawn with, indexed by player id. Distinct shapes
 * as well as distinct colours, so the game is still readable on a terminal with
 * no colour at all and to a player who cannot tell red from green.
 */
export def const BODY_GLYPHS as list of string init ["O", "X", "#", "%", "+", "=", "8", "A"];

/**
 * The colour a snake is drawn in, indexed by player id. Every name here is one
 * the `screen` module knows.
 */
export def const BODY_COLORS as list of string init [
    "green",
    "cyan",
    "yellow",
    "magenta",
    "blue",
    "red",
    "white",
    "gray"
];

/**
 * The glyph every snake's head is drawn with, in that snake's own colour. A head
 * is the one cell a player must find instantly, so it is the same shape for
 * everyone and different from every body glyph.
 */
export def const HEAD_GLYPH as string init "@";

/**
 * The glyph plain food is drawn with.
 */
export def const FOOD_GLYPH as string init "*";

/**
 * The colour plain food is drawn in.
 */
export def const FOOD_COLOR as string init "red";

/**
 * The glyph a food kind is drawn with. Each special gets a letter that reads as its
 * name - `B` for a candy, `T` for a vegetable, `G` for a ghost - and a toadstool gets
 * `!`, because the one thing a player must not mistake it for is something to eat.
 * None of them collides with a body glyph or with the head, which is what keeps the
 * field readable with no colour at all.
 * @param kind {string} the food kind, one of `rules.FOOD_KINDS`
 * @return {string} a one-column glyph
 */
export func foodGlyph(kind as string) {
    match ($kind) {
        when rules.TOADSTOOL { return "!"; }
        when rules.GHOST { return "G"; }
        when rules.CANDY { return "C"; }
        when rules.VEGETABLES { return "V"; }
        else { return FOOD_GLYPH; }
    }
}

/**
 * The colour a food kind is drawn in.
 * @param kind {string} the food kind
 * @return {string} a colour name the `screen` module knows
 */
export func foodColor(kind as string) {
    match ($kind) {
        when rules.TOADSTOOL { return "green"; }
        when rules.GHOST { return "white"; }
        when rules.CANDY { return "yellow"; }
        when rules.VEGETABLES { return "magenta"; }
        else { return FOOD_COLOR; }
    }
}

/**
 * The column the field's cell `(0, 0)` is drawn at - just inside the box border.
 */
export def const FIELD_X as int init 1;

/**
 * The row the field's cell `(0, 0)` is drawn at: below the header row and just
 * inside the box border.
 */
export def const FIELD_Y as int init 2;

/**
 * The narrowest terminal that can hold the header and the footer legibly,
 * whatever the field's own width asks for.
 */
export def const MIN_COLS as int init 34;

/**
 * The glyph a wrapped field's top and bottom edges are drawn with - dashed, because you
 * can walk through them.
 */
export def const WRAP_HORIZONTAL as string init "┄";

/**
 * The glyph a wrapped field's left and right edges are drawn with.
 */
export def const WRAP_VERTICAL as string init "┊";

/**
 * The glyph at the corners of a wrapped field, where no two edges actually meet.
 */
export def const WRAP_CORNER as string init "·";

/**
 * The rows assumed when the terminal reports no size at all.
 */
export def const FALLBACK_ROWS as int init 24;

/**
 * The columns assumed when the terminal reports no size at all.
 */
export def const FALLBACK_COLS as int init 80;

/**
 * The mark the lives column is drawn with. A heart is the one symbol every player
 * already reads as "lives", and it is a single column wide - which the glyph palette
 * and the box borders already rely on elsewhere.
 */
export def const LIVES_MARK as string init "♥";

/**
 * What the scoreboard says about a player who has spent every life.
 */
export def const SPECTATING as string init "spectating";

/**
 * The marker on the scoreboard row belonging to the player at this terminal.
 */
export def const YOU_MARKER as string init ">";

/**
 * The largest field a terminal can show. The counterpart to `Fit`, which answers
 * the same question from the other end.
 * @field width {int} the widest field in cells
 * @field height {int} the tallest field in cells
 */
export def struct Room {
    width as int,
    height as int
};

/**
 * How the terminal must be sized for a given game, and whether it is. Pure
 * arithmetic, kept separate from the drawing so a caller can ask "will this
 * fit?" before it has a buffer, and so the answer is testable on its own.
 * @field rows {int} the rows the frame needs
 * @field cols {int} the columns the frame needs
 * @field fits {bool} whether the terminal offered is at least that big
 */
export def struct Fit {
    rows as int,
    cols as int,
    fits as bool
};

/**
 * The largest field a `rows` by `cols` terminal can show, given room for `players`
 * scoreboard rows and the food key when `specials` is on.
 *
 * This is the inverse of `fit` wherever the terminal can show the game at all: for a
 * terminal of at least `MIN_COLS` columns and enough rows that the height is not
 * clamped, a field of the size this returns is one `fit` reports as fitting. That is
 * the invariant which lets a host negotiate a size every player's terminal can
 * actually draw.
 *
 * Outside that range there is no field that would fit, and the result is clamped
 * into the limits `rules` allows: a terminal far too small yields the smallest legal
 * field rather than a negative one, and `fit` then tells that player their terminal
 * is too small, which is the honest answer. Ask `canShow` first if you want to know
 * which it is.
 *
 * `players` is the number of scoreboard rows to reserve, which a host should size
 * from its **capacity** rather than from who happens to be present: reserving room
 * for a full table means the field never has to change when somebody joins.
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @param players {int} how many scoreboard rows to leave room for
 * @param specials {bool} whether the food key line will be shown
 * @return {Room} the largest field that fits
 */
export func maxField(rows as int, cols as int, players as int, specials as bool) {
    def spare as int init CHROME_ROWS + atLeast($players, 1) + keyRows($specials);
    return Room{
        width: clamp(usable($cols, FALLBACK_COLS) - 2, rules.MIN_WIDTH, rules.MAX_WIDTH),
        height: clamp(usable($rows, FALLBACK_ROWS) - $spare, rules.MIN_HEIGHT, rules.MAX_HEIGHT)
    };
}

/**
 * Whether a terminal can show this game at all: wide enough for the chrome, and tall
 * enough for the field its own `maxField` would pick. A host uses this to flag a
 * player whose terminal cannot work before the game starts, rather than leaving them
 * to discover it from a "terminal too small" screen once everyone else is playing.
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @param players {int} how many scoreboard rows to leave room for
 * @param specials {bool} whether the food key line will be shown
 * @return {bool} true when a playable field fits
 */
export func canShow(rows as int, cols as int, players as int, specials as bool) {
    def room as Room init maxField($rows, $cols, $players, $specials);
    def g as rules.Game init rules.newGame($room.width, $room.height, 1);
    if (not $specials) {
        $g = rules.withoutSpecials($g);
    }
    def crowd as int init atLeast($players, 1);
    for (def i as int init 1; $i <= $crowd; $i = $i + 1) {
        $g = rules.addSnake($g, $i, "p");
    }
    return fit($g, usable($rows, FALLBACK_ROWS), usable($cols, FALLBACK_COLS)).fits;
}

/**
 * The room held inside `maxArea` cells, or unchanged when `maxArea` is `0` - which is
 * what a transport with no size limit reports.
 *
 * Height gives way before width: a player who has just been told the field is narrower
 * than their display minds that more than a few lost rows, and a wide display is the
 * case this exists to serve. Only when the height is already at its floor does the
 * width come down.
 * @param room {Room} the room the terminals agreed on
 * @param maxArea {int} the most cells the transport can describe, or 0 for no limit
 * @return {Room} a room of at most `maxArea` cells
 */
export func withinArea(room as Room, maxArea as int) {
    if ($maxArea <= 0 or $room.width * $room.height <= $maxArea) {
        return $room;
    }
    def height as int init clamp($maxArea // $room.width, rules.MIN_HEIGHT, $room.height);
    if ($room.width * $height <= $maxArea) {
        return Room{width: $room.width, height: $height};
    }
    def width as int init clamp($maxArea // rules.MIN_HEIGHT, rules.MIN_WIDTH, $room.width);
    return Room{width: $width, height: rules.MIN_HEIGHT};
}

/**
 * The smaller of two rooms in each direction - what a table of players can all see.
 * @param a {Room} one player's largest field
 * @param b {Room} another player's largest field
 * @return {Room} the largest field both can show
 */
export func smaller(a as Room, b as Room) {
    return Room{width: minOf($a.width, $b.width), height: minOf($a.height, $b.height)};
}

# The rows a frame spends on everything that is not the field or the scoreboard: the
# header, the two border rows, and the key line.
def const CHROME_ROWS as int init 4;

# clamp / atLeast / minOf are the small integer helpers the sizing arithmetic needs.
func clamp(v as int, lo as int, hi as int) {
    if ($v < $lo) {
        return $lo;
    }
    if ($v > $hi) {
        return $hi;
    }
    return $v;
}

func atLeast(v as int, lo as int) {
    if ($v < $lo) {
        return $lo;
    }
    return $v;
}

func minOf(a as int, b as int) {
    if ($a < $b) {
        return $a;
    }
    return $b;
}

/**
 * The body glyph for a player id. The palette wraps, so a ninth player is legal
 * and merely shares a glyph rather than crashing the renderer.
 * @param id {int} the player id
 * @return {string} a one-column glyph
 */
export func glyphFor(id as int) {
    return BODY_GLYPHS[paletteIndex($id, len(BODY_GLYPHS))];
}

/**
 * The colour for a player id, from the same wrapping palette as `glyphFor`.
 * @param id {int} the player id
 * @return {string} a colour name the `screen` module knows
 */
export func colorFor(id as int) {
    return BODY_COLORS[paletteIndex($id, len(BODY_COLORS))];
}

# paletteIndex maps any id, including a negative one from a corrupt message, onto
# a real slot: ids start at 1, so 1 maps to the first entry. No guard is needed for
# a negative id, because Jennifer's `%` is floored - `(-8) % 8` is 0, not -0 or -8 -
# so the result is always inside the palette for any positive size.
func paletteIndex(id as int, size as int) {
    return ($id - 1) % $size;
}

/**
 * How big a terminal this game needs, and whether the one offered will do.
 * @param g {rules.Game} the game to be drawn
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @return {Fit} the required size and whether it is met
 */
export func fit(g as rules.Game, rows as int, cols as int) {
    def needRows as int init $g.height + len($g.snakes) + CHROME_ROWS + legendRows($g);
    def needCols as int init $g.width + 2;
    if ($needCols < MIN_COLS) {
        $needCols = MIN_COLS;
    }
    return Fit{rows: $needRows, cols: $needCols, fits: $rows >= $needRows and $cols >= $needCols};
}

# legendRows is the extra row the food key needs, or none in a plain game.
func legendRows(g as rules.Game) {
    return keyRows($g.specials);
}

# keyRows is legendRows over a bare flag, for callers that have no game yet.
func keyRows(specials as bool) {
    if ($specials) {
        return 1;
    }
    return 0;
}

/**
 * Draw the whole game: the header, the field with its border, every snake, the
 * food, a scoreboard, and the key legend. When the terminal is too small for the
 * field, a `message` explaining exactly that is drawn instead of a mangled
 * field - a player who cannot see the walls cannot play.
 * @param g {rules.Game} the state to draw
 * @param myId {int} the player id at this terminal, or 0 for a spectator
 * @param status {string} a short status note for the header
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @return {screen.Buffer} the frame, ready for `screen.render` or `screen.diff`
 */
export func render(g as rules.Game, myId as int, status as string, rows as int, cols as int) {
    return renderWith($g, $myId, $status, $rows, $cols, HOST_KEYS);
}

/**
 * Draw the game with a chosen key legend - `HOST_KEYS` or `GUEST_KEYS`.
 *
 * The two differ because Escape does: a host goes back to its title screen, a client leaves.
 * Naming the wrong keys is worse than naming none, so the caller says which it is rather
 * than the renderer guessing from the state, which does not know.
 * @param g {rules.Game} the state to draw
 * @param myId {int} the player id at this terminal, or 0 for a spectator
 * @param status {string} a short status note for the header
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @param legend {string} the key line to draw, `HOST_KEYS` or `GUEST_KEYS`
 * @return {screen.Buffer} the frame
 */
export func renderWith(
    g as rules.Game,
    myId as int,
    status as string,
    rows as int,
    cols as int,
    legend as string) {
    return draw(
        $g,
        $myId,
        $status,
        usable($rows, FALLBACK_ROWS),
        usable($cols, FALLBACK_COLS),
        $legend);
}

# usable substitutes a conventional size when the terminal reports none.
# `term.size` answers 0 under `script`, on a pty opened without a window size, and
# in some CI runners. Zero means "unknown", not "one cell": a frame built to it
# would be a single character, which reads as a broken game rather than a missing
# ioctl. A real terminal that is merely small still gets the honest too-small
# message, because the fallback only ever replaces a size below one.
func usable(reported as int, fallback as int) {
    if ($reported < 1) {
        return $fallback;
    }
    return $reported;
}

# draw is render's body, on a size already known to be plausible.
func draw(
    g as rules.Game,
    myId as int,
    status as string,
    rows as int,
    cols as int,
    legend as string) {
    def sizing as Fit init fit($g, $rows, $cols);
    if (not $sizing.fits) {
        return message(
            "terminal too small",
            [
                io.sprintf("this game needs %d rows x %d columns", $sizing.rows, $sizing.cols),
                io.sprintf("this terminal is %d x %d", $rows, $cols),
                "resize the window, or host a smaller field",
                "with --width and --height"
            ],
            $rows,
            $cols);
    }
    def buf as screen.Buffer init screen.newScreen($rows, $cols);
    $buf = screen.text($buf, 0, 0, header($g, $status));
    $buf = drawBorder($buf, $g);
    $buf = drawFood($buf, $g);
    $buf = drawSnakes($buf, $g);
    $buf = drawScores($buf, $g, $myId);
    $buf = screen.text($buf, 0, $g.height + len($g.snakes) + 3, $legend);
    if ($g.specials) {
        return screen.text($buf, 0, $g.height + len($g.snakes) + 4, foodLegend());
    }
    return $buf;
}

/**
 * The one-line key to the food glyphs, shown only in a game that has specials in
 * it - there is no point explaining a toadstool to a table that will never see one.
 * @return {string} the legend line, no terminator
 */
export func foodLegend() {
    return io.sprintf(
        "%s food  %s candy +3  %s veg -3  %s toadstool!  %s ghost",
        FOOD_GLYPH,
        foodGlyph(rules.CANDY),
        foodGlyph(rules.VEGETABLES),
        foodGlyph(rules.TOADSTOOL),
        foodGlyph(rules.GHOST));
}

/**
 * The key legend a **host** sees while playing. Escape backs out to the title screen, where
 * Escape again leaves; Ctrl-C stops the program from anywhere and is named here because the
 * field is the one screen a player might be on for a long time.
 */
export def const HOST_KEYS as string init "arrows / wasd steer    " + keys.ESCAPE_LABEL +
    "  menu    ^C  quit";

/**
 * The key legend a **client** sees. It has no screen of its own behind the game, so backing
 * out of it leaves.
 */
export def const GUEST_KEYS as string init "arrows / wasd steer    " + keys.ESCAPE_LABEL +
    "  leave";

# header is the top line: the game's name, the tick, and the caller's status.
func header(g as rules.Game, status as string) {
    return io.sprintf(
        "jsnake  tick %d|pad=6|align=left %d player(s)  %s",
        $g.tick,
        len($g.snakes),
        $status);
}

# drawBorder frames the field. A wrapped field gets a dashed border instead of a solid
# one: the rule is invisible until you walk into it, so the frame has to say which game
# this is. `screen.box` draws the solid form; the dashed one is drawn here from the same
# corners so both sit in exactly the same cells.
func drawBorder(buf as screen.Buffer, g as rules.Game) {
    if (not $g.wrap) {
        return screen.box($buf, 0, 1, $g.width + 2, $g.height + 2);
    }
    def out as screen.Buffer init $buf;
    def right as int init $g.width + 1;
    def bottom as int init $g.height + 2;
    $out = screen.hline($out, 1, 1, $g.width, WRAP_HORIZONTAL);
    $out = screen.hline($out, 1, $bottom, $g.width, WRAP_HORIZONTAL);
    $out = screen.vline($out, 0, 2, $g.height, WRAP_VERTICAL);
    $out = screen.vline($out, $right, 2, $g.height, WRAP_VERTICAL);
    $out = screen.set($out, 0, 1, WRAP_CORNER);
    $out = screen.set($out, $right, 1, WRAP_CORNER);
    $out = screen.set($out, 0, $bottom, WRAP_CORNER);
    return screen.set($out, $right, $bottom, WRAP_CORNER);
}

# drawFood paints every piece of food inside the field box.
func drawFood(buf as screen.Buffer, g as rules.Game) {
    def out as screen.Buffer init $buf;
    for (def f in $g.food) {
        $out = plot($out, $f.cell, foodGlyph($f.kind), foodColor($f.kind));
    }
    return $out;
}

# drawSnakes paints every living snake: bodies first, then heads, so a head that
# shares a cell with another snake's tail is still the glyph the player sees.
func drawSnakes(buf as screen.Buffer, g as rules.Game) {
    def out as screen.Buffer init $buf;
    for (def s in $g.snakes) {
        if ($s.alive) {
            def glyph as string init glyphFor($s.id);
            def color as string init colorFor($s.id);
            for (def i as int init 1; $i < len($s.cells); $i = $i + 1) {
                $out = plot($out, $s.cells[$i], $glyph, $color);
            }
        }
    }
    for (def s in $g.snakes) {
        if ($s.alive and len($s.cells) > 0) {
            $out = plot($out, $s.cells[0], HEAD_GLYPH, colorFor($s.id));
        }
    }
    return $out;
}

# plot paints one field cell, ignoring anything off the field: a cell outside the
# box would otherwise be drawn over the border or the scoreboard.
func plot(buf as screen.Buffer, cell as geom.Point, glyph as string, color as string) {
    if ($cell.x < 0 or $cell.y < 0) {
        return $buf;
    }
    return screen.textColor($buf, FIELD_X + $cell.x, FIELD_Y + $cell.y, $glyph, $color);
}

# drawScores writes one scoreboard row per player, below the field box.
func drawScores(buf as screen.Buffer, g as rules.Game, myId as int) {
    def out as screen.Buffer init $buf;
    def top as int init $g.height + 3;
    def leader as int init rules.leaderId($g);
    for (def i as int init 0; $i < len($g.snakes); $i = $i + 1) {
        def s as rules.Snake init $g.snakes[$i];
        $out = screen.textColor(
            $out,
            0,
            $top + $i,
            scoreRow($s, $s.id == $myId, $s.id == $leader, $g.lives),
            colorFor($s.id));
    }
    return $out;
}

/**
 * One scoreboard row for one snake in a game without lives - the endless game, where
 * there is no lives column to draw. `scoreRow` is the general form.
 *
 * Pure, so the exact text a player reads is pinned down by a test rather than by
 * looking at it.
 * @param s {rules.Snake} the snake to describe
 * @param mine {bool} whether this is the player at this terminal
 * @param leading {bool} whether this snake has the highest score
 * @return {string} the row text, no terminator
 */
export func scoreLine(s as rules.Snake, mine as bool, leading as bool) {
    return scoreRow($s, $mine, $leading, rules.UNLIMITED_LIVES);
}

/**
 * One scoreboard row, in a game where lives are counted. `lives` is the game's setting,
 * which is what says whether the column means anything at all: in an endless game there
 * is nothing to count and the column is left out.
 * @param s {rules.Snake} the snake to describe
 * @param mine {bool} whether this is the player at this terminal
 * @param leading {bool} whether this snake has the highest score
 * @param lives {int} the game's lives setting, or `rules.UNLIMITED_LIVES`
 * @return {string} the row text, no terminator
 */
export func scoreRow(s as rules.Snake, mine as bool, leading as bool, lives as int) {
    def marker as string init " ";
    if ($mine) {
        $marker = YOU_MARKER;
    }
    def crown as string init " ";
    if ($leading) {
        $crown = "*";
    }
    return io.sprintf(
        "%s%s%s %s|pad=13 %d|pad=5  len %d|pad=3  %s|pad=3 %s",
        $marker,
        $crown,
        glyphFor($s.id),
        $s.name,
        $s.score,
        bodyLength($s),
        livesColumn($s, $lives),
        state($s, $lives));
}

# livesColumn shows what a player has left to spend, or nothing at all when the game is
# endless - a column of dashes would only invite the question of what it meant.
func livesColumn(s as rules.Snake, lives as int) {
    if ($lives == rules.UNLIMITED_LIVES) {
        return "";
    }
    return io.sprintf("%s%d", LIVES_MARK, $s.lives);
}

# bodyLength is what a player thinks of as their length: the cells on the field
# plus the growth still owed, so eating shows up at once rather than a tick later.
func bodyLength(s as rules.Snake) {
    return len($s.cells) + $s.grow;
}

# state is the short word for what a snake is doing. A ghosting snake says so and
# for how long, because everyone else needs to know the snake coming at them cannot
# be blocked; a player out of lives is a spectator and says that instead of "dead",
# which would suggest they were coming back.
func state(s as rules.Snake, lives as int) {
    if (not $s.alive and $lives != rules.UNLIMITED_LIVES and $s.lives <= 0) {
        return SPECTATING;
    }
    if ($s.alive and $s.ghost > 0) {
        return io.sprintf("ghost %d", $s.ghost);
    }
    if ($s.alive) {
        return "alive";
    }
    if ($s.respawn > 0) {
        return io.sprintf("back in %d", $s.respawn);
    }
    return "dead";
}

/**
 * A centred, boxed message - used for the host menu, for "searching for games",
 * for a connection that failed, and for a terminal too small to play in.
 *
 * The box is sized to the longest line it has to hold and centred in the
 * terminal; a line longer than the terminal is clipped by `screen` rather than
 * wrapped, because a wrapped line would push the box's own border off-centre.
 * @param title {string} the message's heading, drawn on the top border line
 * @param lines {list of string} the body lines, drawn in order
 * @param rows {int} the terminal's rows
 * @param cols {int} the terminal's columns
 * @return {screen.Buffer} the frame
 */
export func message(title as string, lines as list of string, rows as int, cols as int) {
    def high as int init usable($rows, FALLBACK_ROWS);
    def wide as int init usable($cols, FALLBACK_COLS);
    def buf as screen.Buffer init screen.newScreen($high, $wide);
    def inner as int init widest($lines);
    if (len($title) > $inner) {
        $inner = len($title);
    }
    def boxW as int init $inner + 4;
    def boxH as int init len($lines) + 4;
    def x as int init centre($wide, $boxW);
    def y as int init centre($high, $boxH);
    $buf = screen.box($buf, $x, $y, $boxW, $boxH);
    $buf = screen.text($buf, $x + 2, $y, " " + $title + " ");
    for (def i as int init 0; $i < len($lines); $i = $i + 1) {
        $buf = screen.text($buf, $x + 2, $y + 2 + $i, $lines[$i]);
    }
    return $buf;
}

# centre is the offset that puts a box of `size` in the middle of `available`,
# never negative - a box wider than the terminal starts at 0 and is clipped.
func centre(available as int, size as int) {
    def offset as int init ($available - $size) // 2;
    if ($offset < 0) {
        return 0;
    }
    return $offset;
}

# widest is the length of the longest line, or 0 for no lines.
func widest(lines as list of string) {
    def n as int init 0;
    for (def line in $lines) {
        if (len($line) > $n) {
            $n = len($line);
        }
    }
    return $n;
}

/**
 * The title screen's logo: a snake slithering in over the game's name.
 *
 * Every glyph is single-width on purpose. The head is `@` - the game's own head glyph,
 * a deliberate callback - rather than a filled circle, because `●` is East-Asian
 * *ambiguous* width and renders two columns wide in some terminals, which would shear
 * the whole drawing. Twenty runes at its widest, comfortably inside `MIN_COLS`, so the
 * logo never widens the box it sits in.
 *
 * Two details are easy to break and so are pinned by a test:
 *
 * The `J`'s stem sits above the **right** end of its hook (`╝`), so the descender curves
 * left the way a J does. Above the left end instead, the hook runs the wrong way and the
 * letter reads as a `U`.
 *
 * The snake's two rows have to be indented **together**. Shift one and not the other and
 * every corner ends up pointing at a blank - the line still looks like a line at a glance,
 * but it is in pieces.
 */
export def const LOGO as list of string init [
    "      ╭──╮  ╭──╮",
    "   @──╯  ╰──╯  ╰──",
    "    ╦ ╔═╗╔╗╔╔═╗╦╔═╔═╗",
    "    ║ ╚═╗║║║╠═╣╠╩╗║╣ ",
    "   ╚╝ ╚═╝╝╚╝╩ ╩╩ ╩╚═╝"
];

/**
 * The marker on the setup row the cursor is on.
 */
export def const CURSOR_MARKER as string init ">";

/**
 * One row of the host's title screen: a label, its value, and whether the cursor is
 * on it. The column width lives here with the rest of the layout, so a caller
 * composing a setup screen does not have to line anything up itself.
 * @param label {string} the option's name
 * @param value {string} the option's value, already spelled for display
 * @param selected {bool} whether the cursor is on this row
 * @return {string} the row text, no terminator
 */
export func menuRow(label as string, value as string, selected as bool) {
    def marker as string init " ";
    if ($selected) {
        $marker = CURSOR_MARKER;
    }
    return io.sprintf("%s %s|pad=18 %s", $marker, $label, $value);
}

/**
 * The menu of discovered hosts, as body lines for `message`. Kept here so the
 * host list and the game field are drawn by one module, and so the numbering a
 * player types is decided in exactly one place.
 * @param entries {list of string} one description per host, as `beacon.describe` makes them
 * @return {list of string} the numbered body lines, with a prompt
 */
export func menuLines(entries as list of string) {
    def out as list of string init [];
    if (len($entries) == 0) {
        $out[] = "no games found on this network";
        $out[] = "";
        $out[] = "r  search again        " + keys.ESCAPE_LABEL + "  quit";
        return $out;
    }
    for (def i as int init 0; $i < len($entries); $i = $i + 1) {
        $out[] = io.sprintf("%d|pad=2  %s", $i + 1, $entries[$i]);
    }
    $out[] = "";
    $out[] = "1-" + convert.toString(len($entries)) + "  join    r  search again    " +
        keys.ESCAPE_LABEL + "  quit";
    return $out;
}
