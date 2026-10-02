# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for bot.j. Because `choose` is pure, a computer player can be
# put in an exact situation - this wall here, that food there - and its decision
# asserted. The interesting tests are the ones that pin down what separates the
# difficulty levels, since that is the part a player actually feels. Run with:
#
#     jennifer test src/bot_test.j

use testing;
use strings;

import "./proto.j" as proto;

# field builds a game with no food and no snakes, sized for the tests below.
# Specials are off: these tests put the food they mean to test exactly where they
# want it, and one appearing by chance would make a decision test ambiguous.
func field(width as int, height as int) {
    return rules.Game{
        width: $width,
        height: $height,
        snakes: [],
        food: [],
        tick: 0,
        seed: 1,
        specials: false,
        lives: rules.UNLIMITED_LIVES,
        wrap: false,
        round: 1
    };
}

# put adds a living snake with an exact body, head first.
func put(g as rules.Game, id as int, cells as list of geom.Point, dir as string) {
    def out as rules.Game init $g;
    def snakes as list of rules.Snake init $out.snakes;
    $snakes[] = rules.Snake{
        id: $id,
        name: "s",
        cells: $cells,
        dir: $dir,
        alive: true,
        score: 0,
        deaths: 0,
        respawn: 0,
        grow: 0,
        ghost: 0,
        lives: rules.UNLIMITED_LIVES
    };
    $out.snakes = $snakes;
    return $out;
}

# trail is a straight body of `n` cells whose head is at (x, y), facing `dir`.
func trail(x as int, y as int, n as int, dir as string) {
    def cells as list of geom.Point init [];
    def cell as geom.Point init geom.at($x, $y);
    for (def i as int init 0; $i < $n; $i = $i + 1) {
        $cells[] = $cell;
        $cell = geom.step($cell, geom.opposite($dir));
    }
    return $cells;
}

# wall is a body laid out as a barrier along a run of cells.
func wall(cells as list of geom.Point) {
    return $cells;
}

# pick is the direction a level chooses, for brevity in the assertions.
func pick(g as rules.Game, id as int, level as string, seed as int) {
    return choose($g, $id, $level, $seed).dir;
}

# --- the level vocabulary ----------------------------------------------------

func testEveryLevelIsRecognised() {
    for (def level in LEVELS) {
        testing.assertTrue(isLevel($level));
    }
    testing.assertEqual(len(LEVELS), 4);
}

func testTheLevelsAreOrderedEasiestFirst() {
    testing.assertEqual(LEVELS[0], EASY);
    testing.assertEqual(LEVELS[len(LEVELS) - 1], EXPERT);
}

func testAnUnknownLevelIsNotRecognised() {
    testing.assertFalse(isLevel(""));
    testing.assertFalse(isLevel("impossible"));
    testing.assertFalse(isLevel("EASY"));
}

func testLevelOrFallsBackRatherThanFailing() {
    testing.assertEqual(levelOr("nonsense"), DEFAULT_LEVEL);
    testing.assertEqual(levelOr(""), DEFAULT_LEVEL);
    testing.assertEqual(levelOr(HARD), HARD);
}

func testTheDefaultLevelIsAResilientOne() {
    testing.assertTrue(isLevel(DEFAULT_LEVEL));
}

# --- openSpace ---------------------------------------------------------------

func testOpenSpaceCountsAWholeEmptyField() {
    def g as rules.Game init field(4, 3);
    def taken as map of int to bool init {};
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, 100), 12);
}

func testOpenSpaceStopsAtItsLimit() {
    # The bound is the point: the question is "is there enough room", not "how much".
    def g as rules.Game init field(20, 20);
    def taken as map of int to bool init {};
    testing.assertEqual(openSpace($g, geom.at(10, 10), $taken, 7), 7);
}

func testOpenSpaceCountsOnlyWhatIsReachable() {
    # A wall down the middle of a 5-wide field leaves two columns on the left.
    def g as rules.Game init field(5, 3);
    def taken as map of int to bool init {};
    for (def y as int init 0; $y < 3; $y = $y + 1) {
        $taken[geom.index(geom.at(2, $y), 5)] = true;
    }
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, 100), 6);
    testing.assertEqual(openSpace($g, geom.at(4, 0), $taken, 100), 6);
}

func testOpenSpaceOfASealedPocketIsJustThePocket() {
    def g as rules.Game init field(6, 5);
    def taken as map of int to bool init {};
    for (def c in [geom.at(1, 1), geom.at(1, 2), geom.at(1, 3), geom.at(2, 1), geom.at(2, 3)]) {
        $taken[geom.index($c, 6)] = true;
    }
    # (2, 2) is walled left, up and down; only (3, 2) and beyond remain, so the
    # pocket is not sealed - it opens rightwards into the rest of the field.
    testing.assertTrue(openSpace($g, geom.at(2, 2), $taken, 100) > 5);
}

func testOpenSpaceOfAOneCellPocketIsOne() {
    def g as rules.Game init field(6, 5);
    def taken as map of int to bool init {};
    for (def c in [geom.at(1, 2), geom.at(3, 2), geom.at(2, 1), geom.at(2, 3)]) {
        $taken[geom.index($c, 6)] = true;
    }
    testing.assertEqual(openSpace($g, geom.at(2, 2), $taken, 100), 1);
}

func testOpenSpaceOffTheFieldIsZero() {
    def g as rules.Game init field(4, 4);
    def taken as map of int to bool init {};
    testing.assertEqual(openSpace($g, geom.at(-1, 0), $taken, 10), 0);
    testing.assertEqual(openSpace($g, geom.at(4, 0), $taken, 10), 0);
}

func testOpenSpaceWithNoBudgetIsZero() {
    def g as rules.Game init field(4, 4);
    def taken as map of int to bool init {};
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, 0), 0);
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, -3), 0);
}

func testOpenSpaceCountsTheStartingCell() {
    def g as rules.Game init field(1, 1);
    def taken as map of int to bool init {};
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, 10), 1);
}

# --- survey ------------------------------------------------------------------

func testSurveySeesEveryLivingBody() {
    def g as rules.Game init put(field(10, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    def f as Field init survey($g);
    testing.assertTrue(maps.has($f.taken, geom.index(geom.at(5, 3), 10)));
    testing.assertTrue(maps.has($f.taken, geom.index(geom.at(3, 3), 10)));
    testing.assertFalse(maps.has($f.taken, geom.index(geom.at(8, 3), 10)));
}

func testSurveyIgnoresADeadBody() {
    def g as rules.Game init put(field(10, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    $g.snakes[0].alive = false;
    testing.assertEqual(len(survey($g).taken), 0);
}

func testSurveyKnowsWhereEachHeadIsGoing() {
    def g as rules.Game init put(field(10, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    def f as Field init survey($g);
    testing.assertEqual($f.heads[1], geom.index(geom.at(6, 3), 10));
}

func testChooseAndChooseInAgree() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(8, 3))];
    for (def level in LEVELS) {
        testing.assertEqual(
            choose($g, 1, $level, 7).dir,
            chooseIn($g, 1, $level, 7, survey($g)).dir);
    }
}

# --- what every level does ---------------------------------------------------

func testNoLevelEverReversesIntoItsOwnNeck() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 4, geom.RIGHT), geom.RIGHT);
    for (def level in LEVELS) {
        for (def seed as int init 1; $seed < 30; $seed = $seed + 1) {
            testing.assertNotEqual(pick($g, 1, $level, $seed), geom.LEFT);
        }
    }
}

func testNoLevelDrivesIntoAWallWhenItNeedNot() {
    # Head at the right edge facing right: the only survivable moves are up and down.
    def g as rules.Game init put(field(12, 6), 1, trail(11, 3, 3, geom.RIGHT), geom.RIGHT);
    for (def level in LEVELS) {
        for (def seed as int init 1; $seed < 30; $seed = $seed + 1) {
            def d as string init pick($g, 1, $level, $seed);
            testing.assertTrue($d == geom.UP or $d == geom.DOWN);
        }
    }
}

func testNoLevelDrivesIntoABodyWhenItNeedNot() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    # A wall straight ahead and below; up is the only way out.
    $g = put($g, 2, wall([geom.at(6, 3), geom.at(6, 4), geom.at(5, 4)]), geom.UP);
    for (def level in LEVELS) {
        for (def seed as int init 1; $seed < 30; $seed = $seed + 1) {
            testing.assertEqual(pick($g, 1, $level, $seed), geom.UP);
        }
    }
}

func testEveryLevelAnswersWithARealDirection() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    for (def level in LEVELS) {
        testing.assertTrue(geom.isDirection(pick($g, 1, $level, 3)));
    }
}

func testABoxedInSnakeStillAnswers() {
    # Every way out is fatal. A host calls this every tick regardless, so it must
    # not throw and must not return nonsense.
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 2, geom.RIGHT), geom.RIGHT);
    $g = put($g, 2, wall([geom.at(6, 3), geom.at(5, 2), geom.at(5, 4)]), geom.UP);
    for (def level in LEVELS) {
        testing.assertTrue(geom.isDirection(pick($g, 1, $level, 5)));
    }
}

func testChoosingIsDeterministicForOneSeed() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(9, 1))];
    for (def level in LEVELS) {
        def a as Decision init choose($g, 1, $level, 12345);
        def b as Decision init choose($g, 1, $level, 12345);
        testing.assertEqual($a.dir, $b.dir);
        testing.assertEqual($a.seed, $b.seed);
    }
}

func testChoosingAdvancesTheSeed() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.RIGHT);
    testing.assertNotEqual(choose($g, 1, NORMAL, 99).seed, 99);
}

func testChoosingForAnAbsentPlayerIsHarmless() {
    def g as rules.Game init field(12, 6);
    testing.assertTrue(geom.isDirection(choose($g, 7, EXPERT, 1).dir));
}

func testChoosingForADeadPlayerKeepsItsHeading() {
    def g as rules.Game init put(field(12, 6), 1, trail(5, 3, 3, geom.RIGHT), geom.DOWN);
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    testing.assertEqual(choose($g, 1, EXPERT, 1).dir, geom.DOWN);
}

func testASnakeMayChaseItsOwnVacatingTail() {
    # The tightest legal turn on the board: the tail moves off as the head arrives.
    # A bot that refused it would give up the one escape a coiled snake has.
    def g as rules.Game init field(12, 6);
    def coil as list of geom.Point init [
        geom.at(5, 3),
        geom.at(6, 3),
        geom.at(6, 4),
        geom.at(5, 4)
    ];
    $g = put($g, 1, $coil, geom.LEFT);
    $g.snakes[0].dir = geom.DOWN;
    $g = put($g, 2, wall([geom.at(4, 3), geom.at(5, 2)]), geom.UP);
    # Left and up are body or wall, right would reverse; down is the vacating tail.
    testing.assertEqual(pick($g, 1, HARD, 4), geom.DOWN);
}

# --- what the levels do differently -----------------------------------------

func testEasyIgnoresFoodAndNormalChasesIt() {
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(6, 4))];
    # Food is straight ahead, so a food-seeking level goes straight at it.
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.RIGHT);
    testing.assertEqual(pick($g, 1, HARD, 3), geom.RIGHT);
    testing.assertEqual(pick($g, 1, EXPERT, 3), geom.RIGHT);
    # Easy has three safe moves and no reason to prefer any, so over many seeds it
    # uses more than one - which is what "ignores food" looks like from outside.
    def seen as map of string to bool init {};
    for (def seed as int init 1; $seed < 60; $seed = $seed + 1) {
        $seen[pick($g, 1, EASY, $seed)] = true;
    }
    testing.assertTrue(len($seen) > 1);
}

func testAFoodSeekingLevelTurnsTowardsFoodOffToOneSide() {
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(5, 0))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.UP);
    $g.food = [rules.plainFood(geom.at(5, 8))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.DOWN);
}

func testHardRefusesAPocketThatNormalWalksInto() {
    # This is the whole difference between normal and hard: room to think.
    # Food sits in a one-cell dead end. Normal takes the bait; hard does not.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 4, geom.RIGHT), geom.RIGHT);
    $g = put($g, 2, wall([geom.at(7, 4), geom.at(6, 3), geom.at(6, 5)]), geom.UP);
    $g.food = [rules.plainFood(geom.at(6, 4))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.RIGHT);
    def careful as string init pick($g, 1, HARD, 3);
    testing.assertTrue($careful == geom.UP or $careful == geom.DOWN);
    def expert as string init pick($g, 1, EXPERT, 3);
    testing.assertTrue($expert == geom.UP or $expert == geom.DOWN);
}

func testHardStillEntersARoomyGap() {
    # The room check must not make hard refuse every gap, only the fatal ones.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(8, 4))];
    testing.assertEqual(pick($g, 1, HARD, 3), geom.RIGHT);
}

func testExpertRefusesAHeadOnThatHardAccepts() {
    # The difference between hard and expert: expert watches the other heads.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g = put($g, 2, trail(7, 4, 3, geom.LEFT), geom.LEFT);
    $g.food = [rules.plainFood(geom.at(6, 4))];
    testing.assertEqual(pick($g, 1, HARD, 3), geom.RIGHT);
    def wary as string init pick($g, 1, EXPERT, 3);
    testing.assertTrue($wary == geom.UP or $wary == geom.DOWN);
}

func testExpertStillTakesFoodNobodyIsContesting() {
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g = put($g, 2, trail(2, 8, 3, geom.LEFT), geom.LEFT);
    $g.food = [rules.plainFood(geom.at(6, 4))];
    testing.assertEqual(pick($g, 1, EXPERT, 3), geom.RIGHT);
}

# --- they actually play ------------------------------------------------------

# solo runs one bot alone for `ticks` ticks and reports how often it died.
func solo(level as string, ticks as int, seed as int) {
    def g as rules.Game init rules.newGame(24, 12, $seed);
    $g = rules.addSnake($g, 1, "cpu");
    def state as int init $seed + 7;
    for (def t as int init 0; $t < $ticks; $t = $t + 1) {
        def d as Decision init choose($g, 1, $level, $state);
        $state = $d.seed;
        $g = rules.setDirection($g, 1, $d.dir);
        $g = rules.advance($g);
    }
    return rules.snakeById($g, 1);
}

func testANormalBotScoresRatherThanWandering() {
    testing.assertTrue(solo(NORMAL, 120, 4242).score > 0);
}

func testACarefulBotSurvivesALongGame() {
    # 200 ticks with no walls but its own body: the room check is what keeps it
    # alive, and a regression in it shows up here as deaths.
    def s as rules.Snake init solo(HARD, 200, 20260929);
    testing.assertEqual($s.deaths, 0);
    testing.assertTrue($s.score > 0);
}

func testAnExpertBotSurvivesALongGame() {
    def s as rules.Snake init solo(EXPERT, 200, 20260929);
    testing.assertEqual($s.deaths, 0);
    testing.assertTrue($s.score > 0);
}

func testACarefulBotOutscoresAWanderer() {
    # Over the same field and the same number of ticks, the ladder should show.
    testing.assertTrue(solo(HARD, 150, 777).score >= solo(EASY, 150, 777).score);
}

func testAFieldFullOfBotsStaysConsistent() {
    def g as rules.Game init rules.newGame(24, 12, 31337);
    def seeds as list of int init [];
    for (def i as int init 1; $i <= rules.MAX_PLAYERS; $i = $i + 1) {
        $g = rules.addSnake($g, $i, nameFor(EXPERT, $i));
        $seeds[] = $i * 101;
    }
    for (def t as int init 0; $t < 60; $t = $t + 1) {
        def f as Field init survey($g);
        for (def i as int init 1; $i <= rules.MAX_PLAYERS; $i = $i + 1) {
            def d as Decision init chooseIn($g, $i, EXPERT, $seeds[$i - 1], $f);
            $seeds[$i - 1] = $d.seed;
            $g = rules.setDirection($g, $i, $d.dir);
        }
        $g = rules.advance($g);
        def taken as map of string to bool init {};
        for (def s in $g.snakes) {
            for (def c in $s.cells) {
                testing.assertTrue(geom.inBounds($c, $g.width, $g.height));
                testing.assertFalse(maps.has($taken, geom.key($c)));
                $taken[geom.key($c)] = true;
            }
        }
    }
    testing.assertEqual($g.tick, 60);
}

# --- naming ------------------------------------------------------------------

func testBotNamesSayWhatTheyAre() {
    def name as string init nameFor(HARD, 2);
    testing.assertTrue(strings.contains($name, "cpu"));
    testing.assertTrue(strings.contains($name, "2"));
    testing.assertTrue(strings.contains($name, HARD));
}

func testBotNamesFitTheProtocol() {
    for (def level in LEVELS) {
        for (def n as int init 1; $n <= rules.MAX_PLAYERS; $n = $n + 1) {
            def name as string init nameFor($level, $n);
            testing.assertEqual(proto.cleanName($name), $name);
        }
    }
}

func testBotNamesAreDistinct() {
    def seen as map of string to bool init {};
    for (def n as int init 1; $n <= rules.MAX_PLAYERS; $n = $n + 1) {
        def name as string init nameFor(NORMAL, $n);
        testing.assertFalse(maps.has($seen, $name));
        $seen[$name] = true;
    }
}

func testAnUnknownLevelStillNamesSomething() {
    testing.assertTrue(strings.contains(nameFor("bogus", 1), DEFAULT_LEVEL));
}

# --- telling one kind of food from another ----------------------------------

func testHarmfulIsReadFromTheRecipe() {
    testing.assertTrue(harmful(rules.TOADSTOOL));
    testing.assertTrue(harmful(rules.VEGETABLES));
    testing.assertFalse(harmful(rules.PLAIN));
    testing.assertFalse(harmful(rules.CANDY));
    testing.assertFalse(harmful(rules.GHOST));
    testing.assertFalse(harmful(""));
}

func testACandyIsWorthMoreThanACrumbAndATrapIsWorthNothing() {
    testing.assertTrue(worthOf(rules.CANDY) > worthOf(rules.PLAIN));
    testing.assertEqual(worthOf(rules.TOADSTOOL), 0);
    testing.assertEqual(worthOf(rules.VEGETABLES), 0);
    testing.assertTrue(worthOf(rules.GHOST) > 0);
}

func testItemAtNamesWhatIsUnderACell() {
    def g as rules.Game init field(12, 6);
    $g.food = [rules.foodAt(rules.CANDY, geom.at(4, 2))];
    testing.assertEqual(itemAt($g, geom.at(4, 2)), rules.CANDY);
    testing.assertEqual(itemAt($g, geom.at(0, 0)), "");
}

func testACarefulBotRefusesAToadstoolInItsPath() {
    # Straight ahead is a toadstool and there is nothing else worth having: hard and
    # expert must turn aside, even though turning gains them nothing.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.foodAt(rules.TOADSTOOL, geom.at(6, 4))];
    for (def level in [HARD, EXPERT]) {
        def d as string init pick($g, 1, $level, 3);
        testing.assertTrue($d == geom.UP or $d == geom.DOWN);
    }
}

func testAGreedyBotWalksThroughATrapToReachFoodBehindIt() {
    # A toadstool sits between the snake and a crumb. `normal` sees only that the
    # crumb is nearest that way and eats the toadstool on the way to it - which is
    # exactly why it is beatable. `hard` and `expert` go round.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.foodAt(rules.TOADSTOOL, geom.at(6, 4)), rules.plainFood(geom.at(8, 4))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.RIGHT);
    def eaten as rules.Game init rules.advance(rules.setDirection($g, 1, geom.RIGHT));
    testing.assertFalse(rules.snakeById($eaten, 1).alive);
    for (def level in [HARD, EXPERT]) {
        def d as string init pick($g, 1, $level, 3);
        testing.assertTrue($d == geom.UP or $d == geom.DOWN);
    }
}

func testACarefulBotRefusesAVegetablesItCannotAfford() {
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.foodAt(rules.VEGETABLES, geom.at(6, 4))];
    for (def level in [HARD, EXPERT]) {
        def d as string init pick($g, 1, $level, 3);
        testing.assertTrue($d == geom.UP or $d == geom.DOWN);
    }
}

func testABotPrefersACandyToACrumbTheSameDistanceAway() {
    def g as rules.Game init put(field(15, 11), 1, trail(7, 5, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(7, 2)), rules.foodAt(rules.CANDY, geom.at(7, 8))];
    for (def level in [NORMAL, HARD, EXPERT]) {
        testing.assertEqual(pick($g, 1, $level, 3), geom.DOWN);
    }
}

func testABotStillTakesACrumbWhenThatIsAllThereIs() {
    def g as rules.Game init put(field(15, 11), 1, trail(7, 5, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.plainFood(geom.at(7, 2))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.UP);
}

func testACarefulBotIgnoresATrapWhenChoosingWhereToHead() {
    # A toadstool near it must not attract it even slightly, and must not repel it
    # from a direction it is not actually stepping into.
    def g as rules.Game init put(field(15, 11), 1, trail(7, 5, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.foodAt(rules.TOADSTOOL, geom.at(7, 2)), rules.plainFood(geom.at(7, 8))];
    testing.assertEqual(pick($g, 1, HARD, 3), geom.DOWN);
}

func testABotWillTakeATrapRatherThanAWall() {
    # Cornered, a vegetable is better than certain death: the penalty is heavy, not fatal.
    def g as rules.Game init put(field(12, 6), 1, trail(11, 3, 2, geom.RIGHT), geom.RIGHT);
    $g = put($g, 2, wall([geom.at(11, 2)]), geom.UP);
    $g.food = [rules.foodAt(rules.VEGETABLES, geom.at(11, 4))];
    testing.assertEqual(pick($g, 1, HARD, 3), geom.DOWN);
}

func testABotHeadsForAGhost() {
    def g as rules.Game init put(field(15, 11), 1, trail(7, 5, 3, geom.RIGHT), geom.RIGHT);
    $g.food = [rules.foodAt(rules.GHOST, geom.at(7, 2))];
    for (def level in [NORMAL, HARD, EXPERT]) {
        testing.assertEqual(pick($g, 1, $level, 3), geom.UP);
    }
}

func testAGhostingBotPlaysOnSafelyAsIfSolid() {
    # None of the levels knows how to exploit the spell; the point of the test is
    # that having it does not make one behave dangerously either.
    def g as rules.Game init put(field(14, 9), 1, trail(5, 4, 3, geom.RIGHT), geom.RIGHT);
    $g.snakes[0].ghost = 40;
    $g = put($g, 2, wall([geom.at(6, 4), geom.at(6, 5), geom.at(5, 5)]), geom.UP);
    for (def level in LEVELS) {
        testing.assertEqual(pick($g, 1, $level, 3), geom.UP);
    }
}

func testBotsSurviveAFieldFullOfTrapsAndTreats() {
    # The whole special-food system under a careful bot for 200 ticks: it must keep
    # scoring and must not walk into anything it can see is lethal.
    def g as rules.Game init rules.newGame(26, 14, 8675309);
    $g = rules.addSnake($g, 1, "cpu");
    def state as int init 4242;
    for (def t as int init 0; $t < 200; $t = $t + 1) {
        def d as Decision init choose($g, 1, EXPERT, $state);
        $state = $d.seed;
        $g = rules.setDirection($g, 1, $d.dir);
        $g = rules.advance($g);
    }
    def s as rules.Snake init rules.snakeById($g, 1);
    testing.assertTrue($s.score > 0);
    testing.assertTrue($s.deaths <= 1);
}

# --- planning on a wrapped field ---------------------------------------------

func testABotWalksThroughAnEdgeRatherThanRefusingIt() {
    # With walls, a head at the left edge facing left is dead, so every level turns away.
    # With wrapped edges that move is perfectly safe, and a bot that still refused it
    # would be giving up a third of its options for nothing.
    def g as rules.Game init put(field(14, 9), 1, trail(0, 4, 3, geom.LEFT), geom.LEFT);
    $g = rules.withWrap($g, true);
    $g.food = [rules.plainFood(geom.at(13, 4))];
    # The food-seeking levels go straight through, because the food is just beyond it.
    for (def level in [NORMAL, HARD, EXPERT]) {
        testing.assertEqual(pick($g, 1, $level, 3), geom.LEFT);
    }
    # `easy` ignores food and chooses at random among the moves it has not ruled out, so
    # the claim for it is that the edge is among them at all.
    def seen as map of string to bool init {};
    for (def seed as int init 1; $seed < 60; $seed = $seed + 1) {
        $seen[pick($g, 1, EASY, $seed)] = true;
    }
    testing.assertTrue(maps.has($seen, geom.LEFT));
}

func testTheSameEdgeIsRefusedWithWalls() {
    def g as rules.Game init put(field(14, 9), 1, trail(0, 4, 3, geom.LEFT), geom.LEFT);
    $g.food = [rules.plainFood(geom.at(13, 4))];
    for (def level in LEVELS) {
        testing.assertNotEqual(pick($g, 1, $level, 3), geom.LEFT);
    }
}

func testABotTakesTheShortWayRoundAWrappedField() {
    # Food two steps away through the edge, eleven the long way: a food-seeking level has
    # to measure the distance the way the field actually works.
    def g as rules.Game init put(field(14, 9), 1, trail(1, 4, 2, geom.LEFT), geom.LEFT);
    $g = rules.withWrap($g, true);
    $g.food = [rules.plainFood(geom.at(13, 4))];
    testing.assertEqual(pick($g, 1, NORMAL, 3), geom.LEFT);
}

func testFoodDistanceMeasuresBothWaysRound() {
    def walls as rules.Game init field(20, 10);
    def open as rules.Game init rules.withWrap(field(20, 10), true);
    testing.assertEqual(foodDistance($walls, geom.at(1, 0), geom.at(19, 0)), 18);
    testing.assertEqual(foodDistance($open, geom.at(1, 0), geom.at(19, 0)), 2);
}

func testFoodDistanceIsSymmetric() {
    def g as rules.Game init rules.withWrap(field(20, 10), true);
    testing.assertEqual(
        foodDistance($g, geom.at(2, 1), geom.at(17, 8)),
        foodDistance($g, geom.at(17, 8), geom.at(2, 1)));
}

func testFoodDistanceOfACellToItselfIsZero() {
    def g as rules.Game init rules.withWrap(field(20, 10), true);
    testing.assertEqual(foodDistance($g, geom.at(4, 4), geom.at(4, 4)), 0);
}

func testTheFloodFollowsTheEdgesRound() {
    # On a wrapped field the space is one connected ring, so a corridor along the bottom
    # row reaches round to the top - and a careful bot must see that room.
    def g as rules.Game init rules.withWrap(field(10, 6), true);
    def taken as map of int to bool init {};
    for (def x as int init 0; $x < 10; $x = $x + 1) {
        if ($x != 3) {
            $taken[geom.index(geom.at($x, 1), 10)] = true;
            $taken[geom.index(geom.at($x, 4), 10)] = true;
        }
    }
    # Everything is reachable through the gap at x = 3 and round the edges.
    testing.assertEqual(openSpace($g, geom.at(0, 0), $taken, 100), 10 * 6 - 18);
}

func testACarefulBotSurvivesALongWrappedGame() {
    def g as rules.Game init rules.withWrap(rules.newGame(20, 12, 31337), true);
    $g = rules.addSnake($g, 1, "cpu");
    def state as int init 99;
    for (def t as int init 0; $t < 200; $t = $t + 1) {
        def d as Decision init choose($g, 1, EXPERT, $state);
        $state = $d.seed;
        $g = rules.setDirection($g, 1, $d.dir);
        $g = rules.advance($g);
    }
    def s as rules.Snake init rules.snakeById($g, 1);
    testing.assertEqual($s.deaths, 0);
    testing.assertTrue($s.score > 0);
}
