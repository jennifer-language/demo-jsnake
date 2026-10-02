# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * Joining someone else's game: the client side.
 *
 * A guest owns no rules at all. It sends the host a direction when a key is
 * pressed, and it draws whatever `STATE` the host last sent. That is the whole
 * of it, and it is deliberate: with one authority there is nothing to reconcile,
 * so two players never see different games.
 *
 * Split the same way `host` is. `absorb` is **pure** - it folds one inbound line
 * into a `Seat` and decides nothing else - so every message the host can send,
 * including the malformed ones, is exercised by a test with no socket. Only
 * `run` touches the terminal and the network.
 *
 * **A lost `WELCOME` is retried, not fatal.** On UDP the join handshake can lose
 * either half, so the guest re-sends `JOIN` every `JOIN_RETRY_MS` until it is
 * admitted or gives up. The host answers a repeated `JOIN` from a seated peer
 * with the same `WELCOME`, so a retry costs a datagram and nothing else.
 *
 * **The guest keeps talking even when the player does not.** A player thinking
 * about their next move sends nothing, and a UDP host has no socket to watch, so
 * a `PING` goes out every `PING_MS` to keep the seat.
 * @module guest
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./guest.j" as guest;
 * def code as int init guest.run(guest.defaults());
 */

use io;
use os;
use time;
use term;

import "screen.j" as screen;
import "./keys.j" as keys;
import "./rules.j" as rules;
import "./proto.j" as proto;
import "./link.j" as link;
import "./beacon.j" as beacon;
import "./view.j" as view;

/**
 * How often an unanswered `JOIN` is sent again, in milliseconds.
 */
export def const JOIN_RETRY_MS as int init 250;

/**
 * How long to keep asking to join before giving up, in milliseconds.
 */
export def const JOIN_TIMEOUT_MS as int init 4000;

/**
 * How often a keepalive goes out while playing, in milliseconds. Comfortably
 * inside the host's idle allowance even if several are lost in a row.
 */
export def const PING_MS as int init 1000;

/**
 * How long the loop sleeps between passes, in milliseconds.
 */
export def const IDLE_SLEEP_MS as int init 4;

/**
 * How long to allow a TCP dial before calling the host unreachable, in
 * milliseconds.
 */
export def const DIAL_MS as int init 2000;

/**
 * How long a client waits without a `STATE` before it says the host has gone
 * quiet, in milliseconds. A note in the header, not a disconnection: a brief
 * stall on a busy network is not a reason to leave the game.
 */
export def const STALL_MS as int init 2000;

/**
 * The heading on the waiting screen, while the host sets the game up.
 */
export def const WAITING as string init "jsnake - in the lobby";

/**
 * The name a guest plays under when the player gave none.
 */
export def const DEFAULT_NAME as string init "guest";

/**
 * Everything a guest knows. The `game` is the host's last word, not the guest's
 * own simulation - the guest never advances it.
 * @field id {int} this player's id, or 0 before the host has admitted them
 * @field tickMs {int} the host's tick period, as announced
 * @field joined {bool} whether the host has sent a `WELCOME`
 * @field finished {bool} whether the game is over for this guest
 * @field reason {string} why it finished, for the closing message
 * @field game {rules.Game} the last state the host sent
 * @field frames {int} how many `STATE` messages have arrived
 * @field playing {bool} whether the game has started; false while in the lobby
 * @field lobby {Lobby} the host's last waiting-room snapshot
 * @field round {int} the highest round this client has heard about
 */
export def struct Seat {
    id as int,
    tickMs as int,
    joined as bool,
    finished as bool,
    reason as string,
    game as rules.Game,
    frames as int,
    playing as bool,
    lobby as Lobby,
    round as int
};

/**
 * The host's waiting room as the guest last heard it: the field everyone has agreed
 * on, the pace, and who else is at the table.
 * @field width {int} the agreed field width
 * @field height {int} the agreed field height
 * @field tickMs {int} the host's chosen tick period
 * @field capacity {int} how many players the host will seat
 * @field seats {list of proto.Seat} who is waiting
 * @field seen {bool} whether a `LOBBY` has arrived at all
 * @field round {int} the round this lobby is setting up
 */
export def struct Lobby {
    width as int,
    height as int,
    tickMs as int,
    capacity as int,
    seats as list of proto.Seat,
    seen as bool,
    round as int
};

/**
 * How a guest was asked to run.
 * @field mode {string} the transport to use; ignored when a host is discovered
 * @field address {string} the host's `"host:port"`, or "" to go looking for one
 * @field name {string} the player's display name
 * @field discoverMs {int} how long to listen for hosts when discovering
 */
export def struct Options {
    mode as string,
    address as string,
    name as string,
    discoverMs as int
};

/**
 * The options a guest runs with when nothing was asked for: find a game on this
 * network and join it.
 * @return {Options} the default options
 */
export func defaults() {
    return Options{mode: link.UDP, address: "", name: DEFAULT_NAME, discoverMs: beacon.DISCOVER_MS};
}

/**
 * A seat that has not joined anything yet.
 * @return {Seat} the empty seat
 */
export func newSeat() {
    return Seat{
        id: 0,
        tickMs: 0,
        joined: false,
        finished: false,
        reason: "",
        game: rules.newGame(rules.MIN_WIDTH, rules.MIN_HEIGHT, 1),
        frames: 0,
        playing: false,
        round: 0,
        lobby: Lobby{
            width: 0,
            height: 0,
            tickMs: 0,
            capacity: 0,
            seats: [],
            seen: false,
            round: 0
        }
    };
}

/**
 * Fold one line from the host into the seat. Pure and total: a message the guest
 * does not understand, or one that arrives out of order, leaves the seat alone.
 *
 * `WELCOME` is accepted only once. A second one - a duplicate answer to a retried
 * `JOIN` - is ignored rather than reassigning the player's id mid-game, which
 * would make them lose track of their own snake.
 * @param s {Seat} the current seat
 * @param line {string} one line from the host
 * @return {Seat} the seat after the message
 */
export func absorb(s as Seat, line as string) {
    def m as proto.Message init proto.decode($line);
    match ($m.kind) {
        when proto.WELCOME { return onWelcome($s, $m); }
        when proto.LOBBY { return onLobby($s, $m); }
        when proto.STATE { return onState($s, $m); }
        when proto.DENY { return finish($s, refusal($m.text)); }
        when proto.BYE { return finish($s, hostSaid($m.text)); }
        else { return $s; }
    }
}

# onWelcome admits the player, once. A malformed WELCOME - no id - is not an
# admission, so the guest keeps asking rather than playing as nobody.
func onWelcome(s as Seat, m as proto.Message) {
    if ($s.joined or $m.id <= 0) {
        return $s;
    }
    def out as Seat init $s;
    $out.id = $m.id;
    $out.tickMs = $m.tickMs;
    $out.joined = true;
    return $out;
}

# onLobby records the waiting room, and follows the host out of a game when it is setting
# up the next one.
#
# The round number is what tells those two cases apart. A lobby for the round this client
# is already playing, or a later one, is the host moving on - whether the round ended on
# its own or the host pressed Escape to abandon it. A lobby for an *earlier* round is a stale
# message that overtook a game state on UDP, and following it would throw the client out of
# a live game. Comparing numbers needs nothing to be delivered reliably, which is the whole
# reason it is done this way rather than with a "round over" message.
func onLobby(s as Seat, m as proto.Message) {
    if ($s.playing and $m.round < $s.round) {
        return $s;
    }
    def out as Seat init $s;
    $out.playing = false;
    if ($m.round > $out.round) {
        $out.round = $m.round;
    }
    $out.lobby = Lobby{
        width: $m.width,
        height: $m.height,
        tickMs: $m.tickMs,
        capacity: $m.capacity,
        seats: $m.seats,
        seen: true,
        round: $m.round
    };
    return $out;
}

# onState replaces the picture on screen, and is what tells the client the game has
# started - there is no separate "go" message, precisely so there is none to lose on
# UDP. A STATE arriving before the WELCOME is kept: on UDP the two can cross, and
# drawing the field a moment early is better than drawing nothing.
func onState(s as Seat, m as proto.Message) {
    def out as Seat init $s;
    $out.game = $m.game;
    $out.frames = $out.frames + 1;
    $out.playing = true;
    if ($m.game.round > $out.round) {
        $out.round = $m.game.round;
    }
    return $out;
}

# finish ends the guest's game with a reason to show the player.
func finish(s as Seat, reason as string) {
    def out as Seat init $s;
    $out.finished = true;
    $out.reason = $reason;
    return $out;
}

# refusal / hostSaid put a human sentence around a bare reason string, which may
# be empty if the host did not give one.
func refusal(reason as string) {
    if (len($reason) == 0) {
        return "the host refused the join";
    }
    return "the host refused the join: " + $reason;
}

func hostSaid(reason as string) {
    if (len($reason) == 0) {
        return "the host ended the game";
    }
    return "the host ended the game: " + $reason;
}

/**
 * Whether the guest has joined but the host has not started yet - the state in which
 * the waiting screen is shown.
 * @param s {Seat} the seat
 * @return {bool} true while in the host's lobby
 */
export func isWaitingToStart(s as Seat) {
    return $s.joined and not $s.playing and not $s.finished;
}

/**
 * The waiting screen's body: the field everyone has agreed on, the pace, and who else
 * is here. Pure, so what a player reads while waiting is settled by a test.
 * @param s {Seat} the seat, carrying the host's last lobby snapshot
 * @return {list of string} the lines to draw
 */
export func lobbyLines(s as Seat) {
    def out as list of string init [];
    if (not $s.lobby.seen) {
        $out[] = "joined - waiting for the host";
        return $out;
    }
    $out[] = io.sprintf(
        "field %d x %d at %d ms per move",
        $s.lobby.width,
        $s.lobby.height,
        $s.lobby.tickMs);
    $out[] = "";
    $out[] = io.sprintf("players %d of %d", len($s.lobby.seats), $s.lobby.capacity);
    for (def seat in $s.lobby.seats) {
        $out[] = seatLine($seat, $s.id);
    }
    $out[] = "";
    $out[] = "waiting for the host to start   " + keys.ESCAPE_LABEL + "  leave";
    return $out;
}

# seatLine names one player in the waiting room, marking the one at this terminal.
func seatLine(seat as proto.Seat, me as int) {
    def marker as string init " ";
    if ($seat.id == $me) {
        $marker = view.YOU_MARKER;
    }
    return io.sprintf("%s %s|pad=14 %s", $marker, $seat.name, $seat.kind);
}

/**
 * Whether the guest is still waiting to be told its own id.
 * @param s {Seat} the seat
 * @return {bool} true while the handshake is unfinished
 */
export func isWaiting(s as Seat) {
    return not $s.joined and not $s.finished;
}

/**
 * The header note for a playing guest: its name for the game and whether the
 * host is still sending.
 * @param s {Seat} the seat
 * @param address {string} the host's address
 * @param stalled {bool} whether nothing has arrived for a while
 * @return {string} a short status note
 */
export func status(s as Seat, address as string, stalled as bool) {
    if ($stalled) {
        return io.sprintf("%s  waiting for host...", $address);
    }
    if (isSpectating($s)) {
        return io.sprintf("%s  spectating - out of lives", $address);
    }
    return io.sprintf("%s  player %d", $address, $s.id);
}

/**
 * Whether this player has spent every life and is now watching. Read from the game the
 * host last sent, which carries both the lives setting and what each snake has left.
 * @param s {Seat} the seat
 * @return {bool} true when the player is a spectator
 */
export func isSpectating(s as Seat) {
    if (not $s.joined or not rules.hasSnake($s.game, $s.id)) {
        return false;
    }
    return rules.isSpectator($s.game, rules.snakeById($s.game, $s.id));
}

/**
 * Which host in a discovery list a keypress chose: a 1-based index, or `0` for no
 * choice. Pure, so the menu's arithmetic is pinned down by a test rather than
 * discovered by pressing `9` with two hosts listed.
 * @param k {screen.Key} the key pressed
 * @param count {int} how many hosts are listed
 * @return {int} the 1-based choice, or 0
 */
export func choice(k as screen.Key, count as int) {
    def d as int init keys.digitValue($k);
    if ($d >= 1 and $d <= $count) {
        return $d;
    }
    return 0;
}

/**
 * Run a guest: find a game or connect to the one named, play it, and leave
 * tidily. The only impure function here.
 * @param opts {Options} how to run
 * @return {int} a process exit code: 0 for a clean game, 1 when it could not join
 */
export func run(opts as Options) {
    if (not os.isTerminal("stdout")) {
        io.eprintf("jsnake: playing needs a terminal; stdout is not one\n");
        return 2;
    }
    def state as term.State init screen.begin();
    defer screen.end($state);
    def input as screen.Input init screen.startInput();
    def target as Target init pick($opts, $input);
    if (not $target.chosen) {
        return $target.code;
    }
    return play($opts, $target, $input);
}

# Where the guest decided to connect, and what to do when it decided not to.
def struct Target {
    address as string,
    mode as string,
    chosen as bool,
    code as int
};

# pick settles on a host: the one the player named, or one chosen from the menu.
func pick(opts as Options, input as screen.Input) {
    if (len($opts.address) > 0) {
        return Target{address: $opts.address, mode: $opts.mode, chosen: true, code: 0};
    }
    return browse($opts, $input);
}

# browse shows discovered hosts and waits for the player to choose one, search
# again, or leave. The search itself blocks for its window, so the menu is drawn
# first and the answer collected after - a player always sees why they are
# waiting.
func browse(opts as Options, input as screen.Input) {
    def searching as bool init true;
    while ($searching) {
        show("looking for games", ["searching this network..."]);
        def hosts as list of beacon.Found init beacon.discover($opts.discoverMs);
        show("games on this network", menu($hosts));
        def waiting as bool init true;
        while ($waiting) {
            def act as Choice init menuKey(screen.waitKey($input), $hosts);
            if ($act.decided) {
                return $act.target;
            }
            $waiting = not $act.again;
        }
    }
    return leaving();
}

# What the player did at the discovery menu: chose a host, asked to search again,
# or pressed something that means nothing here. Pure, so the menu's arithmetic is
# settled by a test rather than by pressing keys at it.
def struct Choice {
    target as Target,
    decided as bool,
    again as bool
};

func menuKey(k as screen.Key, hosts as list of beacon.Found) {
    # The discovery menu is a client's top level - there is nothing behind it - so backing
    # out of it leaves, the same as it does on a host's title screen.
    if (keys.isBack($k) or keys.isAbort($k)) {
        return Choice{target: leaving(), decided: true, again: false};
    }
    if (keys.isRefresh($k)) {
        return Choice{target: leaving(), decided: false, again: true};
    }
    def n as int init choice($k, len($hosts));
    if ($n == 0) {
        return Choice{target: leaving(), decided: false, again: false};
    }
    def host as beacon.Found init $hosts[$n - 1];
    return Choice{
        target: Target{address: $host.address, mode: $host.mode, chosen: true, code: 0},
        decided: true,
        again: false
    };
}

# leaving is the target that means "the player does not want to play after all".
func leaving() {
    return Target{address: "", mode: "", chosen: false, code: 0};
}

# menu is the discovery list as body lines for `show`.
func menu(hosts as list of beacon.Found) {
    def entries as list of string init [];
    for (def h in $hosts) {
        $entries[] = beacon.describe($h);
    }
    return view.menuLines($entries);
}

# play connects, joins, and runs the game until it ends.
func play(opts as Options, target as Target, input as screen.Input) {
    show("joining", [$target.address]);
    def wire as link.Client init connect($target);
    if (not $wire.open) {
        show("cannot reach that host", [$target.address, "", "any key to leave"]);
        screen.waitKey($input);
        return 1;
    }
    defer link.hangUp($wire);
    def seat as Seat init newSeat();
    def joined as Handshake init shake($wire, $seat, $opts.name, $input);
    $wire = $joined.wire;
    $seat = $joined.seat;
    if (not $seat.joined) {
        show("could not join", [reasonFor($seat), "", "any key to leave"]);
        screen.waitKey($input);
        return 1;
    }
    return session($wire, $seat, $target.address, $input);
}

# connect dials the host, turning a refused connection into a closed client
# rather than a thrown error - the caller has a nicer way to say it.
func connect(target as Target) {
    try {
        return link.dial($target.mode, $target.address, DIAL_MS);
    } catch (e) {
        return link.closedClient($target.mode, $target.address);
    }
}

# A handshake's two halves, threaded back out together.
def struct Handshake {
    wire as link.Client,
    seat as Seat
};

# shake sends JOIN until the host answers or the attempt times out, staying
# responsive to the quit key throughout - a player must never be stuck watching a
# handshake they cannot abandon.
func shake(start as link.Client, seat as Seat, name as string, input as screen.Input) {
    def wire as link.Client init $start;
    def out as Seat init $seat;
    # The host sizes the field to the smallest terminal at the table, so the join
    # carries this one. Re-read each attempt: the window may have been resized between
    # retries, and the last word should be the true one.
    def deadline as int init nowMs() + JOIN_TIMEOUT_MS;
    def nextTry as int init 0;
    while (isWaiting($out) and nowMs() < $deadline and $wire.open) {
        if (nowMs() >= $nextTry) {
            $nextTry = nowMs() + JOIN_RETRY_MS;
            def size as term.Size init screenSize();
            $wire = link.tell($wire, proto.encodeJoin($name, $size.rows, $size.cols));
        }
        def inbox as link.Inbox init link.listenFor($wire);
        $wire = $inbox.client;
        for (def line in $inbox.lines) {
            $out = absorb($out, $line);
        }
        if (drainedQuit($input)) {
            return Handshake{wire: $wire, seat: $out};
        }
        time.sleep(time.fromMilliseconds(IDLE_SLEEP_MS));
    }
    return Handshake{wire: $wire, seat: $out};
}

# drainedQuit reports whether the player asked to leave, discarding anything else
# they pressed while waiting.
func drainedQuit(input as screen.Input) {
    while (screen.hasKey($input)) {
        def k as screen.Key init screen.pollKey($input);
        if (keys.isBack($k) or keys.isAbort($k)) {
            return true;
        }
    }
    return false;
}

# reasonFor explains a failed handshake: the host's own words when it gave any.
func reasonFor(s as Seat) {
    if (len($s.reason) > 0) {
        return $s.reason;
    }
    return "no answer from the host";
}

# session is the guest's main pass: keys out, state in, draw, keepalive.
func session(start as link.Client, seat as Seat, address as string, input as screen.Input) {
    def wire as link.Client init $start;
    def out as Seat init $seat;
    def frame as screen.Buffer init screen.newScreen(1, 1);
    def nextPing as int init nowMs() + PING_MS;
    def lastState as int init nowMs();
    def playing as bool init true;
    while ($playing) {
        def quit as bool init false;
        while (screen.hasKey($input)) {
            def k as screen.Key init screen.pollKey($input);
            if (keys.isBack($k) or keys.isAbort($k)) {
                # A client has no screen of its own behind the game, so backing out of it
                # means leaving. The same Escape on a host goes to its title screen instead,
                # which is the one asymmetry left - and it is the one players expect, since
                # only the host has a screen to go back to.
                $quit = true;
            }
            def dir as string init keys.directionOf($k);
            if (len($dir) > 0) {
                $wire = link.tell($wire, proto.encodeDir($out.id, $dir));
            }
        }
        if ($quit) {
            link.tell($wire, proto.encodeQuit($out.id));
            return 0;
        }
        def inbox as link.Inbox init link.listenFor($wire);
        $wire = $inbox.client;
        for (def line in $inbox.lines) {
            $out = absorb($out, $line);
            $lastState = nowMs();
        }
        if ($out.finished or not $wire.open) {
            show("game over", [reasonFor($out), "", "any key to leave"]);
            screen.waitKey($input);
            return 0;
        }
        if (nowMs() >= $nextPing) {
            $nextPing = nowMs() + PING_MS;
            $wire = link.tell($wire, proto.encodePing($out.id));
        }
        if (isWaitingToStart($out)) {
            $frame = waitingFrame($frame, $out);
        } else {
            $frame = draw($frame, $out, $address, nowMs() - $lastState > STALL_MS);
        }
        time.sleep(time.fromMilliseconds(IDLE_SLEEP_MS));
    }
    return 0;
}

# waitingFrame draws the host's waiting room, writing only what changed - so a roster
# filling up does not flicker.
func waitingFrame(previous as screen.Buffer, s as Seat) {
    def size as term.Size init screenSize();
    def frame as screen.Buffer init view.message(WAITING, lobbyLines($s), $size.rows, $size.cols);
    io.printf("%s", screen.diff($previous, $frame));
    return $frame;
}

# draw paints the next frame, writing only the cells that changed.
func draw(previous as screen.Buffer, s as Seat, address as string, stalled as bool) {
    def size as term.Size init screenSize();
    def frame as screen.Buffer init view.renderWith(
        $s.game,
        $s.id,
        status($s, $address, $stalled),
        $size.rows,
        $size.cols,
        view.GUEST_KEYS);
    io.printf("%s", screen.diff($previous, $frame));
    return $frame;
}

# show paints a whole message screen, sized to the terminal as it is right now -
# the window can have been resized since the last one.
func show(title as string, lines as list of string) {
    def size as term.Size init screenSize();
    def buf as screen.Buffer init view.message($title, $lines, $size.rows, $size.cols);
    io.printf("%s%s", screen.clear(), screen.render($buf));
    return;
}

# screenSize is the terminal as it is right now, or a conventional one when there is no
# usable answer: `term.size` throws off a terminal and reports zero on a pty with no
# window size. A guest refuses to start off a terminal, so this is belt and braces - but
# a frame drawn to a size that threw would be no frame at all.
func screenSize() {
    try {
        def size as term.Size init screen.size();
        if ($size.rows > 0 and $size.cols > 0) {
            return $size;
        }
    } catch (e) {
        return term.Size{rows: view.FALLBACK_ROWS, cols: view.FALLBACK_COLS};
    }
    return term.Size{rows: view.FALLBACK_ROWS, cols: view.FALLBACK_COLS};
}

# nowMs is the wall clock in milliseconds.
func nowMs() {
    return time.unixMillis(time.now());
}
