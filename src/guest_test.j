# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# White-box tests for guest.j. `absorb` is the guest's whole understanding of what
# a host says, and it is pure, so every message - including the ones a hostile or
# broken host would send - is checked here with no socket and no terminal. The
# discovery menu's arithmetic is pinned down the same way. Run with:
#
#     jennifer test src/guest_test.j

use testing;
use strings;

# guest.j has no need of geom; this overlay does, to name a direction.
import "./geom.j" as geom;

# key builds a decoded keypress the way screen.decodeKey would.
func key(name as string, char as string) {
    return screen.Key{name: $name, char: $char};
}

# found builds a discovered host the way beacon.discover would report one.
func found(name as string, address as string, mode as string) {
    return beacon.Found{name: $name, address: $address, mode: $mode, players: 1, capacity: 8};
}

# welcomed is a seat that has completed the handshake as player `id`.
func welcomed(id as int) {
    return absorb(newSeat(), proto.encodeWelcome($id, 20, 10, 100));
}

# game builds a small live game a host could be sending.
func game() {
    def g as rules.Game init rules.newGame(20, 10, 5);
    $g = rules.addSnake($g, 1, "ada");
    $g = rules.addSnake($g, 2, "bob");
    return rules.advance($g);
}

# --- a fresh seat ------------------------------------------------------------

func testANewSeatHasJoinedNothing() {
    def s as Seat init newSeat();
    testing.assertEqual($s.id, 0);
    testing.assertFalse($s.joined);
    testing.assertFalse($s.finished);
    testing.assertEqual($s.reason, "");
    testing.assertEqual($s.frames, 0);
    testing.assertTrue(isWaiting($s));
}

func testDefaultsGoLookingForAGame() {
    def o as Options init defaults();
    testing.assertEqual($o.address, "");
    testing.assertTrue(link.isTransport($o.mode));
    testing.assertTrue($o.discoverMs > 0);
    testing.assertTrue(len($o.name) > 0);
}

# --- WELCOME -----------------------------------------------------------------

func testWelcomeAdmitsThePlayer() {
    def s as Seat init absorb(newSeat(), proto.encodeWelcome(3, 30, 12, 150));
    testing.assertTrue($s.joined);
    testing.assertEqual($s.id, 3);
    testing.assertEqual($s.tickMs, 150);
    testing.assertFalse(isWaiting($s));
}

func testASecondWelcomeIsIgnored() {
    # A retried JOIN can be answered twice on UDP. Reassigning the id mid-game
    # would make the player lose track of which snake is theirs.
    def s as Seat init welcomed(3);
    def again as Seat init absorb($s, proto.encodeWelcome(9, 30, 12, 150));
    testing.assertEqual($again.id, 3);
}

func testAWelcomeWithNoIdIsNotAnAdmission() {
    # Otherwise the guest would play as nobody and never retry.
    def s as Seat init absorb(newSeat(), "WELCOME|0|20|10|100");
    testing.assertFalse($s.joined);
    testing.assertTrue(isWaiting($s));
}

func testAWelcomeWithANegativeIdIsRefused() {
    testing.assertFalse(absorb(newSeat(), "WELCOME|-4|20|10|100").joined);
}

func testAWelcomeWithAGarbledTailStillAdmits() {
    def s as Seat init absorb(newSeat(), "WELCOME|2");
    testing.assertTrue($s.joined);
    testing.assertEqual($s.id, 2);
}

# --- STATE -------------------------------------------------------------------

func testStateBecomesTheGameOnScreen() {
    def s as Seat init absorb(welcomed(1), proto.encodeState(game()));
    testing.assertEqual($s.frames, 1);
    testing.assertEqual(len($s.game.snakes), 2);
    testing.assertEqual($s.game.width, 20);
    testing.assertTrue(rules.hasSnake($s.game, 1));
}

func testEachStateCountsAFrame() {
    def s as Seat init welcomed(1);
    $s = absorb($s, proto.encodeState(game()));
    $s = absorb($s, proto.encodeState(game()));
    testing.assertEqual($s.frames, 2);
}

func testAStateBeforeTheWelcomeIsStillDrawn() {
    # On UDP the two can cross. Drawing the field a moment early beats drawing
    # nothing, and the WELCOME that follows still admits the player.
    def s as Seat init absorb(newSeat(), proto.encodeState(game()));
    testing.assertEqual($s.frames, 1);
    testing.assertFalse($s.joined);
    $s = absorb($s, proto.encodeWelcome(1, 20, 10, 100));
    testing.assertTrue($s.joined);
    testing.assertEqual(len($s.game.snakes), 2);
}

func testTheGuestNeverAdvancesTheGameItself() {
    # The host is the only authority: two consecutive identical STATEs must leave
    # the tick where the host put it.
    def line as string init proto.encodeState(game());
    def s as Seat init absorb(absorb(welcomed(1), $line), $line);
    testing.assertEqual($s.game.tick, proto.decode($line).game.tick);
}

# --- being told to go --------------------------------------------------------

func testDenyEndsTheGameWithTheHostsReason() {
    def s as Seat init absorb(newSeat(), proto.encodeDeny("game is full"));
    testing.assertTrue($s.finished);
    testing.assertFalse(isWaiting($s));
    testing.assertTrue(strings.contains($s.reason, "full"));
    testing.assertTrue(strings.contains($s.reason, "refused"));
}

func testDenyWithNoReasonStillExplainsItself() {
    def s as Seat init absorb(newSeat(), "DENY|");
    testing.assertTrue($s.finished);
    testing.assertTrue(len($s.reason) > 0);
}

func testByeEndsTheGame() {
    def s as Seat init absorb(welcomed(1), proto.encodeBye("host left"));
    testing.assertTrue($s.finished);
    testing.assertTrue(strings.contains($s.reason, "host left"));
}

func testByeWithNoReasonStillExplainsItself() {
    def s as Seat init absorb(welcomed(1), "BYE|");
    testing.assertTrue($s.finished);
    testing.assertTrue(len($s.reason) > 0);
}

func testReasonForFallsBackWhenTheHostSaidNothingAtAll() {
    testing.assertTrue(len(reasonFor(newSeat())) > 0);
    testing.assertTrue(strings.contains(reasonFor(newSeat()), "no answer"));
}

func testReasonForPrefersTheHostsOwnWords() {
    def s as Seat init absorb(newSeat(), proto.encodeDeny("wrong version"));
    testing.assertTrue(strings.contains(reasonFor($s), "wrong version"));
}

# --- garbage from the host ---------------------------------------------------

func testNonsenseFromTheHostChangesNothing() {
    def s as Seat init welcomed(1);
    for (def junk in ["", "|||", "NONSENSE|1", "GET / HTTP/1.1", "WELCOME"]) {
        def after as Seat init absorb($s, $junk);
        testing.assertEqual($after.id, $s.id);
        testing.assertEqual($after.frames, $s.frames);
        testing.assertFalse($after.finished);
    }
}

func testAHostCannotDriveTheGuestWithAClientMessage() {
    # JOIN, DIR, QUIT and PING are things a client says; a host saying them does
    # nothing, so a confused peer cannot unseat or rename the player.
    def s as Seat init welcomed(1);
    for (def line in [
        proto.encodeJoin("x", 24, 80),
        proto.encodeDir(1, geom.UP),
        proto.encodeQuit(1),
        proto.encodePing(1)
    ]) {
        def after as Seat init absorb($s, $line);
        testing.assertEqual($after.id, 1);
        testing.assertFalse($after.finished);
    }
}

func testAnAbsurdFieldFromTheHostIsClamped() {
    # A hostile host must not be able to make the guest allocate a huge buffer.
    def s as Seat init absorb(welcomed(1), "STATE|1|99999999|99999999||");
    testing.assertEqual($s.game.width, rules.MAX_WIDTH);
    testing.assertEqual($s.game.height, rules.MAX_HEIGHT);
}

func testAbsorbIsTotalOverEveryPrefixOfARealState() {
    def full as string init proto.encodeState(game());
    def s as Seat init welcomed(1);
    for (def n as int init 0; $n < len($full); $n = $n + 1) {
        def after as Seat init absorb($s, $full[..$n]);
        testing.assertEqual($after.id, 1);
    }
}

# --- the header note ---------------------------------------------------------

func testStatusNamesTheHostAndThePlayer() {
    def note as string init status(welcomed(4), "192.168.1.5:47475", false);
    testing.assertTrue(strings.contains($note, "192.168.1.5:47475"));
    testing.assertTrue(strings.contains($note, "4"));
}

func testStatusSaysSoWhenTheHostGoesQuiet() {
    def note as string init status(welcomed(4), "192.168.1.5:47475", true);
    testing.assertTrue(strings.contains($note, "waiting"));
}

func testStatusIsOneLine() {
    testing.assertFalse(strings.contains(status(welcomed(1), "x:1", false), "\n"));
    testing.assertFalse(strings.contains(status(welcomed(1), "x:1", true), "\n"));
}

# --- picking a host out of the menu -----------------------------------------

func testChoicePicksAListedHost() {
    testing.assertEqual(choice(key("char", "1"), 3), 1);
    testing.assertEqual(choice(key("char", "3"), 3), 3);
}

func testChoiceRefusesADigitPastTheEndOfTheList() {
    testing.assertEqual(choice(key("char", "4"), 3), 0);
    testing.assertEqual(choice(key("char", "9"), 0), 0);
}

func testChoiceRefusesAnythingThatIsNotADigit() {
    testing.assertEqual(choice(key("char", "x"), 3), 0);
    testing.assertEqual(choice(key("up", ""), 3), 0);
    testing.assertEqual(choice(key("char", "0"), 3), 0);
}

func testTheMenuChoosesAHostAndCarriesItsTransport() {
    # The transport comes from the host that answered, not from --mode: a client
    # that picked a TCP game must not then try to speak UDP at it.
    def hosts as list of beacon.Found init [
        found("alpha", "10.0.0.1:1", link.TCP),
        found("beta", "10.0.0.2:2", link.UDP)
    ];
    def act as Choice init menuKey(key("char", "2"), $hosts);
    testing.assertTrue($act.decided);
    testing.assertFalse($act.again);
    testing.assertTrue($act.target.chosen);
    testing.assertEqual($act.target.address, "10.0.0.2:2");
    testing.assertEqual($act.target.mode, link.UDP);
}

func testTheMenuPicksTheFirstHostWithOne() {
    def hosts as list of beacon.Found init [found("alpha", "10.0.0.1:1", link.TCP)];
    def act as Choice init menuKey(key("char", "1"), $hosts);
    testing.assertEqual($act.target.address, "10.0.0.1:1");
    testing.assertEqual($act.target.mode, link.TCP);
}

func testTheMenuSearchesAgainOnR() {
    def act as Choice init menuKey(key("char", "r"), []);
    testing.assertFalse($act.decided);
    testing.assertTrue($act.again);
}

func testTheMenuLeavesOnEscape() {
    # The discovery menu is a client's top level, so backing out of it leaves.
    def act as Choice init menuKey(key("escape", ""), [found("a", "x:1", link.UDP)]);
    testing.assertTrue($act.decided);
    testing.assertFalse($act.target.chosen);
}

func testTheMenuStaysOnQAndX() {
    for (def ch in ["q", "Q", "x", "X"]) {
        def act as Choice init menuKey(key("char", $ch), [found("a", "x:1", link.UDP)]);
        testing.assertFalse($act.decided);
    }
}

func testTheMenuLeavesOnCtrlC() {
    def act as Choice init menuKey(key("ctrl-c", ""), [found("a", "x:1", link.UDP)]);
    testing.assertTrue($act.decided);
    testing.assertFalse($act.target.chosen);
}

func testTheMenuIgnoresAnIrrelevantKey() {
    def act as Choice init menuKey(key("char", "z"), [found("a", "x:1", link.UDP)]);
    testing.assertFalse($act.decided);
    testing.assertFalse($act.again);
}

func testTheMenuIgnoresADigitWithNoHostsListed() {
    def act as Choice init menuKey(key("char", "1"), []);
    testing.assertFalse($act.decided);
    testing.assertFalse($act.again);
}

func testLeavingIsNotAChosenTarget() {
    testing.assertFalse(leaving().chosen);
    testing.assertEqual(leaving().address, "");
}

# --- a whole session, driven through the pure surface ----------------------

func testAGuestFollowsAWholeGameWithoutASocket() {
    # Exactly the message sequence a host sends: a welcome, then a state per tick,
    # then a goodbye. The guest must track it all and never advance it itself.
    def s as Seat init newSeat();
    $s = absorb($s, proto.encodeWelcome(2, 24, 12, 120));
    testing.assertTrue($s.joined);
    def g as rules.Game init rules.newGame(24, 12, 99);
    $g = rules.addSnake($g, 1, "host");
    $g = rules.addSnake($g, 2, "me");
    for (def t as int init 0; $t < 40; $t = $t + 1) {
        $g = rules.advance($g);
        $s = absorb($s, proto.encodeState($g));
        testing.assertEqual($s.game.tick, $g.tick);
        testing.assertFalse($s.finished);
    }
    testing.assertEqual($s.frames, 40);
    testing.assertEqual($s.id, 2);
    $s = absorb($s, proto.encodeBye("host left"));
    testing.assertTrue($s.finished);
}

func testAGuestCanDrawEveryStateItIsSent() {
    # The guest's whole job: whatever the host sends must be renderable.
    def s as Seat init welcomed(1);
    def g as rules.Game init rules.newGame(24, 12, 7);
    $g = rules.addSnake($g, 1, "me");
    for (def t as int init 0; $t < 20; $t = $t + 1) {
        $g = rules.advance($g);
        $s = absorb($s, proto.encodeState($g));
        def frame as screen.Buffer init view.render(
            $s.game,
            $s.id,
            status($s, "x:1", false),
            30,
            90);
        testing.assertEqual($frame.rows, 30);
        testing.assertEqual($frame.cols, 90);
    }
}

# --- the waiting room --------------------------------------------------------

# lobbyLine builds a LOBBY message the way a host would.
func hostLobby(width as int, height as int, tickMs as int, capacity as int) {
    return hostLobbyFor($width, $height, $tickMs, $capacity, 1);
}

# hostLobbyFor is the same, for a named round - which is what tells a client whether a
# lobby is the host moving on or a stale message that overtook a game state.
func hostLobbyFor(width as int, height as int, tickMs as int, capacity as int, round as int) {
    def seats as list of proto.Seat init [];
    $seats[] = proto.Seat{id: 1, name: "host", kind: "human", rows: 24, cols: 80};
    $seats[] = proto.Seat{id: 2, name: "ada", kind: "human", rows: 30, cols: 100};
    $seats[] = proto.Seat{id: 3, name: "cpu1-hard", kind: "computer", rows: 0, cols: 0};
    return proto.encodeLobby($width, $height, $tickMs, $capacity, $seats, $round);
}

func testANewSeatIsNotYetPlaying() {
    def s as Seat init newSeat();
    testing.assertFalse($s.playing);
    testing.assertFalse($s.lobby.seen);
    testing.assertFalse(isWaitingToStart($s));
}

func testAWelcomedSeatIsWaitingToStart() {
    def s as Seat init welcomed(2);
    testing.assertTrue(isWaitingToStart($s));
    testing.assertFalse($s.playing);
}

func testALobbyTellsTheGuestWhatWasAgreed() {
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    testing.assertTrue($s.lobby.seen);
    testing.assertEqual($s.lobby.width, 40);
    testing.assertEqual($s.lobby.height, 16);
    testing.assertEqual($s.lobby.tickMs, 150);
    testing.assertEqual($s.lobby.capacity, 6);
    testing.assertEqual(len($s.lobby.seats), 3);
    testing.assertTrue(isWaitingToStart($s));
}

func testTheFirstStateStartsTheGame() {
    # There is no "go" message, precisely so there is none to lose on UDP.
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    testing.assertFalse($s.playing);
    $s = absorb($s, proto.encodeState(game()));
    testing.assertTrue($s.playing);
    testing.assertFalse(isWaitingToStart($s));
}

func testALateLobbyDoesNotSendAPlayingGuestBackToTheLobby() {
    # On UDP a lobby snapshot from *before* this round can arrive after its first state.
    # Following it would throw the client out of a live game, so the round number settles it.
    def s as Seat init absorb(welcomed(2), proto.encodeState(rules.withRound(game(), 2)));
    testing.assertTrue($s.playing);
    testing.assertEqual($s.round, 2);
    $s = absorb($s, hostLobbyFor(40, 16, 150, 6, 1));
    testing.assertTrue($s.playing);
    testing.assertFalse(isWaitingToStart($s));
}

func testALobbyForThisRoundMeansTheHostAbandonedIt() {
    # The host backed out mid-round: it goes back to its title screen and starts publishing
    # lobbies again, with the same round number. Clients follow.
    def s as Seat init absorb(welcomed(2), proto.encodeState(rules.withRound(game(), 2)));
    testing.assertTrue($s.playing);
    $s = absorb($s, hostLobbyFor(40, 16, 150, 6, 2));
    testing.assertFalse($s.playing);
    testing.assertTrue(isWaitingToStart($s));
}

func testALobbyForALaterRoundIsAlwaysFollowed() {
    def s as Seat init absorb(welcomed(2), proto.encodeState(rules.withRound(game(), 2)));
    $s = absorb($s, hostLobbyFor(40, 16, 150, 6, 3));
    testing.assertFalse($s.playing);
    testing.assertEqual($s.round, 3);
}

func testTheRoundOnlyEverGoesUp() {
    def s as Seat init absorb(welcomed(2), proto.encodeState(rules.withRound(game(), 5)));
    testing.assertEqual($s.round, 5);
    $s = absorb($s, proto.encodeState(rules.withRound(game(), 2)));
    testing.assertEqual($s.round, 5);
}

func testALobbyBeforeTheWelcomeIsStillKept() {
    def s as Seat init absorb(newSeat(), hostLobby(40, 16, 150, 6));
    testing.assertTrue($s.lobby.seen);
    testing.assertFalse($s.joined);
}

func testTheHostCanStillEndTheGameFromTheLobby() {
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    $s = absorb($s, proto.encodeBye("host left"));
    testing.assertTrue($s.finished);
    testing.assertFalse(isWaitingToStart($s));
}

func testTheWaitingScreenSaysSoBeforeAnyLobbyArrives() {
    def lines as list of string init lobbyLines(welcomed(2));
    testing.assertEqual(len($lines), 1);
    testing.assertTrue(strings.contains($lines[0], "waiting for the host"));
}

func testTheWaitingScreenShowsTheAgreedFieldAndPace() {
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    def whole as string init strings.join(lobbyLines($s), "\n");
    testing.assertTrue(strings.contains($whole, "40 x 16"));
    testing.assertTrue(strings.contains($whole, "150 ms"));
    testing.assertTrue(strings.contains($whole, "3 of 6"));
}

func testTheWaitingScreenNamesEveryoneAtTheTable() {
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    def whole as string init strings.join(lobbyLines($s), "\n");
    testing.assertTrue(strings.contains($whole, "host"));
    testing.assertTrue(strings.contains($whole, "ada"));
    testing.assertTrue(strings.contains($whole, "cpu1-hard"));
    testing.assertTrue(strings.contains($whole, "computer"));
}

func testTheWaitingScreenMarksThePlayerAtThisTerminal() {
    def s as Seat init absorb(welcomed(2), hostLobby(40, 16, 150, 6));
    def marked as int init 0;
    for (def line in lobbyLines($s)) {
        if (strings.startsWith($line, view.YOU_MARKER)) {
            $marked = $marked + 1;
        }
    }
    testing.assertEqual($marked, 1);
    # The way out is named on screen, spelled the way it has to be pressed - a key a player
    # can only find by accident is not a key they have.
    def whole as string init strings.join(lobbyLines($s), "\n");
    testing.assertTrue(strings.contains($whole, keys.ESCAPE_LABEL));
    testing.assertTrue(strings.contains($whole, "leave"));
}

func testTheWaitingScreenSurvivesAnEmptyRoster() {
    def s as Seat init absorb(welcomed(2), proto.encodeLobby(40, 16, 150, 6, [], 1));
    def whole as string init strings.join(lobbyLines($s), "\n");
    testing.assertTrue(strings.contains($whole, "0 of 6"));
}

func testAGuestFollowsALobbyThenAWholeGame() {
    # The full sequence a host sends: welcome, lobby snapshots while it sets up, then
    # states once it starts, then a goodbye.
    def s as Seat init absorb(newSeat(), proto.encodeWelcome(2, 24, 12, 120));
    for (def i as int init 0; $i < 5; $i = $i + 1) {
        $s = absorb($s, hostLobby(40, 16, 120, 6));
        testing.assertTrue(isWaitingToStart($s));
    }
    def g as rules.Game init rules.newGame(40, 16, 99);
    $g = rules.addSnake($g, 2, "ada");
    for (def t as int init 0; $t < 20; $t = $t + 1) {
        $g = rules.advance($g);
        $s = absorb($s, proto.encodeState($g));
        testing.assertTrue($s.playing);
        testing.assertFalse(isWaitingToStart($s));
    }
    testing.assertEqual($s.game.width, 40);
    testing.assertEqual($s.frames, 20);
    $s = absorb($s, proto.encodeBye("host left"));
    testing.assertTrue($s.finished);
}

# --- spectating --------------------------------------------------------------

# spent builds the game a host would send to a player who has used every life.
func spent(id as int, lives as int) {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 5), $lives);
    $g = rules.addSnake($g, $id, "ada");
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    $g.snakes[0].lives = 0;
    return $g;
}

func testAGuestKnowsWhenItIsSpectating() {
    def s as Seat init absorb(welcomed(1), proto.encodeState(spent(1, 2)));
    testing.assertTrue(isSpectating($s));
    testing.assertTrue(strings.contains(status($s, "x:1", false), "spectating"));
}

func testAGuestWithALifeLeftIsNotSpectating() {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 5), 3);
    $g = rules.addSnake($g, 1, "ada");
    def s as Seat init absorb(welcomed(1), proto.encodeState($g));
    testing.assertFalse(isSpectating($s));
    testing.assertTrue(strings.contains(status($s, "x:1", false), "player 1"));
}

func testNobodySpectatesInAnEndlessGame() {
    def s as Seat init absorb(welcomed(1), proto.encodeState(spent(1, rules.UNLIMITED_LIVES)));
    testing.assertFalse(isSpectating($s));
}

func testAGuestNotYetInTheGameIsNotSpectating() {
    testing.assertFalse(isSpectating(newSeat()));
    testing.assertFalse(isSpectating(welcomed(1)));
}

func testAGuestWhoseIdIsNotOnTheFieldIsNotSpectating() {
    # A STATE that does not mention this player at all - after a host dropped them.
    def s as Seat init absorb(welcomed(7), proto.encodeState(spent(1, 2)));
    testing.assertFalse(isSpectating($s));
}

func testAStallSaysSoRatherThanSpectating() {
    # The more urgent thing first: nothing is arriving at all.
    def s as Seat init absorb(welcomed(1), proto.encodeState(spent(1, 2)));
    testing.assertTrue(strings.contains(status($s, "x:1", true), "waiting for host"));
}

func testASpectatingGuestStillDrawsTheGame() {
    def s as Seat init absorb(welcomed(1), proto.encodeState(spent(1, 2)));
    def frame as screen.Buffer init view.render($s.game, $s.id, status($s, "x:1", false), 30, 90);
    testing.assertEqual($frame.rows, 30);
    testing.assertEqual($frame.cols, 90);
}

# --- following the host into another round -----------------------------------

# over is a finished game: everybody out of lives.
func over(id as int) {
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 5), 1);
    $g = rules.addSnake($g, $id, "ada");
    $g.snakes[0].alive = false;
    $g.snakes[0].cells = [];
    $g.snakes[0].lives = 0;
    return $g;
}

func testAGuestFollowsTheHostBackToTheLobbyAfterARound() {
    # The host finished the round and is setting up another. The client has to follow, and
    # it works out that it should from the game it already has - no extra message to lose.
    def s as Seat init absorb(welcomed(1), proto.encodeState(over(1)));
    testing.assertTrue($s.playing);
    testing.assertTrue(rules.isOver($s.game));
    $s = absorb($s, hostLobby(40, 16, 120, 6));
    testing.assertFalse($s.playing);
    testing.assertTrue(isWaitingToStart($s));
}

func testAGuestStaysInAFinishedGameUntilTheHostMovesOn() {
    # Until a LOBBY arrives, the final field stays on screen - there is something to look
    # at while the host decides.
    def s as Seat init absorb(welcomed(1), proto.encodeState(over(1)));
    testing.assertTrue($s.playing);
    testing.assertFalse(isWaitingToStart($s));
}

func testALateLobbyStillCannotInterruptALiveGame() {
    def g as rules.Game init rules.withRound(rules.withLives(rules.newGame(20, 10, 5), 3), 4);
    $g = rules.addSnake($g, 1, "ada");
    def s as Seat init absorb(welcomed(1), proto.encodeState($g));
    testing.assertTrue($s.playing);
    $s = absorb($s, hostLobbyFor(40, 16, 120, 6, 3));
    testing.assertTrue($s.playing);
    testing.assertFalse(isWaitingToStart($s));
}

func testAnEndlessGameFollowsTheHostLikeAnyOther() {
    # An endless game has no finish of its own, but the host can still abandon the round -
    # so what decides is the round number, not whether anybody is out of lives.
    def g as rules.Game init rules.withLives(rules.newGame(20, 10, 5), rules.UNLIMITED_LIVES);
    $g = rules.addSnake($g, 1, "ada");
    $g = rules.withRound($g, 3);
    def s as Seat init absorb(welcomed(1), proto.encodeState($g));
    testing.assertTrue($s.playing);
    # Stale: from before this round.
    $s = absorb($s, hostLobbyFor(40, 16, 120, 6, 2));
    testing.assertTrue($s.playing);
    # Current: the host has gone back to its title screen.
    $s = absorb($s, hostLobbyFor(40, 16, 120, 6, 3));
    testing.assertFalse($s.playing);
    testing.assertTrue(isWaitingToStart($s));
}

func testAGuestPlaysARoundThenAnother() {
    def s as Seat init absorb(newSeat(), proto.encodeWelcome(1, 20, 10, 120));
    for (def round as int init 0; $round < 3; $round = $round + 1) {
        $s = absorb($s, hostLobby(40, 16, 120, 6));
        testing.assertTrue(isWaitingToStart($s));
        def g as rules.Game init rules.withLives(rules.newGame(40, 16, 7), 1);
        $g = rules.addSnake($g, 1, "ada");
        $s = absorb($s, proto.encodeState($g));
        testing.assertTrue($s.playing);
        $s = absorb($s, proto.encodeState(over(1)));
        testing.assertTrue(rules.isOver($s.game));
    }
    testing.assertEqual($s.id, 1);
    testing.assertFalse($s.finished);
}
