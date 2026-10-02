# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The snake game itself: authoritative state and the rules that advance it.
 *
 * Every function here is **pure** - it takes a `Game` and returns a new one,
 * touching no socket, terminal, or clock. That is the point of the module: the
 * host owns one `Game` and calls `advance` on a timer, so the whole of the
 * game's behaviour is reachable from a test with no network and no terminal,
 * and two hosts fed the same inputs agree exactly.
 *
 * Randomness is part of the state, not the environment. `seed` is advanced by a
 * linear congruential generator on every draw, so food placement and respawn
 * points are reproducible from the seed alone - a replay is just the same seed
 * and the same inputs. (`math.rand` would have made `advance` impure and the
 * tests flaky, which is why it is not used here.)
 *
 * **The walls are optional.** By default a head that leaves the field dies. With `wrap`
 * set the border is not a wall at all: a step off one edge arrives at the opposite one,
 * the way it does in Pac-Man, and the only things that can kill you are each other.
 *
 * **The rules.** All snakes move one cell per tick, simultaneously. A head that
 * leaves the field (unless it wraps), enters a cell another body still occupies, or
 * meets another head dies; a snake that eats food scores and grows. A dead snake scatters
 * half its body as food and returns after `RESPAWN_DELAY` ticks, so a player
 * who loses is out for a moment rather than out of the game.
 *
 * **Food comes in kinds.** Plain food stays until eaten. The rest are *specials*:
 * each appears at its own rate, keeps its own countdown, and does its own thing
 * when eaten - a candy lengthens, a vegetable shortens, a toadstool kills outright,
 * a ghost lets you slip through other snakes for a while. One `Recipe` per kind
 * holds all of that in one place (see `recipeFor`), so adding a kind is a row in
 * a table rather than a branch in the tick.
 *
 * Countdowns are measured in **ticks, not seconds**, deliberately: an item that
 * lives a fixed number of *moves* is worth the same to a player whatever tick rate
 * the host runs at, whereas a wall-clock lifetime would be generous on a slow host
 * and stingy on a fast one. `TICKS_PER_SECOND` is the conversion at the default
 * tick, and the comments give each lifetime in seconds at that rate.
 * @module rules
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./rules.j" as rules;
 * def g as rules.Game init rules.newGame(20, 10, 1);
 * $g = rules.addSnake($g, 1, "ada");
 * $g = rules.setDirection($g, 1, geom.RIGHT);
 * $g = rules.advance($g);
 */

use convert;
use maps;

import "./geom.j" as geom;

/**
 * How long a snake is when it arrives, in cells. A new snake is placed as a
 * single head with the rest pending as growth, so it unfurls as it moves
 * instead of needing a straight corridor to be laid out in.
 */
export def const START_LENGTH as int init 4;

/**
 * How many cells a snake gains from one piece of food.
 */
export def const GROWTH_PER_FOOD as int init 2;

/**
 * Points scored for eating one piece of food.
 */
export def const FOOD_SCORE as int init 10;

/**
 * Ticks a dead snake waits before it is placed back on the field.
 */
export def const RESPAWN_DELAY as int init 10;

/**
 * How many lives a player gets unless the host says otherwise. Three is the arcade
 * convention, and it is enough that one careless moment is not the end of the game.
 */
export def const DEFAULT_LIVES as int init 3;

/**
 * The `lives` setting that means "keep coming back for ever" - the endless game, which
 * is what this was before lives existed and still the right choice for a casual table.
 */
export def const UNLIMITED_LIVES as int init 0;

/**
 * The most lives a host may hand out, so the scoreboard column stays one character.
 */
export def const MAX_LIVES as int init 9;

/**
 * The most food the field will ever hold at once, whatever the scatter from a
 * long snake's death would otherwise add.
 */
export def const MAX_FOOD as int init 24;

/**
 * Ticks to a second at the default tick period - the conversion every lifetime and
 * effect duration below is written in terms of, so the numbers can be read as
 * seconds without the code depending on a clock.
 */
export def const TICKS_PER_SECOND as int init 8;

/**
 * Ordinary food: stays until somebody eats it, lengthens the eater a little.
 */
export def const PLAIN as string init "plain";

/**
 * A toadstool: eating it is sudden death, however long the snake was.
 */
export def const TOADSTOOL as string init "toadstool";

/**
 * A ghost: for a while afterwards the eater slips through other snakes' bodies -
 * though not their heads, and not its own body.
 */
export def const GHOST as string init "ghost";

/**
 * A candy: three more segments at once, and worth more than plain food.
 */
export def const CANDY as string init "candy";

/**
 * A vegetable: three segments *gone*. A snake too short to lose them dies.
 */
export def const VEGETABLES as string init "vegetables";

/**
 * Every food kind, plain first. What a renderer draws from and a validator checks
 * against.
 */
export def const FOOD_KINDS as list of string init [PLAIN, TOADSTOOL, GHOST, CANDY, VEGETABLES];

/**
 * The special kinds - everything except plain food. These are the ones that appear
 * by chance, expire on a countdown, and are capped at one on the field each.
 */
export def const SPECIAL_KINDS as list of string init [TOADSTOOL, GHOST, CANDY, VEGETABLES];

/**
 * The `life` of an item that never expires, which is plain food and nothing else.
 */
export def const PERMANENT as int init 0;

/**
 * How many segments a candy adds.
 */
export def const CANDY_BITE as int init 3;

/**
 * How many segments a vegetable takes away. A snake that cannot spare them dies.
 */
export def const VEG_BITE as int init 3;

/**
 * How many of each special kind may be on the field at once. One: a second
 * toadstool on a small field stops being a hazard and starts being a minefield.
 */
export def const SPECIAL_LIMIT as int init 1;

/**
 * The most players one game will ever hold. The renderer has one glyph and one
 * colour per player, so beyond this two players would look alike - which in a
 * game where you find your own snake by its head is not a cosmetic problem.
 */
export def const MAX_PLAYERS as int init 8;

/**
 * The narrowest field the rules will build; `newGame` clamps up to it.
 */
export def const MIN_WIDTH as int init 10;

/**
 * The shortest field the rules will build; `newGame` clamps up to it.
 */
export def const MIN_HEIGHT as int init 6;

/**
 * The widest field the rules will build - an absolute sanity limit, not a transport
 * one. What a game can actually use is decided by the terminals at the table and, on
 * UDP, by how much of a `STATE` line fits in one datagram; see `link.maxFieldArea`.
 */
export def const MAX_WIDTH as int init 240;

/**
 * The tallest field the rules will build. As with `MAX_WIDTH`, a sanity limit rather
 * than the real constraint on a playable field.
 */
export def const MAX_HEIGHT as int init 100;

/**
 * The default field width, sized for an 80-column terminal with room for the
 * border and the scoreboard.
 */
export def const DEFAULT_WIDTH as int init 44;

/**
 * The default field height, sized for a 24-row terminal.
 */
export def const DEFAULT_HEIGHT as int init 16;

# The LCG parameters (the classic glibc constants). The modulus keeps every seed
# under 2^31, so the multiply below stays far inside int64 and can never
# overflow - which in Jennifer would be a runtime error, not a silent wrap.
def const LCG_MULTIPLIER as int init 1103515245;
def const LCG_INCREMENT as int init 12345;
def const LCG_MODULUS as int init 2147483648;

/**
 * One piece of food on the field. Plain food and every special share this shape:
 * a kind, a cell, and how long it has left.
 * @field kind {string} the food kind, one of `FOOD_KINDS`
 * @field cell {geom.Point} where it is
 * @field life {int} ticks until it vanishes, or `PERMANENT` for food that stays
 */
export def struct Item {
    kind as string,
    cell as geom.Point,
    life as int
};

/**
 * What a food kind is and does - the whole of a kind's behaviour in one value, so
 * the tick has no per-kind branches and a new kind is a row in `recipeFor` rather
 * than an edit in four places.
 * @field kind {string} the kind this describes
 * @field life {int} ticks it survives on the field, or `PERMANENT`
 * @field chance {int} the one-in-N chance per tick of one appearing; 0 never appears by chance
 * @field grow {int} segments gained when eaten; negative takes them away
 * @field score {int} points for eating it
 * @field fatal {bool} whether eating it kills outright
 * @field ghost {int} ticks of slipping through other snakes granted when eaten
 */
export def struct Recipe {
    kind as string,
    life as int,
    chance as int,
    grow as int,
    score as int,
    fatal as bool,
    ghost as int
};

/**
 * The recipe for a food kind. An unknown kind reads as plain food, so an item from
 * a peer naming a kind this version does not have is harmless rather than a crash.
 *
 * The numbers, in seconds at the default tick rate: a toadstool and a vegetable last
 * 15s, a ghost 12s, a candy 10s. A candy turns up about every 11 seconds of play,
 * a vegetable every 14, a toadstool every 17, a ghost every 25 - often enough to
 * matter, rarely enough that finding one is an event.
 * @param kind {string} the food kind
 * @return {Recipe} its behaviour
 */
export func recipeFor(kind as string) {
    match ($kind) {
        when TOADSTOOL {
            return Recipe{
                kind: TOADSTOOL,
                life: 15 * TICKS_PER_SECOND,
                chance: 17 * TICKS_PER_SECOND,
                grow: 0,
                score: 0,
                fatal: true,
                ghost: 0
            };
        }
        when GHOST {
            return Recipe{
                kind: GHOST,
                life: 12 * TICKS_PER_SECOND,
                chance: 25 * TICKS_PER_SECOND,
                grow: 0,
                score: FOOD_SCORE,
                fatal: false,
                ghost: 10 * TICKS_PER_SECOND
            };
        }
        when CANDY {
            return Recipe{
                kind: CANDY,
                life: 10 * TICKS_PER_SECOND,
                chance: 11 * TICKS_PER_SECOND,
                grow: CANDY_BITE,
                score: FOOD_SCORE * 3,
                fatal: false,
                ghost: 0
            };
        }
        when VEGETABLES {
            return Recipe{
                kind: VEGETABLES,
                life: 15 * TICKS_PER_SECOND,
                chance: 14 * TICKS_PER_SECOND,
                grow: 0 - VEG_BITE,
                score: 0,
                fatal: false,
                ghost: 0
            };
        }
        else {
            return Recipe{
                kind: PLAIN,
                life: PERMANENT,
                chance: 0,
                grow: GROWTH_PER_FOOD,
                score: FOOD_SCORE,
                fatal: false,
                ghost: 0
            };
        }
    }
}

/**
 * Whether `kind` is a food kind this version knows.
 * @param kind {string} the candidate kind
 * @return {bool} true for one of `FOOD_KINDS`
 */
export func isFoodKind(kind as string) {
    for (def known in FOOD_KINDS) {
        if ($known == $kind) {
            return true;
        }
    }
    return false;
}

/**
 * Whether `kind` is a special - anything that appears by chance and expires.
 * @param kind {string} the candidate kind
 * @return {bool} true for a special kind
 */
export func isSpecial(kind as string) {
    return isFoodKind($kind) and $kind != PLAIN;
}

/**
 * A piece of plain food at `cell` - the food the field is kept stocked with.
 * @param cell {geom.Point} where to put it
 * @return {Item} the item
 */
export func plainFood(cell as geom.Point) {
    return Item{kind: PLAIN, cell: $cell, life: PERMANENT};
}

/**
 * A piece of food of any kind at `cell`, with the lifetime its recipe gives it.
 * @param kind {string} the food kind
 * @param cell {geom.Point} where to put it
 * @return {Item} the item
 */
export func foodAt(kind as string, cell as geom.Point) {
    def recipe as Recipe init recipeFor($kind);
    return Item{kind: $recipe.kind, cell: $cell, life: $recipe.life};
}

/**
 * The index of the food at `cell`, or `-1` when there is none.
 * @param food {list of Item} the food on the field
 * @param cell {geom.Point} the cell to look at
 * @return {int} the index into `food`, or -1
 */
export func foodIndexAt(food as list of Item, cell as geom.Point) {
    for (def i as int init 0; $i < len($food); $i = $i + 1) {
        if (geom.equals($food[$i].cell, $cell)) {
            return $i;
        }
    }
    return -1;
}

/**
 * How many pieces of `kind` are on the field.
 * @param g {Game} the game to count
 * @param kind {string} the food kind
 * @return {int} how many there are
 */
export func foodCount(g as Game, kind as string) {
    def n as int init 0;
    for (def f in $g.food) {
        if ($f.kind == $kind) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * One snake on the field. `cells` is ordered head first, so `cells[0]` is the
 * head and the last element is the tail tip. A dead snake has no cells at all
 * and a `respawn` countdown instead.
 * @field id {int} the player id that owns this snake, unique within a game
 * @field name {string} the player's display name
 * @field cells {list of geom.Point} the body, head first; empty while dead
 * @field dir {string} the direction the head will move next
 * @field alive {bool} whether the snake is on the field
 * @field score {int} points collected so far, kept across deaths
 * @field deaths {int} how many times this snake has died
 * @field respawn {int} ticks left before a dead snake returns; 0 when alive
 * @field grow {int} cells still to be added before the tail starts following
 * @field ghost {int} ticks left of slipping through other snakes' bodies; 0 normally
 * @field lives {int} lives left; at 0 the snake is a spectator and does not return
 */
export def struct Snake {
    id as int,
    name as string,
    cells as list of geom.Point,
    dir as string,
    alive as bool,
    score as int,
    deaths as int,
    respawn as int,
    grow as int,
    ghost as int,
    lives as int
};

/**
 * A whole game: the field, everyone on it, the food, and the random state.
 * Value-semantic, so a host can keep the previous tick's `Game` around for
 * nothing more than the cost of the copy.
 * @field width {int} the field width in cells
 * @field height {int} the field height in cells
 * @field snakes {list of Snake} every player, in join order
 * @field food {list of Item} the food currently on the field, plain and special
 * @field tick {int} how many times `advance` has run
 * @field seed {int} the generator state, advanced by every random draw
 * @field specials {bool} whether special food appears at all; false is a plain game
 * @field lives {int} lives each player starts with, or `UNLIMITED_LIVES` for an endless game
 * @field wrap {bool} whether the edges join up instead of being walls
 * @field round {int} which game this is, counted by the host from 1
 */
export def struct Game {
    width as int,
    height as int,
    snakes as list of Snake,
    food as list of Item,
    tick as int,
    seed as int,
    specials as bool,
    lives as int,
    wrap as bool,
    round as int
};

/**
 * The result of one random draw: the value, and the generator state to carry
 * forward. Jennifer returns one value, and a generator has to hand back both,
 * so the pair is a struct.
 * @field seed {int} the generator state after the draw
 * @field value {int} the drawn value
 */
export def struct Roll {
    seed as int,
    value as int
};

/**
 * The result of looking for an empty cell: where it is, whether there was one,
 * and the generator state to carry forward.
 * @field seed {int} the generator state after the search
 * @field cell {geom.Point} the empty cell found, or the origin when `found` is false
 * @field found {bool} whether an empty cell existed at all
 */
export def struct Spot {
    seed as int,
    cell as geom.Point,
    found as bool
};

# clamp holds v inside [lo, hi].
func clamp(v as int, lo as int, hi as int) {
    if ($v < $lo) {
        return $lo;
    }
    if ($v > $hi) {
        return $hi;
    }
    return $v;
}

# maxOf is the two-argument integer maximum, kept local so rules.j needs no
# library import at all.
func maxOf(a as int, b as int) {
    if ($a > $b) {
        return $a;
    }
    return $b;
}

/**
 * A fresh game on a `width` by `height` field, seeded for reproducibility.
 * Dimensions outside the module's limits are clamped rather than refused, so a
 * host started with `--width 4` gets the smallest playable field instead of an
 * error at the worst moment.
 * @param width {int} the requested field width in cells
 * @param height {int} the requested field height in cells
 * @param seed {int} the initial generator state; any int, including 0
 * @return {Game} an empty game with no snakes and no food
 */
export func newGame(width as int, height as int, seed as int) {
    return Game{
        width: clamp($width, MIN_WIDTH, MAX_WIDTH),
        height: clamp($height, MIN_HEIGHT, MAX_HEIGHT),
        snakes: [],
        food: [],
        tick: 0,
        seed: normalizeSeed($seed),
        specials: true,
        lives: DEFAULT_LIVES,
        wrap: false,
        round: 0
    };
}

/**
 * The same game labelled as round `n`.
 *
 * The rules never read this - it is carried so that a *client* can tell one game from the
 * next. Without it a client cannot distinguish "the host has started another round" from
 * "a stale lobby message overtook a game state on UDP", and following the wrong one either
 * strands it on a frozen field or throws it out of a live game.
 * @param g {Game} the game
 * @param n {int} the round number, counted by the host from 1
 * @return {Game} the game labelled as that round
 */
export func withRound(g as Game, n as int) {
    def out as Game init $g;
    $out.round = $n;
    return $out;
}

/**
 * The same game with the walls taken away: a step off one edge arrives at the opposite
 * one. Nothing else changes - a snake can still run into a body, its own included.
 * @param g {Game} the game
 * @param on {bool} true for wrapped edges, false for walls
 * @return {Game} the game with that border rule
 */
export func withWrap(g as Game, on as bool) {
    def out as Game init $g;
    $out.wrap = $on;
    return $out;
}

/**
 * The cell a head reaches by stepping from `from` in `dir`, taking the game's border
 * rule into account: wrapped round the field when the edges join up, and otherwise left
 * off the field for `resolveDeaths` to judge.
 * @param g {Game} the game, for its dimensions and border rule
 * @param from {geom.Point} the cell stepped from
 * @param dir {string} the direction stepped in
 * @return {geom.Point} the destination, wrapped when the game wraps
 */
export func destination(g as Game, from as geom.Point, dir as string) {
    def ahead as geom.Point init geom.step($from, $dir);
    if ($g.wrap) {
        return geom.wrap($ahead, $g.width, $g.height);
    }
    return $ahead;
}

/**
 * The same game with `n` lives each, applied to everybody already on the field as well
 * as to whoever joins next. `UNLIMITED_LIVES` makes the game endless; anything else is
 * clamped into `[1, MAX_LIVES]`.
 *
 * Changing this mid-game resets what everyone has left, which is why the host only does
 * it from the title screen, before anybody has lost anything.
 * @param g {Game} the game
 * @param n {int} the lives to hand out, or `UNLIMITED_LIVES`
 * @return {Game} the game with that many lives each
 */
export func withLives(g as Game, n as int) {
    def out as Game init $g;
    $out.lives = livesOr($n);
    for (def i as int init 0; $i < len($out.snakes); $i = $i + 1) {
        $out.snakes[$i].lives = $out.lives;
    }
    return $out;
}

/**
 * The lives setting `n` names: `UNLIMITED_LIVES` as given, anything else clamped into
 * the playable range. A host cannot ask for -2 lives and get a game nobody can join.
 * @param n {int} the requested lives
 * @return {int} a lives setting the rules will honour
 */
export func livesOr(n as int) {
    if ($n == UNLIMITED_LIVES) {
        return UNLIMITED_LIVES;
    }
    return clamp($n, 1, MAX_LIVES);
}

/**
 * Whether this snake will come back when its respawn countdown runs out. False once a
 * player has spent every life - from then on they watch.
 * @param g {Game} the game, which knows whether lives are counted at all
 * @param s {Snake} the snake
 * @return {bool} true when the snake still has a life to spend
 */
export func hasLivesLeft(g as Game, s as Snake) {
    return $g.lives == UNLIMITED_LIVES or $s.lives > 0;
}

/**
 * Whether this player is out of the game and watching: dead, with no lives left. A
 * spectator keeps its seat, its name and its score - it simply has no snake.
 * @param g {Game} the game
 * @param s {Snake} the snake
 * @return {bool} true when the player is a spectator
 */
export func isSpectator(g as Game, s as Snake) {
    return not $s.alive and not hasLivesLeft($g, $s);
}

/**
 * How many players are still in the game - on the field or waiting to return. Does not
 * count spectators.
 * @param g {Game} the game
 * @return {int} the number of players with a life left
 */
export func contenders(g as Game) {
    def n as int init 0;
    for (def s in $g.snakes) {
        if (hasLivesLeft($g, $s)) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * Whether the game is finished: somebody played, and nobody has a life left. An endless
 * game is never over.
 * @param g {Game} the game
 * @return {bool} true when every player is a spectator
 */
export func isOver(g as Game) {
    return len($g.snakes) > 0 and contenders($g) == 0;
}

/**
 * The same game with special food switched off - plain food only, the classic
 * game. A host offers this so a group that wants the original rules can have them.
 * @param g {Game} the game
 * @return {Game} the game with specials disabled
 */
export func withoutSpecials(g as Game) {
    def out as Game init $g;
    $out.specials = false;
    def kept as list of Item init [];
    for (def f in $out.food) {
        if ($f.kind == PLAIN) {
            $kept[] = $f;
        }
    }
    $out.food = $kept;
    return $out;
}

# normalizeSeed maps any int onto the generator's [0, LCG_MODULUS) domain. The
# floored `%` keeps a negative seed non-negative, and a zero seed is nudged off
# zero because the LCG's first few draws from 0 are a poor spread.
func normalizeSeed(seed as int) {
    def s as int init $seed % LCG_MODULUS;
    if ($s == 0) {
        return LCG_INCREMENT;
    }
    return $s;
}

/**
 * Draw an integer in `[0, bound)` and report the generator state to carry
 * forward. A `bound` of 1 or less always draws 0.
 * @param seed {int} the current generator state
 * @param bound {int} one past the largest value that may be drawn
 * @return {Roll} the drawn value and the next generator state
 */
export func roll(seed as int, bound as int) {
    def next as int init ($seed * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MODULUS;
    if ($bound <= 1) {
        return Roll{seed: $next, value: 0};
    }
    return Roll{seed: $next, value: $next % $bound};
}

/**
 * The index of the snake with id `id` in `g.snakes`, or `-1` when no snake has
 * that id.
 * @param g {Game} the game to search
 * @param id {int} the player id
 * @return {int} the index into `g.snakes`, or -1
 */
export func snakeIndex(g as Game, id as int) {
    for (def i as int init 0; $i < len($g.snakes); $i = $i + 1) {
        if ($g.snakes[$i].id == $id) {
            return $i;
        }
    }
    return -1;
}

/**
 * Whether a snake with id `id` is in the game (alive or waiting to respawn).
 * @param g {Game} the game to search
 * @param id {int} the player id
 * @return {bool} true when the id belongs to a snake in this game
 */
export func hasSnake(g as Game, id as int) {
    return snakeIndex($g, $id) >= 0;
}

/**
 * The snake with id `id`.
 * @param g {Game} the game to search
 * @param id {int} the player id
 * @return {Snake} the snake
 * @throws {Error} kind "value" when no snake has that id - guard with `hasSnake`
 */
export func snakeById(g as Game, id as int) {
    def i as int init snakeIndex($g, $id);
    if ($i < 0) {
        throw Error{
            kind: "value",
            message: "rules.snakeById: no snake with id " + convert.toString($id),
            file: "",
            line: 0,
            col: 0
        };
    }
    return $g.snakes[$i];
}

/**
 * The lowest player id not yet used in this game - the id to hand the next
 * player who joins. Ids start at 1, so 0 is free to mean "nobody".
 * @param g {Game} the game to inspect
 * @return {int} an unused player id
 */
export func nextId(g as Game) {
    def candidate as int init 1;
    while (hasSnake($g, $candidate)) {
        $candidate = $candidate + 1;
    }
    return $candidate;
}

/**
 * Add a snake for player `id` named `name` and place it on the field. The snake
 * arrives as a single head with `START_LENGTH - 1` cells of pending growth, so
 * it unfurls as it moves. An id already in the game is returned unchanged, so a
 * duplicate `JOIN` cannot fork a player in two.
 * @param g {Game} the game to add to
 * @param id {int} the new player's id
 * @param name {string} the new player's display name
 * @return {Game} the game with the snake on the field
 */
export func addSnake(g as Game, id as int, name as string) {
    if (hasSnake($g, $id)) {
        return $g;
    }
    def out as Game init $g;
    def snakes as list of Snake init $out.snakes;
    $snakes[] = Snake{
        id: $id,
        name: $name,
        cells: [],
        dir: geom.RIGHT,
        alive: false,
        score: 0,
        deaths: 0,
        respawn: 0,
        grow: 0,
        ghost: 0,
        lives: $out.lives
    };
    $out.snakes = $snakes;
    return place($out, len($snakes) - 1);
}

/**
 * Remove the snake with id `id` from the game - what a host does when a player
 * disconnects. An unknown id leaves the game unchanged.
 * @param g {Game} the game to remove from
 * @param id {int} the player id to drop
 * @return {Game} the game without that snake
 */
export func removeSnake(g as Game, id as int) {
    def idx as int init snakeIndex($g, $id);
    if ($idx < 0) {
        return $g;
    }
    def out as Game init $g;
    def kept as list of Snake init [];
    for (def i as int init 0; $i < len($out.snakes); $i = $i + 1) {
        if ($i != $idx) {
            $kept[] = $out.snakes[$i];
        }
    }
    $out.snakes = $kept;
    return $out;
}

/**
 * Point the snake with id `id` in direction `dir` from the next tick onwards.
 * A direction that is not one of `geom`'s four, or that would reverse the snake
 * into its own neck, is ignored - so a stray key or a hostile peer cannot make
 * a snake kill itself by turning round.
 * @param g {Game} the game to steer in
 * @param id {int} the player id
 * @param dir {string} the requested direction
 * @return {Game} the game with the new heading, or unchanged
 */
export func setDirection(g as Game, id as int, dir as string) {
    def idx as int init snakeIndex($g, $id);
    if ($idx < 0 or not geom.isDirection($dir)) {
        return $g;
    }
    if (geom.isReverse(heading($g.snakes[$idx]), $dir)) {
        return $g;
    }
    def out as Game init $g;
    $out.snakes[$idx].dir = $dir;
    return $out;
}

/**
 * The direction the snake is actually travelling, read off the body rather than
 * the requested heading: the step from the neck to the head. A snake with fewer
 * than two cells has no such evidence, so its `dir` is the answer.
 * @param s {Snake} the snake to read
 * @return {string} the direction of travel
 */
export func heading(s as Snake) {
    if (len($s.cells) < 2) {
        return $s.dir;
    }
    for (def i as int init 0; $i < len(geom.DIRECTIONS); $i = $i + 1) {
        def d as string init geom.DIRECTIONS[$i];
        if (geom.equals(geom.step($s.cells[1], $d), $s.cells[0])) {
            return $d;
        }
    }
    return $s.dir;
}

/**
 * How many snakes are currently on the field.
 * @param g {Game} the game to count
 * @return {int} the number of living snakes
 */
export func aliveCount(g as Game) {
    def n as int init 0;
    for (def s in $g.snakes) {
        if ($s.alive) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * The id of the player with the highest score, ties going to the lower id, or
 * `0` when the game has no players yet.
 * @param g {Game} the game to inspect
 * @return {int} the leading player's id, or 0
 */
export func leaderId(g as Game) {
    def best as int init 0;
    def bestScore as int init -1;
    for (def s in $g.snakes) {
        if ($s.score > $bestScore) {
            $best = $s.id;
            $bestScore = $s.score;
        }
    }
    return $best;
}

/**
 * Whether anything - a snake or a piece of food - occupies cell `p`.
 * @param g {Game} the game to inspect
 * @param p {geom.Point} the cell to test
 * @return {bool} true when the cell is taken
 */
export func isOccupied(g as Game, p as geom.Point) {
    if (foodIndexAt($g.food, $p) >= 0) {
        return true;
    }
    for (def s in $g.snakes) {
        if ($s.alive and geom.contains($s.cells, $p)) {
            return true;
        }
    }
    return false;
}

/**
 * Every cell a living snake's body occupies, as a set keyed by `geom.index`. Food
 * is not in it: food is a destination, not an obstacle.
 *
 * This is the picture a computer player plans against, and it is built once per
 * decision rather than asking `isOccupied` per cell - which is the difference
 * between a flood fill that costs a microsecond and one that costs a millisecond.
 * @param g {Game} the game to read
 * @return {map of int to bool} the occupied cell indices
 */
export func bodyCells(g as Game) {
    def taken as map of int to bool init {};
    for (def s in $g.snakes) {
        if ($s.alive) {
            for (def c in $s.cells) {
                $taken[geom.index($c, $g.width)] = true;
            }
        }
    }
    return $taken;
}

/**
 * The cell each living snake's head will move into if nothing changes its
 * heading, keyed by player id. What a cautious computer player checks before
 * driving into a cell another head is also aiming at.
 * @param g {Game} the game to read
 * @return {map of int to int} player id to the `geom.index` of its next head cell
 */
export func nextHeads(g as Game) {
    def heads as map of int to int init {};
    for (def s in $g.snakes) {
        if ($s.alive and len($s.cells) > 0) {
            def ahead as geom.Point init destination($g, $s.cells[0], heading($s));
            $heads[$s.id] = geom.index($ahead, $g.width);
        }
    }
    return $heads;
}

/**
 * Find an empty cell, starting the search at a random offset and scanning the
 * field in order from there. Scanning rather than re-drawing means the search
 * always terminates, even on a field with one cell left.
 * @param g {Game} the game whose field to search
 * @return {Spot} the cell found, whether there was one, and the next seed
 */
export func freeCell(g as Game) {
    def area as int init $g.width * $g.height;
    def r as Roll init roll($g.seed, $area);
    for (def n as int init 0; $n < $area; $n = $n + 1) {
        def at as int init ($r.value + $n) % $area;
        def cell as geom.Point init geom.at($at % $g.width, $at // $g.width);
        if (not isOccupied($g, $cell)) {
            return Spot{seed: $r.seed, cell: $cell, found: true};
        }
    }
    return Spot{seed: $r.seed, cell: geom.at(0, 0), found: false};
}

# place puts the snake at index `idx` back on the field: one cell at a free
# spot, facing a direction whose next step is still on the field, with the rest
# of its starting length pending as growth. On a field with no room at all the
# snake stays dead and tries again next tick.
func place(g as Game, idx as int) {
    def out as Game init $g;
    def spot as Spot init freeCell($out);
    $out.seed = $spot.seed;
    if (not $spot.found) {
        $out.snakes[$idx].respawn = 1;
        return $out;
    }
    def cells as list of geom.Point init [];
    $cells[] = $spot.cell;
    $out.snakes[$idx].cells = $cells;
    $out.snakes[$idx].dir = openDirection($out, $spot.cell);
    $out.snakes[$idx].alive = true;
    $out.snakes[$idx].respawn = 0;
    $out.snakes[$idx].grow = START_LENGTH - 1;
    $out.snakes[$idx].ghost = 0;
    return $out;
}

# openDirection picks a heading whose next cell is on the field and unoccupied,
# preferring the clockwise order from UP; RIGHT is the fallback when the cell is
# boxed in, which only a nearly-full field can produce.
func openDirection(g as Game, from as geom.Point) {
    for (def d in geom.DIRECTIONS) {
        def ahead as geom.Point init destination($g, $from, $d);
        if (geom.inBounds($ahead, $g.width, $g.height) and not isOccupied($g, $ahead)) {
            return $d;
        }
    }
    return geom.RIGHT;
}

/**
 * Advance the game by one tick: every living snake moves one cell at the same
 * instant, collisions are resolved, food is eaten, the dead count down, and the
 * field is restocked. This is the whole of the game's behaviour.
 * @param g {Game} the current state
 * @return {Game} the state one tick later
 */
export func advance(g as Game) {
    def out as Game init $g;
    $out.tick = $g.tick + 1;
    def heads as list of geom.Point init intendedHeads($out);
    def doomed as list of bool init resolveDeaths($out, $heads);
    def before as Game init $out;
    $out = commitMoves($out, $heads, $doomed);
    $out = tickGhosts($out);
    $out = tickRespawns($out, justDied($before, $out));
    $out = expireFood($out);
    $out = replenishFood($out);
    return spawnSpecials($out);
}

# tickGhosts counts every ghosting snake's remaining ticks down. A snake that died
# this tick has already had its ghosting cleared by `kill`.
func tickGhosts(g as Game) {
    def out as Game init $g;
    for (def i as int init 0; $i < len($out.snakes); $i = $i + 1) {
        if ($out.snakes[$i].ghost > 0) {
            $out.snakes[$i].ghost = $out.snakes[$i].ghost - 1;
        }
    }
    return $out;
}

# expireFood removes every item whose countdown has run out. Plain food has
# `PERMANENT` life and never enters the countdown, so it is never removed here.
func expireFood(g as Game) {
    def out as Game init $g;
    def kept as list of Item init [];
    for (def f in $out.food) {
        def item as Item init $f;
        if ($item.life != PERMANENT) {
            $item.life = $item.life - 1;
        }
        if ($item.life != 0 or $f.life == PERMANENT) {
            $kept[] = $item;
        }
    }
    $out.food = $kept;
    return $out;
}

# spawnSpecials gives each special kind its own one-in-N chance of turning up this
# tick, capped at SPECIAL_LIMIT of that kind on the field. Each kind draws its own
# number, so the rates are independent and adding a kind changes no other kind's.
func spawnSpecials(g as Game) {
    def out as Game init $g;
    if (not $out.specials) {
        return $out;
    }
    for (def kind in SPECIAL_KINDS) {
        def recipe as Recipe init recipeFor($kind);
        def r as Roll init roll($out.seed, $recipe.chance);
        $out.seed = $r.seed;
        if ($recipe.chance > 0 and $r.value == 0 and len($out.food) < MAX_FOOD) {
            if (foodCount($out, $kind) < SPECIAL_LIMIT) {
                $out = dropSpecial($out, $kind);
            }
        }
    }
    return $out;
}

# dropSpecial puts one item of `kind` on a free cell, or leaves the field alone when
# there is none.
func dropSpecial(g as Game, kind as string) {
    def out as Game init $g;
    def spot as Spot init freeCell($out);
    $out.seed = $spot.seed;
    if (not $spot.found) {
        return $out;
    }
    def food as list of Item init $out.food;
    $food[] = foodAt($kind, $spot.cell);
    $out.food = $food;
    return $out;
}

# intendedHeads is where each living snake would like its head next tick: one
# step along its heading, except that a turn into its own neck is refused and
# the snake carries straight on. A dead snake gets a placeholder nobody reads.
func intendedHeads(g as Game) {
    def heads as list of geom.Point init [];
    for (def s in $g.snakes) {
        if (not $s.alive or len($s.cells) == 0) {
            $heads[] = geom.at(-1, -1);
        } else {
            def wanted as geom.Point init destination($g, $s.cells[0], $s.dir);
            if (len($s.cells) > 1 and geom.equals($wanted, $s.cells[1])) {
                $heads[] = destination($g, $s.cells[0], heading($s));
            } else {
                $heads[] = $wanted;
            }
        }
    }
    return $heads;
}

# blockedCells is the set of cells that will still be body after the move: every
# living snake's cells, minus the tail tip of each snake whose tail is about to
# follow it (a snake that is growing keeps its tail where it is). Chasing a
# tail one cell ahead is therefore legal, which is how the game is played.
func blockedCells(g as Game) {
    def blocked as map of string to bool init {};
    for (def s in $g.snakes) {
        if ($s.alive) {
            def last as int init len($s.cells);
            if ($s.grow == 0 and $last > 0) {
                $last = $last - 1;
            }
            for (def i as int init 0; $i < $last; $i = $i + 1) {
                $blocked[geom.key($s.cells[$i])] = true;
            }
        }
    }
    return $blocked;
}

# resolveDeaths decides, for each snake, whether this tick kills it: leaving the
# field, entering a cell that is still body, or arriving where another head
# arrives. Every death is judged against the same pre-move picture, so the
# outcome does not depend on the order the snakes happen to sit in the list.
#
# A ghosting snake is judged against a narrower picture: other snakes' *bodies* are
# no longer solid to it, but their heads still are, and so is its own body. That is
# the whole of the ghost effect, and keeping it here means no other function has to
# know about it.
func resolveDeaths(g as Game, heads as list of geom.Point) {
    def blocked as map of string to bool init blockedCells($g);
    def headed as map of string to int init headCells($g);
    def doomed as list of bool init [];
    for (def i as int init 0; $i < len($g.snakes); $i = $i + 1) {
        def s as Snake init $g.snakes[$i];
        if (not $s.alive) {
            $doomed[] = false;
        } else {
            $doomed[] = fatalMove($g, $s, $heads, $i, $blocked, $headed);
        }
    }
    return $doomed;
}

# fatalMove is the per-snake verdict, split out so `resolveDeaths` stays a loop and
# the ghost rule is one readable branch rather than a condition four lines long.
func fatalMove(
    g as Game,
    s as Snake,
    heads as list of geom.Point,
    i as int,
    blocked as map of string to bool,
    headed as map of string to int) {
    def head as geom.Point init $heads[$i];
    if (not geom.inBounds($head, $g.width, $g.height)) {
        return true;
    }
    if (headOnCollision($g, $heads, $i)) {
        return true;
    }
    def at as string init geom.key($head);
    if ($s.ghost > 0) {
        # Through bodies, but not through a head, and not through itself.
        if (maps.has($headed, $at) and $headed[$at] != $s.id) {
            return true;
        }
        return hitsOwnBody($s, $head);
    }
    return maps.has($blocked, $at);
}

# headCells maps each living snake's current head cell to its owner, so a ghosting
# snake can be stopped by a head without being stopped by the body behind it.
func headCells(g as Game) {
    def heads as map of string to int init {};
    for (def s in $g.snakes) {
        if ($s.alive and len($s.cells) > 0) {
            $heads[geom.key($s.cells[0])] = $s.id;
        }
    }
    return $heads;
}

# hitsOwnBody applies the same vacating-tail rule as `blockedCells`, to one snake:
# a snake may always follow its own tail off a cell, ghosting or not.
func hitsOwnBody(s as Snake, cell as geom.Point) {
    def last as int init len($s.cells);
    if ($s.grow == 0 and $last > 0) {
        $last = $last - 1;
    }
    for (def i as int init 0; $i < $last; $i = $i + 1) {
        if (geom.equals($s.cells[$i], $cell)) {
            return true;
        }
    }
    return false;
}

# headOnCollision reports whether another living snake is moving into the same
# cell as snake `i` this tick. Both snakes see it, so both die.
func headOnCollision(g as Game, heads as list of geom.Point, i as int) {
    for (def j as int init 0; $j < len($g.snakes); $j = $j + 1) {
        if ($j != $i and $g.snakes[$j].alive and geom.equals($heads[$j], $heads[$i])) {
            return true;
        }
    }
    return false;
}

# commitMoves writes the tick's outcome into the game: the doomed die and
# scatter, and the survivors move, eat, and grow.
func commitMoves(g as Game, heads as list of geom.Point, doomed as list of bool) {
    def out as Game init $g;
    for (def i as int init 0; $i < len($out.snakes); $i = $i + 1) {
        if ($doomed[$i]) {
            $out = kill($out, $i);
        } elseif ($out.snakes[$i].alive) {
            $out = advanceSnake($out, $i, $heads[$i]);
        }
    }
    return $out;
}

# kill takes a snake off the field, scores the death, and leaves half its body
# behind as food - so a long snake's end feeds whoever is nearby, and a crowded
# field stays interesting.
func kill(g as Game, idx as int) {
    def out as Game init $g;
    def cells as list of geom.Point init $out.snakes[$idx].cells;
    $out.snakes[$idx].alive = false;
    $out.snakes[$idx].cells = [];
    $out.snakes[$idx].grow = 0;
    $out.snakes[$idx].ghost = 0;
    $out.snakes[$idx].deaths = $out.snakes[$idx].deaths + 1;
    if ($out.lives != UNLIMITED_LIVES) {
        $out.snakes[$idx].lives = $out.snakes[$idx].lives - 1;
    }
    # A player out of lives keeps the seat and the score but never comes back, so the
    # countdown is cleared rather than started: `tickRespawns` skips them entirely.
    if (hasLivesLeft($out, $out.snakes[$idx])) {
        $out.snakes[$idx].respawn = RESPAWN_DELAY;
    } else {
        $out.snakes[$idx].respawn = 0;
    }
    return scatter($out, $cells);
}

# scatter drops every second cell of a dead body onto the field as food, up to
# the module's ceiling, skipping any cell already taken.
func scatter(g as Game, cells as list of geom.Point) {
    def out as Game init $g;
    def food as list of Item init $out.food;
    for (def i as int init 0; $i < len($cells); $i = $i + 2) {
        if (len($food) >= MAX_FOOD) {
            $out.food = $food;
            return $out;
        }
        if (foodIndexAt($food, $cells[$i]) < 0) {
            $food[] = plainFood($cells[$i]);
        }
    }
    $out.food = $food;
    return $out;
}

# advanceSnake moves one surviving snake onto `head`: the head is prepended, any
# food under it is eaten, and the tail follows unless there is growth still owed.
# Named to stay clearly distinct from `geom.step`, which is cell arithmetic.
func advanceSnake(g as Game, idx as int, head as geom.Point) {
    def out as Game init $g;
    def bite as Recipe init recipeFor(PLAIN);
    def ate as bool init false;
    def eaten as int init foodIndexAt($out.food, $head);
    if ($eaten >= 0) {
        $bite = recipeFor($out.food[$eaten].kind);
        $ate = true;
        $out.food = dropFood($out.food, $eaten);
        $out.snakes[$idx].score = $out.snakes[$idx].score + $bite.score;
        if ($bite.ghost > 0 and $bite.ghost > $out.snakes[$idx].ghost) {
            $out.snakes[$idx].ghost = $bite.ghost;
        }
    }
    $out = slide($out, $idx, $head, growthFrom($bite, $ate));
    if ($ate) {
        return digest($out, $idx, $bite);
    }
    return $out;
}

# growthFrom is the growth an eaten item owes: only a positive `grow` is owed here.
# A vegetable's negative growth is not "owe minus three", which would quietly cancel a
# candy eaten a moment earlier - it is three segments off the body now, which
# `digest` does after the move.
func growthFrom(bite as Recipe, ate as bool) {
    if ($ate and $bite.grow > 0) {
        return $bite.grow;
    }
    return 0;
}

# slide prepends the new head and either grows or drops the tail tip.
func slide(g as Game, idx as int, head as geom.Point, gained as int) {
    def out as Game init $g;
    $out.snakes[$idx].grow = $out.snakes[$idx].grow + $gained;
    def old as list of geom.Point init $out.snakes[$idx].cells;
    def keep as int init len($old);
    if ($out.snakes[$idx].grow > 0) {
        $out.snakes[$idx].grow = $out.snakes[$idx].grow - 1;
    } else {
        $keep = $keep - 1;
    }
    def next as list of geom.Point init [];
    $next[] = $head;
    for (def i as int init 0; $i < $keep; $i = $i + 1) {
        $next[] = $old[$i];
    }
    $out.snakes[$idx].cells = $next;
    return $out;
}

# digest applies what an eaten item does *after* the move: a fatal item kills, and a
# shrinking item takes segments off the tail - killing a snake with none to spare.
# Done after the move so a snake that dies here still dies where it ate.
func digest(g as Game, idx as int, bite as Recipe) {
    if ($bite.fatal) {
        return kill($g, $idx);
    }
    if ($bite.grow >= 0) {
        return $g;
    }
    def lost as int init 0 - $bite.grow;
    if (len($g.snakes[$idx].cells) - $lost < 1) {
        return kill($g, $idx);
    }
    def out as Game init $g;
    def kept as list of geom.Point init [];
    def keep as int init len($out.snakes[$idx].cells) - $lost;
    for (def i as int init 0; $i < $keep; $i = $i + 1) {
        $kept[] = $out.snakes[$idx].cells[$i];
    }
    $out.snakes[$idx].cells = $kept;
    return $out;
}

# dropFood is the food list without the item at `idx`.
func dropFood(food as list of Item, idx as int) {
    def kept as list of Item init [];
    for (def i as int init 0; $i < len($food); $i = $i + 1) {
        if ($i != $idx) {
            $kept[] = $food[$i];
        }
    }
    return $kept;
}

# justDied marks every snake that was alive before this tick's moves and is not
# alive after them. There are two ways to die - a collision, which `resolveDeaths`
# predicts, and eating something lethal, which only `digest` discovers - so the
# answer is read off the outcome rather than taken from either one.
func justDied(before as Game, after as Game) {
    def died as list of bool init [];
    for (def i as int init 0; $i < len($after.snakes); $i = $i + 1) {
        $died[] = $before.snakes[$i].alive and not $after.snakes[$i].alive;
    }
    return $died;
}

# tickRespawns counts every dead snake down and puts back the ones whose wait is
# over. A snake that cannot be placed (no free cell) keeps waiting.
#
# `doomed` marks the snakes that died in this very tick, and they are skipped:
# counting their first step down here would make the wait one tick shorter than
# RESPAWN_DELAY says.
func tickRespawns(g as Game, doomed as list of bool) {
    def out as Game init $g;
    for (def i as int init 0; $i < len($out.snakes); $i = $i + 1) {
        if (not $out.snakes[$i].alive and not $doomed[$i] and hasLivesLeft($out, $out.snakes[$i])) {
            if ($out.snakes[$i].respawn > 1) {
                $out.snakes[$i].respawn = $out.snakes[$i].respawn - 1;
            } else {
                $out = place($out, $i);
            }
        }
    }
    return $out;
}

/**
 * How much **plain** food the field should hold: one piece per living snake, never
 * fewer than one and never more than `MAX_FOOD`. More players means more food, so a
 * busy field does not turn into a race for a single crumb. Specials are not part of
 * this count - they come and go by their own rates.
 * @param g {Game} the game to size
 * @return {int} the number of plain pieces the field wants
 */
export func foodTarget(g as Game) {
    return clamp(maxOf(1, aliveCount($g)), 1, MAX_FOOD);
}

# replenishFood tops the field up to foodTarget, one piece per call site pass.
# A field with no free cell simply stays as it is.
func replenishFood(g as Game) {
    def out as Game init $g;
    def want as int init foodTarget($out);
    while (foodCount($out, PLAIN) < $want and len($out.food) < MAX_FOOD) {
        def spot as Spot init freeCell($out);
        $out.seed = $spot.seed;
        if (not $spot.found) {
            return $out;
        }
        def food as list of Item init $out.food;
        $food[] = plainFood($spot.cell);
        $out.food = $food;
    }
    return $out;
}
