# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for keys.j. Two layers on purpose: the mapping is checked
# against hand-built `screen.Key` values, and then against the real escape
# sequences a terminal sends, decoded by `screen.decodeKey` - because a mapping
# that is self-consistent but disagrees with the terminal is still wrong. Run
# with:
#
#     jennifer test src/keys_test.j

use testing;
use convert;
use strings;

# key builds a decoded keypress the way screen.decodeKey would.
func key(name as string, char as string) {
    return screen.Key{name: $name, char: $char};
}

# --- steering ----------------------------------------------------------------

func testTheArrowKeysSteer() {
    testing.assertEqual(directionOf(key("up", "")), geom.UP);
    testing.assertEqual(directionOf(key("down", "")), geom.DOWN);
    testing.assertEqual(directionOf(key("left", "")), geom.LEFT);
    testing.assertEqual(directionOf(key("right", "")), geom.RIGHT);
}

func testWasdSteersToo() {
    testing.assertEqual(directionOf(key("char", "w")), geom.UP);
    testing.assertEqual(directionOf(key("char", "s")), geom.DOWN);
    testing.assertEqual(directionOf(key("char", "a")), geom.LEFT);
    testing.assertEqual(directionOf(key("char", "d")), geom.RIGHT);
}

func testWasdIsCaseInsensitive() {
    testing.assertEqual(directionOf(key("char", "W")), geom.UP);
    testing.assertEqual(directionOf(key("char", "S")), geom.DOWN);
    testing.assertEqual(directionOf(key("char", "A")), geom.LEFT);
    testing.assertEqual(directionOf(key("char", "D")), geom.RIGHT);
}

func testAnyOtherKeySteersNowhere() {
    testing.assertEqual(directionOf(key("char", "z")), "");
    testing.assertEqual(directionOf(key("char", "1")), "");
    testing.assertEqual(directionOf(key("f5", "")), "");
    testing.assertEqual(directionOf(key("home", "")), "");
    testing.assertEqual(directionOf(key(NONE, "")), "");
}

func testEveryDirectionKeyMapsToARealDirection() {
    for (def k in [key("up", ""), key("char", "w"), key("char", "A"), key("right", "")]) {
        testing.assertTrue(geom.isDirection(directionOf($k)));
    }
}

# --- backing out, and stopping -----------------------------------------------

func testEscapeIsTheKeyThatBacksOut() {
    testing.assertTrue(isBack(key("escape", "")));
}

func testNothingElseBacksOut() {
    # Escape and nothing else. A plain letter that quietly left a game would be a trap: the
    # letters are for steering, and a player types them without meaning a command.
    for (def k in [
        key("char", "q"),
        key("char", "Q"),
        key("char", "x"),
        key("char", "X"),
        key("char", "w"),
        key("up", ""),
        key("ctrl-c", ""),
        key("eof", ""),
        key(NONE, "")
    ]) {
        testing.assertFalse(isBack($k));
    }
}

func testCtrlCAndEndOfInputStop() {
    testing.assertTrue(isAbort(key("ctrl-c", "")));
    testing.assertTrue(isAbort(key("eof", "")));
}

func testNothingElseStops() {
    for (def k in [
        key("escape", ""),
        key("char", "q"),
        key("char", "x"),
        key("char", "w"),
        key("up", ""),
        key(NONE, "")
    ]) {
        testing.assertFalse(isAbort($k));
    }
}

func testBackingOutAndStoppingAreDifferentKeys() {
    # They do different things - Escape is one level, Ctrl-C is the whole program - so no
    # key may be both, or a host meaning to return to its menu would lose the game instead.
    for (def k in [key("escape", ""), key("ctrl-c", ""), key("eof", ""), key("char", "q")]) {
        testing.assertFalse(isBack($k) and isAbort($k));
    }
}

# --- the other intentions ----------------------------------------------------

func testRefreshKeys() {
    testing.assertTrue(isRefresh(key("char", "r")));
    testing.assertTrue(isRefresh(key("char", "R")));
    testing.assertTrue(isRefresh(key("f5", "")));
    testing.assertFalse(isRefresh(key("char", "q")));
    testing.assertFalse(isRefresh(key("f6", "")));
}

func testConfirmKeys() {
    testing.assertTrue(isConfirm(key("enter", "")));
    testing.assertTrue(isConfirm(key("char", " ")));
    testing.assertFalse(isConfirm(key("char", "x")));
    testing.assertFalse(isConfirm(key("tab", "")));
}

func testIsNothingSpotsAnEmptyPoll() {
    testing.assertTrue(isNothing(key(NONE, "")));
    testing.assertTrue(isNothing(key("unknown", "")));
    testing.assertFalse(isNothing(key("char", "w")));
    testing.assertFalse(isNothing(key("up", "")));
}

func testDigitValueReadsOneThroughNine() {
    for (def d as int init 1; $d <= 9; $d = $d + 1) {
        testing.assertEqual(digitValue(key("char", convert.toString($d))), $d);
    }
}

func testDigitValueIsZeroForAnythingElse() {
    testing.assertEqual(digitValue(key("char", "0")), 0);
    testing.assertEqual(digitValue(key("char", "x")), 0);
    testing.assertEqual(digitValue(key("up", "")), 0);
    testing.assertEqual(digitValue(key(NONE, "")), 0);
}

func testTheIntentionsDoNotOverlap() {
    # A key must not both steer and leave, or the game would do two things at once.
    for (def k in [key("escape", ""), key("ctrl-c", ""), key("char", "r")]) {
        testing.assertEqual(directionOf($k), "");
    }
    for (def k in [key("up", ""), key("char", "w"), key("char", "d")]) {
        testing.assertFalse(isBack($k));
        testing.assertFalse(isAbort($k));
        testing.assertFalse(isRefresh($k));
    }
}

func testWAndSStillSteerRatherThanLeaving() {
    # `q` and `x` are free letters again, but the steering letters must not have moved.
    testing.assertEqual(directionOf(key("char", "w")), geom.UP);
    testing.assertEqual(directionOf(key("char", "a")), geom.LEFT);
    testing.assertEqual(directionOf(key("char", "s")), geom.DOWN);
    testing.assertEqual(directionOf(key("char", "d")), geom.RIGHT);
}

func testPlainLettersAreNotCommands() {
    # `q` and `x` are the two a player raised on other terminal programs is most likely to
    # try. They have to do nothing at all - not leave, and not steer either, which is the
    # subtler way a letter could end up doing damage.
    for (def ch in ["q", "Q", "x", "X"]) {
        def k as screen.Key init key("char", $ch);
        testing.assertFalse(isBack($k));
        testing.assertFalse(isAbort($k));
        testing.assertFalse(isConfirm($k));
        testing.assertFalse(isRefresh($k));
        testing.assertEqual(directionOf($k), "");
        testing.assertEqual(digitValue($k), 0);
    }
}

# --- against what a terminal actually sends ---------------------------------

func testTheRealArrowKeyEscapeSequencesSteer() {
    testing.assertEqual(directionOf(screen.decodeKey([27, 91, 65])), geom.UP);
    testing.assertEqual(directionOf(screen.decodeKey([27, 91, 66])), geom.DOWN);
    testing.assertEqual(directionOf(screen.decodeKey([27, 91, 68])), geom.LEFT);
    testing.assertEqual(directionOf(screen.decodeKey([27, 91, 67])), geom.RIGHT);
}

func testTheApplicationCursorKeysSteerToo() {
    # SS3-introduced arrows, which a terminal in application-keypad mode sends.
    testing.assertEqual(directionOf(screen.decodeKey([27, 79, 65])), geom.UP);
    testing.assertEqual(directionOf(screen.decodeKey([27, 79, 67])), geom.RIGHT);
}

func testTheRealLetterKeysSteer() {
    testing.assertEqual(directionOf(screen.decodeKey([119])), geom.UP);
    testing.assertEqual(directionOf(screen.decodeKey([115])), geom.DOWN);
    testing.assertEqual(directionOf(screen.decodeKey([97])), geom.LEFT);
    testing.assertEqual(directionOf(screen.decodeKey([100])), geom.RIGHT);
}

func testTheRealEscapeByteBacksOut() {
    # 27 is what the key sends. Whether a *lone* one ever reaches us is `ESCAPE_NEEDS_TWO`;
    # the mapping from the decoded key is this file's business and is right either way.
    testing.assertTrue(isBack(screen.decodeKey([27])));
}

func testTwoRealEscapeBytesAlsoBackOut() {
    # What a player actually produces, pressing the key twice: the pair decodes as a single
    # `escape`, which is the only way one is delivered. See `ESCAPE_NEEDS_TWO`.
    testing.assertTrue(isBack(screen.decodeKey([27, 27])));
}

func testTheRealCtrlCAndEofBytesStop() {
    testing.assertTrue(isAbort(screen.decodeKey([3])));
    testing.assertTrue(isAbort(screen.decodeKey([])));
}

func testTheRealQAndXBytesDoNothing() {
    for (def seq in [[113], [81], [120], [88]]) {
        def k as screen.Key init screen.decodeKey($seq);
        testing.assertFalse(isBack($k));
        testing.assertFalse(isAbort($k));
    }
}

func testEscapeThenALetterIsNotAnAccidentalExit() {
    # Escape followed by a printable key decodes as `alt-<char>` rather than as an escape
    # (see `ESCAPE_NEEDS_TWO`). It must not count as backing out - a player who pressed
    # Escape and then a steering key has not asked to leave.
    testing.assertFalse(isBack(screen.decodeKey([27, 113])));
    testing.assertFalse(isBack(screen.decodeKey([27, 119])));
    testing.assertEqual(directionOf(screen.decodeKey([27, 119])), "");
}

func testTheRealDigitKeysPickAHost() {
    testing.assertEqual(digitValue(screen.decodeKey([49])), 1);
    testing.assertEqual(digitValue(screen.decodeKey([51])), 3);
}

func testTheRealEnterKeyConfirms() {
    testing.assertTrue(isConfirm(screen.decodeKey([13])));
    testing.assertTrue(isConfirm(screen.decodeKey([10])));
    testing.assertTrue(isConfirm(screen.decodeKey([32])));
}

func testAMultiByteCharacterIsNotAnAccidentalCommand() {
    # A player with a non-ASCII keyboard layout must not leave by pressing 'ö'.
    def k as screen.Key init screen.decodeKey([195, 182]);
    testing.assertEqual($k.name, "char");
    testing.assertFalse(isBack($k));
    testing.assertFalse(isAbort($k));
    testing.assertEqual(directionOf($k), "");
    testing.assertEqual(digitValue($k), 0);
}

# --- the label the legends print ---------------------------------------------

func testTheEscapeLabelMatchesWhetherOnePressIsEnough() {
    # The legend has to agree with the interpreter underneath, or the screen is lying about
    # what to press. One flag drives both; this is what keeps them together.
    if (ESCAPE_NEEDS_TWO) {
        testing.assertEqual(ESCAPE_LABEL, "esc esc");
    } else {
        testing.assertEqual(ESCAPE_LABEL, "esc");
    }
}

func testBothLabelsAreSpelledTheWayThePlayerPressesThem() {
    # The flag's whole purpose is that flipping it fixes every legend at once, so both
    # answers are checked here - including the one this build does not use.
    testing.assertEqual(escapeLabelFor(true), "esc esc");
    testing.assertEqual(escapeLabelFor(false), "esc");
}

func testTheEscapeLabelNamesNoOtherKey() {
    # Whatever the label says, it names Escape and nothing else.
    testing.assertFalse(strings.contains(ESCAPE_LABEL, "q"));
    testing.assertFalse(strings.contains(ESCAPE_LABEL, "x"));
}

func testEscapeDoesNotAlsoMeanSomethingElse() {
    # Escape carries the whole navigation model now, so it must not double as anything -
    # a key that both left the screen and confirmed on it would be unusable.
    def k as screen.Key init key("escape", "");
    testing.assertEqual(directionOf($k), "");
    testing.assertFalse(isRefresh($k));
    testing.assertFalse(isConfirm($k));
    testing.assertFalse(isAbort($k));
    testing.assertEqual(digitValue($k), 0);
    testing.assertFalse(isNothing($k));
}
