# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for view.j. The renderer is pure, so every one of these runs
# with no terminal: a frame is a cell buffer, and a test reads the cells back
# with `screen.get`. Run with:
#
#     jennifer test src/view_test.j

use testing;
use strings;
use lists;
use maps;

import "ansi.j" as ansi;

# seen is the visible character in a cell, with the colour escapes stripped - so
# an assertion talks about what a player sees, not about SGR codes.
func seen(buf as screen.Buffer, x as int, y as int) {
    return ansi.strip(screen.get($buf, $x, $y));
}

# row is one whole buffer row as plain text, for asserting on a line of chrome.
func row(buf as screen.Buffer, y as int) {
    def out as string init "";
    for (def x as int init 0; $x < $buf.cols; $x = $x + 1) {
        $out = $out + seen($buf, $x, $y);
    }
    return $out;
}

# squash collapses runs of spaces to one, so an assertion can talk about the
# words on a line without pinning down the column padding around them.
func squash(s as string) {
    def out as string init $s;
    while (strings.contains($out, "  ")) {
        $out = strings.replace($out, "  ", " ");
    }
    return strings.trim($out);
}

# staged builds a game with one snake whose body is placed exactly where a test
# wants it, and no food, so nothing drawn is a surprise.
func staged() {
    def g as rules.Game init rules.newGame(20, 8, 1);
    def cells as list of geom.Point init [geom.at(5, 3), geom.at(4, 3), geom.at(3, 3)];
    def snakes as list of rules.Snake init [
        rules.Snake{
            id: 1,
            name: "ada",
            cells: $cells,
            dir: geom.RIGHT,
            alive: true,
            score: 30,
            deaths: 0,
            respawn: 0,
            grow: 0,
            ghost: 0,
            lives: rules.DEFAULT_LIVES
        }
    ];
    $g.snakes = $snakes;
    return $g;
}

# --- the palette -------------------------------------------------------------

func testGlyphAndColourAreStablePerPlayer() {
    testing.assertEqual(glyphFor(1), glyphFor(1));
    testing.assertEqual(colorFor(3), colorFor(3));
}

func testDifferentPlayersLookDifferent() {
    testing.assertNotEqual(glyphFor(1), glyphFor(2));
    testing.assertNotEqual(colorFor(1), colorFor(2));
}

func testEveryPaletteGlyphIsOneColumn() {
    for (def glyph in BODY_GLYPHS) {
        testing.assertEqual(len($glyph), 1);
    }
    testing.assertEqual(len(HEAD_GLYPH), 1);
    testing.assertEqual(len(FOOD_GLYPH), 1);
}

func testNoBodyGlyphCollidesWithTheHeadOrFood() {
    # A head must be findable at a glance and food must not look like a body.
    testing.assertFalse(lists.contains(BODY_GLYPHS, HEAD_GLYPH));
    testing.assertFalse(lists.contains(BODY_GLYPHS, FOOD_GLYPH));
}

func testTheGlyphAndColourPalettesAreTheSameLength() {
    testing.assertEqual(len(BODY_GLYPHS), len(BODY_COLORS));
}

func testEveryPaletteColourIsOneScreenKnows() {
    # screen.textColor throws on a name it does not know, so a typo in the
    # palette would only show up when that player joined. Check it here instead.
    def probe as screen.Buffer init screen.newScreen(1, 4);
    for (def color in BODY_COLORS) {
        testing.assertEqual(
            ansi.strip(screen.get(screen.textColor($probe, 0, 0, "x", $color), 0, 0)),
            "x");
    }
    testing.assertEqual(
        ansi.strip(screen.get(screen.textColor($probe, 0, 0, "x", FOOD_COLOR), 0, 0)),
        "x");
}

func testThePaletteWrapsForAnOverflowingId() {
    testing.assertEqual(glyphFor(len(BODY_GLYPHS) + 1), glyphFor(1));
    testing.assertEqual(colorFor(len(BODY_COLORS) + 1), colorFor(1));
}

func testThePaletteSurvivesANonsenseId() {
    # A corrupt STATE could name player 0 or a negative id; indexing must hold.
    testing.assertEqual(len(glyphFor(0)), 1);
    testing.assertEqual(len(glyphFor(-7)), 1);
    testing.assertTrue(len(colorFor(-7)) > 0);
}

# --- fit ---------------------------------------------------------------------

func testFitAsksForTheFieldPlusItsChrome() {
    # The field, its border, the header, one scoreboard row, the key line, and - in a
    # game with specials in it - the food key.
    def f as Fit init fit(staged(), 100, 100);
    testing.assertEqual($f.rows, 8 + 1 + 4 + 1);
    testing.assertEqual($f.cols, MIN_COLS);
    testing.assertTrue($f.fits);
}

func testFitAsksForTheFieldWidthWhenItExceedsTheMinimum() {
    def g as rules.Game init rules.newGame(60, 10, 1);
    testing.assertEqual(fit($g, 100, 100).cols, 62);
}

func testFitRefusesATerminalThatIsTooShortOrTooNarrow() {
    def g as rules.Game init staged();
    def needed as Fit init fit($g, 100, 100);
    testing.assertFalse(fit($g, $needed.rows - 1, $needed.cols).fits);
    testing.assertFalse(fit($g, $needed.rows, $needed.cols - 1).fits);
    testing.assertTrue(fit($g, $needed.rows, $needed.cols).fits);
}

func testFitGrowsWithThePlayerCount() {
    def one as rules.Game init staged();
    def two as rules.Game init rules.addSnake($one, 2, "bob");
    testing.assertEqual(fit($two, 100, 100).rows, fit($one, 100, 100).rows + 1);
}

# --- the field ---------------------------------------------------------------

func testRenderDrawsTheBoxAroundTheField() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, 0, 1), "┌");
    testing.assertEqual(seen($buf, 21, 1), "┐");
    testing.assertEqual(seen($buf, 0, 10), "└");
    testing.assertEqual(seen($buf, 21, 10), "┘");
}

func testRenderPutsTheHeadWhereTheGameSaysItIs() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 5, FIELD_Y + 3), HEAD_GLYPH);
}

func testRenderDrawsTheBodyBehindTheHead() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 4, FIELD_Y + 3), glyphFor(1));
    testing.assertEqual(seen($buf, FIELD_X + 3, FIELD_Y + 3), glyphFor(1));
}

func testRenderLeavesEmptyCellsEmpty() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 10, FIELD_Y + 1), " ");
}

func testRenderDrawsFood() {
    def g as rules.Game init staged();
    $g.food = [rules.plainFood(geom.at(9, 2)), rules.plainFood(geom.at(0, 0))];
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 9, FIELD_Y + 2), FOOD_GLYPH);
    testing.assertEqual(seen($buf, FIELD_X, FIELD_Y), FOOD_GLYPH);
}

func testRenderDrawsNothingForADeadSnake() {
    def g as rules.Game init staged();
    $g.snakes[0].alive = false;
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 5, FIELD_Y + 3), " ");
}

func testTheHeadWinsWhereItMeetsAnotherSnakesBody() {
    # Bodies are drawn first and heads after, so a head is never hidden.
    def g as rules.Game init staged();
    def other as list of geom.Point init [geom.at(9, 5), geom.at(5, 3)];
    $g = rules.addSnake($g, 2, "bob");
    $g.snakes[1].cells = $other;
    $g.snakes[1].alive = true;
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, FIELD_X + 5, FIELD_Y + 3), HEAD_GLYPH);
}

func testRenderNeverDrawsOutsideTheBox() {
    # A STATE from a peer could name a cell off the field; it must not land on
    # the border, the header, or the scoreboard.
    def g as rules.Game init staged();
    def rogue as list of geom.Point init [geom.at(-5, -5), geom.at(500, 500)];
    $g.snakes[0].cells = $rogue;
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, 0, 1), "┌");
    testing.assertEqual(row($buf, 1), row(render(staged(), 1, "ok", 24, 80), 1));
}

# --- the chrome --------------------------------------------------------------

func testTheHeaderNamesTheGameAndTheTick() {
    def g as rules.Game init staged();
    $g.tick = 42;
    def line as string init row(render($g, 1, "connected", 24, 80), 0);
    testing.assertTrue(strings.contains($line, "jsnake"));
    testing.assertTrue(strings.contains($line, "42"));
    testing.assertTrue(strings.contains($line, "connected"));
}

func testTheScoreboardShowsEveryPlayer() {
    def g as rules.Game init rules.addSnake(staged(), 2, "bob");
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    def first as string init row($buf, 8 + 3);
    def second as string init row($buf, 8 + 4);
    testing.assertTrue(strings.contains($first, "ada"));
    testing.assertTrue(strings.contains($second, "bob"));
}

func testTheLegendIsBelowTheScoreboard() {
    def g as rules.Game init staged();
    def line as string init row(render($g, 1, "ok", 24, 80), 8 + 1 + 3);
    testing.assertTrue(strings.contains($line, "quit"));
}

func testTheFoodKeyIsOnTheRowBelowTheLegend() {
    def g as rules.Game init staged();
    def line as string init row(render($g, 1, "ok", 24, 80), 8 + 1 + 4);
    testing.assertTrue(strings.contains($line, "candy"));
    testing.assertTrue(strings.contains($line, "toadstool"));
}

func testAPlainGameHasNoFoodKey() {
    def g as rules.Game init rules.withoutSpecials(staged());
    def line as string init row(render($g, 1, "ok", 24, 80), 8 + 1 + 4);
    testing.assertEqual(strings.trim($line), "");
    testing.assertEqual(fit($g, 100, 100).rows, 8 + 1 + 4);
}

func testScoreLineNamesTheSnakeAndItsScore() {
    def s as rules.Snake init staged().snakes[0];
    def line as string init scoreLine($s, false, false);
    testing.assertTrue(strings.contains($line, "ada"));
    testing.assertTrue(strings.contains($line, "30"));
    testing.assertTrue(strings.contains($line, "alive"));
}

func testScoreLineMarksTheLocalPlayer() {
    def s as rules.Snake init staged().snakes[0];
    testing.assertTrue(strings.startsWith(scoreLine($s, true, false), YOU_MARKER));
    testing.assertFalse(strings.startsWith(scoreLine($s, false, false), YOU_MARKER));
}

func testScoreLineMarksTheLeader() {
    def s as rules.Snake init staged().snakes[0];
    testing.assertNotEqual(scoreLine($s, false, true), scoreLine($s, false, false));
}

func testScoreLineCountsGrowthIntoTheLength() {
    # Eating shows up in the length at once, not a tick later.
    def s as rules.Snake init staged().snakes[0];
    def grown as rules.Snake init $s;
    $grown.grow = 4;
    testing.assertTrue(strings.contains(squash(scoreLine($grown, false, false)), "len 7"));
    testing.assertTrue(strings.contains(squash(scoreLine($s, false, false)), "len 3"));
}

func testScoreLineCountsDownARespawn() {
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.respawn = 6;
    testing.assertTrue(strings.contains(squash(scoreLine($s, false, false)), "back in 6"));
}

func testScoreLineSaysDeadWhenThereIsNoCountdown() {
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.respawn = 0;
    testing.assertTrue(strings.contains(scoreLine($s, false, false), "dead"));
}

func testTheScoreboardIsOneRowPerPlayerAndNoMore() {
    def g as rules.Game init rules.addSnake(staged(), 2, "bob");
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(strings.trim(row($buf, 8 + 5)), HOST_KEYS);
}

# --- the food kinds on screen ------------------------------------------------

func testEveryFoodKindHasItsOwnGlyph() {
    def seen as map of string to bool init {};
    for (def kind in rules.FOOD_KINDS) {
        def glyph as string init foodGlyph($kind);
        testing.assertEqual(len($glyph), 1);
        testing.assertFalse(maps.has($seen, $glyph));
        $seen[$glyph] = true;
    }
}

func testNoFoodGlyphLooksLikeASnake() {
    # A field has to be readable with no colour at all, so shape alone must say
    # whether a cell is food, a body, or a head.
    for (def kind in rules.FOOD_KINDS) {
        testing.assertFalse(lists.contains(BODY_GLYPHS, foodGlyph($kind)));
        testing.assertNotEqual(foodGlyph($kind), HEAD_GLYPH);
    }
}

func testEveryFoodColourIsOneScreenKnows() {
    def probe as screen.Buffer init screen.newScreen(1, 4);
    for (def kind in rules.FOOD_KINDS) {
        def cell as string init ansi.strip(screen.get(
            screen.textColor($probe, 0, 0, "x", foodColor($kind)),
            0,
            0));
        testing.assertEqual($cell, "x");
    }
}

func testAnUnknownKindFallsBackToPlainFood() {
    testing.assertEqual(foodGlyph("caviar"), FOOD_GLYPH);
    testing.assertEqual(foodColor("caviar"), FOOD_COLOR);
}

func testRenderDrawsEachKindWithItsOwnGlyph() {
    def g as rules.Game init staged();
    def food as list of rules.Item init [];
    for (def i as int init 0; $i < len(rules.FOOD_KINDS); $i = $i + 1) {
        $food[] = rules.foodAt(rules.FOOD_KINDS[$i], geom.at($i, 6));
    }
    $g.food = $food;
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    for (def i as int init 0; $i < len(rules.FOOD_KINDS); $i = $i + 1) {
        testing.assertEqual(seen($buf, FIELD_X + $i, FIELD_Y + 6), foodGlyph(rules.FOOD_KINDS[$i]));
    }
}

func testTheFoodKeyNamesEveryKindItCanDraw() {
    def line as string init foodLegend();
    testing.assertTrue(strings.contains($line, foodGlyph(rules.CANDY)));
    testing.assertTrue(strings.contains($line, foodGlyph(rules.VEGETABLES)));
    testing.assertTrue(strings.contains($line, foodGlyph(rules.TOADSTOOL)));
    testing.assertTrue(strings.contains($line, foodGlyph(rules.GHOST)));
    testing.assertFalse(strings.contains($line, "\n"));
}

func testAGhostingSnakeSaysSoOnTheScoreboard() {
    def s as rules.Snake init staged().snakes[0];
    $s.ghost = 40;
    def line as string init scoreLine($s, false, false);
    testing.assertTrue(strings.contains($line, "ghost"));
    testing.assertTrue(strings.contains($line, "40"));
}

func testASnakeWithNoSpellSaysAlive() {
    def s as rules.Snake init staged().snakes[0];
    testing.assertEqual($s.ghost, 0);
    testing.assertTrue(strings.contains(scoreLine($s, false, false), "alive"));
}

func testADeadSnakeIsNotDescribedAsAGhost() {
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.ghost = 40;
    testing.assertFalse(strings.contains(scoreLine($s, false, false), "ghost"));
}

# --- a terminal too small ---------------------------------------------------

func testATerminalTooSmallGetsAnExplanationNotAMangledField() {
    def g as rules.Game init rules.newGame(60, 30, 1);
    def buf as screen.Buffer init render($g, 1, "ok", 10, 40);
    def whole as string init "";
    for (def y as int init 0; $y < $buf.rows; $y = $y + 1) {
        $whole = $whole + row($buf, $y);
    }
    testing.assertTrue(strings.contains($whole, "too small"));
    testing.assertTrue(strings.contains($whole, "resize"));
}

func testRenderFillsExactlyTheBufferItWasAskedFor() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual($buf.rows, 24);
    testing.assertEqual($buf.cols, 80);
    testing.assertEqual(len($buf.cells), 24 * 80);
}

# --- message ----------------------------------------------------------------

func testMessageDrawsItsTitleAndBody() {
    def buf as screen.Buffer init message("games", ["one", "two"], 20, 40);
    def whole as string init "";
    for (def y as int init 0; $y < $buf.rows; $y = $y + 1) {
        $whole = $whole + row($buf, $y);
    }
    testing.assertTrue(strings.contains($whole, "games"));
    testing.assertTrue(strings.contains($whole, "one"));
    testing.assertTrue(strings.contains($whole, "two"));
}

func testMessageIsBoxedAndCentred() {
    def buf as screen.Buffer init message("t", ["body"], 20, 40);
    def left as int init -1;
    for (def x as int init 0; $x < 40; $x = $x + 1) {
        if ($left < 0 and seen($buf, $x, centre(20, 5)) == "┌") {
            $left = $x;
        }
    }
    testing.assertTrue($left > 0);
    testing.assertTrue($left < 20);
}

func testMessageWithNoBodyStillDrawsABox() {
    def buf as screen.Buffer init message("empty", [], 20, 40);
    testing.assertEqual($buf.rows, 20);
    def found as bool init false;
    for (def x as int init 0; $x < 40; $x = $x + 1) {
        for (def y as int init 0; $y < 20; $y = $y + 1) {
            if (seen($buf, $x, $y) == "┌") {
                $found = true;
            }
        }
    }
    testing.assertTrue($found);
}

func testMessageSurvivesATinyTerminal() {
    def buf as screen.Buffer init message("t", ["a long line that cannot fit"], 3, 10);
    testing.assertEqual($buf.rows, 3);
    testing.assertEqual($buf.cols, 10);
}

func testATerminalThatReportsNoSizeGetsAConventionalOne() {
    # term.size answers 0 under `script` and on a pty opened without a window
    # size. Drawing to that literally would give a one-character frame, which
    # looks like a broken game; 80x24 is the honest assumption instead.
    def buf as screen.Buffer init message("t", ["x"], 0, 0);
    testing.assertEqual($buf.rows, FALLBACK_ROWS);
    testing.assertEqual($buf.cols, FALLBACK_COLS);
}

func testAGameFrameAlsoFallsBackWhenNoSizeIsReported() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 0, 0);
    testing.assertEqual($buf.rows, FALLBACK_ROWS);
    testing.assertEqual($buf.cols, FALLBACK_COLS);
    testing.assertEqual(seen($buf, 0, 1), "┌");
}

func testARealButSmallTerminalStillGetsTheHonestMessage() {
    # The fallback is for "unknown", not for "small": a 10x40 terminal really
    # cannot show a 60x30 field, and should be told so.
    def g as rules.Game init rules.newGame(60, 30, 1);
    def buf as screen.Buffer init render($g, 1, "ok", 10, 40);
    testing.assertEqual($buf.rows, 10);
    def whole as string init "";
    for (def y as int init 0; $y < $buf.rows; $y = $y + 1) {
        $whole = $whole + row($buf, $y);
    }
    testing.assertTrue(strings.contains($whole, "too small"));
}

# --- the host menu ----------------------------------------------------------

func testMenuLinesNumbersEveryHost() {
    def lines as list of string init menuLines(["alpha 1/8", "beta 2/8"]);
    testing.assertTrue(strings.contains($lines[0], "1"));
    testing.assertTrue(strings.contains($lines[0], "alpha"));
    testing.assertTrue(strings.contains($lines[1], "2"));
    testing.assertTrue(strings.contains($lines[1], "beta"));
}

func testMenuLinesEndsWithThePrompt() {
    def lines as list of string init menuLines(["alpha", "beta"]);
    def last as string init $lines[len($lines) - 1];
    testing.assertTrue(strings.contains($last, "1-2"));
    testing.assertTrue(strings.contains($last, "quit"));
}

func testMenuLinesSaysSoWhenNothingWasFound() {
    def lines as list of string init menuLines([]);
    testing.assertTrue(strings.contains($lines[0], "no games found"));
    testing.assertTrue(strings.contains($lines[len($lines) - 1], "search again"));
}

# --- the largest field a terminal can show -----------------------------------

# crowd is a game of `players` snakes on a field of exactly this size - what a
# negotiated size has to be checked against.
func crowd(room as Room, players as int) {
    def g as rules.Game init rules.newGame($room.width, $room.height, 1);
    for (def i as int init 1; $i <= $players; $i = $i + 1) {
        $g = rules.addSnake($g, $i, "p");
    }
    return $g;
}

func testMaxFieldIsTheInverseOfFit() {
    # The invariant the whole size negotiation rests on: a field sized by maxField
    # is one fit reports as fitting, for every terminal that can show the game.
    for (def rows as int init 12; $rows <= 60; $rows = $rows + 7) {
        for (def cols as int init 30; $cols <= 200; $cols = $cols + 17) {
            checkInverse($rows, $cols);
        }
    }
}

# checkInverse asserts the inverse property for one terminal at every player count.
# Split out of the loop above so the nesting stays inside the linter's limit - which
# is the right call anyway: the assertion reads better named than four levels deep.
func checkInverse(rows as int, cols as int) {
    for (def players as int init 1; $players <= rules.MAX_PLAYERS; $players = $players + 3) {
        def room as Room init maxField($rows, $cols, $players, true);
        # Below MIN_COLS the chrome itself does not fit, and a clamped height means
        # the terminal is shorter than the smallest legal field: in both cases there
        # is no size that would work, which is what `canShow` reports.
        if ($cols >= MIN_COLS and $room.height > rules.MIN_HEIGHT) {
            testing.assertTrue(fit(crowd($room, $players), $rows, $cols).fits);
            testing.assertTrue(canShow($rows, $cols, $players, true));
        }
    }
}

func testMaxFieldUsesEveryRowItCan() {
    # One row taller than maxField says must not fit, or the negotiation is leaving
    # playing space on the table.
    def rows as int init 30;
    def cols as int init 90;
    def players as int init 4;
    def room as Room init maxField($rows, $cols, $players, true);
    def taller as Room init Room{width: $room.width, height: $room.height + 1};
    testing.assertFalse(fit(crowd($taller, $players), $rows, $cols).fits);
}

func testMaxFieldUsesEveryColumnItCan() {
    def room as Room init maxField(30, 90, 4, true);
    testing.assertEqual($room.width, 88);
}

func testMaxFieldLeavesRoomForEveryScoreboardRow() {
    def few as Room init maxField(30, 90, 2, true);
    def many as Room init maxField(30, 90, 8, true);
    testing.assertEqual($few.height - $many.height, 6);
    testing.assertEqual($few.width, $many.width);
}

func testMaxFieldLeavesRoomForTheFoodKey() {
    def plain as Room init maxField(30, 90, 4, false);
    def fancy as Room init maxField(30, 90, 4, true);
    testing.assertEqual($plain.height - $fancy.height, 1);
}

func testCanShowAcceptsAnOrdinaryTerminal() {
    testing.assertTrue(canShow(24, 80, 1, true));
    testing.assertTrue(canShow(40, 120, rules.MAX_PLAYERS, true));
}

func testCanShowRefusesATerminalTooNarrowForTheChrome() {
    testing.assertFalse(canShow(40, MIN_COLS - 1, 1, true));
    testing.assertTrue(canShow(40, MIN_COLS, 1, true));
}

func testCanShowRefusesATerminalTooShortForTheSmallestField() {
    testing.assertFalse(canShow(8, 90, rules.MAX_PLAYERS, true));
    testing.assertTrue(canShow(30, 90, rules.MAX_PLAYERS, true));
}

func testCanShowNeedsOneRowLessWithoutTheFoodKey() {
    # The boundary row: a terminal that cannot host a game with specials can host the
    # same game without them, which is a real reason for a host to offer --plain.
    # Exactly enough rows for the smallest field, its border, the header, one
    # scoreboard row and the key line - with no row left for the food key.
    def rows as int init rules.MIN_HEIGHT + CHROME_ROWS + 1;
    testing.assertFalse(canShow($rows, 90, 1, true));
    testing.assertTrue(canShow($rows, 90, 1, false));
}

func testMaxFieldNeverGoesBelowThePlayableMinimum() {
    def tiny as Room init maxField(4, 8, 8, true);
    testing.assertEqual($tiny.width, rules.MIN_WIDTH);
    testing.assertEqual($tiny.height, rules.MIN_HEIGHT);
}

func testMaxFieldNeverGoesAboveTheGamesLimit() {
    def huge as Room init maxField(500, 500, 1, true);
    testing.assertEqual($huge.width, rules.MAX_WIDTH);
    testing.assertEqual($huge.height, rules.MAX_HEIGHT);
}

func testMaxFieldWithNoReportedSizeAssumesTheUsualTerminal() {
    def unknown as Room init maxField(0, 0, 4, true);
    def known as Room init maxField(FALLBACK_ROWS, FALLBACK_COLS, 4, true);
    testing.assertEqual($unknown.width, $known.width);
    testing.assertEqual($unknown.height, $known.height);
}

func testMaxFieldTreatsNoPlayersAsOne() {
    # A host refereeing an empty table still needs one scoreboard row's worth of
    # slack, or the field it picks would not fit the moment somebody joined.
    testing.assertEqual(maxField(30, 90, 0, true).height, maxField(30, 90, 1, true).height);
}

# --- agreeing on a size ------------------------------------------------------

func testSmallerTakesTheTighterOfEachDirection() {
    def wide as Room init Room{width: 80, height: 12};
    def tall as Room init Room{width: 40, height: 30};
    def both as Room init smaller($wide, $tall);
    testing.assertEqual($both.width, 40);
    testing.assertEqual($both.height, 12);
}

func testSmallerIsCommutative() {
    def a as Room init Room{width: 80, height: 12};
    def b as Room init Room{width: 40, height: 30};
    testing.assertEqual(smaller($a, $b).width, smaller($b, $a).width);
    testing.assertEqual(smaller($a, $b).height, smaller($b, $a).height);
}

func testSmallerOfOneRoomWithItselfIsThatRoom() {
    def a as Room init Room{width: 44, height: 16};
    testing.assertEqual(smaller($a, $a).width, 44);
    testing.assertEqual(smaller($a, $a).height, 16);
}

func testTheAgreedSizeFitsEveryTerminalThatAgreedToIt() {
    # Three different terminals, one field: all three must be able to draw it.
    def terminals as list of list of int init [[24, 80], [40, 120], [30, 100]];
    def agreed as Room init maxField(999, 999, rules.MAX_PLAYERS, true);
    for (def t in $terminals) {
        $agreed = smaller($agreed, maxField($t[0], $t[1], rules.MAX_PLAYERS, true));
    }
    def g as rules.Game init crowd($agreed, rules.MAX_PLAYERS);
    for (def t in $terminals) {
        testing.assertTrue(fit($g, $t[0], $t[1]).fits);
    }
}

# --- setup rows --------------------------------------------------------------

func testMenuRowShowsItsLabelAndValue() {
    def line as string init menuRow("speed", "120 ms per move", false);
    testing.assertTrue(strings.contains($line, "speed"));
    testing.assertTrue(strings.contains($line, "120 ms per move"));
}

func testMenuRowMarksTheCursor() {
    testing.assertTrue(strings.startsWith(menuRow("speed", "x", true), CURSOR_MARKER));
    testing.assertFalse(strings.startsWith(menuRow("speed", "x", false), CURSOR_MARKER));
}

func testMenuRowsLineUpTheirValues() {
    # A short label and a long one must put their values in the same column, or the
    # setup screen reads as a ragged list rather than a table.
    def short as string init menuRow("speed", "V", false);
    def long as string init menuRow("computer players", "V", false);
    testing.assertEqual(strings.indexOf($short, "V"), strings.indexOf($long, "V"));
}

func testMenuRowIsOneLine() {
    testing.assertFalse(strings.contains(menuRow("speed", "120 ms", true), "\n"));
}

# --- holding a room inside what the transport can carry ----------------------

func testWithinAreaLeavesASmallRoomAlone() {
    def room as Room init Room{width: 60, height: 20};
    def held as Room init withinArea($room, 9358);
    testing.assertEqual($held.width, 60);
    testing.assertEqual($held.height, 20);
}

func testWithinAreaTreatsZeroAsNoLimit() {
    # A stream transport reports 0: there is no datagram to fit inside.
    def room as Room init Room{width: rules.MAX_WIDTH, height: rules.MAX_HEIGHT};
    def held as Room init withinArea($room, 0);
    testing.assertEqual($held.width, rules.MAX_WIDTH);
    testing.assertEqual($held.height, rules.MAX_HEIGHT);
}

func testWithinAreaTakesTheHeightFirst() {
    # Width is what a wide-display player notices; rows are the cheaper thing to lose.
    def room as Room init Room{width: 200, height: 60};
    def held as Room init withinArea($room, 4000);
    testing.assertEqual($held.width, 200);
    testing.assertEqual($held.height, 20);
    testing.assertTrue($held.width * $held.height <= 4000);
}

func testWithinAreaTakesTheWidthOnlyWhenItMust() {
    # A limit so tight that even the shortest legal field is too wide.
    def room as Room init Room{width: 200, height: 60};
    def held as Room init withinArea($room, 100);
    testing.assertEqual($held.height, rules.MIN_HEIGHT);
    testing.assertTrue($held.width < 200);
    testing.assertTrue($held.width * $held.height <= 100);
}

func testWithinAreaNeverGoesBelowThePlayableMinimum() {
    def held as Room init withinArea(Room{width: 200, height: 60}, 1);
    testing.assertEqual($held.width, rules.MIN_WIDTH);
    testing.assertEqual($held.height, rules.MIN_HEIGHT);
}

func testWithinAreaAlwaysFitsWhenItCan() {
    for (def area as int init 200; $area <= 12000; $area = $area + 700) {
        def held as Room init withinArea(Room{width: 240, height: 100}, $area);
        def cells as int init $held.width * $held.height;
        testing.assertTrue($cells <= $area or $cells == rules.MIN_WIDTH * rules.MIN_HEIGHT);
    }
}

func testWithinAreaNeverGrowsARoom() {
    def room as Room init Room{width: 40, height: 12};
    def held as Room init withinArea($room, 100000);
    testing.assertTrue($held.width <= $room.width);
    testing.assertTrue($held.height <= $room.height);
}

# --- lives on the scoreboard -------------------------------------------------

func testTheScoreboardShowsLivesLeft() {
    def s as rules.Snake init staged().snakes[0];
    $s.lives = 2;
    def line as string init scoreRow($s, false, false, 3);
    testing.assertTrue(strings.contains($line, LIVES_MARK));
    testing.assertTrue(strings.contains($line, "2"));
}

func testAnEndlessGameHasNoLivesColumn() {
    # Nothing to count, so nothing is drawn - a column of dashes would only raise the
    # question of what it meant.
    def s as rules.Snake init staged().snakes[0];
    testing.assertFalse(strings.contains(
        scoreRow($s, false, false, rules.UNLIMITED_LIVES),
        LIVES_MARK));
}

func testScoreLineIsTheEndlessForm() {
    def s as rules.Snake init staged().snakes[0];
    testing.assertEqual(
        scoreLine($s, false, false),
        scoreRow($s, false, false, rules.UNLIMITED_LIVES));
}

func testASpectatorIsDescribedAsSpectating() {
    # Not "dead", which would suggest they were coming back.
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.lives = 0;
    $s.respawn = 0;
    def line as string init scoreRow($s, false, false, 3);
    testing.assertTrue(strings.contains($line, SPECTATING));
    testing.assertFalse(strings.contains($line, "back in"));
}

func testASnakeWaitingToReturnIsNotSpectating() {
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.lives = 1;
    $s.respawn = 6;
    def line as string init squash(scoreRow($s, false, false, 3));
    testing.assertTrue(strings.contains($line, "back in 6"));
    testing.assertFalse(strings.contains($line, SPECTATING));
}

func testNobodySpectatesInAnEndlessGame() {
    def s as rules.Snake init staged().snakes[0];
    $s.alive = false;
    $s.lives = 0;
    $s.respawn = 4;
    testing.assertFalse(strings.contains(
        scoreRow($s, false, false, rules.UNLIMITED_LIVES),
        SPECTATING));
}

func testTheLivesMarkIsOneColumn() {
    testing.assertEqual(len(LIVES_MARK), 1);
}

func testTheScoreboardRowsStillLineUpWithLives() {
    def short as rules.Snake init staged().snakes[0];
    def long as rules.Snake init $short;
    $long.name = "abcdefghijkl";
    $long.score = 99999;
    def a as string init scoreRow($short, false, false, 3);
    def b as string init scoreRow($long, false, false, 3);
    testing.assertEqual(strings.indexOf($a, LIVES_MARK), strings.indexOf($b, LIVES_MARK));
}

func testAFrameDrawsTheLivesOfEveryPlayer() {
    def g as rules.Game init rules.withLives(rules.addSnake(staged(), 2, "bob"), 3);
    $g.snakes[1].lives = 1;
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertTrue(strings.contains(row($buf, 8 + 3), LIVES_MARK));
    testing.assertTrue(strings.contains(row($buf, 8 + 4), LIVES_MARK));
}

func testAnEndlessFrameDrawsNoLives() {
    def g as rules.Game init rules.withLives(staged(), rules.UNLIMITED_LIVES);
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertFalse(strings.contains(row($buf, 8 + 3), LIVES_MARK));
}

# --- the logo ----------------------------------------------------------------

func testTheLogoFitsInsideTheNarrowestPlayableTerminal() {
    # If the logo were wider than MIN_COLS it would widen the box it sits in, and the box
    # would then be clipped on a terminal that could otherwise host a game.
    for (def line in LOGO) {
        testing.assertTrue(len($line) <= MIN_COLS - 4);
    }
}

func testEveryLogoGlyphIsSingleWidth() {
    # A filled circle or an emoji would render two columns wide in some terminals and
    # shear the drawing. Everything here is box-drawing, a space, or ASCII.
    def allowed as string init "╭╮╰╯─│║═╔╗╚╝╠╣╩╦ @";
    for (def line in LOGO) {
        for (def ch in strings.chars($line)) {
            testing.assertTrue(strings.indexOf($allowed, $ch) >= 0);
        }
    }
}

# The rows of LOGO that draw the snake rather than the lettering. The letters are made of
# double-line glyphs that form shapes, not a path, so connectivity means nothing there.
def const SNAKE_ROWS as int init 2;

# sidesOf names the edges a single-line box glyph joins on: u, d, l, r.
func sidesOf(ch as string) {
    match ($ch) {
        when "╭" { return "dr"; }
        when "╮" { return "dl"; }
        when "╰" { return "ur"; }
        when "╯" { return "ul"; }
        when "─" { return "lr"; }
        when "│" { return "ud"; }
        else { return ""; }
    }
}

# glyphAt is the rune at (x, y) of the logo, or a space outside it.
func glyphAt(x as int, y as int) {
    if ($y < 0 or $y >= len(LOGO)) {
        return " ";
    }
    def row as list of string init strings.chars(LOGO[$y]);
    if ($x < 0 or $x >= len($row)) {
        return " ";
    }
    return $row[$x];
}

# neighbourOn is the glyph on one side of a cell.
func neighbourOn(x as int, y as int, side as string) {
    match ($side) {
        when "u" { return glyphAt($x, $y - 1); }
        when "d" { return glyphAt($x, $y + 1); }
        when "l" { return glyphAt($x - 1, $y); }
        else { return glyphAt($x + 1, $y); }
    }
}

# flipSide is the side a neighbour must join back on.
func flipSide(side as string) {
    match ($side) {
        when "u" { return "d"; }
        when "d" { return "u"; }
        when "l" { return "r"; }
        else { return "l"; }
    }
}

func testTheSnakeInTheLogoIsOneConnectedLine() {
    # This has broken twice, both times by indenting one of the snake's rows and not the
    # other: every corner then points at a blank. It still reads as a line at a glance,
    # which is why checking the glyphs are present does not catch it - so each corner is
    # checked against what is actually next to it.
    for (def y as int init 0; $y < SNAKE_ROWS; $y = $y + 1) {
        def row as list of string init strings.chars(LOGO[$y]);
        for (def x as int init 0; $x < len($row); $x = $x + 1) {
            checkCorner($row[$x], $x, $y);
        }
    }
}

# checkCorner asserts that a corner glyph meets something on both of the sides it joins.
# Corners only: a horizontal run may legitimately dangle at the tail tip.
func checkCorner(ch as string, x as int, y as int) {
    if (strings.indexOf("╭╮╰╯", $ch) < 0) {
        return;
    }
    for (def side in strings.chars(sidesOf($ch))) {
        def neighbour as string init neighbourOn($x, $y, $side);
        testing.assertTrue(strings.indexOf(sidesOf($neighbour), flipSide($side)) >= 0);
    }
}

func testTheLogoSnakeStartsAtItsHead() {
    # The head joins rightwards into the body, so there is something for it to join to.
    def head as int init strings.indexOf(LOGO[1], HEAD_GLYPH);
    testing.assertTrue($head >= 0);
    testing.assertEqual(glyphAt($head + 1, 1), "─");
}

func testTheLogoJHooksTheRightWay() {
    # A J's descender curves left: the stem stands above the *right* end of the hook. With
    # the stem above the left end the hook runs the wrong way and the letter reads as a U,
    # which is exactly what it did before somebody pointed it out.
    def stem as int init strings.indexOf(LOGO[3], "║");
    def hookEnd as int init strings.indexOf(LOGO[4], "╝");
    def hookStart as int init strings.indexOf(LOGO[4], "╚");
    testing.assertEqual($stem, $hookEnd);
    testing.assertTrue($hookStart < $stem);
}

func testTheLogoSpellsTheGamesName() {
    # The letter rows are the bottom three; checking a couple of their distinctive cells
    # is enough to catch a logo mangled by an editor or a re-indent.
    testing.assertEqual(len(LOGO), 5);
    testing.assertTrue(strings.contains(LOGO[2], "╔═╗"));
    testing.assertTrue(strings.contains(LOGO[4], "╚═╝"));
}

func testTheLogoHasAHeadOnIt() {
    testing.assertTrue(strings.contains(LOGO[1], HEAD_GLYPH));
}

func testTheLogoRowsAreNotAccidentallyEmpty() {
    for (def line in LOGO) {
        testing.assertTrue(len(strings.trim($line)) > 0);
    }
}

# --- the two kinds of border -------------------------------------------------

func testAWalledFieldIsDrawnWithASolidBorder() {
    def buf as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, 0, 1), "┌");
    testing.assertEqual(seen($buf, 1, 1), "─");
    testing.assertEqual(seen($buf, 0, 2), "│");
}

func testAWrappedFieldIsDrawnWithADashedBorder() {
    # A rule a player cannot see until they walk into it has to be visible before they do:
    # with no walls the frame is dashed, so the field looks like what it is.
    def g as rules.Game init rules.withWrap(staged(), true);
    def buf as screen.Buffer init render($g, 1, "ok", 24, 80);
    testing.assertEqual(seen($buf, 1, 1), WRAP_HORIZONTAL);
    testing.assertEqual(seen($buf, 0, 2), WRAP_VERTICAL);
    for (def corner in [
        [0, 1],
        [$g.width + 1, 1],
        [0, $g.height + 2],
        [$g.width + 1, $g.height + 2]
    ]) {
        testing.assertEqual(seen($buf, $corner[0], $corner[1]), WRAP_CORNER);
    }
}

func testTheTwoBordersShareNoGlyphs() {
    # So the two are told apart at a glance rather than by counting.
    def walled as screen.Buffer init render(staged(), 1, "ok", 24, 80);
    def wrapped as screen.Buffer init render(rules.withWrap(staged(), true), 1, "ok", 24, 80);
    testing.assertFalse(row($walled, 1) == row($wrapped, 1));
    testing.assertFalse(strings.contains(row($wrapped, 1), "─"));
    testing.assertFalse(strings.contains(row($walled, 1), WRAP_HORIZONTAL));
}

# --- that every legend names the keys the game actually has -------------------

func testEveryKeyLegendNamesEscapeTheWayItMustBePressed() {
    # One constant decides whether the legends say `esc` or `esc esc`. Every line that tells
    # a player how to leave has to be built from it, or a screen ends up instructing a
    # keypress that does nothing.
    for (def legend in [HOST_KEYS, GUEST_KEYS]) {
        testing.assertTrue(strings.contains($legend, keys.ESCAPE_LABEL));
    }
}

func testNoLegendNamesAKeyTheGameIgnores() {
    # A legend is the only place a player learns a key, so one naming a key that does
    # nothing is worse than one naming none. `q` and `x` are the likely mistakes, and are
    # checked with their spacing, since `quit` legitimately contains a q.
    def lines as list of string init [HOST_KEYS, GUEST_KEYS];
    for (def line in menuLines(["one game", "another"])) {
        $lines[] = $line;
    }
    for (def line in menuLines([])) {
        $lines[] = $line;
    }
    for (def line in $lines) {
        for (def dead in [" q ", " x ", " q  ", " x  ", "q / x", "q quit", "x menu"]) {
            testing.assertFalse(strings.contains($line, $dead));
        }
    }
}

func testTheJoinMenuOffersAWayOut() {
    # Including the empty one: "no games found" with no way to leave would be a dead end.
    for (def entries in [["a game"], []]) {
        def whole as string init strings.join(menuLines($entries), "\n");
        testing.assertTrue(strings.contains($whole, keys.ESCAPE_LABEL));
    }
}

