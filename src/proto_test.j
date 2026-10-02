# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for proto.j: every message's round trip, the name scrubber,
# stream framing, and - at least as important - what happens to the malformed,
# truncated, hostile, and version-skewed lines a host will actually receive.
# Run with:
#
#     jennifer test src/proto_test.j

use testing;

# proto knows nothing of transports; the tests check the two agree on the limits.
import "./link.j" as link;

# --- name scrubbing ----------------------------------------------------------

func testCleanNameKeepsAnOrdinaryName() {
    testing.assertEqual(cleanName("ada"), "ada");
    testing.assertEqual(cleanName("Player-2"), "Player-2");
}

func testCleanNameDropsEverySeparator() {
    testing.assertEqual(cleanName("a|b"), "ab");
    testing.assertEqual(cleanName("a;b"), "ab");
    testing.assertEqual(cleanName("a,b"), "ab");
    testing.assertEqual(cleanName("a b"), "ab");
    testing.assertEqual(cleanName("a.b"), "ab");
}

func testCleanNameDropsControlCharactersAndNewlines() {
    testing.assertEqual(cleanName("ad\na"), "ada");
    testing.assertEqual(cleanName("ad\ta"), "ada");
    testing.assertEqual(cleanName("ad\ra"), "ada");
}

func testCleanNameTrimsToTheLimit() {
    def long as string init strings.repeat("x", 40);
    testing.assertEqual(len(cleanName($long)), MAX_NAME);
}

func testCleanNameFallsBackForAnEmptyResult() {
    testing.assertEqual(cleanName(""), ANONYMOUS);
    testing.assertEqual(cleanName("|||"), ANONYMOUS);
    testing.assertEqual(cleanName("   "), ANONYMOUS);
}

func testCleanNameIsIdempotent() {
    def once as string init cleanName("we|ird na;me!!");
    testing.assertEqual(cleanName($once), $once);
}

func testAScrubbedNameNeverBreaksTheGrammar() {
    # The whole point of the scrubber: a name goes through an encode/decode
    # round trip without adding a field.
    def nasty as string init "evil|JOIN|1|pwn";
    def line as string init encodeJoin($nasty, 24, 80);
    # Kind, version, name, rows, cols - and not one field more, whatever the name
    # tried to smuggle in.
    testing.assertEqual(len(strings.split($line, FIELD_SEPARATOR)), 5);
    testing.assertEqual(decode($line).kind, JOIN);
    testing.assertEqual(decode($line).rows, 24);
}

# --- kindOf ------------------------------------------------------------------

func testKindOfReadsTheLeadingField() {
    testing.assertEqual(kindOf("STATE|1|2|3||"), STATE);
    testing.assertEqual(kindOf("JOIN|1|ada"), JOIN);
    testing.assertEqual(kindOf("PING|4"), PING);
}

func testKindOfRejectsTheUnknown() {
    testing.assertEqual(kindOf("HELLO|1"), BAD);
    testing.assertEqual(kindOf(""), BAD);
    testing.assertEqual(kindOf("join|1|ada"), BAD);
}

# --- JOIN --------------------------------------------------------------------

func testJoinRoundTrips() {
    def m as Message init decode(encodeJoin("ada", 24, 80));
    testing.assertEqual($m.kind, JOIN);
    testing.assertEqual($m.text, "ada");
    testing.assertEqual($m.name, "ada");
}

func testJoinCarriesTheVersion() {
    testing.assertTrue(strings.contains(
        encodeJoin("ada", 24, 80),
        FIELD_SEPARATOR + VERSION +
            FIELD_SEPARATOR));
}

func testJoinFromAnotherVersionIsRefused() {
    testing.assertEqual(decode("JOIN|99|ada").kind, BAD);
    testing.assertEqual(decode("JOIN||ada").kind, BAD);
}

func testJoinScrubsOnTheHostSide() {
    # A hand-rolled client can skip its own scrubber; the host's decoder cannot.
    testing.assertEqual(
        decode("JOIN|1|" + strings.repeat("z", 50)).text,
        strings.repeat("z", MAX_NAME));
}

# --- WELCOME -----------------------------------------------------------------

func testWelcomeRoundTrips() {
    def m as Message init decode(encodeWelcome(3, 40, 20, 120));
    testing.assertEqual($m.kind, WELCOME);
    testing.assertEqual($m.id, 3);
    testing.assertEqual($m.width, 40);
    testing.assertEqual($m.height, 20);
    testing.assertEqual($m.tickMs, 120);
}

func testWelcomeWithMissingFieldsReadsAsZero() {
    def m as Message init decode("WELCOME|7");
    testing.assertEqual($m.id, 7);
    testing.assertEqual($m.width, 0);
    testing.assertEqual($m.tickMs, 0);
}

func testWelcomeWithGarbageNumbersReadsAsZero() {
    def m as Message init decode("WELCOME|x|y|z|w");
    testing.assertEqual($m.id, 0);
    testing.assertEqual($m.height, 0);
}

# --- DENY and BYE ------------------------------------------------------------

func testDenyRoundTrips() {
    def m as Message init decode(encodeDeny("game full"));
    testing.assertEqual($m.kind, DENY);
    testing.assertEqual($m.text, "game full");
}

func testByeRoundTrips() {
    def m as Message init decode(encodeBye("host shutting down"));
    testing.assertEqual($m.kind, BYE);
    testing.assertEqual($m.text, "host shutting down");
}

func testAReasonCannotSmuggleAFieldOrALine() {
    def m as Message init decode(encodeDeny("no|room\nSTATE|9"));
    testing.assertEqual($m.kind, DENY);
    testing.assertFalse(strings.contains($m.text, FIELD_SEPARATOR));
    testing.assertFalse(strings.contains($m.text, LINE_END));
}

# --- DIR ---------------------------------------------------------------------

func testDirRoundTrips() {
    def m as Message init decode(encodeDir(2, geom.UP));
    testing.assertEqual($m.kind, DIR);
    testing.assertEqual($m.id, 2);
    testing.assertEqual($m.text, geom.UP);
}

func testDirRoundTripsEveryDirection() {
    for (def d in geom.DIRECTIONS) {
        testing.assertEqual(decode(encodeDir(1, $d)).text, $d);
    }
}

func testDirCarriesNonsenseThroughForTheRulesToRefuse() {
    # proto's job is transport, not validation: rules.setDirection is the guard.
    def m as Message init decode("DIR|1|sideways");
    testing.assertEqual($m.kind, DIR);
    testing.assertEqual($m.text, "sideways");
    testing.assertFalse(geom.isDirection($m.text));
}

# --- QUIT and PING -----------------------------------------------------------

func testQuitRoundTrips() {
    def m as Message init decode(encodeQuit(5));
    testing.assertEqual($m.kind, QUIT);
    testing.assertEqual($m.id, 5);
}

func testPingRoundTrips() {
    def m as Message init decode(encodePing(6));
    testing.assertEqual($m.kind, PING);
    testing.assertEqual($m.id, 6);
}

# --- discovery ---------------------------------------------------------------

func testQueryRoundTrips() {
    testing.assertEqual(decode(encodeQuery()).kind, QUERY);
}

func testQueryFromAnotherVersionIsRefused() {
    testing.assertEqual(decode("QUERY|2").kind, BAD);
}

func testOfferRoundTrips() {
    def m as Message init decode(encodeOffer(47475, "tcp", "kitchen", 2, 8));
    testing.assertEqual($m.kind, OFFER);
    testing.assertEqual($m.port, 47475);
    testing.assertEqual($m.text, "tcp");
    testing.assertEqual($m.name, "kitchen");
    testing.assertEqual($m.players, 2);
    testing.assertEqual($m.capacity, 8);
}

func testOfferFromAnotherVersionIsRefused() {
    testing.assertEqual(decode("OFFER|7|47475|tcp|x|1|8").kind, BAD);
}

func testOfferWithATruncatedTailReadsAsZeros() {
    def m as Message init decode("OFFER|1|47475");
    testing.assertEqual($m.kind, OFFER);
    testing.assertEqual($m.port, 47475);
    testing.assertEqual($m.players, 0);
    testing.assertEqual($m.capacity, 0);
}

# --- STATE -------------------------------------------------------------------

# sample builds a small game with two snakes and two pieces of food.
func sample() {
    def g as rules.Game init rules.newGame(20, 10, 5);
    $g = rules.addSnake($g, 1, "ada");
    $g = rules.addSnake($g, 2, "bob");
    $g = rules.advance($g);
    $g = rules.advance($g);
    return $g;
}

func testStateRoundTripsTheField() {
    def g as rules.Game init sample();
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual($back.width, $g.width);
    testing.assertEqual($back.height, $g.height);
    testing.assertEqual($back.tick, $g.tick);
}

func testStateRoundTripsTheFood() {
    def g as rules.Game init sample();
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(len($back.food), len($g.food));
    for (def f in $g.food) {
        def at as int init rules.foodIndexAt($back.food, $f.cell);
        testing.assertTrue($at >= 0);
        testing.assertEqual($back.food[$at].kind, $f.kind);
        testing.assertEqual($back.food[$at].life, $f.life);
    }
}

func testStateRoundTripsEveryFoodKind() {
    def g as rules.Game init rules.newGame(20, 10, 1);
    def food as list of rules.Item init [];
    for (def i as int init 0; $i < len(rules.FOOD_KINDS); $i = $i + 1) {
        $food[] = rules.foodAt(rules.FOOD_KINDS[$i], geom.at($i, 3));
    }
    $g.food = $food;
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(len($back.food), len(rules.FOOD_KINDS));
    for (def i as int init 0; $i < len(rules.FOOD_KINDS); $i = $i + 1) {
        testing.assertEqual($back.food[$i].kind, rules.FOOD_KINDS[$i]);
        testing.assertEqual($back.food[$i].life, rules.recipeFor(rules.FOOD_KINDS[$i]).life);
    }
}

func testStateRoundTripsACountdownPartWayThrough() {
    def g as rules.Game init rules.newGame(20, 10, 1);
    $g.food = [rules.Item{kind: rules.TOADSTOOL, cell: geom.at(4, 4), life: 37}];
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual($back.food[0].life, 37);
    testing.assertEqual($back.food[0].kind, rules.TOADSTOOL);
}

func testATerseFoodRecordReadsAsPlainFood() {
    # A bare cell key, as a hand-typed test or an `nc` session produces.
    def m as Message init decode("STATE|1|20|10|3.4;5.6|");
    testing.assertEqual(len($m.game.food), 2);
    testing.assertEqual($m.game.food[0].kind, rules.PLAIN);
    testing.assertEqual($m.game.food[0].life, rules.PERMANENT);
    testing.assertTrue(geom.equals($m.game.food[1].cell, geom.at(5, 6)));
}

func testAnUnknownFoodKindFromAPeerReadsAsPlainFood() {
    def m as Message init decode("STATE|1|20|10|caviar,3.4,50|");
    testing.assertEqual(len($m.game.food), 1);
    testing.assertEqual($m.game.food[0].kind, rules.PLAIN);
    testing.assertTrue(geom.equals($m.game.food[0].cell, geom.at(3, 4)));
}

func testAFoodRecordWithNoLifeReadsAsPermanent() {
    def m as Message init decode("STATE|1|20|10|candy,3.4|");
    testing.assertEqual($m.game.food[0].kind, rules.CANDY);
    testing.assertEqual($m.game.food[0].life, rules.PERMANENT);
}

func testStateRoundTripsTheGhostTimer() {
    def g as rules.Game init sample();
    $g.snakes[0].ghost = 55;
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(rules.snakeById($back, $g.snakes[0].id).ghost, 55);
}

func testStateRoundTripsEverySnake() {
    def g as rules.Game init sample();
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(len($back.snakes), len($g.snakes));
    for (def s in $g.snakes) {
        def r as rules.Snake init rules.snakeById($back, $s.id);
        testing.assertEqual($r.name, $s.name);
        testing.assertEqual($r.alive, $s.alive);
        testing.assertEqual($r.score, $s.score);
        testing.assertEqual($r.deaths, $s.deaths);
        testing.assertEqual($r.dir, $s.dir);
        testing.assertEqual(len($r.cells), len($s.cells));
        for (def i as int init 0; $i < len($s.cells); $i = $i + 1) {
            testing.assertTrue(geom.equals($r.cells[$i], $s.cells[$i]));
        }
    }
}

func testStateRoundTripsALongBody() {
    def g as rules.Game init rules.newGame(30, 12, 9);
    $g = rules.addSnake($g, 1, "ada");
    for (def i as int init 0; $i < 6; $i = $i + 1) {
        $g = rules.advance($g);
    }
    def back as rules.Game init decode(encodeState($g)).game;
    def before as rules.Snake init rules.snakeById($g, 1);
    def after as rules.Snake init rules.snakeById($back, 1);
    testing.assertEqual(len($after.cells), len($before.cells));
    testing.assertTrue(geom.equals($after.cells[0], $before.cells[0]));
}

func testStateRoundTripsADeadSnake() {
    def g as rules.Game init rules.newGame(20, 10, 3);
    $g = rules.addSnake($g, 1, "ada");
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    $g.snakes[0].deaths = 2;
    def back as rules.Game init decode(encodeState($g)).game;
    def s as rules.Snake init rules.snakeById($back, 1);
    testing.assertFalse($s.alive);
    testing.assertEqual(len($s.cells), 0);
    testing.assertEqual($s.deaths, 2);
}

func testStateRoundTripsAnEmptyGame() {
    def g as rules.Game init rules.newGame(20, 10, 1);
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(len($back.snakes), 0);
    testing.assertEqual(len($back.food), 0);
}

func testStateIsOneLine() {
    def line as string init encodeState(sample());
    testing.assertFalse(strings.contains($line, LINE_END));
}

func testStateClampsAnAbsurdFieldFromAPeer() {
    # A hostile host must not be able to make a client allocate a huge buffer.
    def m as Message init decode("STATE|1|99999999|99999999||");
    testing.assertEqual($m.game.width, rules.MAX_WIDTH);
    testing.assertEqual($m.game.height, rules.MAX_HEIGHT);
}

func testStateSurvivesATruncatedSnakeRecord() {
    def m as Message init decode("STATE|1|20|10||1,ada,1,0,0,up,0");
    testing.assertEqual($m.kind, STATE);
    testing.assertEqual(len($m.game.snakes), 0);
}

func testStateSurvivesAGarbageBody() {
    def m as Message init decode("STATE|1|20|10||1,ada,1,0,0,up,0,3,zz qq");
    testing.assertEqual(len($m.game.snakes), 1);
    testing.assertEqual(len(rules.snakeById($m.game, 1).cells), 2);
}

func testStateToleratesDoubledAndTrailingSeparators() {
    def m as Message init decode("STATE|1|20|10|plain,3.4,0;;plain,5.6,0;||");
    testing.assertEqual(len($m.game.food), 2);
}

# --- decode is total ---------------------------------------------------------

func testDecodeOfRubbishIsBadNotAThrow() {
    testing.assertEqual(decode("").kind, BAD);
    testing.assertEqual(decode("|||||").kind, BAD);
    testing.assertEqual(decode("\n").kind, BAD);
    testing.assertEqual(decode("GET / HTTP/1.1").kind, BAD);
    testing.assertEqual(decode(strings.repeat("A", 5000)).kind, BAD);
}

func testDecodeKeepsTheOffendingLineForTheLog() {
    testing.assertEqual(decode("NONSENSE|1").text, "NONSENSE|1");
}

func testDecodeToleratesCrLfAndSurroundingSpace() {
    testing.assertEqual(decode("PING|9\r").id, 9);
    testing.assertEqual(decode("  PING|9  ").id, 9);
}

func testDecodeNeverThrowsOnAnyPrefixOfAValidMessage() {
    # Every truncation of a real line must decode to something, not blow up.
    def full as string init encodeState(sample());
    for (def n as int init 0; $n < len($full); $n = $n + 1) {
        def m as Message init decode($full[..$n]);
        testing.assertTrue($m.kind == STATE or $m.kind == BAD);
    }
}

# --- framing -----------------------------------------------------------------

func testFramesSplitsWholeLines() {
    def f as Frames init frames("A|1\nB|2\n");
    testing.assertEqual(len($f.lines), 2);
    testing.assertEqual($f.lines[0], "A|1");
    testing.assertEqual($f.lines[1], "B|2");
    testing.assertEqual($f.rest, "");
}

func testFramesKeepsThePartialTail() {
    def f as Frames init frames("A|1\nB|2");
    testing.assertEqual(len($f.lines), 1);
    testing.assertEqual($f.rest, "B|2");
}

func testFramesOfAnEmptyBufferIsEmpty() {
    def f as Frames init frames("");
    testing.assertEqual(len($f.lines), 0);
    testing.assertEqual($f.rest, "");
}

func testFramesDropsBlankLines() {
    def f as Frames init frames("A|1\n\n\nB|2\n");
    testing.assertEqual(len($f.lines), 2);
}

func testFramesStripsCarriageReturns() {
    def f as Frames init frames("A|1\r\nB|2\r\n");
    testing.assertEqual($f.lines[0], "A|1");
    testing.assertEqual($f.lines[1], "B|2");
}

func testFramesReassemblesAcrossChunks() {
    # The case that makes TCP different from UDP: a message split by the network.
    def whole as string init wire(encodeDir(1, geom.LEFT)) + wire(encodePing(1));
    def carried as string init "";
    def got as list of string init [];
    for (def i as int init 0; $i < len($whole); $i = $i + 1) {
        def f as Frames init frames($carried + $whole[$i..$i + 1]);
        for (def line in $f.lines) {
            $got[] = $line;
        }
        $carried = $f.rest;
    }
    testing.assertEqual(len($got), 2);
    testing.assertEqual(decode($got[0]).text, geom.LEFT);
    testing.assertEqual(decode($got[1]).kind, PING);
    testing.assertEqual($carried, "");
}

func testWireAddsExactlyOneTerminator() {
    testing.assertEqual(wire("A|1"), "A|1" + LINE_END);
    def f as Frames init frames(wire(encodePing(3)));
    testing.assertEqual(len($f.lines), 1);
    testing.assertEqual($f.rest, "");
}

# --- the terminal size on a join --------------------------------------------

func testJoinCarriesTheTerminalSize() {
    def m as Message init decode(encodeJoin("ada", 40, 120));
    testing.assertEqual($m.kind, JOIN);
    testing.assertEqual($m.text, "ada");
    testing.assertEqual($m.rows, 40);
    testing.assertEqual($m.cols, 120);
}

func testAJoinWithNoSizeReportsZero() {
    # An older or terser client says nothing; the host treats that as "no limit".
    def m as Message init decode("JOIN|1|ada");
    testing.assertEqual($m.kind, JOIN);
    testing.assertEqual($m.rows, 0);
    testing.assertEqual($m.cols, 0);
}

func testAJoinWithAGarbledSizeReportsZero() {
    def m as Message init decode("JOIN|1|ada|tall|wide");
    testing.assertEqual($m.rows, 0);
    testing.assertEqual($m.cols, 0);
}

# --- the lobby --------------------------------------------------------------

# roster builds a lobby roster the way a host would.
func roster() {
    def seats as list of Seat init [];
    $seats[] = Seat{id: 1, name: "ada", kind: "human", rows: 24, cols: 80};
    $seats[] = Seat{id: 2, name: "cpu1-hard", kind: "computer", rows: 0, cols: 0};
    return $seats;
}

func testLobbyRoundTrips() {
    def m as Message init decode(encodeLobby(44, 16, 125, 8, roster(), 1));
    testing.assertEqual($m.kind, LOBBY);
    testing.assertEqual($m.width, 44);
    testing.assertEqual($m.height, 16);
    testing.assertEqual($m.tickMs, 125);
    testing.assertEqual($m.capacity, 8);
}

func testLobbyRoundTripsTheRoster() {
    def m as Message init decode(encodeLobby(44, 16, 125, 8, roster(), 1));
    testing.assertEqual(len($m.seats), 2);
    testing.assertEqual($m.seats[0].id, 1);
    testing.assertEqual($m.seats[0].name, "ada");
    testing.assertEqual($m.seats[0].kind, "human");
    testing.assertEqual($m.seats[0].rows, 24);
    testing.assertEqual($m.seats[0].cols, 80);
    testing.assertEqual($m.seats[1].name, "cpu1-hard");
    testing.assertEqual($m.seats[1].kind, "computer");
}

func testAnEmptyLobbyRoundTrips() {
    def m as Message init decode(encodeLobby(44, 16, 125, 8, [], 1));
    testing.assertEqual($m.kind, LOBBY);
    testing.assertEqual(len($m.seats), 0);
}

func testALobbyIsOneLine() {
    testing.assertFalse(strings.contains(encodeLobby(44, 16, 125, 8, roster(), 1), LINE_END));
}

func testALobbyScrubsTheNamesItPublishes() {
    # A roster goes out to every client, so a name that could break the grammar must
    # not reach the wire even if it somehow reached the host.
    def seats as list of Seat init [
        Seat{id: 1, name: "ev|il;x", kind: "human", rows: 24, cols: 80}
    ];
    def m as Message init decode(encodeLobby(44, 16, 125, 8, $seats, 1));
    testing.assertEqual(len($m.seats), 1);
    testing.assertEqual($m.seats[0].name, "evilx");
}

func testALobbySurvivesATruncatedSeatRecord() {
    def m as Message init decode("LOBBY|44|16|125|8|1,ada");
    testing.assertEqual($m.kind, LOBBY);
    testing.assertEqual(len($m.seats), 0);
}

func testALobbySeatWithNoSizeReadsAsZero() {
    def m as Message init decode("LOBBY|44|16|125|8|1,ada,human");
    testing.assertEqual(len($m.seats), 1);
    testing.assertEqual($m.seats[0].rows, 0);
}

func testALobbyWithAGarbledHeadFallsBackToTheMinimum() {
    def m as Message init decode("LOBBY|x|y|z|w|");
    testing.assertEqual($m.game.width, rules.MIN_WIDTH);
    testing.assertEqual($m.width, rules.MIN_WIDTH);
    testing.assertEqual($m.height, rules.MIN_HEIGHT);
}

# --- how big a STATE line can get -------------------------------------------

# packed is the worst case a STATE line can reach for a given field: every cell covered
# by snake, split between the maximum number of players so the per-snake overhead
# repeats as often as possible, with the longest legal names.
func packed(width as int, height as int) {
    def g as rules.Game init rules.newGame($width, $height, 1);
    def per as int init ($width * $height) // rules.MAX_PLAYERS;
    for (def id as int init 1; $id <= rules.MAX_PLAYERS; $id = $id + 1) {
        $g = rules.addSnake($g, $id, strings.repeat("m", MAX_NAME));
        def body as list of geom.Point init [];
        for (def i as int init 0; $i < $per; $i = $i + 1) {
            def at as int init ($id - 1) * $per + $i;
            $body[] = geom.at($at % $width, $at // $width);
        }
        $g.snakes[$id - 1].cells = $body;
    }
    return $g;
}

func testTheMeasuredCostPerCellIsAnUpperBound() {
    # STATE_BYTES_PER_CELL is what `link` divides a datagram by to decide how large a
    # UDP game may be, so it has to be an over-estimate. If this fails, that limit is too
    # generous and a busy game's STATE would not fit the datagram it was sized for.
    #
    # The widest field the rules allow is used on purpose, because a cell's cost is
    # mostly its coordinates and those grow a digit at a time: a narrow field would
    # measure cheaper than reality. Only a few rows of it, to keep the test quick -
    # the per-cell cost does not fall as rows are added.
    for (def f in [[rules.MAX_WIDTH, 8], [rules.MAX_WIDTH, 16], [120, 16]]) {
        def size as int init len(wire(encodeState(packed($f[0], $f[1]))));
        def cells as int init $f[0] * $f[1];
        testing.assertTrue($size <= $cells * STATE_BYTES_PER_CELL);
    }
}

func testTheUdpAreaLimitRespectsTheDatagram() {
    # The guarantee the UDP area limit exists to make, stated as the arithmetic it is:
    # the largest field allowed on UDP, at the per-cell cost measured above, fits one
    # datagram. Checked this way rather than by building a 9000-cell game, which the
    # interpreter would take minutes over for no extra confidence.
    def area as int init link.maxFieldArea(link.UDP);
    testing.assertTrue($area > 0);
    testing.assertTrue($area * STATE_BYTES_PER_CELL <= link.MAX_DATAGRAM);
}

func testAStreamTransportHasNoAreaLimit() {
    testing.assertEqual(link.maxFieldArea(link.TCP), 0);
}

func testTheLargestStateLineFitsWhatAStreamWillBuffer() {
    # A STATE line for the largest field the rules allow must not be mistaken for a
    # flood by the transport and discarded.
    testing.assertTrue(MAX_STATE_BYTES < link.MAX_BUFFER);
}

func testAReadBufferCannotTruncateADatagram() {
    # The bug this guards: a UDP read with a buffer smaller than the datagram does not
    # leave the rest for next time - the kernel discards it, the STATE fails to decode,
    # and the client's screen freezes while the game carries on.
    testing.assertTrue(link.READ_SIZE > link.MAX_DATAGRAM);
}

func testAStateLineForAPlayableFieldIsFarUnderTheDatagramLimit() {
    # The realistic case rather than the pathological one: a busy eight-player game on a
    # field sized for a large display still has plenty of headroom.
    def g as rules.Game init rules.newGame(180, 50, 1);
    for (def id as int init 1; $id <= rules.MAX_PLAYERS; $id = $id + 1) {
        $g = rules.addSnake($g, $id, "player");
        def body as list of geom.Point init [];
        for (def i as int init 0; $i < 120; $i = $i + 1) {
            $body[] = geom.at($i % 180, $id * 3);
        }
        $g.snakes[$id - 1].cells = $body;
    }
    testing.assertTrue(len(wire(encodeState($g))) < link.MAX_DATAGRAM // 4);
}

# --- lives on the wire -------------------------------------------------------

func testStateRoundTripsTheLivesSetting() {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 1), 4);
    $g = rules.addSnake($g, 1, "ada");
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual($back.lives, 4);
    testing.assertEqual(rules.snakeById($back, 1).lives, 4);
}

func testStateRoundTripsLivesPartWaySpent() {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 1), 3);
    $g = rules.addSnake($g, 1, "ada");
    $g.snakes[0].lives = 1;
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual(rules.snakeById($back, 1).lives, 1);
    testing.assertTrue(rules.hasLivesLeft($back, rules.snakeById($back, 1)));
}

func testStateRoundTripsASpectator() {
    # A client has to be able to tell "waiting to come back" from "out for good", or its
    # scoreboard would promise a return that never happens.
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 1), 2);
    $g = rules.addSnake($g, 1, "ada");
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    $g.snakes[0].lives = 0;
    def back as rules.Game init decode(encodeState($g)).game;
    def s as rules.Snake init rules.snakeById($back, 1);
    testing.assertTrue(rules.isSpectator($back, $s));
    testing.assertFalse(rules.hasLivesLeft($back, $s));
}

func testStateRoundTripsAnEndlessGame() {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 1), rules.UNLIMITED_LIVES);
    $g = rules.addSnake($g, 1, "ada");
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    def back as rules.Game init decode(encodeState($g)).game;
    testing.assertEqual($back.lives, rules.UNLIMITED_LIVES);
    # Nobody is ever a spectator in an endless game, however dead they are right now.
    testing.assertFalse(rules.isSpectator($back, rules.snakeById($back, 1)));
}

func testAStateWithNoLivesFieldReadsAsEndless() {
    # The field is last, so a line without it still decodes - as the endless game, which
    # is what the protocol meant before lives existed.
    def m as Message init decode("STATE|1|20|10||1,ada,1,0,0,up,0,0,5.5");
    testing.assertEqual($m.game.lives, rules.UNLIMITED_LIVES);
    testing.assertEqual(len($m.game.snakes), 1);
}

func testASnakeRecordWithoutLivesIsIgnored() {
    # A snake record is nine fields. One with eight is dropped rather than guessed at - a
    # decoder that filled in a default would invent a game state nobody sent.
    def m as Message init decode("STATE|1|20|10||1,ada,1,0,0,up,0,5.5|3");
    testing.assertEqual(len($m.game.snakes), 0);
}
