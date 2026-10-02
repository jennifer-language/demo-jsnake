# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for geom.j: the direction vocabulary, cell arithmetic, and the
# cell-key round trip. Run with:
#
#     jennifer test src/geom_test.j

use testing;
use maps;

# --- construction and equality ----------------------------------------------

func testAtBuildsTheCell() {
    def p as Point init at(3, 7);
    testing.assertEqual($p.x, 3);
    testing.assertEqual($p.y, 7);
}

func testEqualsComparesBothCoordinates() {
    testing.assertTrue(equals(at(2, 5), at(2, 5)));
    testing.assertFalse(equals(at(2, 5), at(5, 2)));
    testing.assertFalse(equals(at(2, 5), at(2, 6)));
}

func testPointsAreValueSemantic() {
    def a as Point init at(1, 1);
    def b as Point init $a;
    $b.x = 9;
    testing.assertEqual($a.x, 1);
}

# --- the direction vocabulary -----------------------------------------------

func testIsDirectionAcceptsTheFour() {
    testing.assertTrue(isDirection(UP));
    testing.assertTrue(isDirection(DOWN));
    testing.assertTrue(isDirection(LEFT));
    testing.assertTrue(isDirection(RIGHT));
}

func testIsDirectionRejectsAnythingElse() {
    testing.assertFalse(isDirection(""));
    testing.assertFalse(isDirection("north"));
    testing.assertFalse(isDirection("UP"));
}

func testDirectionsListIsClockwiseFromUp() {
    testing.assertEqual(len(DIRECTIONS), 4);
    testing.assertEqual(DIRECTIONS[0], UP);
    testing.assertEqual(DIRECTIONS[1], RIGHT);
    testing.assertEqual(DIRECTIONS[2], DOWN);
    testing.assertEqual(DIRECTIONS[3], LEFT);
}

# --- stepping ----------------------------------------------------------------

func testStepUpDecrementsY() {
    testing.assertTrue(equals(step(at(4, 4), UP), at(4, 3)));
}

func testStepDownIncrementsY() {
    testing.assertTrue(equals(step(at(4, 4), DOWN), at(4, 5)));
}

func testStepLeftAndRightMoveX() {
    testing.assertTrue(equals(step(at(4, 4), LEFT), at(3, 4)));
    testing.assertTrue(equals(step(at(4, 4), RIGHT), at(5, 4)));
}

func testStepWithUnknownDirectionStandsStill() {
    testing.assertTrue(equals(step(at(4, 4), "sideways"), at(4, 4)));
}

func testStepLeavesTheFieldWithoutComplaint() {
    # Bounds are the caller's business: step is arithmetic, not a rule.
    testing.assertTrue(equals(step(at(0, 0), UP), at(0, -1)));
}

# --- reversal ----------------------------------------------------------------

func testOppositePairsTheDirections() {
    testing.assertEqual(opposite(UP), DOWN);
    testing.assertEqual(opposite(DOWN), UP);
    testing.assertEqual(opposite(LEFT), RIGHT);
    testing.assertEqual(opposite(RIGHT), LEFT);
}

func testOppositeOfNonsenseIsItself() {
    testing.assertEqual(opposite("wobble"), "wobble");
}

func testIsReverseSpotsTheForbiddenTurn() {
    testing.assertTrue(isReverse(UP, DOWN));
    testing.assertTrue(isReverse(LEFT, RIGHT));
    testing.assertFalse(isReverse(UP, LEFT));
    testing.assertFalse(isReverse(UP, UP));
}

func testIsReverseRejectsNonsenseOnEitherSide() {
    testing.assertFalse(isReverse("", DOWN));
    testing.assertFalse(isReverse(UP, "downwards"));
}

# --- bounds ------------------------------------------------------------------

func testInBoundsAcceptsTheInterior() {
    testing.assertTrue(inBounds(at(0, 0), 10, 5));
    testing.assertTrue(inBounds(at(9, 4), 10, 5));
}

func testInBoundsRejectsEveryEdgeOverrun() {
    testing.assertFalse(inBounds(at(-1, 0), 10, 5));
    testing.assertFalse(inBounds(at(0, -1), 10, 5));
    testing.assertFalse(inBounds(at(10, 0), 10, 5));
    testing.assertFalse(inBounds(at(0, 5), 10, 5));
}

# --- list membership ---------------------------------------------------------

func testIndexOfFindsTheFirstOccurrence() {
    def cells as list of Point init [at(1, 1), at(2, 2), at(1, 1)];
    testing.assertEqual(indexOf($cells, at(1, 1)), 0);
    testing.assertEqual(indexOf($cells, at(2, 2)), 1);
}

func testIndexOfAnswersMinusOneWhenAbsent() {
    def cells as list of Point init [at(1, 1)];
    testing.assertEqual(indexOf($cells, at(0, 0)), -1);
    testing.assertEqual(indexOf([], at(0, 0)), -1);
}

func testContainsMirrorsIndexOf() {
    def cells as list of Point init [at(3, 4)];
    testing.assertTrue(contains($cells, at(3, 4)));
    testing.assertFalse(contains($cells, at(4, 3)));
}

# --- cell keys ---------------------------------------------------------------

func testKeyUsesTheDocumentedSpelling() {
    testing.assertEqual(key(at(12, 5)), "12.5");
    testing.assertEqual(key(at(0, 0)), "0.0");
}

func testKeyRoundTrips() {
    def p as Point init at(17, 3);
    testing.assertTrue(equals(fromKey(key($p)), $p));
}

func testKeyRoundTripsNegativeCoordinates() {
    def p as Point init at(-2, -9);
    testing.assertTrue(equals(fromKey(key($p)), $p));
}

func testKeysAreDistinctPerCell() {
    testing.assertNotEqual(key(at(1, 12)), key(at(11, 2)));
}

func testFromKeyIsTotalOnGarbage() {
    testing.assertTrue(equals(fromKey(""), at(0, 0)));
    testing.assertTrue(equals(fromKey("5"), at(0, 0)));
    testing.assertTrue(equals(fromKey("1.2.3"), at(0, 0)));
    testing.assertTrue(equals(fromKey("a.b"), at(0, 0)));
}

# --- tolerant integer reading ------------------------------------------------

func testToIntOrParsesDecimals() {
    testing.assertEqual(toIntOr("42", -1), 42);
    testing.assertEqual(toIntOr("-7", 0), -7);
}

func testToIntOrFallsBackOnGarbage() {
    testing.assertEqual(toIntOr("", 5), 5);
    testing.assertEqual(toIntOr("twelve", 5), 5);
}

func testToIntOrZeroIsTheZeroFlavour() {
    testing.assertEqual(toIntOrZero("8"), 8);
    testing.assertEqual(toIntOrZero("nope"), 0);
}

# --- row-major indices -------------------------------------------------------

func testIndexIsRowMajor() {
    testing.assertEqual(index(at(0, 0), 10), 0);
    testing.assertEqual(index(at(3, 0), 10), 3);
    testing.assertEqual(index(at(0, 1), 10), 10);
    testing.assertEqual(index(at(4, 2), 10), 24);
}

func testIndexRoundTripsThroughFromIndex() {
    def width as int init 13;
    for (def y as int init 0; $y < 7; $y = $y + 1) {
        for (def x as int init 0; $x < $width; $x = $x + 1) {
            def p as Point init at($x, $y);
            testing.assertTrue(equals(fromIndex(index($p, $width), $width), $p));
        }
    }
}

func testIndexIsUniquePerCell() {
    def seen as map of int to bool init {};
    for (def y as int init 0; $y < 5; $y = $y + 1) {
        for (def x as int init 0; $x < 8; $x = $x + 1) {
            def i as int init index(at($x, $y), 8);
            testing.assertFalse(maps.has($seen, $i));
            $seen[$i] = true;
        }
    }
    testing.assertEqual(len($seen), 40);
}

func testFromIndexWalksTheFieldInOrder() {
    testing.assertTrue(equals(fromIndex(0, 4), at(0, 0)));
    testing.assertTrue(equals(fromIndex(3, 4), at(3, 0)));
    testing.assertTrue(equals(fromIndex(4, 4), at(0, 1)));
    testing.assertTrue(equals(fromIndex(9, 4), at(1, 2)));
}

# --- step distance -----------------------------------------------------------

func testDistanceCountsStepsAlongTheGrid() {
    testing.assertEqual(distance(at(0, 0), at(3, 4)), 7);
    testing.assertEqual(distance(at(3, 4), at(0, 0)), 7);
    testing.assertEqual(distance(at(5, 5), at(5, 5)), 0);
}

func testDistanceIsNeverNegative() {
    testing.assertEqual(distance(at(9, 2), at(1, 8)), 14);
    testing.assertEqual(distance(at(-3, -4), at(0, 0)), 7);
}

func testDistanceOfOneStepIsOne() {
    for (def d in DIRECTIONS) {
        testing.assertEqual(distance(at(5, 5), step(at(5, 5), $d)), 1);
    }
}

func testAbsOfHandlesBothSigns() {
    testing.assertEqual(absOf(5), 5);
    testing.assertEqual(absOf(-5), 5);
    testing.assertEqual(absOf(0), 0);
}

# --- wrapping round the edges ------------------------------------------------

func testWrapLeavesAnInteriorCellAlone() {
    testing.assertTrue(equals(wrap(at(5, 3), 20, 10), at(5, 3)));
    testing.assertTrue(equals(wrap(at(0, 0), 20, 10), at(0, 0)));
    testing.assertTrue(equals(wrap(at(19, 9), 20, 10), at(19, 9)));
}

func testWrapCarriesAStepOffOneEdgeToTheOther() {
    testing.assertTrue(equals(wrap(at(-1, 5), 20, 10), at(19, 5)));
    testing.assertTrue(equals(wrap(at(20, 5), 20, 10), at(0, 5)));
    testing.assertTrue(equals(wrap(at(5, -1), 20, 10), at(5, 9)));
    testing.assertTrue(equals(wrap(at(5, 10), 20, 10), at(5, 0)));
}

func testWrapHandlesACornerInBothDirectionsAtOnce() {
    testing.assertTrue(equals(wrap(at(-1, -1), 20, 10), at(19, 9)));
    testing.assertTrue(equals(wrap(at(20, 10), 20, 10), at(0, 0)));
}

func testWrapReliesOnFlooredModuloRatherThanASignFix() {
    # -1 % 20 is 19 in Jennifer, so no correction is needed for a negative coordinate.
    testing.assertEqual(wrap(at(-1, 0), 20, 10).x, 19);
    testing.assertEqual(wrap(at(-21, 0), 20, 10).x, 19);
}

func testWrapOfAStepIsAlwaysOnTheField() {
    for (def d in DIRECTIONS) {
        for (def x as int init 0; $x < 4; $x = $x + 3) {
            for (def y as int init 0; $y < 4; $y = $y + 3) {
                def p as Point init wrap(step(at($x, $y), $d), 4, 4);
                testing.assertTrue(inBounds($p, 4, 4));
            }
        }
    }
}

func testWrapOnADegenerateFieldIsHarmless() {
    testing.assertTrue(equals(wrap(at(3, 3), 0, 0), at(3, 3)));
    testing.assertTrue(equals(wrap(at(3, 3), -1, 5), at(3, 3)));
}
