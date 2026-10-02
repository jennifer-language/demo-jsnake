# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# White-box tests for host.j. Every decision a host makes is pure, so the whole
# of its behaviour is exercised here with no socket and no terminal: players
# join, are refused, steer, cheat, quit, go quiet, and are swept. Run with:
#
#     jennifer test src/host_test.j

use testing;
use io;
use channel;
use net;
use strings;
use lists;
use convert;

# table is a small host table with room for three.
func table() {
    return newTable(20, 10, 7, 3, DEFAULT_TICK_MS);
}

# join runs a JOIN from `peer` and returns the reaction.
func join(t as Table, peer as string, name as string) {
    return handle($t, $peer, proto.encodeJoin($name, 24, 80), 0);
}

# --- newTable ----------------------------------------------------------------

func testNewTableStartsEmpty() {
    def t as Table init table();
    testing.assertEqual(len($t.players), 0);
    testing.assertEqual(len($t.game.snakes), 0);
    testing.assertEqual($t.capacity, 3);
    testing.assertEqual(localId($t), 0);
    testing.assertFalse(isFull($t));
}

func testNewTableClampsAnAbsurdTick() {
    testing.assertEqual(newTable(20, 10, 1, 4, 1).tickMs, MIN_TICK_MS);
    testing.assertEqual(newTable(20, 10, 1, 4, 100000).tickMs, MAX_TICK_MS);
    testing.assertEqual(newTable(20, 10, 1, 4, 200).tickMs, 200);
}

func testNewTableInsistsOnAtLeastOneSeat() {
    testing.assertEqual(newTable(20, 10, 1, 0, 200).capacity, 1);
    testing.assertEqual(newTable(20, 10, 1, -5, 200).capacity, 1);
}

func testDefaultsAreAPlayableGame() {
    def o as Options init defaults();
    testing.assertTrue(link.isTransport($o.mode));
    testing.assertTrue($o.tickMs >= MIN_TICK_MS and $o.tickMs <= MAX_TICK_MS);
    testing.assertTrue($o.capacity > 0);
    testing.assertTrue($o.width >= rules.MIN_WIDTH);
    testing.assertTrue($o.height >= rules.MIN_HEIGHT);
}

func testTheDefaultCapacityFitsThePalette() {
    # More players than glyphs would give two of them the same look.
    testing.assertTrue(DEFAULT_CAPACITY <= len(view.BODY_GLYPHS));
}

# --- the local player --------------------------------------------------------

func testSeatLocalPutsTheHostOnTheField() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    testing.assertEqual(len($t.players), 1);
    testing.assertEqual(localId($t), 1);
    testing.assertTrue(rules.hasSnake($t.game, 1));
    testing.assertEqual(len(audience($t)), 0);
}

func testSeatLocalOnlyEverSeatsOne() {
    def t as Table init seatLocal(seatLocal(table(), "ada", 24, 80), "impostor", 24, 80);
    testing.assertEqual(len($t.players), 1);
}

func testTheLocalPlayerHasNoPeerToBeConfusedWith() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    testing.assertEqual(seatOf($t, ""), -1);
    testing.assertEqual(idAt($t, ""), 0);
}

func testSteerLocalTurnsTheHostsSnake() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    $t.game.snakes[0].dir = geom.RIGHT;
    $t = steerLocal($t, geom.UP);
    testing.assertEqual(rules.snakeById($t.game, 1).dir, geom.UP);
}

func testSteerLocalDoesNothingWithNoLocalPlayer() {
    def t as Table init table();
    testing.assertEqual(len(steerLocal($t, geom.UP).players), 0);
}

# --- joining -----------------------------------------------------------------

func testJoinSeatsAPlayerAndWelcomesThem() {
    def r as Reaction init join(table(), "c1", "bob");
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(len($r.replies), 1);
    testing.assertEqual($r.replies[0].peer, "c1");
    def m as proto.Message init proto.decode($r.replies[0].body);
    testing.assertEqual($m.kind, proto.WELCOME);
    testing.assertEqual($m.id, 1);
    testing.assertEqual($m.width, 20);
    testing.assertEqual($m.height, 10);
    testing.assertEqual($m.tickMs, DEFAULT_TICK_MS);
}

func testJoinPutsTheNewPlayersSnakeOnTheField() {
    def r as Reaction init join(table(), "c1", "bob");
    testing.assertTrue(rules.hasSnake($r.table.game, 1));
    testing.assertEqual(rules.snakeById($r.table.game, 1).name, "bob");
}

func testJoinScrubsTheNameItWasGiven() {
    def r as Reaction init handle(table(), "c1", "JOIN|1|ev il;na,me", 0);
    testing.assertEqual($r.table.players[0].name, "evilname");
}

func testAnExtraFieldOnAJoinIsIgnoredNotSpliced() {
    # A `|` in the name ends the name field, so the tail is a field the host does
    # not read - it cannot leak into the name and it cannot confuse the parse.
    def r as Reaction init handle(table(), "c1", "JOIN|1|ada|DIR|1|up", 0);
    testing.assertEqual($r.table.players[0].name, "ada");
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.WELCOME);
}

func testTwoPlayersGetDifferentIds() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init join($t, "c2", "bob");
    testing.assertEqual(len($r.table.players), 2);
    testing.assertNotEqual(idAt($r.table, "c1"), idAt($r.table, "c2"));
}

func testARepeatedJoinIsAnsweredNotDuplicated() {
    # A WELCOME can be lost on UDP; the client asks again. One player, one snake.
    def t as Table init join(table(), "c1", "ada").table;
    def again as Reaction init join($t, "c1", "ada");
    testing.assertEqual(len($again.table.players), 1);
    testing.assertEqual(len($again.replies), 1);
    testing.assertEqual(proto.decode($again.replies[0].body).kind, proto.WELCOME);
    testing.assertEqual(proto.decode($again.replies[0].body).id, 1);
}

func testARepeatedJoinCannotRenameOrRespawnAPlayer() {
    def t as Table init join(table(), "c1", "ada").table;
    def moved as rules.Game init $t.game;
    def again as Reaction init join($t, "c1", "someoneelse");
    testing.assertEqual($again.table.players[0].name, "ada");
    testing.assertEqual(len($again.table.game.snakes), len($moved.snakes));
}

func testAFullGameRefusesAndForgetsTheCaller() {
    def t as Table init table();
    $t = join($t, "c1", "a").table;
    $t = join($t, "c2", "b").table;
    $t = join($t, "c3", "c").table;
    testing.assertTrue(isFull($t));
    def r as Reaction init join($t, "c4", "d");
    testing.assertEqual(len($r.table.players), 3);
    testing.assertEqual(len($r.replies), 1);
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.DENY);
    testing.assertEqual(len($r.dropped), 1);
    testing.assertEqual($r.dropped[0], "c4");
}

func testTheHostsOwnSeatCountsTowardsCapacity() {
    def t as Table init seatLocal(newTable(20, 10, 1, 1, 200), "ada", 24, 80);
    testing.assertTrue(isFull($t));
    testing.assertEqual(proto.decode(join($t, "c1", "bob").replies[0].body).kind, proto.DENY);
}

func testAFreedSeatCanBeTakenAgain() {
    def t as Table init table();
    $t = join($t, "c1", "a").table;
    $t = join($t, "c2", "b").table;
    $t = join($t, "c3", "c").table;
    $t = unseat($t, "c2");
    testing.assertFalse(isFull($t));
    def r as Reaction init join($t, "c4", "d");
    testing.assertEqual(len($r.table.players), 3);
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.WELCOME);
}

# --- steering ----------------------------------------------------------------

func testDirSteersThePlayerAtThatPeer() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.snakes[0].dir = geom.RIGHT;
    def r as Reaction init handle($t, "c1", proto.encodeDir(1, geom.UP), 0);
    testing.assertEqual(rules.snakeById($r.table.game, 1).dir, geom.UP);
    testing.assertEqual(len($r.replies), 0);
}

func testDirCannotSteerSomebodyElsesSnake() {
    # The security-relevant one: identity is the peer, not the id in the message.
    def t as Table init join(table(), "c1", "ada").table;
    $t = join($t, "c2", "bob").table;
    def victim as int init idAt($t, "c2");
    $t.game.snakes[0].dir = geom.RIGHT;
    $t.game.snakes[1].dir = geom.RIGHT;
    def r as Reaction init handle($t, "c1", proto.encodeDir($victim, geom.UP), 0);
    testing.assertEqual(rules.snakeById($r.table.game, $victim).dir, geom.RIGHT);
    testing.assertEqual(rules.snakeById($r.table.game, idAt($t, "c1")).dir, geom.UP);
}

func testDirFromAnUnseatedPeerIsIgnored() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.snakes[0].dir = geom.RIGHT;
    def r as Reaction init handle($t, "stranger", proto.encodeDir(1, geom.UP), 0);
    testing.assertEqual(rules.snakeById($r.table.game, 1).dir, geom.RIGHT);
    testing.assertEqual(len($r.table.players), 1);
}

func testDirWithANonsenseDirectionIsIgnored() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.snakes[0].dir = geom.RIGHT;
    def r as Reaction init handle($t, "c1", "DIR|1|sideways", 0);
    testing.assertEqual(rules.snakeById($r.table.game, 1).dir, geom.RIGHT);
}

func testDirCannotReverseASnakeIntoItself() {
    def t as Table init join(table(), "c1", "ada").table;
    $t = advance($t);
    $t = advance($t);
    def facing as string init rules.heading(rules.snakeById($t.game, 1));
    def r as Reaction init handle($t, "c1", proto.encodeDir(1, geom.opposite($facing)), 0);
    testing.assertEqual(rules.snakeById($r.table.game, 1).dir, $facing);
}

# --- leaving -----------------------------------------------------------------

func testQuitUnseatsAndClearsTheField() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init handle($t, "c1", proto.encodeQuit(1), 0);
    testing.assertEqual(len($r.table.players), 0);
    testing.assertFalse(rules.hasSnake($r.table.game, 1));
}

func testQuitFromAStrangerChangesNothing() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init handle($t, "stranger", proto.encodeQuit(1), 0);
    testing.assertEqual(len($r.table.players), 1);
}

func testUnseatIsIdempotent() {
    def t as Table init join(table(), "c1", "ada").table;
    $t = unseat($t, "c1");
    $t = unseat($t, "c1");
    testing.assertEqual(len($t.players), 0);
}

# --- keepalive and sweeping -------------------------------------------------

func testPingRefreshesAPlayersLastSeen() {
    def t as Table init join(table(), "c1", "ada").table;
    testing.assertEqual($t.players[0].lastSeen, 0);
    def r as Reaction init handle($t, "c1", proto.encodePing(1), 40);
    testing.assertEqual($r.table.players[0].lastSeen, 40);
    testing.assertEqual(len($r.replies), 0);
}

func testAnyMessageRefreshesLastSeen() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init handle($t, "c1", proto.encodeDir(1, geom.UP), 55);
    testing.assertEqual($r.table.players[0].lastSeen, 55);
}

func testSweepKeepsAPlayerWhoIsStillTalking() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init sweep($t, IDLE_TICKS, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL);
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(len($r.dropped), 0);
}

func testSweepDropsAPlayerWhoHasGoneQuiet() {
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init sweep($t, IDLE_TICKS + 1, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL);
    testing.assertEqual(len($r.table.players), 0);
    testing.assertFalse(rules.hasSnake($r.table.game, 1));
    testing.assertEqual(len($r.dropped), 1);
    testing.assertEqual($r.dropped[0], "c1");
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.BYE);
}

func testSweepNeverDropsTheLocalPlayer() {
    # There is no socket for the host's own keyboard to go quiet on.
    def t as Table init seatLocal(table(), "ada", 24, 80);
    def r as Reaction init sweep($t, 100000, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL);
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(len($r.dropped), 0);
}

func testSweepDropsSeveralAtOnce() {
    def t as Table init table();
    $t = join($t, "c1", "a").table;
    $t = join($t, "c2", "b").table;
    $t = seatLocal($t, "host", 24, 80);
    def r as Reaction init sweep($t, IDLE_TICKS + 5, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL);
    testing.assertEqual(len($r.table.players), 1);
    testing.assertTrue($r.table.players[0].local);
    testing.assertEqual(len($r.dropped), 2);
}

# --- garbage in ------------------------------------------------------------

func testAMalformedMessageChangesNothingAndSaysNothing() {
    def t as Table init join(table(), "c1", "ada").table;
    def before as int init len($t.players);
    for (def junk in ["", "NONSENSE|1", "|||", "GET / HTTP/1.1", "JOIN|99|x", "STATE|1|2|3||"]) {
        def r as Reaction init handle($t, "c1", $junk, 0);
        testing.assertEqual(len($r.table.players), $before);
        testing.assertEqual(len($r.replies), 0);
        testing.assertEqual(len($r.dropped), 0);
    }
}

func testAClientCannotDriveTheHostWithAHostMessage() {
    # WELCOME and STATE are things a host says; a client saying them is ignored.
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init handle($t, "c1", proto.encodeWelcome(9, 999, 999, 1), 0);
    testing.assertEqual($r.table.game.width, 20);
    testing.assertEqual(len($r.table.players), 1);
}

func testAnUnseatedStrangerCannotFillTheTableWithGarbage() {
    def t as Table init table();
    def r as Reaction init handle($t, "stranger", "PING|1", 0);
    testing.assertEqual(len($r.table.players), 0);
}

# --- ticking and broadcasting ----------------------------------------------

func testAdvanceTicksTheGame() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    testing.assertEqual(advance($t).game.tick, 1);
    testing.assertEqual(advance(advance($t)).game.tick, 2);
}

func testStateLineRoundTripsThroughTheProtocol() {
    def t as Table init advance(join(table(), "c1", "ada").table);
    def m as proto.Message init proto.decode(stateLine($t));
    testing.assertEqual($m.kind, proto.STATE);
    testing.assertEqual($m.game.tick, $t.game.tick);
    testing.assertEqual(len($m.game.snakes), 1);
    testing.assertEqual(rules.snakeById($m.game, 1).name, "ada");
}

func testAudienceIsTheRemotePlayersOnly() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = join($t, "c1", "a").table;
    $t = join($t, "c2", "b").table;
    def peers as list of string init audience($t);
    testing.assertEqual(len($peers), 2);
    testing.assertTrue(lists.contains($peers, "c1"));
    testing.assertTrue(lists.contains($peers, "c2"));
}

func testIndexOfIdFindsTheSeat() {
    def t as Table init join(table(), "c1", "ada").table;
    testing.assertEqual(indexOfId($t, 1), 0);
    testing.assertEqual(indexOfId($t, 99), -1);
}

# --- a whole game, driven through the pure surface --------------------------

func testAHostRunsAGameForTwoPlayersWithoutASocket() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = join($t, "c1", "guest").table;
    testing.assertEqual(len($t.players), 2);
    for (def tick as int init 0; $tick < 120; $tick = $tick + 1) {
        def dir as string init geom.DIRECTIONS[$tick % 4];
        $t = steerLocal($t, $dir);
        $t = handle($t, "c1", proto.encodeDir(99, $dir), $tick).table;
        $t = advance($t);
        def swept as Reaction init sweep($t, $t.game.tick, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL);
        $t = $swept.table;
        # The state must stay describable and re-readable every single tick.
        def m as proto.Message init proto.decode(stateLine($t));
        testing.assertEqual($m.kind, proto.STATE);
        testing.assertEqual(len($m.game.snakes), len($t.game.snakes));
    }
    testing.assertEqual(len($t.players), 2);
    testing.assertEqual($t.game.tick, 120);
}

func testAPlayerWhoStopsTalkingIsEventuallySweptMidGame() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = join($t, "c1", "guest").table;
    for (def tick as int init 0; $tick < IDLE_TICKS + 5; $tick = $tick + 1) {
        $t = advance($t);
        $t = sweep($t, $t.game.tick, IDLE_TICKS, FORFEIT, bot.DEFAULT_LEVEL).table;
    }
    testing.assertEqual(len($t.players), 1);
    testing.assertTrue($t.players[0].local);
    testing.assertFalse(strings.contains(stateLine($t), "guest"));
}

# --- the player cap ---------------------------------------------------------

func testCapacityCannotExceedTheGamesLimit() {
    # More players than the game allows would give two of them the same glyph.
    testing.assertEqual(newTable(20, 10, 1, 999, 200).capacity, rules.MAX_PLAYERS);
    testing.assertEqual(newTable(20, 10, 1, rules.MAX_PLAYERS, 200).capacity, rules.MAX_PLAYERS);
}

func testTheGamesLimitFitsTheRenderersPalette() {
    testing.assertTrue(rules.MAX_PLAYERS <= len(view.BODY_GLYPHS));
    testing.assertTrue(rules.MAX_PLAYERS <= len(view.BODY_COLORS));
}

func testAHostCannotBeAskedToSeatMorePlayersThanTheCap() {
    def t as Table init newTable(40, 20, 1, rules.MAX_PLAYERS + 5, 200);
    for (def i as int init 0; $i < rules.MAX_PLAYERS + 5; $i = $i + 1) {
        $t = join($t, "c" + convert.toString($i), "p").table;
    }
    testing.assertEqual(len($t.players), rules.MAX_PLAYERS);
}

# --- computer players -------------------------------------------------------

func testSeatBotPutsAComputerPlayerOnTheField() {
    def t as Table init seatBot(table(), bot.HARD);
    testing.assertEqual(len($t.players), 1);
    testing.assertTrue(isBot($t.players[0]));
    testing.assertEqual($t.players[0].level, bot.HARD);
    testing.assertTrue(rules.hasSnake($t.game, $t.players[0].id));
    testing.assertEqual(botCount($t), 1);
    testing.assertEqual(humanCount($t), 0);
}

func testABotNeedsNoPeerAndIsNotBroadcastTo() {
    def t as Table init seatBot(table(), bot.NORMAL);
    testing.assertEqual($t.players[0].peer, "");
    testing.assertEqual(len(audience($t)), 0);
}

func testSeatBotsFillsWhatItCan() {
    def t as Table init seatBots(table(), 2, bot.EASY);
    testing.assertEqual(botCount($t), 2);
    testing.assertNotEqual($t.players[0].name, $t.players[1].name);
}

func testSeatBotsStopsAtCapacity() {
    def t as Table init seatBots(table(), 99, bot.EASY);
    testing.assertEqual(len($t.players), $t.capacity);
}

func testSeatBotFallsBackOnAnUnknownLevel() {
    def t as Table init seatBot(table(), "unbeatable");
    testing.assertEqual($t.players[0].level, bot.DEFAULT_LEVEL);
}

func testBotsAndPeopleShareTheSameTable() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    $t = seatBot($t, bot.HARD);
    $t = join($t, "c1", "bob").table;
    testing.assertEqual(len($t.players), 3);
    testing.assertEqual(botCount($t), 1);
    testing.assertEqual(humanCount($t), 2);
    testing.assertEqual(len(audience($t)), 1);
    testing.assertTrue(isFull($t));
}

func testEveryBotGetsItsOwnRandomState() {
    def t as Table init seatBots(newTable(30, 16, 5, 4, 200), 3, bot.NORMAL);
    testing.assertNotEqual($t.players[0].seed, $t.players[1].seed);
    testing.assertNotEqual($t.players[1].seed, $t.players[2].seed);
}

func testSteerBotsSetsEveryBotsHeading() {
    def t as Table init seatBots(newTable(30, 16, 11, 4, 200), 2, bot.NORMAL);
    def before as int init $t.players[0].seed;
    $t = steerBots($t);
    testing.assertNotEqual($t.players[0].seed, $before);
    for (def p in $t.players) {
        testing.assertTrue(geom.isDirection(rules.snakeById($t.game, $p.id).dir));
    }
}

func testSteerBotsLeavesPeopleAlone() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    $t.game.snakes[0].dir = geom.RIGHT;
    $t = seatBot($t, bot.NORMAL);
    $t = steerBots($t);
    testing.assertEqual(rules.snakeById($t.game, 1).dir, geom.RIGHT);
}

func testSteerBotsOnATableWithNoBotsIsANoOp() {
    def t as Table init seatLocal(table(), "ada", 24, 80);
    testing.assertEqual(len(steerBots($t).players), 1);
}

func testAGameOfBotsPlaysItself() {
    def t as Table init seatBots(newTable(26, 14, 20260929, 4, 200), 4, bot.HARD);
    for (def tick as int init 0; $tick < 80; $tick = $tick + 1) {
        $t = steerBots($t);
        $t = advance($t);
        $t = sweep($t, $t.game.tick, IDLE_TICKS, FORFEIT, bot.HARD).table;
    }
    testing.assertEqual(len($t.players), 4);
    testing.assertEqual($t.game.tick, 80);
    def scored as int init 0;
    for (def p in $t.players) {
        $scored = $scored + rules.snakeById($t.game, $p.id).score;
    }
    testing.assertTrue($scored > 0);
}

func testABotIsNeverSweptForBeingQuiet() {
    # It has no socket to fall silent on.
    def t as Table init seatBot(table(), bot.NORMAL);
    def r as Reaction init sweep($t, 100000, IDLE_TICKS, FORFEIT, bot.NORMAL);
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(len($r.dropped), 0);
}

# --- the disconnect policy --------------------------------------------------

func testBothPoliciesAreRecognised() {
    for (def policy in LEAVE_POLICIES) {
        testing.assertTrue(isLeavePolicy($policy));
    }
    testing.assertEqual(len(LEAVE_POLICIES), 2);
}

func testAnUnknownPolicyFallsBackRatherThanFailing() {
    testing.assertFalse(isLeavePolicy("shrug"));
    testing.assertEqual(leavePolicyOr("shrug"), DEFAULT_ON_LEAVE);
    testing.assertEqual(leavePolicyOr(TAKEOVER), TAKEOVER);
}

func testForfeitFreesTheSeat() {
    def t as Table init join(table(), "c1", "ada").table;
    def after as Table init onLeave($t, "c1", FORFEIT, bot.NORMAL);
    testing.assertEqual(len($after.players), 0);
    testing.assertFalse(rules.hasSnake($after.game, 1));
}

func testTakeoverKeepsTheSeatAndHandsItToAComputer() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.snakes[0].score = 70;
    def after as Table init onLeave($t, "c1", TAKEOVER, bot.HARD);
    testing.assertEqual(len($after.players), 1);
    testing.assertTrue(isBot($after.players[0]));
    testing.assertEqual($after.players[0].level, bot.HARD);
    testing.assertTrue(rules.hasSnake($after.game, 1));
    testing.assertEqual(rules.snakeById($after.game, 1).score, 70);
}

func testTakeoverKeepsTheBodyWhereItWas() {
    def t as Table init join(table(), "c1", "ada").table;
    $t = advance($t);
    $t = advance($t);
    def before as list of geom.Point init rules.snakeById($t.game, 1).cells;
    def after as Table init onLeave($t, "c1", TAKEOVER, bot.HARD);
    def now as list of geom.Point init rules.snakeById($after.game, 1).cells;
    testing.assertEqual(len($now), len($before));
    testing.assertTrue(geom.equals($now[0], $before[0]));
}

func testATakenOverSeatIsMarkedOnTheScoreboard() {
    def t as Table init join(table(), "c1", "ada").table;
    def after as Table init onLeave($t, "c1", TAKEOVER, bot.HARD);
    testing.assertTrue(strings.contains($after.players[0].name, "cpu"));
    testing.assertEqual(rules.snakeById($after.game, 1).name, $after.players[0].name);
}

func testATakenOverSeatNeedsNoSocket() {
    def t as Table init join(table(), "c1", "ada").table;
    def after as Table init onLeave($t, "c1", TAKEOVER, bot.HARD);
    testing.assertEqual($after.players[0].peer, "");
    testing.assertEqual(len(audience($after)), 0);
    testing.assertEqual(seatOf($after, "c1"), -1);
}

func testATakenOverSeatIsThenSteeredByTheComputer() {
    def t as Table init join(newTable(30, 16, 13, 3, 200), "c1", "ada").table;
    $t = onLeave($t, "c1", TAKEOVER, bot.NORMAL);
    def before as int init $t.players[0].seed;
    $t = steerBots($t);
    testing.assertNotEqual($t.players[0].seed, $before);
}

func testATakenOverSeatIsNeverTakenOverTwice() {
    def t as Table init join(table(), "c1", "ada").table;
    def once as Table init onLeave($t, "c1", TAKEOVER, bot.HARD);
    def name as string init $once.players[0].name;
    def twice as Table init takeover($once, "", bot.HARD);
    testing.assertEqual($twice.players[0].name, $name);
}

func testTakeoverOfAnUnknownPeerChangesNothing() {
    def t as Table init join(table(), "c1", "ada").table;
    testing.assertEqual(len(takeover($t, "stranger", bot.HARD).players), 1);
}

func testADeliberateQuitAlwaysForfeitsWhateverThePolicy() {
    # A player who chose to leave has not asked a computer to play on for them.
    def t as Table init join(table(), "c1", "ada").table;
    def r as Reaction init handle($t, "c1", proto.encodeQuit(1), 0);
    testing.assertEqual(len($r.table.players), 0);
    testing.assertFalse(rules.hasSnake($r.table.game, 1));
}

func testASweepUnderTakeoverKeepsTheFieldFull() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = join($t, "c1", "guest").table;
    def r as Reaction init sweep($t, IDLE_TICKS + 1, IDLE_TICKS, TAKEOVER, bot.HARD);
    testing.assertEqual(len($r.table.players), 2);
    testing.assertEqual(botCount($r.table), 1);
    # The transport is still told to forget the dead socket.
    testing.assertEqual(len($r.dropped), 1);
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.BYE);
}

func testASweepUnderForfeitEmptiesTheSeat() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = join($t, "c1", "guest").table;
    def r as Reaction init sweep($t, IDLE_TICKS + 1, IDLE_TICKS, FORFEIT, bot.HARD);
    testing.assertEqual(len($r.table.players), 1);
    testing.assertEqual(botCount($r.table), 0);
}

func testTheGameKeepsGoingAfterATakeover() {
    def t as Table init seatLocal(newTable(30, 16, 99, 4, 200), "host", 24, 80);
    $t = join($t, "c1", "guest").table;
    $t = onLeave($t, "c1", TAKEOVER, bot.HARD);
    for (def tick as int init 0; $tick < 60; $tick = $tick + 1) {
        $t = steerBots($t);
        $t = advance($t);
    }
    testing.assertEqual(len($t.players), 2);
    testing.assertEqual(botCount($t), 1);
    testing.assertEqual($t.game.tick, 60);
}

func testDefaultsCarryABotLevelAndAPolicy() {
    def o as Options init defaults();
    testing.assertTrue(bot.isLevel($o.botLevel));
    testing.assertTrue(isLeavePolicy($o.onLeave));
    testing.assertTrue($o.bots >= 0);
    testing.assertTrue($o.capacity <= rules.MAX_PLAYERS);
}

# --- special food ------------------------------------------------------------

func testATableStartsWithSpecialsEnabled() {
    testing.assertTrue(table().game.specials);
    testing.assertTrue(defaults().specials);
}

func testAHostCanServeAPlainGame() {
    def t as Table init table();
    $t.game = rules.withoutSpecials($t.game);
    $t = seatBots($t, 2, bot.NORMAL);
    for (def tick as int init 0; $tick < 120; $tick = $tick + 1) {
        $t = steerBots($t);
        $t = advance($t);
    }
    for (def kind in rules.SPECIAL_KINDS) {
        testing.assertEqual(rules.foodCount($t.game, $kind), 0);
    }
    testing.assertTrue(rules.foodCount($t.game, rules.PLAIN) > 0);
}

func testSpecialFoodReachesEveryClientInTheState() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.food = [rules.foodAt(rules.TOADSTOOL, geom.at(4, 4))];
    def back as rules.Game init proto.decode(stateLine($t)).game;
    testing.assertEqual(rules.foodCount($back, rules.TOADSTOOL), 1);
    testing.assertEqual($back.food[0].life, rules.recipeFor(rules.TOADSTOOL).life);
}

func testAGhostingSnakeIsVisibleToEveryClient() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game.snakes[0].ghost = 33;
    def back as rules.Game init proto.decode(stateLine($t)).game;
    testing.assertEqual(rules.snakeById($back, 1).ghost, 33);
}

func testAHostedGameWithSpecialsAndBotsRunsCleanly() {
    def t as Table init seatLocal(
        newTable(26, 14, 20260929, rules.MAX_PLAYERS, 200),
        "host",
        24,
        80);
    $t = seatBots($t, 3, bot.HARD);
    $t = join($t, "c1", "guest").table;
    for (def tick as int init 0; $tick < 200; $tick = $tick + 1) {
        $t = handle($t, "c1", proto.encodePing(1), $tick).table;
        $t = steerBots($t);
        $t = advance($t);
        $t = sweep($t, $tick, IDLE_TICKS, TAKEOVER, bot.HARD).table;
        testing.assertEqual(proto.decode(stateLine($t)).kind, proto.STATE);
    }
    testing.assertEqual(len($t.players), 5);
    testing.assertEqual($t.game.tick, 200);
}

# --- the title screen's settings ---------------------------------------------

# press applies a sequence of key names to a setup, for brevity below.
func press(s as Setup, names as list of string) {
    def out as Setup init $s;
    for (def n in $names) {
        $out = pressed($out, screen.Key{name: $n, char: ""});
    }
    return $out;
}

# onRow moves the cursor to the row named, by pressing down until it lands there. Tests
# navigate by name rather than by counting presses, so inserting a setup row does not
# quietly point half of them at the wrong thing.
func onRow(s as Setup, name as string) {
    def out as Setup init $s;
    for (def i as int init 0; $i < len(SETUP_ROWS); $i = $i + 1) {
        if (SETUP_ROWS[$out.row] == $name) {
            return $out;
        }
        $out = press($out, ["down"]);
    }
    testing.assertEqual(SETUP_ROWS[$out.row], $name);
    return $out;
}

# typed applies a sequence of printable characters to a setup.
func typed(s as Setup, chars as list of string) {
    def out as Setup init $s;
    for (def c in $chars) {
        $out = pressed($out, screen.Key{name: "char", char: $c});
    }
    return $out;
}

func testSetupStartsFromTheCommandLine() {
    def o as Options init defaults();
    $o.tickMs = 150;
    $o.capacity = 4;
    $o.bots = 2;
    $o.botLevel = bot.HARD;
    $o.onLeave = TAKEOVER;
    $o.specials = false;
    def s as Setup init setupFrom($o);
    testing.assertEqual($s.tickMs, 150);
    testing.assertEqual($s.capacity, 4);
    testing.assertEqual($s.bots, 2);
    testing.assertEqual($s.botLevel, bot.HARD);
    testing.assertEqual($s.onLeave, TAKEOVER);
    testing.assertFalse($s.specials);
    testing.assertEqual($s.row, 0);
    testing.assertFalse($s.start);
    testing.assertFalse($s.quit);
}

func testSetupClampsAnImpossibleCommandLine() {
    def o as Options init defaults();
    $o.tickMs = 1;
    $o.capacity = 999;
    $o.bots = -4;
    $o.botLevel = "unbeatable";
    $o.onLeave = "shrug";
    def s as Setup init setupFrom($o);
    testing.assertEqual($s.tickMs, MIN_TICK_MS);
    testing.assertEqual($s.capacity, rules.MAX_PLAYERS);
    testing.assertEqual($s.bots, 0);
    testing.assertEqual($s.botLevel, bot.DEFAULT_LEVEL);
    testing.assertEqual($s.onLeave, DEFAULT_ON_LEAVE);
}

func testTheCursorMovesAndWrapsBothWays() {
    def s as Setup init setupFrom(defaults());
    testing.assertEqual(press($s, ["down"]).row, 1);
    testing.assertEqual(press($s, ["up"]).row, len(SETUP_ROWS) - 1);
    def wrapped as Setup init $s;
    for (def i as int init 0; $i < len(SETUP_ROWS); $i = $i + 1) {
        $wrapped = press($wrapped, ["down"]);
    }
    testing.assertEqual($wrapped.row, 0);
}

func testWasdMovesTheCursorToo() {
    def s as Setup init setupFrom(defaults());
    testing.assertEqual(typed($s, ["s"]).start, true);
    testing.assertEqual(typed($s, ["w"]).row, len(SETUP_ROWS) - 1);
    testing.assertEqual(typed($s, ["j"]).row, 0);
}

func testRightMakesTheGameFaster() {
    # The row reads as speed, so right must mean faster - a smaller tick.
    def s as Setup init setupFrom(defaults());
    testing.assertTrue(press($s, ["right"]).tickMs < $s.tickMs);
    testing.assertTrue(press($s, ["left"]).tickMs > $s.tickMs);
}

func testTheSpeedStopsAtItsLimits() {
    def s as Setup init setupFrom(defaults());
    for (def i as int init 0; $i < 400; $i = $i + 1) {
        $s = press($s, ["right"]);
    }
    testing.assertEqual($s.tickMs, MIN_TICK_MS);
    for (def i as int init 0; $i < 400; $i = $i + 1) {
        $s = press($s, ["left"]);
    }
    testing.assertEqual($s.tickMs, MAX_TICK_MS);
}

func testThePlayerCountStopsAtItsLimits() {
    def s as Setup init onRow(setupFrom(defaults()), "players");
    for (def i as int init 0; $i < 30; $i = $i + 1) {
        $s = press($s, ["left"]);
    }
    testing.assertEqual($s.capacity, 1);
    for (def i as int init 0; $i < 30; $i = $i + 1) {
        $s = press($s, ["right"]);
    }
    testing.assertEqual($s.capacity, rules.MAX_PLAYERS);
}

func testTheBotCountStopsAtItsLimits() {
    def s as Setup init onRow(setupFrom(defaults()), "computer players");
    for (def i as int init 0; $i < 30; $i = $i + 1) {
        $s = press($s, ["left"]);
    }
    testing.assertEqual($s.bots, 0);
    for (def i as int init 0; $i < 30; $i = $i + 1) {
        $s = press($s, ["right"]);
    }
    testing.assertEqual($s.bots, rules.MAX_PLAYERS);
}

func testTheSkillWalksTheLadderAndStops() {
    def s as Setup init onRow(setupFrom(defaults()), "computer skill");
    for (def i as int init 0; $i < 10; $i = $i + 1) {
        $s = press($s, ["left"]);
    }
    testing.assertEqual($s.botLevel, bot.LEVELS[0]);
    for (def i as int init 0; $i < 10; $i = $i + 1) {
        $s = press($s, ["right"]);
    }
    testing.assertEqual($s.botLevel, bot.LEVELS[len(bot.LEVELS) - 1]);
}

func testTheDisconnectPolicyToggles() {
    def s as Setup init onRow(setupFrom(defaults()), "on disconnect");
    def once as Setup init press($s, ["right"]);
    testing.assertNotEqual($once.onLeave, $s.onLeave);
    testing.assertEqual(press($once, ["right"]).onLeave, $s.onLeave);
    testing.assertEqual(press($once, ["left"]).onLeave, $s.onLeave);
}

func testSpecialFoodToggles() {
    def s as Setup init onRow(setupFrom(defaults()), "special food");
    testing.assertFalse(press($s, ["right"]).specials);
    testing.assertTrue(press($s, ["right", "right"]).specials);
}

func testEnterAndSStart() {
    def s as Setup init setupFrom(defaults());
    testing.assertTrue(press($s, ["enter"]).start);
    testing.assertTrue(typed($s, ["s"]).start);
    testing.assertTrue(typed($s, [" "]).start);
}

func testEscapeLeavesFromTheTitleScreen() {
    # There is nothing behind the title screen, so backing out of it means leaving.
    def s as Setup init setupFrom(defaults());
    testing.assertTrue(press($s, ["escape"]).quit);
    testing.assertFalse(press($s, ["escape"]).start);
}

func testPlainLettersDoNotLeaveTheTitleScreen() {
    # The keys a player might try on spec. Escape is the only way out, and a letter that
    # quietly ended the session instead would be a trap.
    def s as Setup init setupFrom(defaults());
    for (def ch in ["q", "Q", "x", "X"]) {
        testing.assertFalse(typed($s, [$ch]).quit);
    }
}

func testCtrlCLeavesFromTheTitleScreen() {
    # The emergency exit works from every screen: raw mode delivers Ctrl-C as a byte, so a
    # program that ignored it would be the only one on the system that did.
    def s as Setup init setupFrom(defaults());
    testing.assertTrue(press($s, ["ctrl-c"]).quit);
}

func testAnIrrelevantKeyChangesNothing() {
    def s as Setup init setupFrom(defaults());
    def after as Setup init press($s, ["f7", "home", "pagedown", "none"]);
    testing.assertEqual($after.row, $s.row);
    testing.assertEqual($after.tickMs, $s.tickMs);
    testing.assertFalse($after.start);
    testing.assertFalse($after.quit);
}

func testEverySetupRowHasAValueAndRespondsToAnArrow() {
    def s as Setup init setupFrom(defaults());
    for (def i as int init 0; $i < len(SETUP_ROWS); $i = $i + 1) {
        def at as Setup init $s;
        $at.row = $i;
        testing.assertTrue(len(setupValue($at, $i)) > 0);
        # Every row must respond to an arrow, or it is decoration. Not necessarily to
        # `right`: a row already at its maximum has nowhere further to go, which is
        # the correct behaviour rather than a dead row.
        def right as string init setupValue(press($at, ["right"]), $i);
        def left as string init setupValue(press($at, ["left"]), $i);
        def before as string init setupValue($at, $i);
        testing.assertTrue($right != $before or $left != $before);
    }
}

func testAnySetupProducesRunnableOptions() {
    # Whatever the host types at the title screen, the result must be options the
    # game will accept without further checking.
    def s as Setup init setupFrom(defaults());
    def keys as list of string init [
        "down",
        "right",
        "down",
        "left",
        "down",
        "right",
        "down",
        "right",
        "down",
        "right",
        "down",
        "right"
    ];
    for (def i as int init 0; $i < 6; $i = $i + 1) {
        $s = press($s, $keys);
        def o as Options init withSetup(defaults(), $s);
        testing.assertTrue($o.tickMs >= MIN_TICK_MS and $o.tickMs <= MAX_TICK_MS);
        testing.assertTrue($o.capacity >= 1 and $o.capacity <= rules.MAX_PLAYERS);
        testing.assertTrue($o.bots >= 0 and $o.bots <= rules.MAX_PLAYERS);
        testing.assertTrue(bot.isLevel($o.botLevel));
        testing.assertTrue(isLeavePolicy($o.onLeave));
    }
}

func testWithSetupKeepsWhatTheTitleScreenDoesNotOffer() {
    # The transport, the port and the name are settled before the lobby opens.
    def o as Options init defaults();
    $o.mode = link.TCP;
    $o.port = 50000;
    $o.name = "kitchen";
    def after as Options init withSetup($o, press(setupFrom($o), ["right"]));
    testing.assertEqual($after.mode, link.TCP);
    testing.assertEqual($after.port, 50000);
    testing.assertEqual($after.name, "kitchen");
}

# --- agreeing on a field size -----------------------------------------------

# atTerminal seats a remote player who reports the given terminal.
func atTerminal(t as Table, peer as string, name as string, rows as int, cols as int) {
    return handle($t, $peer, proto.encodeJoin($name, $rows, $cols), 0).table;
}

func testTheSmallestTerminalWins() {
    def t as Table init newTable(100, 40, 1, 4, 200);
    $t = atTerminal($t, "c1", "wide", 40, 200);
    $t = atTerminal($t, "c2", "small", 24, 80);
    def room as view.Room init agreedField($t, view.Room{width: 100, height: 40}, 60, 220);
    def tight as view.Room init view.maxField(24, 80, $t.capacity, true);
    testing.assertEqual($room.width, $tight.width);
    testing.assertEqual($room.height, $tight.height);
}

func testTheSmallestInEachDirectionWins() {
    # A short wide terminal and a tall narrow one between them decide both numbers.
    def t as Table init newTable(200, 60, 1, 4, 200);
    $t = atTerminal($t, "c1", "wide", 20, 200);
    $t = atTerminal($t, "c2", "tall", 60, 50);
    def room as view.Room init agreedField($t, view.Room{width: 200, height: 60}, 60, 220);
    testing.assertEqual($room.width, view.maxField(60, 50, 4, true).width);
    testing.assertEqual($room.height, view.maxField(20, 200, 4, true).height);
}

func testTheHostsRequestedSizeIsACap() {
    def t as Table init newTable(20, 12, 1, 4, 200);
    $t = atTerminal($t, "c1", "huge", 200, 400);
    def room as view.Room init agreedField($t, view.Room{width: 20, height: 12}, 60, 220);
    testing.assertEqual($room.width, 20);
    testing.assertEqual($room.height, 12);
}

func testASeatWithNoTerminalConstrainsNothing() {
    # Computer players, and a client too old to report a size.
    def t as Table init newTable(60, 24, 1, 4, 200);
    $t = seatBots($t, 2, bot.NORMAL);
    $t = handle($t, "c1", "JOIN|1|old", 0).table;
    def room as view.Room init agreedField($t, view.Room{width: 60, height: 24}, 60, 220);
    testing.assertEqual($room.width, 60);
    testing.assertEqual($room.height, 24);
}

func testTheAgreedFieldFitsEveryTerminalThatReportedOne() {
    def t as Table init newTable(rules.MAX_WIDTH, rules.MAX_HEIGHT, 1, rules.MAX_PLAYERS, 200);
    def terminals as list of list of int init [[24, 80], [50, 200], [30, 100]];
    for (def i as int init 0; $i < len($terminals); $i = $i + 1) {
        $t = atTerminal($t, "c" + convert.toString($i), "p", $terminals[$i][0], $terminals[$i][1]);
    }
    def room as view.Room init agreedField($t, capFrom(defaults()), 60, 220);
    def ready as Table init startGame($t, $room, 1, 1);
    for (def term in $terminals) {
        testing.assertTrue(view.fit($ready.game, $term[0], $term[1]).fits);
    }
}

func testReservingEveryScoreboardRowMeansAJoinNeverBreaksTheView() {
    # The field is sized for a full table, so it still fits when the table fills.
    def t as Table init newTable(rules.MAX_WIDTH, rules.MAX_HEIGHT, 1, rules.MAX_PLAYERS, 200);
    $t = atTerminal($t, "c1", "p", 24, 80);
    def room as view.Room init agreedField($t, capFrom(defaults()), 60, 220);
    def ready as Table init startGame($t, $room, 1, 1);
    for (def i as int init 2; $i <= rules.MAX_PLAYERS; $i = $i + 1) {
        $ready = atTerminal($ready, "c" + convert.toString($i), "p", 24, 80);
        testing.assertTrue(view.fit($ready.game, 24, 80).fits);
    }
    testing.assertEqual(len($ready.players), rules.MAX_PLAYERS);
}

func testCanPlaySpotsATerminalTooSmallForTheTable() {
    def t as Table init newTable(60, 24, 1, rules.MAX_PLAYERS, 200);
    $t = atTerminal($t, "c1", "tiny", 8, 20);
    $t = atTerminal($t, "c2", "fine", 40, 120);
    testing.assertFalse(canPlay($t, $t.players[0]));
    testing.assertTrue(canPlay($t, $t.players[1]));
}

func testCanPlayAcceptsASeatWithNoTerminal() {
    def t as Table init seatBots(newTable(60, 24, 1, 4, 200), 1, bot.NORMAL);
    testing.assertTrue(canPlay($t, $t.players[0]));
}

# --- starting the game ------------------------------------------------------

func testStartGamePutsEveryoneOnTheAgreedField() {
    def t as Table init seatLocal(newTable(100, 40, 1, 4, 200), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 24, 80);
    $t = seatBots($t, 1, bot.HARD);
    def room as view.Room init view.Room{width: 30, height: 14};
    def ready as Table init startGame($t, $room, 99, 1);
    testing.assertEqual($ready.game.width, 30);
    testing.assertEqual($ready.game.height, 14);
    testing.assertEqual(len($ready.players), 3);
    for (def p in $ready.players) {
        testing.assertTrue(rules.hasSnake($ready.game, $p.id));
        for (def c in rules.snakeById($ready.game, $p.id).cells) {
            testing.assertTrue(geom.inBounds($c, 30, 14));
        }
    }
}

func testStartGameKeepsWhoIsWhat() {
    def t as Table init seatLocal(newTable(60, 24, 1, 4, 200), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    $t = seatBots($t, 1, bot.EXPERT);
    def ready as Table init startGame($t, view.Room{width: 40, height: 16}, 7, 1);
    testing.assertEqual(localId($ready), 1);
    testing.assertEqual(botCount($ready), 1);
    testing.assertEqual(humanCount($ready), 2);
    testing.assertEqual(idAt($ready, "c1"), 2);
    testing.assertEqual($ready.players[1].rows, 30);
    testing.assertEqual($ready.players[1].cols, 100);
    for (def p in $ready.players) {
        if (isBot($p)) {
            testing.assertEqual($p.level, bot.EXPERT);
        }
    }
}

func testStartGameKeepsAPlainGamePlain() {
    def t as Table init seatLocal(newTable(60, 24, 1, 4, 200), "host", 24, 80);
    $t.game = rules.withoutSpecials($t.game);
    def ready as Table init startGame($t, view.Room{width: 40, height: 16}, 7, 1);
    testing.assertFalse($ready.game.specials);
}

func testStartGameStartsAtTickZero() {
    def t as Table init seatLocal(newTable(60, 24, 1, 4, 200), "host", 24, 80);
    def ready as Table init startGame(advance(advance($t)), view.Room{width: 40, height: 16}, 7, 1);
    testing.assertEqual($ready.game.tick, 0);
}

func testAStartedGameIsImmediatelyPlayable() {
    def t as Table init seatLocal(newTable(60, 24, 1, 4, 200), "host", 30, 100);
    $t = seatBots($t, 2, bot.HARD);
    def room as view.Room init agreedField($t, capFrom(defaults()), 60, 220);
    def ready as Table init startGame($t, $room, 4242, 1);
    for (def tick as int init 0; $tick < 60; $tick = $tick + 1) {
        $ready = steerBots($ready);
        $ready = advance($ready);
    }
    testing.assertEqual($ready.game.tick, 60);
    testing.assertEqual(len($ready.players), 3);
}

# --- what the title screen says ---------------------------------------------

# A terminal with room to spare, so a test about *what* the title screen says is not
# also a test about which layout it chose. The tests that care about the layout name
# their own size.
def const ROOMY_ROWS as int init 40;
def const ROOMY_COLS as int init 100;

func testTheTitleScreenShowsEverySetting() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    def lines as list of string init titleLines(
        $t,
        setupFrom(defaults()),
        view.Room{width: 40, height: 16},
        "hosting udp:47475",
        BY_TERMINAL,
        ROOMY_ROWS,
        ROOMY_COLS);
    def whole as string init strings.join($lines, "\n");
    for (def row in SETUP_ROWS) {
        testing.assertTrue(strings.contains($whole, $row));
    }
}

func testTheTitleScreenShowsTheAgreedFieldAndTheRoster() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    def lines as list of string init titleLines(
        $t,
        setupFrom(defaults()),
        view.Room{width: 40, height: 16},
        "hosting udp:47475",
        BY_TERMINAL,
        ROOMY_ROWS,
        ROOMY_COLS);
    def whole as string init strings.join($lines, "\n");
    testing.assertTrue(strings.contains($whole, "40 x 16"));
    testing.assertTrue(strings.contains($whole, "host"));
    testing.assertTrue(strings.contains($whole, "guest"));
    testing.assertTrue(strings.contains($whole, "hosting udp:47475"));
    testing.assertTrue(strings.contains($whole, "start"));
}

func testTheTitleScreenMarksTheCursorOnExactlyOneRow() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    def setup as Setup init press(setupFrom(defaults()), ["down", "down"]);
    def lines as list of string init titleLines(
        $t,
        $setup,
        view.Room{width: 40, height: 16},
        "x",
        BY_TERMINAL,
        ROOMY_ROWS,
        ROOMY_COLS);
    def marked as int init 0;
    for (def line in $lines) {
        if (strings.startsWith($line, view.CURSOR_MARKER)) {
            $marked = $marked + 1;
        }
    }
    testing.assertEqual($marked, 1);
}

func testTheTitleScreenWarnsAboutATerminalTooSmall() {
    def t as Table init newTable(60, 24, 1, rules.MAX_PLAYERS, 200);
    $t = atTerminal($t, "c1", "tiny", 8, 20);
    def lines as list of string init titleLines(
        $t,
        setupFrom(defaults()),
        view.Room{width: 40, height: 16},
        "x",
        BY_TERMINAL,
        ROOMY_ROWS,
        ROOMY_COLS);
    testing.assertTrue(strings.contains(strings.join($lines, "\n"), "TOO SMALL"));
}

func testTheTitleScreenSaysHowManySeatsAreTaken() {
    def t as Table init seatLocal(newTable(60, 24, 1, 6, 200), "host", 24, 80);
    def lines as list of string init titleLines(
        $t,
        setupFrom(defaults()),
        view.Room{width: 40, height: 16},
        "x",
        BY_TERMINAL,
        ROOMY_ROWS,
        ROOMY_COLS);
    testing.assertTrue(strings.contains(strings.join($lines, "\n"), "1 of 6"));
}

# --- that the title screen fits the terminal it is drawn on ------------------

# fullTable seats the host plus enough computer players to fill every seat, which is the
# case the layouts exist for: a full table is what does not fit an ordinary terminal.
func fullTable() {
    def t as Table init seatLocal(newTable(60, 24, 1, rules.MAX_PLAYERS, 200), "ada", 24, 80);
    return seatBots($t, rules.MAX_PLAYERS - 1, bot.NORMAL);
}

# titleAt builds the title screen for one terminal size.
func titleAt(t as Table, rows as int, cols as int) {
    return titleLines(
        $t,
        setupFrom(defaults()),
        view.Room{width: 40, height: 16},
        "hosting udp:47475",
        BY_TERMINAL,
        $rows,
        $cols);
}

func testTheTitleScreenFitsEightPlayersOnAnOrdinaryTerminal() {
    # The case that sent us here: a full table on 80x24 wanted thirty-four rows, so the
    # field size and `enter start` fell off the bottom and a first-time host could not
    # see how to begin. `view.message` frames the body with a border and a blank row on
    # each side, so the body has four fewer rows than the terminal to play with.
    def lines as list of string init titleAt(fullTable(), 24, 80);
    testing.assertTrue(len($lines) + 4 <= 24);
}

func testTheTitleScreenFitsEveryTableOnEveryTerminal() {
    # Not just the one size: every seat count against every terminal a game can be played
    # on. `rules.MIN_HEIGHT + 4` is the shortest terminal `view.canShow` will agree to.
    for (def seats as int init 1; $seats <= rules.MAX_PLAYERS; $seats = $seats + 1) {
        def t as Table init seatLocal(newTable(60, 24, 1, $seats, 200), "ada", 24, 80);
        if ($seats > 1) {
            $t = seatBots($t, $seats - 1, bot.NORMAL);
        }
        for (def rows as int init 20; $rows <= 40; $rows = $rows + 1) {
            def lines as list of string init titleAt($t, $rows, 80);
            testing.assertTrue(len($lines) + 4 <= $rows);
        }
    }
}

func testTheTitleScreenNeverOutgrowsItsWidth() {
    # A folded roster is the one layout that can be too *wide*, and `proto.MAX_NAME` is
    # what bounds it: twelve runes a name, two names to a row.
    for (def rows as int init 20; $rows <= 40; $rows = $rows + 1) {
        for (def line in titleAt(fullTable(), $rows, 80)) {
            testing.assertTrue(len($line) + 4 <= 80);
        }
    }
}

func testTheTitleScreenKeepsWhatMattersWhenItShrinks() {
    # Fitting is worth nothing if the lines that survive are the decorative ones. These
    # four are the screen's whole purpose, and no layout may drop any of them.
    for (def rows as int init 20; $rows <= 40; $rows = $rows + 1) {
        def whole as string init strings.join(titleAt(fullTable(), $rows, 80), "\n");
        testing.assertTrue(strings.contains($whole, "enter start"));
        testing.assertTrue(strings.contains($whole, "field 40 x 16"));
        testing.assertTrue(strings.contains($whole, "8 of 8"));
        for (def row in SETUP_ROWS) {
            testing.assertTrue(strings.contains($whole, $row));
        }
    }
}

func testTheTitleScreenNamesEveryPlayerHoweverItFolds() {
    # Folding may shorten what is said *about* a player, but never drop one: a host
    # counting heads before starting has to find all eight.
    def t as Table init fullTable();
    for (def rows as int init 20; $rows <= 40; $rows = $rows + 1) {
        def whole as string init strings.join(titleAt($t, $rows, 80), "\n");
        for (def p in $t.players) {
            testing.assertTrue(strings.contains($whole, $p.name));
        }
    }
}

func testTheTitleScreenGivesUpTheLogoBeforeTheRoster() {
    # The order things are sacrificed in. A terminal roomy enough for everything shows
    # the logo and spells each player out; the same table on 80x24 has neither, and the
    # roster is what folds last.
    def t as Table init fullTable();
    def roomy as string init strings.join(titleAt($t, 40, 80), "\n");
    testing.assertTrue(strings.contains($roomy, view.LOGO[2]));
    testing.assertTrue(strings.contains($roomy, "at the keyboard"));

    def cramped as string init strings.join(titleAt($t, 24, 80), "\n");
    testing.assertFalse(strings.contains($cramped, view.LOGO[2]));
    testing.assertFalse(strings.contains($cramped, "at the keyboard"));
}

func testAFoldedRosterStillSaysWhoIsDrivingEachSnake() {
    def t as Table init fullTable();
    def whole as string init strings.join(titleAt($t, 24, 80), "\n");
    # The host is the one at the keyboard, and the rest are computer players; a folded
    # roster says so in three characters rather than fifteen.
    testing.assertTrue(strings.contains($whole, "you"));
    testing.assertTrue(strings.contains($whole, "cpu"));
}

func testAFoldedRosterStillFlagsATerminalTooSmall() {
    # `TERMINAL TOO SMALL` is actionable - resize the window before the game starts - so
    # it has to survive folding. It does, as a `!` on the entry plus one legend line,
    # which is cheaper than the words on every row.
    def t as Table init seatLocal(newTable(60, 24, 1, rules.MAX_PLAYERS, 200), "ada", 24, 80);
    $t = atTerminal($t, "c1", "tiny", 8, 20);
    $t = seatBots($t, rules.MAX_PLAYERS - 2, bot.NORMAL);
    def whole as string init strings.join(titleAt($t, 24, 80), "\n");
    testing.assertTrue(strings.contains($whole, "TOO SMALL"));
    testing.assertTrue(strings.contains($whole, "human!"));
}

func testTheTitleScreenCostsNoLegendWhenEveryTerminalFits() {
    # The legend is only worth a row when something is flagged.
    def whole as string init strings.join(titleAt(fullTable(), 24, 80), "\n");
    testing.assertFalse(strings.contains($whole, "TOO SMALL"));
}

func testTheTitleScreenFallsBackWhenNoSizeIsReported() {
    # `term.size` answers 0 under some pty setups. Treat that as the default terminal
    # rather than as a terminal with no rows at all, which would pick the tightest
    # layout for a screen that may have had room for everything.
    def t as Table init fullTable();
    testing.assertEqual(
        strings.join(titleAt($t, 0, 0), "\n"),
        strings.join(titleAt($t, view.FALLBACK_ROWS, view.FALLBACK_COLS), "\n"));
}

func testATerminalTooSmallForAnyLayoutGetsTheTightestOne() {
    # Below every layout nothing can fit and `view.message` clips. Returning the
    # tightest build means the clip eats blank rows and decoration; returning the
    # roomiest would eat the roster and the keys.
    def t as Table init fullTable();
    testing.assertEqual(
        strings.join(titleAt($t, 8, 80), "\n"),
        strings.join(titleAt($t, 20, 80), "\n"));
}

func testTheRosterPublishedToClientsMatchesTheTable() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    $t = seatBots($t, 1, bot.HARD);
    def seats as list of proto.Seat init roster($t);
    testing.assertEqual(len($seats), 3);
    testing.assertEqual($seats[0].name, "host");
    testing.assertEqual($seats[1].name, "guest");
    testing.assertEqual($seats[1].rows, 30);
    testing.assertEqual($seats[1].cols, 100);
    testing.assertEqual($seats[2].kind, COMPUTER);
}

func testTheRosterSurvivesTheWire() {
    def t as Table init seatLocal(table(), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    def line as string init proto.encodeLobby(40, 16, 125, $t.capacity, roster($t), 1);
    def m as proto.Message init proto.decode($line);
    testing.assertEqual($m.kind, proto.LOBBY);
    testing.assertEqual(len($m.seats), 2);
    testing.assertEqual($m.seats[1].name, "guest");
    testing.assertEqual($m.width, 40);
    testing.assertEqual($m.capacity, $t.capacity);
}

# --- rebuilding the table as the host changes its mind ----------------------

func testReseatKeepsTheHumansAndRebuildsTheBots() {
    def o as Options init defaults();
    def t as Table init seatLocal(newTable($o.width, $o.height, 5, 8, 200), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    $t = seatBots($t, 1, bot.NORMAL);
    def setup as Setup init setupFrom($o);
    $setup.bots = 3;
    $setup.botLevel = bot.EXPERT;
    $setup.capacity = 8;
    def after as Table init reseat($t, $o, $setup);
    testing.assertEqual(humanCount($after), 2);
    testing.assertEqual(botCount($after), 3);
    testing.assertEqual(idAt($after, "c1"), idAt($t, "c1"));
    for (def p in $after.players) {
        if (isBot($p)) {
            testing.assertEqual($p.level, bot.EXPERT);
        }
    }
}

func testReseatKeepsEachPlayersReportedTerminal() {
    def o as Options init defaults();
    def t as Table init atTerminal(
        newTable($o.width, $o.height, 5, 8, 200),
        "c1",
        "guest",
        30,
        100);
    def setup as Setup init setupFrom($o);
    $setup.bots = 1;
    def after as Table init reseat($t, $o, $setup);
    testing.assertEqual($after.players[0].rows, 30);
    testing.assertEqual($after.players[0].cols, 100);
}

func testReseatDoesNothingWhenTheSetupAlreadyMatches() {
    def o as Options init defaults();
    def t as Table init seatBots(
        newTable($o.width, $o.height, 5, $o.capacity, $o.tickMs),
        $o.bots,
        $o.botLevel);
    def before as int init len($t.players);
    testing.assertTrue(unchanged($t, setupFrom($o)));
    testing.assertEqual(len(reseat($t, $o, setupFrom($o)).players), $before);
}

func testReseatFollowsTheSpecialFoodSetting() {
    def o as Options init defaults();
    def t as Table init newTable($o.width, $o.height, 5, $o.capacity, $o.tickMs);
    def setup as Setup init setupFrom($o);
    $setup.specials = false;
    def after as Table init reseat($t, $o, $setup);
    testing.assertFalse($after.game.specials);
    testing.assertFalse(unchanged($t, $setup));
}

func testReseatFollowsTheCapacitySetting() {
    def o as Options init defaults();
    def t as Table init newTable($o.width, $o.height, 5, 8, $o.tickMs);
    def setup as Setup init setupFrom($o);
    $setup.capacity = 2;
    testing.assertEqual(reseat($t, $o, $setup).capacity, 2);
}

func testReseatWillNotSeatMoreBotsThanSeats() {
    def o as Options init defaults();
    def t as Table init seatLocal(newTable($o.width, $o.height, 5, 8, $o.tickMs), "host", 24, 80);
    def setup as Setup init setupFrom($o);
    $setup.capacity = 3;
    $setup.bots = 8;
    def after as Table init reseat($t, $o, $setup);
    testing.assertEqual(len($after.players), 3);
    testing.assertEqual(humanCount($after), 1);
}

# --- the cap must not bind unless the host asked for it ----------------------

func testTheDefaultCapDoesNotBindAtAll() {
    # The bug this guards: a default --width / --height was capping the negotiation,
    # so a 50x160 terminal still got a 44x16 field and the title screen claimed that
    # was the largest the terminals could show.
    def o as Options init defaults();
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    def room as view.Room init agreedField($t, capFrom($o), 50, 160);
    def free as view.Room init view.maxField(50, 160, 2, true);
    testing.assertEqual($room.width, $free.width);
    testing.assertEqual($room.height, $free.height);
    testing.assertTrue($room.width > rules.DEFAULT_WIDTH);
    testing.assertTrue($room.height > rules.DEFAULT_HEIGHT);
    testing.assertFalse(cappedByHost($t, capFrom($o), 50, 160));
}

func testABigTerminalGetsABigField() {
    def o as Options init defaults();
    def t as Table init seatLocal(newTable($o.width, $o.height, 1, 2, 200), "host", 50, 160);
    def room as view.Room init agreedField($t, capFrom($o), 50, 160);
    # 160 columns would allow 158, but the game's own maximum is the real ceiling.
    # 160 columns leaves 158 for the field, and nothing now caps it below that.
    testing.assertEqual($room.width, 158);
    testing.assertEqual($room.height, 43);
}

func testAnExplicitCapStillBinds() {
    def o as Options init defaults();
    $o.width = 30;
    $o.height = 12;
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    def room as view.Room init agreedField($t, capFrom($o), 50, 160);
    testing.assertEqual($room.width, 30);
    testing.assertEqual($room.height, 12);
    testing.assertTrue(cappedByHost($t, capFrom($o), 50, 160));
}

func testCappedByHostIsFalseWhenATerminalIsTheTighterLimit() {
    # A cap that is looser than the smallest terminal did not decide anything, and
    # the title screen must not claim it did.
    def o as Options init defaults();
    $o.width = rules.MAX_WIDTH;
    $o.height = rules.MAX_HEIGHT;
    def t as Table init atTerminal(newTable($o.width, $o.height, 1, 2, 200), "c1", "small", 24, 80);
    testing.assertFalse(cappedByHost($t, capFrom($o), 50, 160));
}

func testTheTitleScreenNamesWhicheverLimitBound() {
    # A player looking at a field smaller than their display needs to know which knob
    # would change it, so each limit says something different and only one at a time.
    def t as Table init seatLocal(table(), "host", 24, 80);
    def room as view.Room init view.Room{width: 30, height: 12};
    def byCap as string init titled($t, $room, BY_CAP);
    def byWire as string init titled($t, $room, BY_TRANSPORT);
    def byTerm as string init titled($t, $room, BY_TERMINAL);
    testing.assertTrue(strings.contains($byCap, "capped by --width"));
    testing.assertTrue(strings.contains($byWire, "udp datagram"));
    testing.assertTrue(strings.contains($byWire, "--mode tcp"));
    testing.assertTrue(strings.contains($byTerm, "largest every terminal"));
    testing.assertFalse(strings.contains($byCap, "largest every terminal"));
    testing.assertFalse(strings.contains($byWire, "largest every terminal"));
}

# titled is the title screen as one string, for the assertions above.
func titled(t as Table, room as view.Room, limit as string) {
    return strings.join(
        titleLines($t, setupFrom(defaults()), $room, "x", $limit, ROOMY_ROWS, ROOMY_COLS),
        "\n");
}

# --- a watching host still constrains the field ------------------------------

func testAWatchingHostsTerminalStillDecidesTheSize() {
    # The second bug this guards: --watch leaves the host with no seat, so before the
    # fix its terminal was not consulted - yet it is the one drawing the game.
    def o as Options init defaults();
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    testing.assertEqual(len($t.players), 0);
    def room as view.Room init agreedField($t, capFrom($o), 24, 80);
    def mine as view.Room init view.maxField(24, 80, 2, true);
    testing.assertEqual($room.width, $mine.width);
    testing.assertEqual($room.height, $mine.height);
}

func testAWatchingHostOnASmallTerminalCanStillDrawTheGame() {
    def o as Options init defaults();
    def t as Table init atTerminal(newTable($o.width, $o.height, 1, 4, 200), "c1", "big", 60, 200);
    def room as view.Room init agreedField($t, capFrom($o), 24, 80);
    def ready as Table init startGame($t, $room, 1, 1);
    testing.assertTrue(view.fit($ready.game, 24, 80).fits);
    testing.assertTrue(view.fit($ready.game, 60, 200).fits);
}

func testTheHostsScreenCountsEvenWithASeatOfItsOwn() {
    # Counting it twice - once as the screen, once as the local seat - must be
    # harmless, because `smaller` is idempotent.
    def o as Options init defaults();
    def t as Table init seatLocal(newTable($o.width, $o.height, 1, 2, 200), "host", 24, 80);
    def room as view.Room init agreedField($t, capFrom($o), 24, 80);
    testing.assertEqual($room.width, view.maxField(24, 80, 2, true).width);
    testing.assertEqual($room.height, view.maxField(24, 80, 2, true).height);
}

# --- the transport's own limit on the field ----------------------------------

func testALargeUdpFieldIsHeldToWhatADatagramCarries() {
    def o as Options init defaults();
    $o.mode = link.UDP;
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    def room as view.Room init playableField($t, $o, 90, 300);
    testing.assertTrue($room.width * $room.height <= link.maxFieldArea(link.UDP));
    testing.assertEqual(fieldLimit($t, $o, 90, 300), BY_TRANSPORT);
}

func testTheSameFieldOnTcpIsNotHeldBack() {
    # The reason a host on a big display might choose tcp: a stream has no datagram.
    def o as Options init defaults();
    $o.mode = link.TCP;
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    def udp as Options init $o;
    $udp.mode = link.UDP;
    def wide as view.Room init playableField($t, $o, 90, 300);
    def narrow as view.Room init playableField($t, $udp, 90, 300);
    testing.assertTrue($wide.width * $wide.height > $narrow.width * $narrow.height);
    testing.assertEqual(fieldLimit($t, $o, 90, 300), BY_TERMINAL);
}

func testAnOrdinaryTerminalIsNotHeldBackByEitherTransport() {
    # The common case must be untouched by all of this: on a normal screen the terminal
    # is the only thing that decides, whichever transport is in use.
    for (def mode in link.TRANSPORTS) {
        def o as Options init defaults();
        $o.mode = $mode;
        def t as Table init newTable($o.width, $o.height, 1, 2, 200);
        def room as view.Room init playableField($t, $o, 24, 80);
        testing.assertEqual($room.width, 78);
        testing.assertEqual($room.height, 17);
        testing.assertEqual(fieldLimit($t, $o, 24, 80), BY_TERMINAL);
    }
}

func testAWideDisplayFinallyGetsItsWidth() {
    # The bug this guards: rules.MAX_WIDTH was 120, so a 190-column display was cut to
    # about two thirds of its width for no reason the code could justify.
    def o as Options init defaults();
    $o.mode = link.TCP;
    def t as Table init newTable($o.width, $o.height, 1, 2, 200);
    def room as view.Room init playableField($t, $o, 33, 190);
    testing.assertEqual($room.width, 188);
    testing.assertTrue($room.width > 120);
}

func testAPlayableFieldIsAlwaysDrawableByEveryone() {
    # Whatever combination of terminal, cap and transport, the field that comes out must
    # be one every reported terminal can draw - that is the whole point.
    def terminals as list of list of int init [[24, 80], [33, 190], [60, 300], [20, 62]];
    for (def mode in link.TRANSPORTS) {
        def o as Options init defaults();
        $o.mode = $mode;
        def t as Table init newTable($o.width, $o.height, 1, rules.MAX_PLAYERS, 200);
        for (def i as int init 0; $i < len($terminals); $i = $i + 1) {
            $t = atTerminal(
                $t,
                "c" + convert.toString($i),
                "p",
                $terminals[$i][0],
                $terminals[$i][1]);
        }
        def ready as Table init startGame($t, playableField($t, $o, 40, 200), 1, 1);
        for (def term in $terminals) {
            testing.assertTrue(view.fit($ready.game, $term[0], $term[1]).fits);
        }
    }
}

# --- lives, from the host's side ---------------------------------------------

func testATableHandsOutTheLivesTheOptionsAskFor() {
    def o as Options init defaults();
    $o.lives = 2;
    def t as Table init tableFor($o, setupFrom($o), []);
    testing.assertEqual($t.game.lives, 2);
    for (def p in $t.players) {
        testing.assertEqual(rules.snakeById($t.game, $p.id).lives, 2);
    }
}

func testTheLivesRowWalksOneToNineThenUnlimited() {
    def s as Setup init onRow(setupFrom(defaults()), "lives");
    def seen as list of string init [];
    for (def i as int init 0; $i < rules.MAX_LIVES + 1; $i = $i + 1) {
        $seen[] = setupValue($s, $s.row);
        $s = press($s, ["right"]);
    }
    testing.assertTrue(lists.contains($seen, "1"));
    testing.assertTrue(lists.contains($seen, convert.toString(rules.MAX_LIVES)));
    testing.assertTrue(lists.contains($seen, "unlimited"));
    # A full cycle comes back to where it started.
    testing.assertEqual(setupValue($s, $s.row), $seen[0]);
}

func testTheLivesRowWalksBackwardsToo() {
    def s as Setup init onRow(setupFrom(defaults()), "lives");
    def before as int init $s.lives;
    testing.assertEqual(press(press($s, ["left"]), ["right"]).lives, $before);
}

func testTheLivesRowNamesTheEndlessGame() {
    def s as Setup init onRow(setupFrom(defaults()), "lives");
    $s.lives = rules.UNLIMITED_LIVES;
    testing.assertEqual(setupValue($s, $s.row), "unlimited");
}

func testTheSetupCarriesLivesIntoTheOptions() {
    def s as Setup init onRow(setupFrom(defaults()), "lives");
    $s.lives = 5;
    testing.assertEqual(withSetup(defaults(), $s).lives, 5);
}

func testAnySetupProducesALivesSettingTheRulesAccept() {
    def s as Setup init onRow(setupFrom(defaults()), "lives");
    for (def i as int init 0; $i < 30; $i = $i + 1) {
        $s = press($s, ["right"]);
        testing.assertEqual($s.lives, rules.livesOr($s.lives));
    }
}

func testChangingLivesRebuildsTheTable() {
    def o as Options init defaults();
    def t as Table init tableFor($o, setupFrom($o), []);
    def s as Setup init setupFrom($o);
    $s.lives = 1;
    testing.assertFalse(unchanged($t, $s));
    testing.assertEqual(reseat($t, $o, $s).game.lives, 1);
}

func testStartGameKeepsTheLivesSetting() {
    def t as Table init seatLocal(newTable(60, 24, 1, 4, 200), "host", 24, 80);
    $t.game = rules.withLives($t.game, 2);
    def ready as Table init startGame($t, view.Room{width: 40, height: 16}, 7, 1);
    testing.assertEqual($ready.game.lives, 2);
    testing.assertEqual(rules.snakeById($ready.game, 1).lives, 2);
}

func testLivesReachEveryClientInTheState() {
    def t as Table init join(table(), "c1", "ada").table;
    $t.game = rules.withLives($t.game, 4);
    def back as rules.Game init proto.decode(stateLine($t)).game;
    testing.assertEqual($back.lives, 4);
    testing.assertEqual(rules.snakeById($back, 1).lives, 4);
}

func testASpectatorKeepsItsSeatAtTheHost() {
    # Out of lives is not out of the game: the seat, the score and the socket all stay.
    def t as Table init join(newTable(20, 10, 1, 3, 200), "c1", "ada").table;
    $t.game = rules.withLives($t.game, 1);
    $t.game.snakes[0].alive = false;
    $t.game.snakes[0].cells = [];
    $t.game.snakes[0].lives = 0;
    testing.assertEqual(len($t.players), 1);
    testing.assertEqual(len(audience($t)), 1);
    testing.assertTrue(rules.isSpectator($t.game, rules.snakeById($t.game, 1)));
    # And a sweep leaves them alone while they keep talking.
    def r as Reaction init sweep($t, 0, IDLE_TICKS, FORFEIT, bot.NORMAL);
    testing.assertEqual(len($r.table.players), 1);
}

func testASpectatorStillReceivesTheGame() {
    def t as Table init join(newTable(20, 10, 1, 3, 200), "c1", "ada").table;
    $t.game = rules.withLives($t.game, 1);
    $t.game.snakes[0].alive = false;
    $t.game.snakes[0].lives = 0;
    def m as proto.Message init proto.decode(stateLine($t));
    testing.assertEqual($m.kind, proto.STATE);
    testing.assertTrue(rules.isSpectator($m.game, rules.snakeById($m.game, 1)));
}

func testTheHeaderSaysSoWhenEverybodyIsOut() {
    def t as Table init seatBots(newTable(20, 10, 1, 2, 200), 1, bot.NORMAL);
    $t.game = rules.withLives($t.game, 1);
    $t.game.snakes[0].alive = false;
    $t.game.snakes[0].cells = [];
    $t.game.snakes[0].lives = 0;
    testing.assertTrue(rules.isOver($t.game));
    testing.assertTrue(strings.contains(banner($t, "hosting udp:1"), "GAME OVER"));
    testing.assertFalse(strings.contains(banner(table(), "hosting udp:1"), "GAME OVER"));
}

func testAHostedGameWithLivesReachesAFinish() {
    def t as Table init seatBots(newTable(14, 8, 20260929, 4, 200), 4, bot.EASY);
    $t.game = rules.withLives($t.game, 1);
    for (def tick as int init 0; $tick < 500 and not rules.isOver($t.game); $tick = $tick + 1) {
        $t = steerBots($t);
        $t = advance($t);
    }
    testing.assertTrue(rules.isOver($t.game));
    testing.assertEqual(len($t.players), 4);
    testing.assertEqual(proto.decode(stateLine($t)).kind, proto.STATE);
}

func testTheHeaderFitsTheNarrowestPlayableTerminal() {
    # `screen` clips a row rather than wrapping it, so a header longer than the terminal
    # loses its tail silently - and the tail is where the game-over note goes.
    def t as Table init seatBots(newTable(20, 10, 1, rules.MAX_PLAYERS, 200), 1, bot.NORMAL);
    $t.game = rules.withLives($t.game, 1);
    $t.game.snakes[0].alive = false;
    $t.game.snakes[0].cells = [];
    $t.game.snakes[0].lives = 0;
    def wire as link.Host init link.Host{
        mode: link.UDP,
        udp: net.UDPSocket{id: 0},
        listener: net.Listener{id: 0},
        arrivals: channel.make(1),
        conns: {},
        buffers: {},
        port: 47475
    };
    for (def announcing in [true, false]) {
        def header as string init banner($t, note($wire, $announcing));
        def line as string init io.sprintf(
            "jsnake  tick %d|pad=6|align=left %d player(s)  %s",
            99999,
            rules.MAX_PLAYERS,
            $header);
        testing.assertTrue(len($line) <= view.MIN_COLS + 46);
        testing.assertTrue(len($line) <= 80);
    }
}

# --- a round ends, and another can be set up ---------------------------------

func testPeopleAreWhoCarriesToTheNextRound() {
    def t as Table init seatLocal(newTable(20, 10, 1, 8, 200), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 30, 100);
    $t = seatBots($t, 2, bot.NORMAL);
    def keep as list of Player init people($t);
    testing.assertEqual(len($keep), 2);
    testing.assertEqual($keep[0].name, "host");
    testing.assertEqual($keep[1].name, "guest");
}

func testTheNextRoundSeatsThePeopleAgainWithoutThemRejoining() {
    # Their sockets never went anywhere, so neither should their seats.
    def o as Options init defaults();
    def first as Table init atTerminal(tableFor($o, setupFrom($o), []), "c1", "guest", 30, 100);
    def keep as list of Player init people($first);
    def second as Table init tableFor($o, setupFrom($o), $keep);
    testing.assertEqual(humanCount($second), len($keep));
    testing.assertEqual(idAt($second, "c1"), idAt($first, "c1"));
    testing.assertEqual($second.players[1].rows, 30);
    testing.assertEqual($second.players[1].cols, 100);
}

func testTheNextRoundRebuildsTheComputerPlayersFromTheSetup() {
    def o as Options init defaults();
    def s as Setup init setupFrom($o);
    $s.bots = 2;
    $s.botLevel = bot.EXPERT;
    def first as Table init tableFor($o, $s, []);
    def keep as list of Player init people($first);
    $s.bots = 1;
    $s.botLevel = bot.EASY;
    def second as Table init tableFor($o, $s, $keep);
    testing.assertEqual(botCount($second), 1);
    for (def p in $second.players) {
        if (isBot($p)) {
            testing.assertEqual($p.level, bot.EASY);
        }
    }
}

func testTheNextRoundStartsEverybodyOnFullLives() {
    def o as Options init defaults();
    $o.lives = 2;
    def first as Table init tableFor($o, setupFrom($o), []);
    $first.game.snakes[0].lives = 0;
    def second as Table init tableFor($o, setupFrom($o), people($first));
    testing.assertEqual(rules.snakeById($second.game, $second.players[0].id).lives, 2);
    testing.assertFalse(rules.isOver($second.game));
}

func testTheNextRoundDoesNotSeatTheHostTwice() {
    def o as Options init defaults();
    def first as Table init tableFor($o, setupFrom($o), []);
    testing.assertEqual(localId($first), 1);
    def second as Table init tableFor($o, setupFrom($o), people($first));
    def locals as int init 0;
    for (def p in $second.players) {
        if ($p.local) {
            $locals = $locals + 1;
        }
    }
    testing.assertEqual($locals, 1);
}

func testAWatchingHostSeatsNobodyOnEitherRound() {
    def o as Options init defaults();
    $o.play = false;
    def first as Table init tableFor($o, setupFrom($o), []);
    testing.assertEqual(len($first.players), 0);
    testing.assertEqual(len(tableFor($o, setupFrom($o), people($first)).players), 0);
}

# --- the end-of-round standings ----------------------------------------------

# finished is a table where everybody has spent their last life.
func finished() {
    def t as Table init seatLocal(newTable(20, 10, 1, 8, 200), "host", 24, 80);
    $t = atTerminal($t, "c1", "guest", 24, 80);
    $t = seatBots($t, 1, bot.NORMAL);
    $t.game = rules.withLives($t.game, 1);
    for (def i as int init 0; $i < len($t.game.snakes); $i = $i + 1) {
        $t.game.snakes[$i].alive = false;
        $t.game.snakes[$i].cells = [];
        $t.game.snakes[$i].lives = 0;
    }
    $t.game.snakes[0].score = 30;
    $t.game.snakes[1].score = 90;
    $t.game.snakes[2].score = 60;
    return $t;
}

func testTheStandingsRankByScore() {
    def lines as list of string init standingsLines(finished());
    testing.assertTrue(strings.contains($lines[0], "guest"));
    testing.assertTrue(strings.contains($lines[1], "cpu1-normal"));
    testing.assertTrue(strings.contains($lines[2], "host"));
}

func testTheStandingsListEverybodyExactlyOnce() {
    def t as Table init finished();
    def lines as list of string init standingsLines($t);
    # One line per player, then a blank and the prompt.
    testing.assertEqual(len($lines), len($t.players) + 2);
    for (def p in $t.players) {
        def seen as int init 0;
        for (def line in $lines) {
            if (strings.contains($line, $p.name)) {
                $seen = $seen + 1;
            }
        }
        testing.assertEqual($seen, 1);
    }
}

func testTheStandingsShowScoresAndDeaths() {
    def whole as string init strings.join(standingsLines(finished()), "\n");
    testing.assertTrue(strings.contains($whole, "90"));
    testing.assertTrue(strings.contains($whole, "death"));
}

func testTheStandingsOfferAnotherRoundAndAWayBack() {
    # Enter plays again; Escape goes back to the title screen, from where Escape again
    # leaves. Naming a way straight out here would skip a level the host usually wants.
    def last as string init standingsLines(finished())[len(standingsLines(finished())) - 1];
    testing.assertTrue(strings.contains($last, "another round"));
    testing.assertTrue(strings.contains($last, keys.ESCAPE_LABEL));
    testing.assertTrue(strings.contains($last, "menu"));
}

func testTheStandingsBreakTiesOnThePlayerId() {
    def t as Table init finished();
    for (def i as int init 0; $i < len($t.game.snakes); $i = $i + 1) {
        $t.game.snakes[$i].score = 10;
    }
    def lines as list of string init standingsLines($t);
    testing.assertTrue(strings.contains($lines[0], "host"));
    testing.assertTrue(strings.contains($lines[1], "guest"));
}

func testTheStandingsSurviveAnEmptyTable() {
    def lines as list of string init standingsLines(newTable(20, 10, 1, 4, 200));
    testing.assertTrue(strings.contains($lines[0], "nobody played"));
}

# --- the computer-player count cannot promise seats that do not exist --------

func testMaxBotsIsEverySeatThePeopleAreNotUsing() {
    def t as Table init newTable(20, 10, 1, 8, 200);
    testing.assertEqual(maxBots($t), 8);
    $t = seatLocal($t, "host", 24, 80);
    testing.assertEqual(maxBots($t), 7);
    $t = atTerminal($t, "c1", "guest", 24, 80);
    testing.assertEqual(maxBots($t), 6);
}

func testMaxBotsIgnoresTheComputerPlayersAlreadySeated() {
    # It is a ceiling on the total, not on how many more could be added.
    def t as Table init seatBots(
        seatLocal(newTable(20, 10, 1, 8, 200), "host", 24, 80),
        4,
        bot.NORMAL);
    testing.assertEqual(maxBots($t), 7);
}

func testMaxBotsIsNeverNegative() {
    def t as Table init newTable(20, 10, 1, 1, 200);
    $t = seatLocal($t, "host", 24, 80);
    testing.assertEqual(maxBots($t), 0);
}

func testTheBotsRowIsHeldToWhatCanBeSeated() {
    # The bug this fixes: `--players 8 --bots 8` with the host playing seats one person and
    # seven computers, but the title screen went on reading `computer players 8`.
    def o as Options init defaults();
    $o.capacity = 8;
    $o.bots = 8;
    def t as Table init tableFor($o, setupFrom($o), []);
    def s as Setup init fitBots(setupFrom($o), $t);
    testing.assertEqual(humanCount($t), 1);
    testing.assertEqual(botCount($t), 7);
    testing.assertEqual($s.bots, 7);
    testing.assertEqual($s.bots, botCount($t));
}

func testTheBotsRowIsLeftAloneWhenItAlreadyFits() {
    def o as Options init defaults();
    $o.capacity = 8;
    $o.bots = 3;
    def t as Table init tableFor($o, setupFrom($o), []);
    testing.assertEqual(fitBots(setupFrom($o), $t).bots, 3);
}

func testAWatchingHostLeavesEverySeatToTheComputers() {
    def o as Options init defaults();
    $o.capacity = 8;
    $o.bots = 8;
    $o.play = false;
    def t as Table init tableFor($o, setupFrom($o), []);
    testing.assertEqual(botCount($t), 8);
    testing.assertEqual(fitBots(setupFrom($o), $t).bots, 8);
}

func testTheCeilingFallsAsPeopleJoin() {
    # Two seats of computers on an eight-seat table, so there is room for people to arrive.
    def o as Options init defaults();
    $o.capacity = 8;
    $o.bots = 2;
    def t as Table init tableFor($o, setupFrom($o), []);
    def s as Setup init setupFrom($o);
    testing.assertEqual(maxBots($t), 7);
    $t = atTerminal($t, "c1", "ada", 24, 80);
    $t = atTerminal($t, "c2", "bob", 24, 80);
    testing.assertEqual(humanCount($t), 3);
    testing.assertEqual(maxBots($t), 5);
    # The host now asks for a full house of computers; it is held to the five seats left.
    $s.bots = rules.MAX_PLAYERS;
    $s = fitBots($s, $t);
    testing.assertEqual($s.bots, 5);
    def after as Table init reseat($t, $o, $s);
    testing.assertEqual(humanCount($after), 3);
    testing.assertEqual(botCount($after), 5);
    testing.assertEqual(len($after.players), 8);
}

func testAFullHouseOfComputersLeavesNoRoomToJoin() {
    # The flip side of the same arithmetic, and worth knowing: fill every seat with
    # computers and a person asking to join is refused, because there is nowhere to sit.
    def o as Options init defaults();
    $o.capacity = 4;
    $o.bots = rules.MAX_PLAYERS;
    def t as Table init tableFor($o, setupFrom($o), []);
    testing.assertTrue(isFull($t));
    def r as Reaction init join($t, "c1", "late");
    testing.assertEqual(proto.decode($r.replies[0].body).kind, proto.DENY);
    # Turning the computers down makes room again.
    def s as Setup init fitBots(setupFrom($o), $t);
    $s.bots = 1;
    def fewer as Table init reseat($t, $o, $s);
    testing.assertFalse(isFull($fewer));
    testing.assertEqual(
        proto.decode(join($fewer, "c1", "late").replies[0].body).kind,
        proto.WELCOME);
}

func testWhatTheRowSaysIsWhatGetsSeated() {
    # The property that makes the number trustworthy, across the whole range.
    def o as Options init defaults();
    $o.capacity = 8;
    for (def asked as int init 0; $asked <= rules.MAX_PLAYERS; $asked = $asked + 1) {
        $o.bots = $asked;
        def t as Table init tableFor($o, setupFrom($o), []);
        def s as Setup init fitBots(setupFrom($o), $t);
        testing.assertEqual($s.bots, botCount($t));
        testing.assertTrue(len($t.players) <= $t.capacity);
    }
}

func testTheRowStillSaysWhatGetsSeatedOnASmallTable() {
    def o as Options init defaults();
    for (def seats as int init 1; $seats <= 4; $seats = $seats + 1) {
        $o.capacity = $seats;
        $o.bots = rules.MAX_PLAYERS;
        def t as Table init tableFor($o, setupFrom($o), []);
        def s as Setup init fitBots(setupFrom($o), $t);
        testing.assertEqual($s.bots, botCount($t));
        testing.assertEqual(len($t.players), $seats);
    }
}

# --- a player's id survives a rebuild ----------------------------------------

func testAPlayerKeepsItsIdAcrossARound() {
    # A client learns its id once, from its WELCOME, and uses it to find its own snake on
    # every screen after that. Rebuilding the table with fresh ids silently points every
    # client at somebody else's snake - which is exactly what happened when the people were
    # re-seated in a different order from the one they arrived in.
    def o as Options init defaults();
    $o.capacity = 4;
    $o.bots = 1;
    def first as Table init tableFor($o, setupFrom($o), []);
    $first = atTerminal($first, "c1", "ada", 24, 80);
    def before as int init idAt($first, "c1");
    testing.assertTrue($before > 0);
    def second as Table init tableFor($o, setupFrom($o), people($first));
    testing.assertEqual(idAt($second, "c1"), $before);
}

func testIdsSurviveEvenWhenTheSeatingOrderChanges() {
    # The bug's exact shape: a computer player was seated before the person arrived, so the
    # person had id 3; on the rebuild the people go first and they would have become id 2.
    def o as Options init defaults();
    $o.capacity = 4;
    $o.bots = 1;
    def first as Table init tableFor($o, setupFrom($o), []);
    $first = atTerminal($first, "c1", "ada", 24, 80);
    testing.assertEqual(localId($first), 1);
    testing.assertEqual(idAt($first, "c1"), 3);
    def second as Table init tableFor($o, setupFrom($o), people($first));
    testing.assertEqual(localId($second), 1);
    testing.assertEqual(idAt($second, "c1"), 3);
}

func testIdsSurviveASetupChangeMidLobby() {
    def o as Options init defaults();
    def t as Table init atTerminal(tableFor($o, setupFrom($o), []), "c1", "ada", 24, 80);
    def before as int init idAt($t, "c1");
    def s as Setup init setupFrom($o);
    $s.bots = 3;
    testing.assertEqual(idAt(reseat($t, $o, $s), "c1"), $before);
}

func testIdsSurviveStartingTheGame() {
    def o as Options init defaults();
    def t as Table init atTerminal(tableFor($o, setupFrom($o), []), "c1", "ada", 24, 80);
    def before as int init idAt($t, "c1");
    def ready as Table init startGame($t, view.Room{width: 30, height: 12}, 7, 1);
    testing.assertEqual(idAt($ready, "c1"), $before);
    testing.assertTrue(rules.hasSnake($ready.game, $before));
}

func testANewJoinerStillGetsAFreeId() {
    # Preserving ids must not stop the next arrival getting one of their own.
    def o as Options init defaults();
    $o.capacity = 4;
    def t as Table init atTerminal(tableFor($o, setupFrom($o), []), "c1", "ada", 24, 80);
    def rebuilt as Table init tableFor($o, setupFrom($o), people($t));
    def joined as Table init atTerminal($rebuilt, "c2", "bob", 24, 80);
    def ids as map of int to bool init {};
    for (def p in $joined.players) {
        testing.assertFalse(maps.has($ids, $p.id));
        $ids[$p.id] = true;
    }
    testing.assertEqual(len($joined.players), len($ids));
}

func testIdsStayPutAcrossSeveralRounds() {
    def o as Options init defaults();
    $o.capacity = 6;
    $o.bots = 2;
    def t as Table init tableFor($o, setupFrom($o), []);
    $t = atTerminal($t, "c1", "ada", 24, 80);
    $t = atTerminal($t, "c2", "bob", 24, 80);
    def ada as int init idAt($t, "c1");
    def bob as int init idAt($t, "c2");
    for (def round as int init 0; $round < 4; $round = $round + 1) {
        $t = startGame(
            tableFor($o, setupFrom($o), people($t)),
            view.Room{width: 30, height: 12},
            $round + 1,
            $round + 1);
        testing.assertEqual(idAt($t, "c1"), $ada);
        testing.assertEqual(idAt($t, "c2"), $bob);
        testing.assertEqual($t.game.round, $round + 1);
    }
}
