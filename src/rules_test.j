# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for rules.j: the generator, the roster, and every branch of
# one tick - movement, walls, bodies, head-on meetings, eating, growth, death
# scatter, respawn, and food replenishment. Run with:
#
#     jennifer test src/rules_test.j
#
# Because `advance` is pure and the generator lives in the state, every test
# below is exact: no clock, no socket, no `math.rand`, no tolerance.

use testing;

# --- helpers -----------------------------------------------------------------

# handMade builds a game whose snakes and food are placed exactly where a test
# wants them, bypassing the random placement `addSnake` would do.
# Specials are off and lives are unlimited here: these tests pin down the core rules, and
# a toadstool appearing by chance - or a snake running out of lives mid-test - would make
# them different tests. Special food and lives each have their own section at the end.
func handMade(width as int, height as int) {
    return Game{
        width: $width,
        height: $height,
        snakes: [],
        food: [],
        tick: 0,
        seed: 1,
        specials: false,
        lives: UNLIMITED_LIVES,
        wrap: false,
        round: 1
    };
}

# withSnake appends a fully specified snake, head first, so a test can state the
# exact body it means to exercise.
func withSnake(g as Game, id as int, cells as list of geom.Point, dir as string, grow as int) {
    def out as Game init $g;
    def snakes as list of Snake init $out.snakes;
    $snakes[] = Snake{
        id: $id,
        name: "p" + convert.toString($id),
        cells: $cells,
        dir: $dir,
        alive: true,
        score: 0,
        deaths: 0,
        respawn: 0,
        grow: $grow,
        ghost: 0,
        lives: $out.lives
    };
    $out.snakes = $snakes;
    return $out;
}

# bodyFacing builds a straight body of `n` cells whose head is at (headX, headY)
# and whose tail trails away behind it - so a snake facing LEFT has its body to
# the right of its head, which is what keeps these fixtures on the field.
func bodyFacing(headX as int, headY as int, n as int, dir as string) {
    def cells as list of geom.Point init [];
    def cell as geom.Point init geom.at($headX, $headY);
    def back as string init geom.opposite($dir);
    for (def i as int init 0; $i < $n; $i = $i + 1) {
        $cells[] = $cell;
        $cell = geom.step($cell, $back);
    }
    return $cells;
}

# --- the generator -----------------------------------------------------------

func testRollStaysInRange() {
    def seed as int init 7;
    for (def i as int init 0; $i < 200; $i = $i + 1) {
        def r as Roll init roll($seed, 10);
        testing.assertTrue($r.value >= 0 and $r.value < 10);
        $seed = $r.seed;
    }
}

func testRollIsDeterministic() {
    def a as Roll init roll(12345, 100);
    def b as Roll init roll(12345, 100);
    testing.assertEqual($a.value, $b.value);
    testing.assertEqual($a.seed, $b.seed);
}

func testRollAdvancesTheSeed() {
    def r as Roll init roll(99, 5);
    testing.assertNotEqual($r.seed, 99);
}

func testRollWithDegenerateBoundIsZero() {
    testing.assertEqual(roll(5, 1).value, 0);
    testing.assertEqual(roll(5, 0).value, 0);
    testing.assertEqual(roll(5, -3).value, 0);
}

func testRollSpreadsOverItsRange() {
    # A generator that always answered the same value would pass the range test
    # above, so check the spread too: 400 draws must cover all four buckets.
    def seen as map of int to bool init {};
    def seed as int init 3;
    for (def i as int init 0; $i < 400; $i = $i + 1) {
        def r as Roll init roll($seed, 4);
        $seen[$r.value] = true;
        $seed = $r.seed;
    }
    testing.assertEqual(len($seen), 4);
}

func testNormalizeSeedIsNonNegative() {
    testing.assertTrue(normalizeSeed(-99) >= 0);
    testing.assertTrue(normalizeSeed(0) > 0);
    testing.assertEqual(normalizeSeed(12), 12);
}

# --- newGame -----------------------------------------------------------------

func testNewGameStartsEmpty() {
    def g as Game init newGame(20, 10, 5);
    testing.assertEqual($g.width, 20);
    testing.assertEqual($g.height, 10);
    testing.assertEqual(len($g.snakes), 0);
    testing.assertEqual(len($g.food), 0);
    testing.assertEqual($g.tick, 0);
}

func testNewGameClampsTinyFields() {
    def g as Game init newGame(1, 1, 1);
    testing.assertEqual($g.width, MIN_WIDTH);
    testing.assertEqual($g.height, MIN_HEIGHT);
}

func testNewGameClampsHugeFields() {
    def g as Game init newGame(9000, 9000, 1);
    testing.assertEqual($g.width, MAX_WIDTH);
    testing.assertEqual($g.height, MAX_HEIGHT);
}

func testNewGameIsReproducible() {
    def a as Game init newGame(20, 10, 42);
    def b as Game init newGame(20, 10, 42);
    testing.assertEqual($a.seed, $b.seed);
}

# --- the roster --------------------------------------------------------------

func testNextIdStartsAtOne() {
    testing.assertEqual(nextId(newGame(20, 10, 1)), 1);
}

func testNextIdFillsTheLowestGap() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "a");
    $g = addSnake($g, 2, "b");
    $g = addSnake($g, 3, "c");
    testing.assertEqual(nextId($g), 4);
    $g = removeSnake($g, 2);
    testing.assertEqual(nextId($g), 2);
}

func testAddSnakePlacesItOnTheField() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "ada");
    def s as Snake init snakeById($g, 1);
    testing.assertTrue($s.alive);
    testing.assertEqual(len($s.cells), 1);
    testing.assertEqual($s.grow, START_LENGTH - 1);
    testing.assertTrue(geom.inBounds($s.cells[0], $g.width, $g.height));
    testing.assertEqual($s.name, "ada");
}

func testAddSnakeIgnoresADuplicateId() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "ada");
    def again as Game init addSnake($g, 1, "impostor");
    testing.assertEqual(len($again.snakes), 1);
    testing.assertEqual(snakeById($again, 1).name, "ada");
}

func testAddSnakeFacesAnOpenDirection() {
    def g as Game init newGame(20, 10, 7);
    $g = addSnake($g, 1, "ada");
    def s as Snake init snakeById($g, 1);
    def ahead as geom.Point init geom.step($s.cells[0], $s.dir);
    testing.assertTrue(geom.inBounds($ahead, $g.width, $g.height));
}

func testSnakesNeverShareACell() {
    def g as Game init newGame(12, 6, 3);
    for (def i as int init 1; $i <= 6; $i = $i + 1) {
        $g = addSnake($g, $i, "p");
    }
    def seen as map of string to bool init {};
    for (def s in $g.snakes) {
        for (def c in $s.cells) {
            testing.assertFalse(maps.has($seen, geom.key($c)));
            $seen[geom.key($c)] = true;
        }
    }
}

func testRemoveSnakeDropsOnlyThatSnake() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "a");
    $g = addSnake($g, 2, "b");
    $g = removeSnake($g, 1);
    testing.assertEqual(len($g.snakes), 1);
    testing.assertTrue(hasSnake($g, 2));
    testing.assertFalse(hasSnake($g, 1));
}

func testRemoveSnakeIgnoresAnUnknownId() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "a");
    testing.assertEqual(len(removeSnake($g, 99).snakes), 1);
}

func testSnakeIndexAndHasSnakeAgree() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 4, "a");
    testing.assertEqual(snakeIndex($g, 4), 0);
    testing.assertEqual(snakeIndex($g, 5), -1);
    testing.assertTrue(hasSnake($g, 4));
    testing.assertFalse(hasSnake($g, 5));
}

func testSnakeByIdThrowsOnAnUnknownId() {
    testing.assertThrows("snakeByIdOnEmptyGame", "value");
}

func snakeByIdOnEmptyGame() {
    def g as Game init newGame(20, 10, 1);
    def s as Snake init snakeById($g, 12);
    testing.assertEqual($s.id, 12);
}

# --- steering ----------------------------------------------------------------

func testSetDirectionTurnsTheSnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g = setDirection($g, 1, geom.UP);
    testing.assertEqual(snakeById($g, 1).dir, geom.UP);
}

func testSetDirectionRefusesAReversal() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g = setDirection($g, 1, geom.LEFT);
    testing.assertEqual(snakeById($g, 1).dir, geom.RIGHT);
}

func testSetDirectionRefusesNonsense() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g = setDirection($g, 1, "backwards");
    testing.assertEqual(snakeById($g, 1).dir, geom.RIGHT);
}

func testSetDirectionIgnoresAnUnknownPlayer() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    testing.assertEqual(len(setDirection($g, 99, geom.UP).snakes), 1);
}

func testSetDirectionJudgesTheReversalAgainstTheBodyNotTheRequest() {
    # A player who turns twice inside one tick must not be able to double back:
    # geom.RIGHT -> geom.UP is accepted, and geom.UP -> geom.LEFT would then be legal by `dir`, but
    # the body still runs to the left, so the turn is measured against it.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g = setDirection($g, 1, geom.UP);
    $g = setDirection($g, 1, geom.LEFT);
    testing.assertEqual(snakeById($g, 1).dir, geom.UP);
}

func testHeadingReadsTheBody() {
    def g as Game init handMade(20, 10);
    # A body running left from (5,5) is travelling geom.RIGHT, whatever `dir` claims.
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.UP, 0);
    testing.assertEqual(heading(snakeById($g, 1)), geom.RIGHT);
}

func testHeadingFallsBackToDirForAShortSnake() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(2, 2)];
    $g = withSnake($g, 1, $one, geom.DOWN, 0);
    testing.assertEqual(heading(snakeById($g, 1)), geom.DOWN);
}

# --- movement ----------------------------------------------------------------

func testAdvanceCountsTheTick() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    testing.assertEqual(advance($g).tick, 1);
    testing.assertEqual(advance(advance($g)).tick, 2);
}

func testAdvanceMovesTheHeadAndFollowsWithTheTail() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    def s as Snake init snakeById(advance($g), 1);
    testing.assertEqual(len($s.cells), 3);
    testing.assertTrue(geom.equals($s.cells[0], geom.at(6, 5)));
    testing.assertTrue(geom.equals($s.cells[1], geom.at(5, 5)));
    testing.assertTrue(geom.equals($s.cells[2], geom.at(4, 5)));
}

func testAdvanceGrowsInsteadOfFollowingWhenGrowthIsOwed() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 2);
    def s as Snake init snakeById(advance($g), 1);
    testing.assertEqual(len($s.cells), 4);
    testing.assertEqual($s.grow, 1);
}

func testAdvanceRefusesToDriveIntoItsOwnNeck() {
    # `dir` says geom.LEFT but the neck is to the left, so the snake carries on geom.RIGHT
    # rather than killing itself on a direction it should never have accepted.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].dir = geom.LEFT;
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    testing.assertTrue(geom.equals($s.cells[0], geom.at(6, 5)));
}

func testAdvanceLetsASnakeChaseItsOwnTail() {
    # The tail vacates as the head arrives, so the cell is free this tick.
    def g as Game init handMade(20, 10);
    def square as list of geom.Point init [
        geom.at(5, 5),
        geom.at(6, 5),
        geom.at(6, 6),
        geom.at(5, 6)
    ];
    $g = withSnake($g, 1, $square, geom.LEFT, 0);
    $g.snakes[0].dir = geom.DOWN;
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    testing.assertTrue(geom.equals($s.cells[0], geom.at(5, 6)));
}

func testAdvanceKillsASnakeThatEatsItsOwnBody() {
    # A growing snake's tail stays put, so the same turn into it is fatal.
    def g as Game init handMade(20, 10);
    def square as list of geom.Point init [
        geom.at(5, 5),
        geom.at(6, 5),
        geom.at(6, 6),
        geom.at(5, 6)
    ];
    $g = withSnake($g, 1, $square, geom.LEFT, 3);
    $g.snakes[0].dir = geom.DOWN;
    def s as Snake init snakeById(advance($g), 1);
    testing.assertFalse($s.alive);
}

# --- walls -------------------------------------------------------------------

func testAdvanceKillsAtTheLeftWall() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    def s as Snake init snakeById(advance($g), 1);
    testing.assertFalse($s.alive);
    testing.assertEqual($s.deaths, 1);
    testing.assertEqual(len($s.cells), 0);
}

func testAdvanceKillsAtEveryWall() {
    def g as Game init handMade(20, 10);
    def top as list of geom.Point init [geom.at(3, 0)];
    def bottom as list of geom.Point init [geom.at(4, 9)];
    def right as list of geom.Point init [geom.at(19, 3)];
    $g = withSnake($g, 1, $top, geom.UP, 0);
    $g = withSnake($g, 2, $bottom, geom.DOWN, 0);
    $g = withSnake($g, 3, $right, geom.RIGHT, 0);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertFalse(snakeById($after, 2).alive);
    testing.assertFalse(snakeById($after, 3).alive);
}

func testASnakeSurvivesRunningAlongAWall() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(5, 0)];
    $g = withSnake($g, 1, $one, geom.RIGHT, 0);
    testing.assertTrue(snakeById(advance($g), 1).alive);
}

# --- snake against snake -----------------------------------------------------

func testAdvanceKillsASnakeThatRunsIntoAnotherBody() {
    def g as Game init handMade(20, 10);
    def runner as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $runner, geom.RIGHT, 0);
    # A long stationary-looking wall of body geom.at x = 5..8, growing so its tail
    # stays put and cell (5, 5) is still occupied after the tick.
    $g = withSnake($g, 2, bodyFacing(8, 5, 4, geom.RIGHT), geom.RIGHT, 5);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertTrue(snakeById($after, 2).alive);
}

func testAdvanceKillsBothSnakesInAHeadOnMeeting() {
    def g as Game init handMade(20, 10);
    def a as list of geom.Point init [geom.at(4, 5)];
    def b as list of geom.Point init [geom.at(6, 5)];
    $g = withSnake($g, 1, $a, geom.RIGHT, 0);
    $g = withSnake($g, 2, $b, geom.LEFT, 0);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertFalse(snakeById($after, 2).alive);
}

func testDeathIsJudgedBeforeAnybodyMoves() {
    # Both snakes aim geom.at (5, 5). Whichever sits first in the list must not get
    # there first: a simultaneous tick kills both, in either order.
    def g as Game init handMade(20, 10);
    def a as list of geom.Point init [geom.at(5, 4)];
    def b as list of geom.Point init [geom.at(5, 6)];
    $g = withSnake($g, 2, $b, geom.UP, 0);
    $g = withSnake($g, 1, $a, geom.DOWN, 0);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertFalse(snakeById($after, 2).alive);
}

func testADeadSnakeIsNoObstacle() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $one, geom.RIGHT, 0);
    $g = withSnake($g, 2, [], geom.RIGHT, 0);
    $g.snakes[1].alive = false;
    $g.snakes[1].respawn = 5;
    testing.assertTrue(snakeById(advance($g), 1).alive);
}

# --- eating ------------------------------------------------------------------

func testEatingScoresAndGrows() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [plainFood(geom.at(6, 5))];
    def after as Game init advance($g);
    def s as Snake init snakeById($after, 1);
    testing.assertEqual($s.score, FOOD_SCORE);
    testing.assertEqual($s.grow, GROWTH_PER_FOOD - 1);
    testing.assertEqual(len($s.cells), 4);
}

func testEatingRemovesThatPieceOfFood() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [plainFood(geom.at(6, 5)), plainFood(geom.at(12, 8))];
    def after as Game init advance($g);
    testing.assertFalse(foodIndexAt($after.food, geom.at(6, 5)) >= 0);
    testing.assertTrue(foodIndexAt($after.food, geom.at(12, 8)) >= 0);
}

func testFoodIsNotAnObstacle() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [plainFood(geom.at(6, 5))];
    testing.assertTrue(snakeById(advance($g), 1).alive);
}

func testScoreSurvivesDeath() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g.snakes[0].score = 70;
    testing.assertEqual(snakeById(advance($g), 1).score, 70);
}

# --- death scatter -----------------------------------------------------------

func testDeathScattersHalfTheBodyAsFood() {
    def g as Game init handMade(20, 10);
    # A body of 5 running into the left wall: cells 0, 2, 4 become food.
    $g = withSnake($g, 1, bodyFacing(0, 5, 5, geom.LEFT), geom.LEFT, 0);
    def after as Game init advance($g);
    testing.assertTrue(foodIndexAt($after.food, geom.at(0, 5)) >= 0);
    testing.assertTrue(foodIndexAt($after.food, geom.at(2, 5)) >= 0);
    testing.assertTrue(foodIndexAt($after.food, geom.at(4, 5)) >= 0);
    testing.assertFalse(foodIndexAt($after.food, geom.at(1, 5)) >= 0);
    for (def f in $after.food) {
        testing.assertTrue(geom.inBounds($f.cell, $after.width, $after.height));
    }
}

func testScatterRespectsTheFoodCeiling() {
    def g as Game init handMade(60, 40);
    def crowd as list of Item init [];
    for (def i as int init 0; $i < MAX_FOOD; $i = $i + 1) {
        $crowd[] = plainFood(geom.at($i, 39));
    }
    $g.food = $crowd;
    $g = withSnake($g, 1, bodyFacing(0, 5, 20, geom.LEFT), geom.LEFT, 0);
    testing.assertEqual(len(advance($g).food), MAX_FOOD);
}

func testScatterNeverDuplicatesAFoodCell() {
    def g as Game init handMade(20, 10);
    $g.food = [plainFood(geom.at(4, 5))];
    $g = withSnake($g, 1, bodyFacing(4, 5, 5, geom.LEFT), geom.LEFT, 0);
    def after as Game init advance($g);
    def seen as map of string to bool init {};
    for (def f in $after.food) {
        testing.assertFalse(maps.has($seen, geom.key($f.cell)));
        $seen[geom.key($f.cell)] = true;
    }
}

# --- respawn -----------------------------------------------------------------

func testDeathStartsTheRespawnCountdown() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    testing.assertEqual(snakeById(advance($g), 1).respawn, RESPAWN_DELAY);
}

func testTheCountdownRunsDownAndTheSnakeReturns() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g = advance($g);
    for (def i as int init 0; $i < RESPAWN_DELAY - 1; $i = $i + 1) {
        $g = advance($g);
        testing.assertFalse(snakeById($g, 1).alive);
    }
    $g = advance($g);
    def s as Snake init snakeById($g, 1);
    testing.assertTrue($s.alive);
    testing.assertEqual($s.respawn, 0);
    testing.assertEqual(len($s.cells), 1);
    testing.assertEqual($s.deaths, 1);
}

func testARespawnedSnakeKeepsItsScore() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g.snakes[0].score = 120;
    for (def i as int init 0; $i <= RESPAWN_DELAY; $i = $i + 1) {
        $g = advance($g);
    }
    testing.assertEqual(snakeById($g, 1).score, 120);
}

# --- food replenishment ------------------------------------------------------

func testFoodTargetTracksTheCrowd() {
    def g as Game init handMade(20, 10);
    testing.assertEqual(foodTarget($g), 1);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    testing.assertEqual(foodTarget($g), 1);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 3, bodyFacing(15, 2, 2, geom.LEFT), geom.LEFT, 0);
    testing.assertEqual(foodTarget($g), 3);
}

func testAdvanceRestocksTheFieldToTarget() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.RIGHT), geom.RIGHT, 0);
    def after as Game init advance($g);
    testing.assertEqual(len($after.food), 2);
}

func testReplenishedFoodLandsOnEmptyCells() {
    def g as Game init handMade(12, 6);
    $g = withSnake($g, 1, bodyFacing(5, 2, 3, geom.RIGHT), geom.RIGHT, 0);
    def after as Game init advance($g);
    for (def f in $after.food) {
        testing.assertTrue(geom.inBounds($f.cell, $after.width, $after.height));
        for (def s in $after.snakes) {
            testing.assertFalse(geom.contains($s.cells, $f.cell));
        }
    }
}

func testAdvanceIsReproducibleFromTheSeed() {
    def a as Game init addSnake(newGame(20, 10, 1234), 1, "ada");
    def b as Game init addSnake(newGame(20, 10, 1234), 1, "ada");
    for (def i as int init 0; $i < 25; $i = $i + 1) {
        $a = advance($a);
        $b = advance($b);
    }
    testing.assertEqual($a.seed, $b.seed);
    testing.assertEqual($a.tick, $b.tick);
    testing.assertEqual(len($a.food), len($b.food));
    testing.assertEqual(snakeById($a, 1).score, snakeById($b, 1).score);
    testing.assertEqual(len(snakeById($a, 1).cells), len(snakeById($b, 1).cells));
}

func testDifferentSeedsDivergeSomewhere() {
    def a as Game init addSnake(newGame(20, 10, 1), 1, "ada");
    def b as Game init addSnake(newGame(20, 10, 999), 1, "ada");
    testing.assertNotEqual($a.seed, $b.seed);
}

# --- occupancy and bookkeeping ----------------------------------------------

func testIsOccupiedSeesBodiesAndFood() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [plainFood(geom.at(9, 9))];
    testing.assertTrue(isOccupied($g, geom.at(5, 5)));
    testing.assertTrue(isOccupied($g, geom.at(3, 5)));
    testing.assertTrue(isOccupied($g, geom.at(9, 9)));
    testing.assertFalse(isOccupied($g, geom.at(1, 1)));
}

func testIsOccupiedIgnoresADeadSnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].alive = false;
    testing.assertFalse(isOccupied($g, geom.at(5, 5)));
}

func testFreeCellFindsSomethingOnAnEmptyField() {
    def spot as Spot init freeCell(handMade(20, 10));
    testing.assertTrue($spot.found);
    testing.assertTrue(geom.inBounds($spot.cell, 20, 10));
}

func testFreeCellGivesUpOnAFullField() {
    def g as Game init handMade(10, 6);
    def every as list of Item init [];
    for (def y as int init 0; $y < 6; $y = $y + 1) {
        for (def x as int init 0; $x < 10; $x = $x + 1) {
            $every[] = plainFood(geom.at($x, $y));
        }
    }
    $g.food = $every;
    testing.assertFalse(freeCell($g).found);
}

func testAliveCountCountsOnlyTheLiving() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[1].alive = false;
    testing.assertEqual(aliveCount($g), 1);
}

func testLeaderIdPicksTheTopScore() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[1].score = 50;
    testing.assertEqual(leaderId($g), 2);
}

func testLeaderIdBreaksTiesOnTheLowerId() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.RIGHT), geom.RIGHT, 0);
    testing.assertEqual(leaderId($g), 1);
}

func testLeaderIdIsZeroWithNoPlayers() {
    testing.assertEqual(leaderId(handMade(20, 10)), 0);
}

# --- the game survives being played ----------------------------------------

func testAFullGameRunsWithoutBreakingItsInvariants() {
    # Six players steered by a deterministic pattern for 300 ticks: the field
    # must never hold a snake off it, two snakes in one cell, or stale food.
    def g as Game init newGame(24, 12, 20260929);
    for (def i as int init 1; $i <= 6; $i = $i + 1) {
        $g = addSnake($g, $i, "p" + convert.toString($i));
    }
    for (def t as int init 0; $t < 300; $t = $t + 1) {
        for (def i as int init 1; $i <= 6; $i = $i + 1) {
            def r as Roll init roll($g.seed + $t + $i, len(geom.DIRECTIONS));
            $g = setDirection($g, $i, geom.DIRECTIONS[$r.value]);
        }
        $g = advance($g);
        def taken as map of string to bool init {};
        for (def s in $g.snakes) {
            testing.assertTrue($s.alive or len($s.cells) == 0);
            for (def c in $s.cells) {
                testing.assertTrue(geom.inBounds($c, $g.width, $g.height));
                testing.assertFalse(maps.has($taken, geom.key($c)));
                $taken[geom.key($c)] = true;
            }
        }
        for (def f in $g.food) {
            testing.assertTrue(geom.inBounds($f.cell, $g.width, $g.height));
            testing.assertFalse(maps.has($taken, geom.key($f.cell)));
        }
        testing.assertTrue(len($g.food) <= MAX_FOOD);
    }
    testing.assertEqual($g.tick, 300);
    testing.assertEqual(len($g.snakes), 6);
}

func testEverySnakeStaysConnected() {
    # A body is a path: each cell must touch the one before it. A bug in the
    # grow/follow arithmetic would tear it apart, and nothing else would notice.
    def g as Game init newGame(20, 10, 77);
    $g = addSnake($g, 1, "ada");
    for (def t as int init 0; $t < 60; $t = $t + 1) {
        $g = advance($g);
        def cells as list of geom.Point init snakeById($g, 1).cells;
        for (def i as int init 1; $i < len($cells); $i = $i + 1) {
            def dx as int init $cells[$i].x - $cells[$i - 1].x;
            def dy as int init $cells[$i].y - $cells[$i - 1].y;
            def stepped as int init $dx * $dx + $dy * $dy;
            testing.assertEqual($stepped, 1);
        }
    }
}

# --- the occupancy views a computer player plans against --------------------

func testBodyCellsSeesEveryLivingCell() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    def taken as map of int to bool init bodyCells($g);
    testing.assertEqual(len($taken), 3);
    testing.assertTrue(maps.has($taken, geom.index(geom.at(5, 5), 20)));
    testing.assertTrue(maps.has($taken, geom.index(geom.at(3, 5), 20)));
    testing.assertFalse(maps.has($taken, geom.index(geom.at(2, 5), 20)));
}

func testBodyCellsIgnoresADeadSnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].alive = false;
    testing.assertEqual(len(bodyCells($g)), 0);
}

func testBodyCellsLeavesFoodOut() {
    # Food is a destination, not an obstacle.
    def g as Game init handMade(20, 10);
    $g.food = [plainFood(geom.at(9, 9))];
    testing.assertEqual(len(bodyCells($g)), 0);
}

func testBodyCellsCoversEverySnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(15, 2, 2, geom.LEFT), geom.LEFT, 0);
    testing.assertEqual(len(bodyCells($g)), 5);
}

func testNextHeadsReadsTheBodyNotTheRequestedHeading() {
    # A snake whose `dir` would reverse it carries straight on, and nextHeads has
    # to agree with that or a bot would dodge a cell nobody is entering.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].dir = geom.LEFT;
    def heads as map of int to int init nextHeads($g);
    testing.assertEqual($heads[1], geom.index(geom.at(6, 5), 20));
}

func testNextHeadsCoversEveryLivingSnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(5, 8, 2, geom.DOWN), geom.DOWN, 0);
    def heads as map of int to int init nextHeads($g);
    testing.assertEqual(len($heads), 2);
    testing.assertEqual($heads[2], geom.index(geom.at(5, 9), 20));
}

func testNextHeadsSkipsADeadSnake() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    testing.assertEqual(len(nextHeads($g)), 0);
}

# --- heading on a body that cannot be walked -------------------------------

func testHeadingFallsBackWhenTheBodyIsNotAPath() {
    # A STATE from a peer can describe a body whose neck is nowhere near its head.
    # `heading` must still answer something rather than looping or throwing.
    def g as Game init handMade(20, 10);
    def broken as list of geom.Point init [geom.at(0, 0), geom.at(5, 5)];
    $g = withSnake($g, 1, $broken, geom.DOWN, 0);
    testing.assertEqual(heading(snakeById($g, 1)), geom.DOWN);
}

# --- a field with no room left ---------------------------------------------

func testASnakeCannotBePlacedOnAFullFieldAndKeepsWaiting() {
    def g as Game init handMade(10, 6);
    def every as list of Item init [];
    for (def y as int init 0; $y < 6; $y = $y + 1) {
        for (def x as int init 0; $x < 10; $x = $x + 1) {
            $every[] = plainFood(geom.at($x, $y));
        }
    }
    $g.food = $every;
    $g = addSnake($g, 1, "ada");
    def s as Snake init snakeById($g, 1);
    testing.assertFalse($s.alive);
    testing.assertEqual(len($s.cells), 0);
    testing.assertEqual($s.respawn, 1);
}

func testAWaitingSnakeKeepsWaitingWhileTheFieldStaysFull() {
    def g as Game init handMade(10, 6);
    def every as list of Item init [];
    for (def y as int init 0; $y < 6; $y = $y + 1) {
        for (def x as int init 0; $x < 10; $x = $x + 1) {
            $every[] = plainFood(geom.at($x, $y));
        }
    }
    $g.food = $every;
    $g = addSnake($g, 1, "ada");
    for (def t as int init 0; $t < 5; $t = $t + 1) {
        $g = advance($g);
        testing.assertFalse(snakeById($g, 1).alive);
    }
    testing.assertEqual($g.tick, 5);
}

func testFoodIsNotReplenishedWhenThereIsNowhereToPutIt() {
    # Every cell is body, so the field wants food and cannot have any. It must
    # return rather than search for ever.
    def g as Game init handMade(10, 6);
    def every as list of geom.Point init [];
    for (def y as int init 0; $y < 6; $y = $y + 1) {
        for (def x as int init 0; $x < 10; $x = $x + 1) {
            $every[] = geom.at($x, $y);
        }
    }
    $g = withSnake($g, 1, $every, geom.RIGHT, 0);
    testing.assertEqual(foodTarget($g), 1);
    def after as Game init replenishFood($g);
    testing.assertEqual(len($after.food), 0);
}

# --- the food catalogue ------------------------------------------------------

func testEveryKindHasARecipeUnderItsOwnName() {
    for (def kind in FOOD_KINDS) {
        testing.assertEqual(recipeFor($kind).kind, $kind);
        testing.assertTrue(isFoodKind($kind));
    }
}

func testAnUnknownKindReadsAsPlainFood() {
    # An item from a peer naming a kind this version lacks must be harmless.
    testing.assertEqual(recipeFor("caviar").kind, PLAIN);
    testing.assertFalse(isFoodKind("caviar"));
    testing.assertFalse(isFoodKind(""));
}

func testPlainFoodIsTheOnlyKindThatStays() {
    testing.assertEqual(recipeFor(PLAIN).life, PERMANENT);
    for (def kind in SPECIAL_KINDS) {
        testing.assertTrue(recipeFor($kind).life > 0);
    }
}

func testOnlySpecialsAppearByChance() {
    testing.assertEqual(recipeFor(PLAIN).chance, 0);
    for (def kind in SPECIAL_KINDS) {
        testing.assertTrue(recipeFor($kind).chance > 0);
        testing.assertTrue(isSpecial($kind));
    }
    testing.assertFalse(isSpecial(PLAIN));
}

func testEveryKindsRateIsItsOwn() {
    # "rate of appearance also item specific": no two kinds share a rate, so one
    # cannot be mistaken for another when tuning them.
    def seen as map of int to bool init {};
    for (def kind in SPECIAL_KINDS) {
        def chance as int init recipeFor($kind).chance;
        testing.assertFalse(maps.has($seen, $chance));
        $seen[$chance] = true;
    }
}

func testTheRecipesSayWhatTheExamplesSay() {
    testing.assertTrue(recipeFor(TOADSTOOL).fatal);
    testing.assertEqual(recipeFor(GHOST).ghost, 10 * TICKS_PER_SECOND);
    testing.assertEqual(recipeFor(CANDY).grow, CANDY_BITE);
    testing.assertEqual(recipeFor(VEGETABLES).grow, 0 - VEG_BITE);
    testing.assertFalse(recipeFor(CANDY).fatal);
    testing.assertFalse(recipeFor(VEGETABLES).fatal);
}

func testALifetimeIsMeasuredInMovesNotSeconds() {
    # 15 seconds at the default tick is 120 moves, and a host on a faster tick gets
    # the same 120 moves - an item is worth the same to a player either way.
    testing.assertEqual(recipeFor(TOADSTOOL).life, 15 * TICKS_PER_SECOND);
    testing.assertEqual(recipeFor(VEGETABLES).life, 15 * TICKS_PER_SECOND);
    testing.assertEqual(recipeFor(GHOST).life, 12 * TICKS_PER_SECOND);
    testing.assertEqual(recipeFor(CANDY).life, 10 * TICKS_PER_SECOND);
}

func testFoodAtCarriesItsKindsLifetime() {
    for (def kind in FOOD_KINDS) {
        def item as Item init foodAt($kind, geom.at(3, 4));
        testing.assertEqual($item.kind, $kind);
        testing.assertEqual($item.life, recipeFor($kind).life);
        testing.assertTrue(geom.equals($item.cell, geom.at(3, 4)));
    }
}

func testPlainFoodIsFoodAtPlain() {
    def a as Item init plainFood(geom.at(1, 2));
    def b as Item init foodAt(PLAIN, geom.at(1, 2));
    testing.assertEqual($a.kind, $b.kind);
    testing.assertEqual($a.life, $b.life);
}

func testFoodIndexAtFindsTheItemUnderACell() {
    def food as list of Item init [plainFood(geom.at(1, 1)), foodAt(CANDY, geom.at(5, 5))];
    testing.assertEqual(foodIndexAt($food, geom.at(5, 5)), 1);
    testing.assertEqual(foodIndexAt($food, geom.at(9, 9)), -1);
    testing.assertEqual(foodIndexAt([], geom.at(0, 0)), -1);
}

func testFoodCountCountsByKind() {
    def g as Game init handMade(20, 10);
    $g.food = [plainFood(geom.at(1, 1)), plainFood(geom.at(2, 2)), foodAt(CANDY, geom.at(3, 3))];
    testing.assertEqual(foodCount($g, PLAIN), 2);
    testing.assertEqual(foodCount($g, CANDY), 1);
    testing.assertEqual(foodCount($g, TOADSTOOL), 0);
}

# --- eating a candy ---------------------------------------------------------

func testACandyAddsThreeSegments() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(CANDY, geom.at(6, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    # One segment of the three arrives with this move; the rest is owed.
    testing.assertEqual(len($s.cells) + $s.grow, 3 + CANDY_BITE);
}

func testACandyIsWorthMoreThanPlainFood() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(CANDY, geom.at(6, 5))];
    def rich as int init snakeById(advance($g), 1).score;
    $g.food = [plainFood(geom.at(6, 5))];
    testing.assertTrue($rich > snakeById(advance($g), 1).score);
}

# --- eating a vegetable ---------------------------------------------------------

func testAVegetablesTakesThreeSegmentsOff() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(8, 5, 8, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(VEGETABLES, geom.at(9, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    testing.assertEqual(len($s.cells), 8 - VEG_BITE);
    testing.assertTrue(geom.equals($s.cells[0], geom.at(9, 5)));
}

func testAVegetablesKillsASnakeWithTooLittleToLose() {
    def g as Game init handMade(20, 10);
    def short as list of geom.Point init [geom.at(5, 5), geom.at(4, 5), geom.at(3, 5)];
    $g = withSnake($g, 1, $short, geom.RIGHT, 0);
    $g.food = [foodAt(VEGETABLES, geom.at(6, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertFalse($s.alive);
    testing.assertEqual($s.deaths, 1);
}

func testAVegetablesLeavesASnakeThatCanJustSpareThem() {
    # Four segments, three taken: one left, still alive. The boundary case.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 4, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(VEGETABLES, geom.at(6, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    testing.assertEqual(len($s.cells), 1);
}

func testAVegetablesDoesNotQuietlyCancelACandy() {
    # A vegetable is three segments off the body now, not "minus three owed": otherwise
    # it would silently undo growth a player had already earned.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(8, 5, 8, geom.RIGHT), geom.RIGHT, 5);
    $g.food = [foodAt(VEGETABLES, geom.at(9, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.grow > 0);
}

# --- eating a toadstool ------------------------------------------------------

func testAToadstoolIsSuddenDeath() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(8, 5, 12, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(TOADSTOOL, geom.at(9, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertFalse($s.alive);
    testing.assertEqual(len($s.cells), 0);
    testing.assertEqual($s.deaths, 1);
    testing.assertEqual($s.respawn, RESPAWN_DELAY);
}

func testAToadstoolKillsHoweverLongTheSnakeIs() {
    for (def length as int init 1; $length <= 10; $length = $length + 3) {
        def g as Game init handMade(20, 10);
        $g = withSnake($g, 1, bodyFacing(8, 5, $length, geom.RIGHT), geom.RIGHT, 0);
        $g.food = [foodAt(TOADSTOOL, geom.at(9, 5))];
        testing.assertFalse(snakeById(advance($g), 1).alive);
    }
}

func testAToadstoolScoresNothing() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 4, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].score = 40;
    $g.food = [foodAt(TOADSTOOL, geom.at(6, 5))];
    testing.assertEqual(snakeById(advance($g), 1).score, 40);
}

func testADeadlyBiteStillFeedsTheField() {
    # Death by toadstool scatters the body like any other death.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(8, 5, 6, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(TOADSTOOL, geom.at(9, 5))];
    testing.assertTrue(foodCount(advance($g), PLAIN) > 0);
}

# --- eating a ghost ----------------------------------------------------------

func testAGhostGrantsItsSpell() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.food = [foodAt(GHOST, geom.at(6, 5))];
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    # One tick of the spell is spent on the move that ate it.
    testing.assertEqual($s.ghost, recipeFor(GHOST).ghost - 1);
}

func testTheSpellRunsOut() {
    def g as Game init handMade(30, 10);
    $g = withSnake($g, 1, bodyFacing(2, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].ghost = 3;
    $g = advance($g);
    testing.assertEqual(snakeById($g, 1).ghost, 2);
    $g = advance($g);
    $g = advance($g);
    testing.assertEqual(snakeById($g, 1).ghost, 0);
}

func testEatingASecondGhostRefreshesRatherThanStacks() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(5, 5, 3, geom.RIGHT), geom.RIGHT, 0);
    $g.snakes[0].ghost = 2;
    $g.food = [foodAt(GHOST, geom.at(6, 5))];
    testing.assertEqual(snakeById(advance($g), 1).ghost, recipeFor(GHOST).ghost - 1);
}

func testAGhostSlipsThroughAnotherSnakesBody() {
    def g as Game init handMade(20, 10);
    def runner as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $runner, geom.RIGHT, 0);
    $g.snakes[0].ghost = 20;
    # A wall of body across the runner's path, growing so its tail stays put.
    $g = withSnake($g, 2, bodyFacing(8, 5, 4, geom.RIGHT), geom.RIGHT, 5);
    def after as Game init advance($g);
    testing.assertTrue(snakeById($after, 1).alive);
    testing.assertTrue(geom.equals(snakeById($after, 1).cells[0], geom.at(5, 5)));
}

func testWithoutTheSpellTheSameMoveIsFatal() {
    # The control for the test above: only the ghost timer differs.
    def g as Game init handMade(20, 10);
    def runner as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $runner, geom.RIGHT, 0);
    $g = withSnake($g, 2, bodyFacing(8, 5, 4, geom.RIGHT), geom.RIGHT, 5);
    testing.assertFalse(snakeById(advance($g), 1).alive);
}

func testAGhostIsStoppedByAnotherSnakesHead() {
    # "the body, not the head": a ghost that met a head would be untouchable.
    def g as Game init handMade(20, 10);
    def runner as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $runner, geom.RIGHT, 0);
    $g.snakes[0].ghost = 20;
    # Another snake's head sits at (5, 5) and is not moving away: its dir points at
    # its own neck, so `intendedHeads` keeps it going right, off the contested cell -
    # but the head cell itself is what the ghost is refused.
    $g = withSnake($g, 2, [geom.at(5, 5), geom.at(5, 6)], geom.UP, 4);
    testing.assertFalse(snakeById(advance($g), 1).alive);
}

func testAGhostStillDiesOnItsOwnBody() {
    def g as Game init handMade(20, 10);
    def coil as list of geom.Point init [
        geom.at(5, 5),
        geom.at(6, 5),
        geom.at(6, 6),
        geom.at(5, 6)
    ];
    $g = withSnake($g, 1, $coil, geom.LEFT, 3);
    $g.snakes[0].ghost = 20;
    $g.snakes[0].dir = geom.DOWN;
    testing.assertFalse(snakeById(advance($g), 1).alive);
}

func testAGhostStillDiesAtAWall() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g.snakes[0].ghost = 20;
    testing.assertFalse(snakeById(advance($g), 1).alive);
}

func testAGhostStillDiesHeadOn() {
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, [geom.at(4, 5)], geom.RIGHT, 0);
    $g.snakes[0].ghost = 20;
    $g = withSnake($g, 2, [geom.at(6, 5)], geom.LEFT, 0);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertFalse(snakeById($after, 2).alive);
}

func testGhostingIsOneDirectional() {
    # A ghost passes through others; others do not pass through the ghost.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, bodyFacing(8, 5, 4, geom.RIGHT), geom.RIGHT, 5);
    $g.snakes[0].ghost = 20;
    $g = withSnake($g, 2, [geom.at(4, 5)], geom.RIGHT, 0);
    testing.assertFalse(snakeById(advance($g), 2).alive);
}

func testDeathEndsTheSpell() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g.snakes[0].ghost = 20;
    testing.assertEqual(snakeById(advance($g), 1).ghost, 0);
}

func testARespawnedSnakeIsNotStillAGhost() {
    def g as Game init handMade(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    $g.snakes[0].ghost = 200;
    for (def t as int init 0; $t <= RESPAWN_DELAY; $t = $t + 1) {
        $g = advance($g);
    }
    def s as Snake init snakeById($g, 1);
    testing.assertTrue($s.alive);
    testing.assertEqual($s.ghost, 0);
}

# --- countdowns --------------------------------------------------------------

func testASpecialCountsDownAndVanishes() {
    # No snakes at all, so the countdown is the only thing that can remove it: with
    # one on the field it would eventually wander over and eat it instead.
    def g as Game init handMade(20, 10);
    $g.food = [foodAt(CANDY, geom.at(15, 2))];
    def life as int init recipeFor(CANDY).life;
    for (def t as int init 0; $t < $life - 1; $t = $t + 1) {
        $g = advance($g);
        testing.assertEqual(foodCount($g, CANDY), 1);
    }
    $g = advance($g);
    testing.assertEqual(foodCount($g, CANDY), 0);
}

func testTheCountdownIsVisibleWhileItRuns() {
    def g as Game init handMade(20, 10);
    $g.food = [foodAt(TOADSTOOL, geom.at(15, 2))];
    def before as int init $g.food[0].life;
    $g = advance($g);
    testing.assertEqual($g.food[foodIndexAt($g.food, geom.at(15, 2))].life, $before - 1);
}

func testPlainFoodNeverExpires() {
    def g as Game init handMade(20, 10);
    $g.food = [plainFood(geom.at(15, 2))];
    for (def t as int init 0; $t < 200; $t = $t + 1) {
        $g = advance($g);
    }
    testing.assertTrue(foodIndexAt($g.food, geom.at(15, 2)) >= 0);
    testing.assertEqual($g.food[foodIndexAt($g.food, geom.at(15, 2))].life, PERMANENT);
}

# --- appearing on their own --------------------------------------------------

func testSpecialsTurnUpOnTheirOwnOverTime() {
    def g as Game init newGame(30, 16, 424242);
    $g = addSnake($g, 1, "ada");
    def seenKinds as map of string to bool init {};
    for (def t as int init 0; $t < 2000; $t = $t + 1) {
        $g = advance($g);
        for (def f in $g.food) {
            $seenKinds[$f.kind] = true;
        }
    }
    for (def kind in SPECIAL_KINDS) {
        testing.assertTrue(maps.has($seenKinds, $kind));
    }
}

func testNoMoreThanOneOfEachSpecialAtATime() {
    def g as Game init newGame(30, 16, 31415);
    $g = addSnake($g, 1, "ada");
    for (def t as int init 0; $t < 600; $t = $t + 1) {
        $g = advance($g);
        for (def kind in SPECIAL_KINDS) {
            testing.assertTrue(foodCount($g, $kind) <= SPECIAL_LIMIT);
        }
        testing.assertTrue(len($g.food) <= MAX_FOOD);
    }
}

func testSpecialsNeverLandOnTopOfAnything() {
    def g as Game init newGame(20, 10, 2718);
    $g = addSnake($g, 1, "ada");
    for (def t as int init 0; $t < 400; $t = $t + 1) {
        $g = advance($g);
        def taken as map of string to bool init {};
        for (def s in $g.snakes) {
            for (def c in $s.cells) {
                $taken[geom.key($c)] = true;
            }
        }
        for (def f in $g.food) {
            testing.assertFalse(maps.has($taken, geom.key($f.cell)));
            testing.assertTrue(geom.inBounds($f.cell, $g.width, $g.height));
            $taken[geom.key($f.cell)] = true;
        }
    }
}

func testAPlainGameHasNoSpecialsAtAll() {
    def g as Game init withoutSpecials(newGame(30, 16, 99));
    $g = addSnake($g, 1, "ada");
    for (def t as int init 0; $t < 800; $t = $t + 1) {
        $g = advance($g);
        for (def kind in SPECIAL_KINDS) {
            testing.assertEqual(foodCount($g, $kind), 0);
        }
    }
    testing.assertTrue(foodCount($g, PLAIN) > 0);
}

func testWithoutSpecialsClearsTheOnesAlreadyThere() {
    def g as Game init newGame(20, 10, 1);
    $g.food = [plainFood(geom.at(1, 1)), foodAt(CANDY, geom.at(2, 2))];
    def plain as Game init withoutSpecials($g);
    testing.assertFalse($plain.specials);
    testing.assertEqual(foodCount($plain, CANDY), 0);
    testing.assertEqual(foodCount($plain, PLAIN), 1);
}

func testSpecialsAreStillReproducibleFromTheSeed() {
    def a as Game init addSnake(newGame(24, 12, 5150), 1, "ada");
    def b as Game init addSnake(newGame(24, 12, 5150), 1, "ada");
    for (def t as int init 0; $t < 300; $t = $t + 1) {
        $a = advance($a);
        $b = advance($b);
    }
    testing.assertEqual(len($a.food), len($b.food));
    for (def i as int init 0; $i < len($a.food); $i = $i + 1) {
        testing.assertEqual($a.food[$i].kind, $b.food[$i].kind);
        testing.assertEqual($a.food[$i].life, $b.food[$i].life);
        testing.assertTrue(geom.equals($a.food[$i].cell, $b.food[$i].cell));
    }
}

func testAGameWithSpecialsSurvivesBeingPlayedHard() {
    # Six snakes steered at random for 400 ticks with every special in play: no
    # snake off the field, no two in one cell, no food on top of anything.
    def g as Game init newGame(26, 14, 20260929);
    for (def i as int init 1; $i <= 6; $i = $i + 1) {
        $g = addSnake($g, $i, "p" + convert.toString($i));
    }
    for (def t as int init 0; $t < 400; $t = $t + 1) {
        for (def i as int init 1; $i <= 6; $i = $i + 1) {
            def r as Roll init roll($g.seed + $t + $i, len(geom.DIRECTIONS));
            $g = setDirection($g, $i, geom.DIRECTIONS[$r.value]);
        }
        $g = advance($g);
        def taken as map of string to bool init {};
        for (def s in $g.snakes) {
            testing.assertTrue($s.ghost >= 0);
            for (def c in $s.cells) {
                testing.assertTrue(geom.inBounds($c, $g.width, $g.height));
                testing.assertFalse(maps.has($taken, geom.key($c)));
                $taken[geom.key($c)] = true;
            }
        }
        for (def f in $g.food) {
            testing.assertTrue(isFoodKind($f.kind));
            testing.assertTrue(geom.inBounds($f.cell, $g.width, $g.height));
        }
    }
    testing.assertEqual($g.tick, 400);
}

func testASpecialCannotAppearWithNowhereToPutIt() {
    # Every cell is body and a special's number comes up: the field is left alone
    # rather than the item being dropped on top of a snake.
    def g as Game init handMade(10, 6);
    $g.specials = true;
    def every as list of geom.Point init [];
    for (def y as int init 0; $y < 6; $y = $y + 1) {
        for (def x as int init 0; $x < 10; $x = $x + 1) {
            $every[] = geom.at($x, $y);
        }
    }
    $g = withSnake($g, 1, $every, geom.RIGHT, 99);
    def before as int init len($g.food);
    for (def t as int init 0; $t < 200; $t = $t + 1) {
        $g = spawnSpecials($g);
    }
    testing.assertEqual(len($g.food), $before);
}

# --- lives and spectators ----------------------------------------------------

# counted is a game where lives are counted, so a snake can run out of them.
func counted(width as int, height as int, lives as int) {
    def g as Game init handMade($width, $height);
    return withLives($g, $lives);
}

# suicidal puts a snake one move from the left wall, so `advance` kills it.
func suicidal(g as Game, id as int) {
    def one as list of geom.Point init [geom.at(0, 5)];
    return withSnake($g, $id, $one, geom.LEFT, 0);
}

func testLivesOrClampsWhatAHostAsksFor() {
    testing.assertEqual(livesOr(3), 3);
    testing.assertEqual(livesOr(1), 1);
    testing.assertEqual(livesOr(MAX_LIVES), MAX_LIVES);
    testing.assertEqual(livesOr(99), MAX_LIVES);
    testing.assertEqual(livesOr(-4), 1);
}

func testUnlimitedLivesPassesThroughUntouched() {
    # Zero is a setting, not a mistake: it is the endless game.
    testing.assertEqual(livesOr(UNLIMITED_LIVES), UNLIMITED_LIVES);
}

func testANewGameCountsLivesByDefault() {
    def g as Game init newGame(20, 10, 1);
    testing.assertEqual($g.lives, DEFAULT_LIVES);
    testing.assertTrue($g.lives > 0);
}

func testWithLivesSetsTheGameAndEveryoneOnIt() {
    def g as Game init newGame(20, 10, 1);
    $g = addSnake($g, 1, "ada");
    $g = addSnake($g, 2, "bob");
    $g = withLives($g, 5);
    testing.assertEqual($g.lives, 5);
    testing.assertEqual(snakeById($g, 1).lives, 5);
    testing.assertEqual(snakeById($g, 2).lives, 5);
}

func testANewPlayerGetsTheGamesLives() {
    def g as Game init withLives(newGame(20, 10, 1), 2);
    $g = addSnake($g, 1, "ada");
    testing.assertEqual(snakeById($g, 1).lives, 2);
}

func testDyingSpendsALife() {
    def g as Game init suicidal(counted(20, 10, 3), 1);
    def after as Game init advance($g);
    testing.assertEqual(snakeById($after, 1).lives, 2);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertEqual(snakeById($after, 1).respawn, RESPAWN_DELAY);
    testing.assertFalse(isSpectator($after, snakeById($after, 1)));
}

func testASnakeWithLivesLeftStillComesBack() {
    def g as Game init suicidal(counted(20, 10, 3), 1);
    for (def t as int init 0; $t <= RESPAWN_DELAY; $t = $t + 1) {
        $g = advance($g);
    }
    def s as Snake init snakeById($g, 1);
    testing.assertTrue($s.alive);
    testing.assertEqual($s.lives, 2);
}

func testTheLastLifeMakesASpectator() {
    def g as Game init suicidal(counted(20, 10, 1), 1);
    def after as Game init advance($g);
    def s as Snake init snakeById($after, 1);
    testing.assertEqual($s.lives, 0);
    testing.assertFalse($s.alive);
    testing.assertTrue(isSpectator($after, $s));
    # No countdown, because there is nothing to count down to.
    testing.assertEqual($s.respawn, 0);
}

func testASpectatorNeverComesBack() {
    # The whole point: a respawn of 0 must not be read as "due now".
    def g as Game init suicidal(counted(20, 10, 1), 1);
    for (def t as int init 0; $t < RESPAWN_DELAY * 4; $t = $t + 1) {
        $g = advance($g);
        def s as Snake init snakeById($g, 1);
        testing.assertFalse($s.alive);
        testing.assertEqual(len($s.cells), 0);
        testing.assertTrue(isSpectator($g, $s));
    }
}

func testEveryLifeIsSpentInTurn() {
    # `kill` rather than a wall: a respawn lands at a random free cell, so steering into
    # a wall again is not reliable, and this test is about the lives, not the geometry.
    def g as Game init withSnake(
        counted(20, 10, 3),
        1,
        bodyFacing(5, 5, 3, geom.RIGHT),
        geom.RIGHT,
        0);
    for (def life as int init 3; $life > 0; $life = $life - 1) {
        testing.assertEqual(snakeById($g, 1).lives, $life);
        testing.assertTrue(hasLivesLeft($g, snakeById($g, 1)));
        $g = kill($g, 0);
        testing.assertEqual(snakeById($g, 1).lives, $life - 1);
        for (def t as int init 0; $t <= RESPAWN_DELAY; $t = $t + 1) {
            $g = advance($g);
        }
    }
    testing.assertTrue(isSpectator($g, snakeById($g, 1)));
    testing.assertEqual(snakeById($g, 1).deaths, 3);
    testing.assertEqual(snakeById($g, 1).lives, 0);
}

func testASpectatorKeepsItsSeatAndItsScore() {
    def g as Game init suicidal(counted(20, 10, 1), 1);
    $g.snakes[0].score = 120;
    def after as Game init advance($g);
    testing.assertEqual(len($after.snakes), 1);
    testing.assertTrue(hasSnake($after, 1));
    testing.assertEqual(snakeById($after, 1).score, 120);
    testing.assertEqual(snakeById($after, 1).name, "p1");
}

func testASpectatorStillFeedsTheFieldOnItsWayOut() {
    def g as Game init withSnake(
        counted(20, 10, 1),
        1,
        bodyFacing(0, 5, 6, geom.LEFT),
        geom.LEFT,
        0);
    testing.assertTrue(foodCount(advance($g), PLAIN) > 0);
}

func testASpectatorIsNoObstacle() {
    def g as Game init counted(20, 10, 1);
    def runner as list of geom.Point init [geom.at(4, 5)];
    $g = withSnake($g, 1, $runner, geom.RIGHT, 0);
    $g = withSnake($g, 2, [geom.at(5, 5)], geom.UP, 0);
    $g.snakes[1].alive = false;
    $g.snakes[1].cells = [];
    $g.snakes[1].lives = 0;
    testing.assertTrue(snakeById(advance($g), 1).alive);
}

func testUnlimitedLivesNeverRunsOut() {
    def g as Game init withSnake(
        withLives(handMade(20, 10), UNLIMITED_LIVES),
        1,
        bodyFacing(5, 5, 3, geom.RIGHT),
        geom.RIGHT,
        0);
    for (def round as int init 0; $round < 5; $round = $round + 1) {
        $g = kill($g, 0);
        testing.assertFalse(isSpectator($g, snakeById($g, 1)));
        for (def t as int init 0; $t <= RESPAWN_DELAY; $t = $t + 1) {
            $g = advance($g);
        }
        testing.assertTrue(snakeById($g, 1).alive);
    }
    def s as Snake init snakeById($g, 1);
    testing.assertTrue(hasLivesLeft($g, $s));
    testing.assertEqual($s.lives, UNLIMITED_LIVES);
    testing.assertEqual($s.deaths, 5);
}

func testUnlimitedLivesNeverDecrementsTheCounter() {
    def g as Game init suicidal(withLives(handMade(20, 10), UNLIMITED_LIVES), 1);
    testing.assertEqual(advance($g).snakes[0].lives, UNLIMITED_LIVES);
}

# --- who is still in the game ------------------------------------------------

func testContendersCountsEveryoneWithALifeLeft() {
    def g as Game init counted(20, 10, 2);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = suicidal($g, 2);
    testing.assertEqual(contenders($g), 2);
    $g = advance($g);
    testing.assertEqual(contenders($g), 2);
}

func testASpectatorIsNotAContender() {
    def g as Game init suicidal(counted(20, 10, 1), 1);
    testing.assertEqual(contenders($g), 1);
    testing.assertEqual(contenders(advance($g)), 0);
}

func testAGameIsOverWhenEverybodyIsOut() {
    def g as Game init suicidal(counted(20, 10, 1), 1);
    testing.assertFalse(isOver($g));
    testing.assertTrue(isOver(advance($g)));
}

func testAGameIsNotOverWhileSomebodyHasALifeLeft() {
    def g as Game init counted(20, 10, 1);
    $g = withSnake($g, 1, bodyFacing(5, 5, 2, geom.RIGHT), geom.RIGHT, 0);
    $g = suicidal($g, 2);
    testing.assertFalse(isOver(advance($g)));
}

func testAnEmptyGameIsNotOver() {
    # Nobody has lost; the host is simply waiting for players.
    testing.assertFalse(isOver(counted(20, 10, 3)));
}

func testAnEndlessGameIsNeverOver() {
    def g as Game init suicidal(withLives(handMade(20, 10), UNLIMITED_LIVES), 1);
    for (def t as int init 0; $t < 40; $t = $t + 1) {
        $g = advance($g);
        testing.assertFalse(isOver($g));
    }
}

func testTheFieldStillTicksWithOnlySpectatorsOnIt() {
    # A finished game must not be a broken one: food still replenishes, nothing throws.
    def g as Game init suicidal(counted(20, 10, 1), 1);
    for (def t as int init 0; $t < 30; $t = $t + 1) {
        $g = advance($g);
    }
    testing.assertTrue(isOver($g));
    testing.assertTrue(foodCount($g, PLAIN) >= 1);
    testing.assertEqual(aliveCount($g), 0);
}

func testAGameWithLivesPlaysToAFinish() {
    # Six players steered at random on a small field with two lives each: the game must
    # reach a finish and stay consistent all the way there.
    def g as Game init withLives(newGame(14, 8, 20260929), 2);
    for (def i as int init 1; $i <= 6; $i = $i + 1) {
        $g = addSnake($g, $i, "p" + convert.toString($i));
    }
    for (def t as int init 0; $t < 600 and not isOver($g); $t = $t + 1) {
        for (def i as int init 1; $i <= 6; $i = $i + 1) {
            def r as Roll init roll($g.seed + $t + $i, len(geom.DIRECTIONS));
            $g = setDirection($g, $i, geom.DIRECTIONS[$r.value]);
        }
        $g = advance($g);
        for (def s in $g.snakes) {
            testing.assertTrue($s.lives >= 0);
            testing.assertTrue($s.lives <= 2);
            if (isSpectator($g, $s)) {
                testing.assertEqual(len($s.cells), 0);
            }
        }
    }
    testing.assertTrue(isOver($g));
    testing.assertEqual(len($g.snakes), 6);
    for (def s in $g.snakes) {
        testing.assertEqual($s.lives, 0);
        testing.assertEqual($s.deaths, 2);
    }
}

# --- wrapped edges -----------------------------------------------------------

# wrapped is a game with no walls: a step off one edge arrives at the other.
func wrapped(width as int, height as int) {
    return withWrap(handMade($width, $height), true);
}

func testAWallsGameDoesNotWrapByDefault() {
    testing.assertFalse(newGame(20, 10, 1).wrap);
    testing.assertFalse(handMade(20, 10).wrap);
}

func testWithWrapSwitchesTheBorderRule() {
    testing.assertTrue(withWrap(handMade(20, 10), true).wrap);
    testing.assertFalse(withWrap(wrapped(20, 10), false).wrap);
}

func testDestinationWrapsOnlyWhenTheGameDoes() {
    def walls as Game init handMade(20, 10);
    def open as Game init wrapped(20, 10);
    testing.assertTrue(geom.equals(destination($walls, geom.at(0, 5), geom.LEFT), geom.at(-1, 5)));
    testing.assertTrue(geom.equals(destination($open, geom.at(0, 5), geom.LEFT), geom.at(19, 5)));
}

func testDestinationLeavesAnInteriorStepAlone() {
    for (def g in [handMade(20, 10), wrapped(20, 10)]) {
        testing.assertTrue(geom.equals(destination($g, geom.at(5, 5), geom.RIGHT), geom.at(6, 5)));
    }
}

func testASnakeWalksThroughTheLeftEdge() {
    def g as Game init wrapped(20, 10);
    def one as list of geom.Point init [geom.at(0, 5)];
    $g = withSnake($g, 1, $one, geom.LEFT, 0);
    def s as Snake init snakeById(advance($g), 1);
    testing.assertTrue($s.alive);
    testing.assertTrue(geom.equals($s.cells[0], geom.at(19, 5)));
}

func testASnakeWalksThroughEveryEdge() {
    def g as Game init wrapped(20, 10);
    $g = withSnake($g, 1, [geom.at(0, 5)], geom.LEFT, 0);
    $g = withSnake($g, 2, [geom.at(19, 2)], geom.RIGHT, 0);
    $g = withSnake($g, 3, [geom.at(7, 0)], geom.UP, 0);
    $g = withSnake($g, 4, [geom.at(11, 9)], geom.DOWN, 0);
    def after as Game init advance($g);
    testing.assertTrue(geom.equals(snakeById($after, 1).cells[0], geom.at(19, 5)));
    testing.assertTrue(geom.equals(snakeById($after, 2).cells[0], geom.at(0, 2)));
    testing.assertTrue(geom.equals(snakeById($after, 3).cells[0], geom.at(7, 9)));
    testing.assertTrue(geom.equals(snakeById($after, 4).cells[0], geom.at(11, 0)));
    for (def s in $after.snakes) {
        testing.assertTrue($s.alive);
    }
}

func testTheSameMoveIsFatalWithWalls() {
    # The control: only the border rule differs.
    def g as Game init handMade(20, 10);
    $g = withSnake($g, 1, [geom.at(0, 5)], geom.LEFT, 0);
    testing.assertFalse(snakeById(advance($g), 1).alive);
}

func testWrappingAroundStillHitsABody() {
    # The edges are open; the snakes are not. A head coming through the left edge into a
    # body parked there still dies.
    def g as Game init wrapped(20, 10);
    $g = withSnake($g, 1, [geom.at(0, 5)], geom.LEFT, 0);
    $g = withSnake($g, 2, bodyFacing(19, 5, 4, geom.UP), geom.UP, 5);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
}

func testWrappingAroundStillMeetsAHeadOn() {
    def g as Game init wrapped(20, 10);
    $g = withSnake($g, 1, [geom.at(0, 5)], geom.LEFT, 0);
    $g = withSnake($g, 2, [geom.at(18, 5)], geom.RIGHT, 0);
    def after as Game init advance($g);
    testing.assertFalse(snakeById($after, 1).alive);
    testing.assertFalse(snakeById($after, 2).alive);
}

func testASnakeStaysConnectedThroughAnEdge() {
    # The body follows the head round, so the cells are contiguous *on the wrapped
    # field* - the two ends of a crossing are adjacent, not nineteen apart.
    def g as Game init wrapped(20, 10);
    $g = withSnake($g, 1, bodyFacing(1, 5, 3, geom.LEFT), geom.LEFT, 0);
    $g = advance($g);
    $g = advance($g);
    def cells as list of geom.Point init snakeById($g, 1).cells;
    for (def i as int init 1; $i < len($cells); $i = $i + 1) {
        def stepped as bool init false;
        for (def d in geom.DIRECTIONS) {
            if (geom.equals(destination($g, $cells[$i], $d), $cells[$i - 1])) {
                $stepped = true;
            }
        }
        testing.assertTrue($stepped);
    }
}

func testASnakeCanChaseItsTailThroughAnEdge() {
    def g as Game init wrapped(6, 6);
    def ring as list of geom.Point init [
        geom.at(0, 2),
        geom.at(1, 2),
        geom.at(1, 3),
        geom.at(0, 3)
    ];
    $g = withSnake($g, 1, $ring, geom.LEFT, 0);
    $g.snakes[0].dir = geom.DOWN;
    testing.assertTrue(snakeById(advance($g), 1).alive);
}

func testANewSnakeOnAWrappedFieldFacesSomewhereUsable() {
    def g as Game init withWrap(newGame(12, 6, 3), true);
    for (def i as int init 1; $i <= 4; $i = $i + 1) {
        $g = addSnake($g, $i, "p");
        def s as Snake init snakeById($g, $i);
        def ahead as geom.Point init destination($g, $s.cells[0], $s.dir);
        testing.assertTrue(geom.inBounds($ahead, $g.width, $g.height));
    }
}

func testAWrappedGameSurvivesBeingPlayedHard() {
    # Nobody can die at a wall, so the only deaths are collisions - and the field must
    # stay consistent with cells crossing the edges constantly.
    def g as Game init withWrap(withLives(newGame(16, 10, 20260929), UNLIMITED_LIVES), true);
    for (def i as int init 1; $i <= 5; $i = $i + 1) {
        $g = addSnake($g, $i, "p" + convert.toString($i));
    }
    for (def t as int init 0; $t < 300; $t = $t + 1) {
        for (def i as int init 1; $i <= 5; $i = $i + 1) {
            def r as Roll init roll($g.seed + $t + $i, len(geom.DIRECTIONS));
            $g = setDirection($g, $i, geom.DIRECTIONS[$r.value]);
        }
        $g = advance($g);
        def taken as map of string to bool init {};
        for (def s in $g.snakes) {
            for (def c in $s.cells) {
                testing.assertTrue(geom.inBounds($c, $g.width, $g.height));
                testing.assertFalse(maps.has($taken, geom.key($c)));
                $taken[geom.key($c)] = true;
            }
        }
    }
    testing.assertEqual($g.tick, 300);
}

func testWrappingIsReproducibleFromTheSeed() {
    def a as Game init addSnake(withWrap(newGame(20, 10, 4242), true), 1, "ada");
    def b as Game init addSnake(withWrap(newGame(20, 10, 4242), true), 1, "ada");
    for (def t as int init 0; $t < 60; $t = $t + 1) {
        $a = advance($a);
        $b = advance($b);
    }
    testing.assertEqual($a.seed, $b.seed);
    testing.assertEqual(len(snakeById($a, 1).cells), len(snakeById($b, 1).cells));
}
