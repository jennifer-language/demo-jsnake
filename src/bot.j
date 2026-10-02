# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The computer player: how a snake nobody is driving decides where to go.
 *
 * Pure, like `rules`. `choose` takes a game, a player id, a difficulty, and a
 * random state, and returns a direction and the next random state. It reads the
 * game and changes nothing, so a computer player can be tested exactly - "put a
 * wall here and food there, and an expert must turn left" - with no clock and no
 * terminal. The randomness is threaded rather than drawn from `math.rand` for the
 * same reason it is in `rules`: a reproducible game is a debuggable one.
 *
 * **The four levels differ in what they are allowed to look at**, not in how much
 * they cheat. None of them sees anything a human player cannot:
 *
 * - `EASY` wanders. It avoids a cell it can see is fatal and picks at random
 *   among the rest. It does not look for food, so it dies of boredom eventually.
 * - `NORMAL` heads for the nearest food by the shortest path, still refusing only
 *   the moves that are immediately fatal. It will happily seal itself into a
 *   pocket, which is what makes it beatable.
 * - `HARD` adds room to think: before a move it floods the space the new head
 *   would have and refuses one that leaves less room than its own length. That is
 *   the single check that stops a snake from trapping itself in its own coils.
 * - `EXPERT` adds the other snakes. It treats a cell another head is also moving
 *   into as fatal rather than merely unlucky, and when food is far away it prefers
 *   the roomiest move over the greedy one.
 *
 * **Food is not all worth eating.** A computer player reads each item's `Recipe`
 * rather than treating every cell of food alike: a candy is worth going out of its
 * way for, a plain crumb is worth a little, and a toadstool or a vegetable is a trap.
 * `NORMAL` is greedy enough to be caught by the traps, which is what keeps it
 * beatable; `HARD` and `EXPERT` avoid a cell holding something that would hurt them
 * as firmly as they avoid a wall. A `GHOST` is worth having and none of them knows
 * what to do with the spell afterwards - it plays on as if solid, which is safe.
 *
 * **Cost is bounded on purpose.** A host runs up to `rules.MAX_PLAYERS` of these
 * every tick, so the flood fill stops as soon as it has found enough room rather
 * than mapping the whole field: the question is never "how much space is there"
 * but "is there enough", and that one has a cheap answer.
 * @module bot
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./bot.j" as bot;
 * def pick as bot.Decision init bot.choose($game, 2, bot.HARD, $seed);
 * $game = rules.setDirection($game, 2, $pick.dir);
 * $seed = $pick.seed;
 */

use maps;
use convert;

import "./geom.j" as geom;
import "./rules.j" as rules;

/**
 * The wandering level: avoids the obviously fatal, ignores food.
 */
export def const EASY as string init "easy";

/**
 * The greedy level: shortest path to the nearest food, no foresight.
 */
export def const NORMAL as string init "normal";

/**
 * The careful level: greedy, but refuses a move into a space too small to live in.
 */
export def const HARD as string init "hard";

/**
 * The hardest level: careful, and it watches the other snakes' heads too.
 */
export def const EXPERT as string init "expert";

/**
 * Every level, easiest first - what a `--bot-level` flag validates against and
 * what its help text lists.
 */
export def const LEVELS as list of string init [EASY, NORMAL, HARD, EXPERT];

/**
 * The level used when none was asked for: enough of an opponent to be worth
 * playing, not enough to be discouraging.
 */
export def const DEFAULT_LEVEL as string init NORMAL;

# How much open space a careful snake insists on, as a multiple of its own length
# plus a constant - so a short snake still refuses to enter a two-cell pocket.
def const ROOM_FACTOR as int init 1;
def const ROOM_MARGIN as int init 4;

# The relative worth of the things a move is judged on. Survival dominates
# everything; after that, closing on food and having room to move trade off.
def const SCORE_FATAL as int init -1000000;
def const SCORE_CONTESTED as int init -10000;
def const SCORE_CRAMPED as int init -1000;
def const WEIGHT_FOOD as int init 12;
def const WEIGHT_ROOM as int init 3;

# How much a level that can see the difference dislikes stepping on something that
# hurts. Well short of fatal - a cornered snake should still eat a vegetable rather
# than hit a wall - and well past any amount of food-seeking.
def const SCORE_HARMFUL as int init 5000;

# What an item is worth to a snake heading for it, as a multiplier on the ordinary
# food weight. A candy is three ordinary crumbs, a ghost is one, and the two
# harmful kinds are worth nothing at all to head towards.
def const WORTH_CANDY as int init 3;

/**
 * The shared picture every computer player plans against this tick: which cells are
 * body, and where each snake's head is heading. Built once per tick by `survey`
 * and handed to every `chooseIn` call, because it is the same for all of them - a
 * host stepping eight bots would otherwise build it eight times.
 * @field taken {map of int to bool} occupied cell indices, as `rules.bodyCells` builds them
 * @field heads {map of int to int} player id to the cell index its head is moving into
 */
export def struct Field {
    taken as map of int to bool,
    heads as map of int to int
};

/**
 * Read the game once, for every computer player in it. Call this at the top of a
 * tick and pass the result to `chooseIn` for each bot.
 * @param g {rules.Game} the game to read
 * @return {Field} the shared view
 */
export func survey(g as rules.Game) {
    return Field{taken: rules.bodyCells($g), heads: rules.nextHeads($g)};
}

/**
 * A decision: where to go, and the random state to carry forward. Jennifer
 * returns one value and a generator has to hand back both.
 * @field dir {string} the chosen direction, always one of `geom`'s four
 * @field seed {int} the random state after any tie-break draws
 */
export def struct Decision {
    dir as string,
    seed as int
};

/**
 * Whether `level` names a difficulty this module implements.
 * @param level {string} the candidate level name
 * @return {bool} true for one of `LEVELS`
 */
export func isLevel(level as string) {
    for (def known in LEVELS) {
        if ($known == $level) {
            return true;
        }
    }
    return false;
}

/**
 * The level `level` names, falling back to `DEFAULT_LEVEL` for anything else - so
 * a typo on the command line produces a playable game with a note rather than an
 * error, and an unknown level can never reach the scoring code.
 * @param level {string} the requested level name
 * @return {string} a level from `LEVELS`
 */
export func levelOr(level as string) {
    if (isLevel($level)) {
        return $level;
    }
    return DEFAULT_LEVEL;
}

/**
 * Choose a direction for the snake with id `id`.
 *
 * Total: a snake that is dead, absent, or boxed in on all four sides still gets a
 * direction back - its current heading - because a host must be able to call this
 * every tick for every computer player without checking anything first.
 * @param g {rules.Game} the game to plan against
 * @param id {int} the computer player's id
 * @param level {string} the difficulty, one of `LEVELS`
 * @param seed {int} the player's own random state
 * @return {Decision} the direction to take and the next random state
 */
export func choose(g as rules.Game, id as int, level as string, seed as int) {
    return chooseIn($g, $id, $level, $seed, survey($g));
}

/**
 * Choose a direction using a `Field` already surveyed this tick - what a host with
 * several computer players calls, once per bot, after one `survey`.
 *
 * Total in the same way `choose` is: a dead, absent, or boxed-in snake still gets
 * a direction back.
 * @param g {rules.Game} the game to plan against
 * @param id {int} the computer player's id
 * @param level {string} the difficulty, one of `LEVELS`
 * @param seed {int} the player's own random state
 * @param field {Field} this tick's shared view, from `survey`
 * @return {Decision} the direction to take and the next random state
 */
export func chooseIn(g as rules.Game, id as int, level as string, seed as int, field as Field) {
    if (not rules.hasSnake($g, $id)) {
        return Decision{dir: geom.RIGHT, seed: $seed};
    }
    def me as rules.Snake init rules.snakeById($g, $id);
    if (not $me.alive or len($me.cells) == 0) {
        return Decision{dir: $me.dir, seed: $seed};
    }
    def skill as string init levelOr($level);
    def taken as map of int to bool init $field.taken;
    def rivals as map of int to bool init contested($field, $id, $skill);
    def best as int init SCORE_FATAL - 1;
    def choice as string init rules.heading($me);
    def state as int init $seed;
    for (def dir in geom.DIRECTIONS) {
        if (not geom.isReverse(rules.heading($me), $dir)) {
            def roll as rules.Roll init rules.roll($state, JITTER);
            $state = $roll.seed;
            def score as int init rate($g, $me, $dir, $skill, $taken, $rivals) + $roll.value;
            if ($score > $best) {
                $best = $score;
                $choice = $dir;
            }
        }
    }
    return Decision{dir: $choice, seed: $state};
}

# The size of the random tie-break added to every candidate's score. Big enough
# that two equally good moves are chosen between fairly - which is what stops a
# bot from pacing the same rut for ever - and far too small to outweigh any real
# difference in the scoring below.
def const JITTER as int init 3;

# contested is the set of cells another snake's head is also moving into, for the
# levels that care. The levels that do not get an empty set, so the scoring code
# below has no level test in it.
func contested(field as Field, id as int, level as string) {
    def cells as map of int to bool init {};
    if ($level != EXPERT) {
        return $cells;
    }
    for (def other in $field.heads) {
        if ($other != $id) {
            $cells[$field.heads[$other]] = true;
        }
    }
    return $cells;
}

# rate scores one candidate move. Higher is better; the three penalties are far
# apart in size, so a survivable cramped move always beats a fatal roomy one.
func rate(
    g as rules.Game,
    me as rules.Snake,
    dir as string,
    level as string,
    taken as map of int to bool,
    rivals as map of int to bool) {
    # `rules.destination` applies the game's border rule, so on a wrapped field a step off
    # the edge is the cell on the far side rather than a wall - and a bot using plain
    # `geom.step` here would refuse the safest move on the board.
    def head as geom.Point init rules.destination($g, $me.cells[0], $dir);
    if (not geom.inBounds($head, $g.width, $g.height)) {
        return SCORE_FATAL;
    }
    def at as int init geom.index($head, $g.width);
    if (maps.has($taken, $at) and not vacating($me, $head)) {
        return SCORE_FATAL;
    }
    def score as int init 0;
    if (maps.has($rivals, $at)) {
        $score = $score + SCORE_CONTESTED;
    }
    if (wantsRoom($level)) {
        def need as int init len($me.cells) * ROOM_FACTOR + ROOM_MARGIN;
        def room as int init openSpace($g, $head, $taken, $need);
        if ($room < $need) {
            $score = $score + SCORE_CRAMPED + $room;
        } elseif ($level == EXPERT) {
            $score = $score + $room * WEIGHT_ROOM;
        }
    }
    if (wantsFood($level)) {
        $score = $score + foodScore($g, $head);
    }
    if (avoidsTraps($level) and harmful(itemAt($g, $head))) {
        $score = $score - SCORE_HARMFUL;
    }
    return $score;
}

# itemAt is the kind of food on a cell, or "" when there is none.
func itemAt(g as rules.Game, cell as geom.Point) {
    def at as int init rules.foodIndexAt($g.food, $cell);
    if ($at < 0) {
        return "";
    }
    return $g.food[$at].kind;
}

# harmful reports whether eating this kind would cost the eater something: death, or
# segments it may not be able to spare. Read from the recipe, so a kind added to
# `rules` is judged correctly here without this function being touched.
func harmful(kind as string) {
    if (len($kind) == 0) {
        return false;
    }
    def recipe as rules.Recipe init rules.recipeFor($kind);
    return $recipe.fatal or $recipe.grow < 0;
}

# avoidsTraps says which levels can tell a toadstool from a crumb. The greedy levels
# cannot, which is exactly why they are beatable.
func avoidsTraps(level as string) {
    return $level == HARD or $level == EXPERT;
}

# vacating reports whether the cell is this snake's own tail tip and about to be
# freed: chasing your own tail one cell behind is legal, and a bot that thought
# otherwise would refuse the tightest safe turn on the board.
func vacating(me as rules.Snake, head as geom.Point) {
    if ($me.grow > 0 or len($me.cells) == 0) {
        return false;
    }
    return geom.equals($me.cells[len($me.cells) - 1], $head);
}

# wantsFood / wantsRoom say which levels look at what. Named rather than inlined
# so the difficulty ladder is legible in one place.
func wantsFood(level as string) {
    return $level != EASY;
}

func wantsRoom(level as string) {
    return $level == HARD or $level == EXPERT;
}

# foodDistance is how far a head is from a cell, the shortest way round: on a wrapped
# field going off one edge may be much closer than crossing the whole board.
func foodDistance(g as rules.Game, head as geom.Point, cell as geom.Point) {
    if (not $g.wrap) {
        return geom.distance($head, $cell);
    }
    return shorter($head.x, $cell.x, $g.width) + shorter($head.y, $cell.y, $g.height);
}

# shorter is the smaller of the two ways round one axis of a wrapped field. Named `goal`
# rather than `to`, which is a keyword - it appears in `map of K to V`.
func shorter(from as int, goal as int, span as int) {
    def direct as int init ($goal - $from) % $span;
    def around as int init $span - $direct;
    if ($around < $direct) {
        return $around;
    }
    return $direct;
}

# foodScore rewards closing on the best food in reach: for each item, how near it is
# scaled by what it is worth, and the best of those wins. A field with nothing worth
# eating scores 0, so a bot with nothing to chase falls through to its other
# preferences rather than being drawn towards a toadstool for want of an alternative.
func foodScore(g as rules.Game, head as geom.Point) {
    def span as int init $g.width + $g.height;
    def best as int init 0;
    for (def f in $g.food) {
        def worth as int init worthOf($f.kind);
        if ($worth > 0) {
            def value as int init ($span - geom.distance($head, $f.cell)) * WEIGHT_FOOD * $worth;
            if ($value > $best) {
                $best = $value;
            }
        }
    }
    return $best;
}

# worthOf is how much a kind is worth heading towards: nothing for something that
# would hurt, more for a candy than for a crumb.
func worthOf(kind as string) {
    if (harmful($kind)) {
        return 0;
    }
    if ($kind == rules.CANDY) {
        return WORTH_CANDY;
    }
    return 1;
}

/**
 * How many free cells are reachable from `from`, stopping once `limit` have been
 * found. The bound is the point: a computer player never needs to know the exact
 * size of the space it is entering, only whether it is big enough to live in, and
 * stopping early turns a whole-field flood into a handful of steps.
 * @param g {rules.Game} the game whose field to search
 * @param from {geom.Point} the cell to flood out from, counted as one of the free cells
 * @param taken {map of int to bool} the occupied cells, as `rules.bodyCells` builds them
 * @param limit {int} stop once this many free cells have been reached
 * @return {int} the number of free cells found, never more than `limit`
 */
export func openSpace(
    g as rules.Game,
    from as geom.Point,
    taken as map of int to bool,
    limit as int) {
    if (not geom.inBounds($from, $g.width, $g.height) or $limit <= 0) {
        return 0;
    }
    def seen as map of int to bool init {};
    def stack as list of int init [];
    $stack[] = geom.index($from, $g.width);
    $seen[geom.index($from, $g.width)] = true;
    def found as int init 0;
    def next as int init 0;
    while ($next < len($stack) and $found < $limit) {
        def here as geom.Point init geom.fromIndex($stack[$next], $g.width);
        $next = $next + 1;
        $found = $found + 1;
        for (def dir in geom.DIRECTIONS) {
            # Kept inline rather than pulled into a helper: this is the flood's hot
            # loop, and -1 stands for "not a cell worth queueing" so the whole test
            # is one condition instead of a nested pair.
            #
            # The flood follows the border rule as well, so on a wrapped field the space
            # behind a snake is correctly one connected region rather than four corners.
            def side as geom.Point init rules.destination($g, $here, $dir);
            def at as int init -1;
            if (geom.inBounds($side, $g.width, $g.height)) {
                $at = geom.index($side, $g.width);
            }
            if ($at >= 0 and not maps.has($seen, $at) and not maps.has($taken, $at)) {
                $seen[$at] = true;
                $stack[] = $at;
            }
        }
    }
    return $found;
}

/**
 * A display name for a computer player at a given level, distinct from a human's
 * so a scoreboard says who is who without a column for it.
 * @param level {string} the difficulty
 * @param n {int} which computer player this is, from 1
 * @return {string} a name, already short enough for the protocol
 */
export func nameFor(level as string, n as int) {
    return "cpu" + convert.toString($n) + "-" + levelOr($level);
}
