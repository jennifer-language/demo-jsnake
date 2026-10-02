# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * Hosting a game: the authoritative side.
 *
 * The host owns the one real `rules.Game`. Clients send it steering and it sends
 * them the whole state every tick; it never trusts a client for anything else.
 *
 * The module is deliberately split in two. Everything that *decides* something -
 * who is seated, what an inbound message does, who has gone quiet - is pure, in
 * `handle` and `sweep`, over a `Table` value. Only `run` touches the terminal,
 * the clock, and the sockets, and it contains no rules at all. That is what makes
 * a host's behaviour testable: the tests below seat players, steer them, drop
 * them, and fill the game up without opening a socket.
 *
 * **A client's identity is the peer it speaks from, never the id it claims.** A
 * `DIR` message carries a player id, and the host ignores it in favour of the id
 * seated at that peer. Otherwise anyone who could reach the port could steer
 * somebody else's snake, which on a LAN game is the difference between a prank
 * and a protocol.
 *
 * **Joining is idempotent.** On UDP a `WELCOME` can be lost, and the client will
 * ask again. A second `JOIN` from a seated peer is answered with the same
 * `WELCOME` rather than seating a second snake for one player.
 * @module host
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./host.j" as host;
 * def code as int init host.run(host.defaults());
 */

use io;
use os;
use time;
use term;
use maps;
use strings;

import "screen.j" as screen;
import "./geom.j" as geom;
import "./keys.j" as keys;
import "./bot.j" as bot;
import "./rules.j" as rules;
import "./proto.j" as proto;
import "./link.j" as link;
import "./beacon.j" as beacon;
import "./view.j" as view;

/**
 * How many players a host accepts unless told otherwise: as many as the game
 * allows, since a host that wants fewer says so.
 */
export def const DEFAULT_CAPACITY as int init rules.MAX_PLAYERS;

/**
 * A seat driven by a person, at a keyboard somewhere.
 */
export def const HUMAN as string init "human";

/**
 * A seat driven by `bot` - a computer player.
 */
export def const COMPUTER as string init "computer";

/**
 * The disconnect policy where a player who drops out loses their game: the seat
 * is freed and the snake leaves the field.
 */
export def const FORFEIT as string init "forfeit";

/**
 * The disconnect policy where a computer player takes the abandoned snake over,
 * keeping its score and its body. The field stays as full as it was, which is what
 * a room full of players usually wants when somebody's wifi drops.
 */
export def const TAKEOVER as string init "takeover";

/**
 * Both disconnect policies, for validating a flag and listing it in help text.
 */
export def const LEAVE_POLICIES as list of string init [FORFEIT, TAKEOVER];

/**
 * What happens to a dropped player unless the host says otherwise.
 */
export def const DEFAULT_ON_LEAVE as string init FORFEIT;

/**
 * The suffix added to a human's name when a computer player takes their snake
 * over, so the scoreboard shows at a glance that nobody is driving it.
 */
export def const TAKEOVER_SUFFIX as string init "-cpu";

/**
 * The tick period in milliseconds: how long a snake takes to move one cell.
 * About eight moves a second, which is the pace an arcade snake is played at.
 */
export def const DEFAULT_TICK_MS as int init 125;

/**
 * The shortest tick a host will accept. Below this the game is unplayable and a
 * host would spend its time sending rather than simulating.
 */
export def const MIN_TICK_MS as int init 40;

/**
 * The longest tick a host will accept.
 */
export def const MAX_TICK_MS as int init 1000;

/**
 * How many ticks of silence before a player is assumed gone. On TCP a departure
 * is usually noticed at once by the socket closing; on UDP there is nothing to
 * close, so this is the only thing that reclaims a seat.
 */
export def const IDLE_TICKS as int init 80;

/**
 * How long the loop sleeps between passes, in milliseconds. Short enough that a
 * keypress is acted on within a frame, long enough that an idle host is not a
 * busy loop.
 */
export def const IDLE_SLEEP_MS as int init 4;

/**
 * The name a host shows when the player gave none.
 */
export def const DEFAULT_NAME as string init "jsnake";

/**
 * One connected player. The snake itself lives in the game; this is the seat.
 * @field id {int} the player id, matching the snake's id in the game
 * @field peer {string} the transport peer to answer, empty for the local player
 * @field name {string} the player's scrubbed display name
 * @field lastSeen {int} the tick this player was last heard from
 * @field local {bool} whether this is the player sitting at the host's keyboard
 * @field kind {string} `HUMAN` or `COMPUTER` - who is driving
 * @field level {string} a computer player's difficulty; empty for a human
 * @field seed {int} a computer player's own random state, advanced every tick
 * @field rows {int} the terminal rows this player reported; 0 when they did not say
 * @field cols {int} the terminal columns this player reported; 0 when they did not say
 */
export def struct Player {
    id as int,
    peer as string,
    name as string,
    lastSeen as int,
    local as bool,
    kind as string,
    level as string,
    seed as int,
    rows as int,
    cols as int
};

/**
 * Everything a host decides with: the game, the seats, and the limits. Pure
 * value, so `handle` and `sweep` can be driven straight from a test.
 * @field game {rules.Game} the authoritative game state
 * @field players {list of Player} the seats, in join order
 * @field capacity {int} how many players may be seated at once
 * @field tickMs {int} the tick period announced to clients
 */
export def struct Table {
    game as rules.Game,
    players as list of Player,
    capacity as int,
    tickMs as int
};

/**
 * What handling one message, or one sweep, comes to: the new table, the messages
 * to send, and the peers to forget. The host's I/O layer does exactly what this
 * says and decides nothing itself.
 * @field table {Table} the table after the message
 * @field replies {list of link.Packet} messages to send, each to its own peer
 * @field dropped {list of string} peers to forget at the transport layer
 */
export def struct Reaction {
    table as Table,
    replies as list of link.Packet,
    dropped as list of string
};

/**
 * How a host was asked to run.
 * @field mode {string} the transport, `link.TCP` or `link.UDP`
 * @field port {int} the game port to bind, or 0 for any free port
 * @field name {string} the host's display name, shown to clients discovering it
 * @field width {int} the field width in cells
 * @field height {int} the field height in cells
 * @field tickMs {int} the tick period in milliseconds
 * @field capacity {int} how many players to accept
 * @field seed {int} the game's random seed; 0 asks for one from the clock
 * @field play {bool} whether the host also plays at its own keyboard
 * @field discoverable {bool} whether to answer discovery broadcasts
 * @field bots {int} how many computer players to seat at the start
 * @field botLevel {string} the difficulty those computer players play at
 * @field onLeave {string} what happens to a dropped player: `FORFEIT` or `TAKEOVER`
 * @field specials {bool} whether special food appears; false is the classic game
 * @field lobby {bool} whether to show the title screen before starting
 * @field lives {int} lives each player gets, or `rules.UNLIMITED_LIVES` for an endless game
 * @field wrap {bool} whether the field's edges join up instead of being walls
 */
export def struct Options {
    mode as string,
    port as int,
    name as string,
    width as int,
    height as int,
    tickMs as int,
    capacity as int,
    seed as int,
    play as bool,
    discoverable as bool,
    bots as int,
    botLevel as string,
    onLeave as string,
    specials as bool,
    lobby as bool,
    lives as int,
    wrap as bool
};

/**
 * The options a host runs with when nothing was asked for: a UDP game on the
 * default port, discoverable, with the host playing.
 * @return {Options} the default options
 */
export func defaults() {
    return Options{
        mode: link.UDP,
        port: link.DEFAULT_PORT,
        name: DEFAULT_NAME,
        width: rules.MAX_WIDTH,
        height: rules.MAX_HEIGHT,
        tickMs: DEFAULT_TICK_MS,
        capacity: DEFAULT_CAPACITY,
        seed: 0,
        play: true,
        discoverable: true,
        bots: 0,
        botLevel: bot.DEFAULT_LEVEL,
        onLeave: DEFAULT_ON_LEAVE,
        specials: true,
        lobby: true,
        lives: rules.DEFAULT_LIVES,
        wrap: false
    };
}

/**
 * Whether `policy` names a disconnect policy this module implements.
 * @param policy {string} the candidate policy name
 * @return {bool} true for `FORFEIT` or `TAKEOVER`
 */
export func isLeavePolicy(policy as string) {
    return $policy == FORFEIT or $policy == TAKEOVER;
}

/**
 * The policy `policy` names, falling back to `DEFAULT_ON_LEAVE` for anything
 * else - so a typo on the command line cannot leave the host with no policy at
 * the moment a player drops.
 * @param policy {string} the requested policy name
 * @return {string} a policy from `LEAVE_POLICIES`
 */
export func leavePolicyOr(policy as string) {
    if (isLeavePolicy($policy)) {
        return $policy;
    }
    return DEFAULT_ON_LEAVE;
}

/**
 * A fresh table. The tick period is clamped into the playable range rather than
 * refused, so `--tick 1` yields the fastest sensible game instead of an error.
 * @param width {int} the field width in cells
 * @param height {int} the field height in cells
 * @param seed {int} the game's random seed
 * @param capacity {int} how many players may be seated
 * @param tickMs {int} the requested tick period in milliseconds
 * @return {Table} the empty table
 */
export func newTable(width as int, height as int, seed as int, capacity as int, tickMs as int) {
    return Table{
        game: rules.newGame($width, $height, $seed),
        players: [],
        capacity: clamp($capacity, 1, rules.MAX_PLAYERS),
        tickMs: clamp($tickMs, MIN_TICK_MS, MAX_TICK_MS)
    };
}

# clamp holds v inside [lo, hi]; atLeast is its one-sided form.
func clamp(v as int, lo as int, hi as int) {
    if ($v < $lo) {
        return $lo;
    }
    if ($v > $hi) {
        return $hi;
    }
    return $v;
}

/**
 * The index of the seat at `peer`, or `-1`. The local player's empty peer never
 * matches, so a message from a peer that somehow arrived with an empty address
 * cannot be taken for the host's own keyboard.
 * @param t {Table} the table to search
 * @param peer {string} the transport peer
 * @return {int} the index into `t.players`, or -1
 */
export func seatOf(t as Table, peer as string) {
    if (len($peer) == 0) {
        return -1;
    }
    for (def i as int init 0; $i < len($t.players); $i = $i + 1) {
        if ($t.players[$i].peer == $peer) {
            return $i;
        }
    }
    return -1;
}

/**
 * The player id seated at `peer`, or `0` when nobody is.
 * @param t {Table} the table to search
 * @param peer {string} the transport peer
 * @return {int} the player id, or 0
 */
export func idAt(t as Table, peer as string) {
    def i as int init seatOf($t, $peer);
    if ($i < 0) {
        return 0;
    }
    return $t.players[$i].id;
}

/**
 * The index of the seat holding player `id`, or `-1`.
 * @param t {Table} the table to search
 * @param id {int} the player id
 * @return {int} the index into `t.players`, or -1
 */
export func indexOfId(t as Table, id as int) {
    for (def i as int init 0; $i < len($t.players); $i = $i + 1) {
        if ($t.players[$i].id == $id) {
            return $i;
        }
    }
    return -1;
}

/**
 * The id of the player at the host's own keyboard, or `0` when the host is only
 * refereeing.
 * @param t {Table} the table to inspect
 * @return {int} the local player's id, or 0
 */
export func localId(t as Table) {
    for (def p in $t.players) {
        if ($p.local) {
            return $p.id;
        }
    }
    return 0;
}

/**
 * Whether every seat is taken.
 * @param t {Table} the table to inspect
 * @return {bool} true when no more players may be seated
 */
export func isFull(t as Table) {
    return len($t.players) >= $t.capacity;
}

/**
 * Seat the player at the host's keyboard, who reports the terminal they are sitting
 * at so the field can be sized to it like anyone else's. Returns the table unchanged
 * when the game is full or somebody is already seated locally.
 * @param t {Table} the table to seat into
 * @param name {string} the local player's name
 * @param rows {int} the host's terminal rows
 * @param cols {int} the host's terminal columns
 * @return {Table} the table with the local player seated
 */
export func seatLocal(t as Table, name as string, rows as int, cols as int) {
    if (isFull($t) or localId($t) != 0) {
        return $t;
    }
    return seatWith($t, "", $name, true, HUMAN, "", 0, $rows, $cols);
}

/**
 * Seat one computer player at difficulty `level`. Returns the table unchanged when
 * the game is full, so a caller can ask for more bots than there are seats and get
 * as many as fit.
 * @param t {Table} the table to seat into
 * @param level {string} the difficulty, one of `bot.LEVELS`
 * @return {Table} the table with one more computer player
 */
export func seatBot(t as Table, level as string) {
    if (isFull($t)) {
        return $t;
    }
    def skill as string init bot.levelOr($level);
    return seat(
        $t,
        "",
        bot.nameFor($skill, botCount($t) + 1),
        false,
        COMPUTER,
        $skill,
        botSeed($t));
}

/**
 * How many computer players this table has room for: every seat the people are not using.
 *
 * The host's own seat counts as a person's when it is playing, which is why `--players 8`
 * with `--bots 8` yields seven computers and not eight - there are only seven seats left.
 * @param t {Table} the table
 * @return {int} the number of computer players that would fit, never negative
 */
export func maxBots(t as Table) {
    def spare as int init $t.capacity - humanCount($t);
    if ($spare < 0) {
        return 0;
    }
    return $spare;
}

/**
 * The setup with its computer-player count held down to what the table can actually seat.
 *
 * Without this the title screen will happily read `computer players 8` on an eight-seat
 * table where the host is playing, while only seven are ever seated - the number says one
 * thing and the roster below it says another. Clamping here means the row can only ever
 * show a number that comes true.
 *
 * It is applied against the live table rather than fixed at setup time because the ceiling
 * moves: every person who joins lowers it, and everyone who leaves raises it again.
 * @param s {Setup} the setup as the host left it
 * @param t {Table} the table it is being applied to
 * @return {Setup} the setup, with `bots` no higher than `maxBots`
 */
export func fitBots(s as Setup, t as Table) {
    def room as int init maxBots($t);
    if ($s.bots <= $room) {
        return $s;
    }
    def out as Setup init $s;
    $out.bots = $room;
    return $out;
}

/**
 * Seat up to `n` computer players, stopping when the game is full.
 * @param t {Table} the table to seat into
 * @param n {int} how many to try to seat
 * @param level {string} the difficulty they all play at
 * @return {Table} the table with the computer players seated
 */
export func seatBots(t as Table, n as int, level as string) {
    def out as Table init $t;
    for (def i as int init 0; $i < $n; $i = $i + 1) {
        $out = seatBot($out, $level);
    }
    return $out;
}

# botSeed gives each computer player a different starting random state, derived
# from the game's own seed so a whole match stays reproducible.
func botSeed(t as Table) {
    return $t.game.seed + len($t.players) * 7919 + 1;
}

# seat adds one player and puts their snake on the field, reporting no terminal - for
# a seat that has none of its own, which is every computer player.
func seat(
    t as Table,
    peer as string,
    name as string,
    local as bool,
    kind as string,
    level as string,
    tick as int) {
    return seatWith($t, $peer, $name, $local, $kind, $level, $tick, 0, 0);
}

# seatWith is `seat` plus the terminal this player is sitting at, which a joining
# client reports in its JOIN and the local player reads from its own screen. A seat
# with no terminal puts no constraint on the agreed field size.
func seatWith(
    t as Table,
    peer as string,
    name as string,
    local as bool,
    kind as string,
    level as string,
    tick as int,
    rows as int,
    cols as int) {
    def out as Table init $t;
    def id as int init rules.nextId($out.game);
    def clean as string init proto.cleanName($name);
    $out.game = rules.addSnake($out.game, $id, $clean);
    def players as list of Player init $out.players;
    $players[] = Player{
        id: $id,
        peer: $peer,
        name: $clean,
        lastSeen: $tick,
        local: $local,
        kind: $kind,
        level: $level,
        seed: $tick,
        rows: $rows,
        cols: $cols
    };
    $out.players = $players;
    return $out;
}

/**
 * Whether a seat is driven by a computer player.
 * @param p {Player} the seat
 * @return {bool} true for a computer player
 */
export func isBot(p as Player) {
    return $p.kind == COMPUTER;
}

/**
 * How many computer players are seated.
 * @param t {Table} the table to count
 * @return {int} the number of computer players
 */
export func botCount(t as Table) {
    def n as int init 0;
    for (def p in $t.players) {
        if (isBot($p)) {
            $n = $n + 1;
        }
    }
    return $n;
}

/**
 * How many people are seated - the host at its keyboard plus every connected
 * client, but no computer players.
 * @param t {Table} the table to count
 * @return {int} the number of human players
 */
export func humanCount(t as Table) {
    return len($t.players) - botCount($t);
}

/**
 * Hand the snake at `peer` to a computer player: the seat keeps its id, its score,
 * and its body, and stops needing a socket. The name gains `TAKEOVER_SUFFIX` so
 * the scoreboard shows that nobody is driving it any more.
 *
 * An unknown peer, or one already driven by a computer, leaves the table alone.
 * @param t {Table} the table
 * @param peer {string} the peer that dropped out
 * @param level {string} the difficulty the computer player takes over at
 * @return {Table} the table with that seat under new management
 */
export func takeover(t as Table, peer as string, level as string) {
    def i as int init seatOf($t, $peer);
    if ($i < 0 or isBot($t.players[$i])) {
        return $t;
    }
    def out as Table init $t;
    $out.players[$i].kind = COMPUTER;
    $out.players[$i].level = bot.levelOr($level);
    $out.players[$i].peer = "";
    $out.players[$i].local = false;
    $out.players[$i].seed = botSeed($out);
    $out.players[$i].name = proto.cleanName($out.players[$i].name + TAKEOVER_SUFFIX);
    $out.game.snakes[rules.snakeIndex($out.game, $out.players[$i].id)].name = $out.players[$i].name;
    return $out;
}

/**
 * Apply the host's disconnect policy to a player who dropped out unexpectedly -
 * a closed socket or a timeout, not a `QUIT`.
 *
 * A deliberate `QUIT` always forfeits, whatever the policy: a player who chose to
 * leave has not asked a computer to keep playing for them. This is only for the
 * departures nobody chose.
 * @param t {Table} the table
 * @param peer {string} the peer that dropped out
 * @param policy {string} `FORFEIT` or `TAKEOVER`
 * @param level {string} the difficulty a taking-over computer player plays at
 * @return {Table} the table after the policy
 */
export func onLeave(t as Table, peer as string, policy as string, level as string) {
    if (leavePolicyOr($policy) == TAKEOVER) {
        return takeover($t, $peer, $level);
    }
    return unseat($t, $peer);
}

/**
 * Let every computer player choose its next heading. Call once per tick, before
 * `advance`. The field is surveyed once and shared, so the cost of eight bots is
 * eight decisions rather than eight surveys.
 * @param t {Table} the table
 * @return {Table} the table with every computer player's heading set
 */
export func steerBots(t as Table) {
    def out as Table init $t;
    if (botCount($out) == 0) {
        return $out;
    }
    def field as bot.Field init bot.survey($out.game);
    for (def i as int init 0; $i < len($out.players); $i = $i + 1) {
        if (isBot($out.players[$i])) {
            def d as bot.Decision init bot.chooseIn(
                $out.game,
                $out.players[$i].id,
                $out.players[$i].level,
                $out.players[$i].seed,
                $field);
            $out.players[$i].seed = $d.seed;
            $out.game = rules.setDirection($out.game, $out.players[$i].id, $d.dir);
        }
    }
    return $out;
}

/**
 * Forget a seat and take its snake off the field. An unknown peer leaves the
 * table unchanged, so a double departure is harmless.
 * @param t {Table} the table
 * @param peer {string} the peer to unseat
 * @return {Table} the table without that player
 */
export func unseat(t as Table, peer as string) {
    def i as int init seatOf($t, $peer);
    if ($i < 0) {
        return $t;
    }
    def out as Table init $t;
    $out.game = rules.removeSnake($out.game, $out.players[$i].id);
    def kept as list of Player init [];
    for (def j as int init 0; $j < len($out.players); $j = $j + 1) {
        if ($j != $i) {
            $kept[] = $out.players[$j];
        }
    }
    $out.players = $kept;
    return $out;
}

/**
 * Handle one inbound message. Pure: it returns the new table plus what to send
 * and whom to forget, and performs no I/O of its own.
 *
 * The `peer` argument is the authority on who is speaking; any player id inside
 * the message is advisory and is not trusted for anything.
 * @param t {Table} the current table
 * @param peer {string} the transport peer the message arrived from
 * @param line {string} the raw message line
 * @param tick {int} the current tick, recorded as the peer's last activity
 * @return {Reaction} the new table, the replies to send, and the peers to forget
 */
export func handle(t as Table, peer as string, line as string, tick as int) {
    def m as proto.Message init proto.decode($line);
    def out as Table init touch($t, $peer, $tick);
    match ($m.kind) {
        when proto.JOIN { return onJoin($out, $peer, $m, $tick); }
        when proto.DIR { return onDir($out, $peer, $m); }
        when proto.QUIT { return quiet(unseat($out, $peer)); }
        when proto.PING { return quiet($out); }
        else { return quiet($out); }
    }
}

# touch records that we have just heard from a seated peer, which is what keeps a
# UDP player from being swept while they are quietly playing.
func touch(t as Table, peer as string, tick as int) {
    def i as int init seatOf($t, $peer);
    if ($i < 0) {
        return $t;
    }
    def out as Table init $t;
    $out.players[$i].lastSeen = $tick;
    return $out;
}

# quiet is a reaction that changes the table and says nothing.
func quiet(t as Table) {
    return Reaction{table: $t, replies: [], dropped: []};
}

# onJoin seats a new player, or re-answers one already seated: a WELCOME can be
# lost on UDP, and the client's retry must not earn it a second snake.
func onJoin(t as Table, peer as string, m as proto.Message, tick as int) {
    def seated as int init idAt($t, $peer);
    if ($seated != 0) {
        return reply($t, $peer, welcomeFor($t, $seated));
    }
    if (isFull($t)) {
        return Reaction{
            table: $t,
            replies: [link.Packet{peer: $peer, body: proto.encodeDeny("game is full")}],
            dropped: [$peer]
        };
    }
    def out as Table init seatWith($t, $peer, $m.text, false, HUMAN, "", $tick, $m.rows, $m.cols);
    return reply($out, $peer, welcomeFor($out, idAt($out, $peer)));
}

# welcomeFor is the admission message for a seated player.
func welcomeFor(t as Table, id as int) {
    return proto.encodeWelcome($id, $t.game.width, $t.game.height, $t.tickMs);
}

# onDir steers the snake seated at this peer - not the one the message names.
func onDir(t as Table, peer as string, m as proto.Message) {
    def id as int init idAt($t, $peer);
    if ($id == 0 or not geom.isDirection($m.text)) {
        return quiet($t);
    }
    def out as Table init $t;
    $out.game = rules.setDirection($out.game, $id, $m.text);
    return quiet($out);
}

# reply is a reaction carrying one message back to one peer.
func reply(t as Table, peer as string, line as string) {
    return Reaction{table: $t, replies: [link.Packet{peer: $peer, body: $line}], dropped: []};
}

/**
 * Steer the local player, whose keypresses arrive at the keyboard rather than
 * over a socket.
 * @param t {Table} the table
 * @param dir {string} the direction, a `geom` direction
 * @return {Table} the table with the local snake's heading set
 */
export func steerLocal(t as Table, dir as string) {
    def id as int init localId($t);
    if ($id == 0) {
        return $t;
    }
    def out as Table init $t;
    $out.game = rules.setDirection($out.game, $id, $dir);
    return $out;
}

/**
 * Drop every remote player not heard from for `idleTicks` ticks, telling each one
 * why. The local player is never swept - there is no socket to go quiet on.
 * @param t {Table} the table
 * @param tick {int} the current tick
 * @param idleTicks {int} how many ticks of silence to tolerate
 * @return {Reaction} the table without the idle players, and the goodbyes to send
 */
export func sweep(t as Table, tick as int, idleTicks as int, policy as string, level as string) {
    def out as Table init $t;
    def replies as list of link.Packet init [];
    def dropped as list of string init [];
    for (def p in $t.players) {
        if (isIdle($p, $tick, $idleTicks)) {
            $replies[] = link.Packet{peer: $p.peer, body: proto.encodeBye("timed out")};
            $dropped[] = $p.peer;
        }
    }
    for (def peer in $dropped) {
        $out = onLeave($out, $peer, $policy, $level);
    }
    return Reaction{table: $out, replies: $replies, dropped: $dropped};
}

# isIdle reports whether a seat has gone quiet for too long. Only a remote person
# can: the host's own keyboard has no socket to fall silent on, and a computer
# player is never waiting on the network at all.
func isIdle(p as Player, tick as int, idleTicks as int) {
    if ($p.local or isBot($p)) {
        return false;
    }
    return $tick - $p.lastSeen > $idleTicks;
}

/**
 * Advance the game one tick.
 * @param t {Table} the table
 * @return {Table} the table one tick later
 */
export func advance(t as Table) {
    def out as Table init $t;
    $out.game = rules.advance($out.game);
    return $out;
}

/**
 * The `STATE` line describing the table's game, to be sent to every player.
 * @param t {Table} the table
 * @return {string} the encoded `STATE` message
 */
export func stateLine(t as Table) {
    return proto.encodeState($t.game);
}

/**
 * The peers of every remote player - who a `STATE` goes to. The local player is
 * not among them; they read the same game out of memory.
 * @param t {Table} the table
 * @return {list of string} the remote peers
 */
export func audience(t as Table) {
    def out as list of string init [];
    for (def p in $t.players) {
        if (not $p.local and not isBot($p) and len($p.peer) > 0) {
            $out[] = $p.peer;
        }
    }
    return $out;
}

/**
 * The options a host can change from the title screen, and which row the cursor is
 * on. Value-semantic and changed only by `pressed`, so the whole setup screen is a
 * pure function of the keys typed at it - which is what makes it testable without a
 * terminal.
 * @field tickMs {int} the tick period in milliseconds
 * @field capacity {int} how many players to seat
 * @field bots {int} how many computer players to add
 * @field botLevel {string} the difficulty those computer players play at
 * @field onLeave {string} what happens to a dropped player
 * @field specials {bool} whether special food appears
 * @field lives {int} lives each player gets, or `rules.UNLIMITED_LIVES`
 * @field wrap {bool} whether the edges join up instead of being walls
 * @field row {int} the selected row, an index into `SETUP_ROWS`
 * @field start {bool} set once the host has asked to begin
 * @field quit {bool} set once the host has asked to leave
 */
export def struct Setup {
    tickMs as int,
    capacity as int,
    bots as int,
    botLevel as string,
    onLeave as string,
    specials as bool,
    lives as int,
    wrap as bool,
    row as int,
    start as bool,
    quit as bool
};

/**
 * The setup rows, in the order the title screen lists them. The cursor moves over
 * these and left / right changes the selected one.
 */
export def const SETUP_ROWS as list of string init [
    "speed",
    "players",
    "lives",
    "edges",
    "computer players",
    "computer skill",
    "on disconnect",
    "special food"
];

/**
 * How much one press of left or right moves the tick period, in milliseconds.
 */
export def const TICK_STEP as int init 5;

/**
 * The setup a host starts the title screen with, taken from its command line.
 * @param opts {Options} the options the host was started with
 * @return {Setup} the initial setup, cursor on the first row
 */
export func setupFrom(opts as Options) {
    return Setup{
        tickMs: clamp($opts.tickMs, MIN_TICK_MS, MAX_TICK_MS),
        capacity: clamp($opts.capacity, 1, rules.MAX_PLAYERS),
        bots: clamp($opts.bots, 0, rules.MAX_PLAYERS),
        botLevel: bot.levelOr($opts.botLevel),
        onLeave: leavePolicyOr($opts.onLeave),
        specials: $opts.specials,
        lives: rules.livesOr($opts.lives),
        wrap: $opts.wrap,
        row: 0,
        start: false,
        quit: false
    };
}

/**
 * The setup after one keypress. Pure and total: any key at all is accepted, and one
 * that means nothing here leaves the setup exactly as it was.
 *
 * Up and down move the cursor, left and right change the selected row, Enter or `s`
 * starts the game, and Escape leaves - there is no screen behind this one. The cursor
 * wraps, because a list of eight rows is quicker to reach round the end than to walk back.
 * @param s {Setup} the current setup
 * @param k {screen.Key} the key pressed
 * @return {Setup} the setup after that key
 */
export func pressed(s as Setup, k as screen.Key) {
    def out as Setup init $s;
    # Escape backs out of wherever you are, and there is nothing behind the title screen -
    # so here, and only here, backing out means leaving the program.
    if (keys.isBack($k) or keys.isAbort($k)) {
        $out.quit = true;
        return $out;
    }
    if (keys.isConfirm($k) or isStartKey($k)) {
        $out.start = true;
        return $out;
    }
    match ($k.name) {
        when "up" { $out.row = wrapRow($out.row - 1); }
        when "down" { $out.row = wrapRow($out.row + 1); }
        when "left" { return adjust($out, -1); }
        when "right" { return adjust($out, 1); }
        else { return letterKey($out, $k); }
    }
    return $out;
}

# isStartKey is the explicit "go" key, for a host who would rather type a letter than
# find Enter. Enter and space work too, via keys.isConfirm.
func isStartKey(k as screen.Key) {
    return $k.name == "char" and ($k.char == "s" or $k.char == "S");
}

# letterKey maps the WASD keys onto the same cursor movement as the arrows, so the
# title screen is navigable on a terminal that swallows arrow keys - the same reason
# the game itself accepts them.
func letterKey(s as Setup, k as screen.Key) {
    match (keys.directionOf($k)) {
        when geom.UP { return moved($s, -1); }
        when geom.DOWN { return moved($s, 1); }
        when geom.LEFT { return adjust($s, -1); }
        when geom.RIGHT { return adjust($s, 1); }
        else { return $s; }
    }
}

# moved walks the cursor by `step`, wrapping at both ends.
func moved(s as Setup, step as int) {
    def out as Setup init $s;
    $out.row = wrapRow($out.row + $step);
    return $out;
}

# wrapRow keeps a row index inside the list, wrapping round either end.
func wrapRow(row as int) {
    return $row % len(SETUP_ROWS);
}

# adjust changes the selected row by one step in the given direction. Every value is
# clamped to what the rest of the program will accept, so a setup produced here is
# always one `newTable` and `rules` will honour without further checking.
func adjust(s as Setup, step as int) {
    def out as Setup init $s;
    match (SETUP_ROWS[$out.row]) {
        when "speed" {
            # Right means faster, which is a *smaller* tick: the row reads as speed,
            # not as milliseconds, so the arrow has to match the label.
            $out.tickMs = clamp($out.tickMs - $step * TICK_STEP, MIN_TICK_MS, MAX_TICK_MS);
        }
        when "players" { $out.capacity = clamp($out.capacity + $step, 1, rules.MAX_PLAYERS); }
        when "lives" {
            # One step past the top is the endless game, which is the natural place for
            # it: "more than nine lives" and "no limit" are the same wish.
            $out.lives = stepLives($out.lives, $step);
        }
        when "edges" { $out.wrap = not $out.wrap; }
        when "computer players" { $out.bots = clamp($out.bots + $step, 0, rules.MAX_PLAYERS); }
        when "computer skill" { $out.botLevel = stepLevel($out.botLevel, $step); }
        when "on disconnect" { $out.onLeave = otherPolicy($out.onLeave); }
        when "special food" { $out.specials = not $out.specials; }
        else { return $out; }
    }
    return $out;
}

# stepLevel walks the difficulty ladder, stopping at each end rather than wrapping:
# a host holding the right arrow should land on `expert`, not cycle back to `easy`.
func stepLevel(level as string, step as int) {
    def at as int init 0;
    for (def i as int init 0; $i < len(bot.LEVELS); $i = $i + 1) {
        if (bot.LEVELS[$i] == $level) {
            $at = $i;
        }
    }
    return bot.LEVELS[clamp($at + $step, 0, len(bot.LEVELS) - 1)];
}

# stepLives walks the lives setting, with the endless game sitting just past the top:
# 1..MAX_LIVES then unlimited, wrapping both ways.
func stepLives(lives as int, step as int) {
    def at as int init $lives;
    if ($lives == rules.UNLIMITED_LIVES) {
        $at = rules.MAX_LIVES + 1;
    }
    def next as int init ($at - 1 + $step) % (rules.MAX_LIVES + 1) + 1;
    if ($next > rules.MAX_LIVES) {
        return rules.UNLIMITED_LIVES;
    }
    return $next;
}

# otherPolicy is the disconnect policy that is not this one - there are two, so
# either arrow toggles.
func otherPolicy(policy as string) {
    if (leavePolicyOr($policy) == FORFEIT) {
        return TAKEOVER;
    }
    return FORFEIT;
}

/**
 * The value shown against a setup row, ready to draw. Kept beside `adjust` so a row's
 * label, its value, and the effect of changing it cannot drift apart.
 * @param s {Setup} the setup to read
 * @param row {int} the row index, into `SETUP_ROWS`
 * @return {string} the value as the title screen shows it
 */
export func setupValue(s as Setup, row as int) {
    match (SETUP_ROWS[wrapRow($row)]) {
        when "speed" { return io.sprintf("%d ms per move", $s.tickMs); }
        when "players" { return io.sprintf("%d", $s.capacity); }
        when "computer players" { return io.sprintf("%d", $s.bots); }
        when "computer skill" { return $s.botLevel; }
        when "on disconnect" { return $s.onLeave; }
        when "lives" { return livesLabel($s.lives); }
        when "edges" { return edgeLabel($s.wrap); }
        when "special food" { return onOff($s.specials); }
        else { return ""; }
    }
}

# livesLabel spells the lives setting, naming the endless game rather than showing a 0
# that a host would have to guess the meaning of.
func livesLabel(lives as int) {
    if ($lives == rules.UNLIMITED_LIVES) {
        return "unlimited";
    }
    return io.sprintf("%d", $lives);
}

# edgeLabel names the border rule in the terms a player thinks about it, rather than as
# a flag: "walls" kill you, "wrap around" does not.
func edgeLabel(wrap as bool) {
    if ($wrap) {
        return "wrap around";
    }
    return "walls";
}

# onOff spells a flag for the title screen.
func onOff(flag as bool) {
    if ($flag) {
        return "on";
    }
    return "off";
}

/**
 * The options a host will actually run with, after the title screen. The command line
 * supplies everything the title screen does not offer - the transport, the port, the
 * name, the field cap - and the setup overrides the rest.
 * @param opts {Options} the options the host was started with
 * @param s {Setup} the setup as the host left it
 * @return {Options} the options to run
 */
export func withSetup(opts as Options, s as Setup) {
    def out as Options init $opts;
    $out.tickMs = $s.tickMs;
    $out.capacity = $s.capacity;
    $out.bots = $s.bots;
    $out.botLevel = $s.botLevel;
    $out.onLeave = $s.onLeave;
    $out.specials = $s.specials;
    $out.lives = $s.lives;
    $out.wrap = $s.wrap;
    return $out;
}

/**
 * The field every player at this table can draw: the smallest of what each reported
 * terminal can show, held under the host's own requested cap.
 *
 * The host's own terminal (`rows` / `cols`) always counts, whether or not it holds a
 * seat: a `--watch` referee draws the same game everybody else does, so its window
 * constrains the field exactly as a player's would.
 *
 * Reserving `t.capacity` scoreboard rows rather than the seats actually taken is
 * deliberate: the field is then still drawable when the table fills up, so nobody's
 * display breaks because somebody joined. A seat that reported no terminal - every
 * computer player, and a client too old to say - constrains nothing.
 * @param t {Table} the table to size for
 * @param cap {view.Room} the host's own requested maximum, from `--width` / `--height`
 * @param rows {int} the host's terminal rows
 * @param cols {int} the host's terminal columns
 * @return {view.Room} the field size to play on
 */
export func agreedField(t as Table, cap as view.Room, rows as int, cols as int) {
    def room as view.Room init view.smaller(
        $cap,
        view.maxField($rows, $cols, $t.capacity, $t.game.specials));
    for (def p in $t.players) {
        if ($p.rows > 0 or $p.cols > 0) {
            $room = view.smaller(
                $room,
                view.maxField($p.rows, $p.cols, $t.capacity, $t.game.specials));
        }
    }
    return $room;
}

/**
 * Whether the agreed field is smaller than the terminals would have allowed, i.e.
 * whether the host's `--width` / `--height` cap is what decided it. The title screen
 * says which, because "the largest every terminal can show" is a claim that would be
 * false whenever a cap binds.
 * @param t {Table} the table
 * @param cap {view.Room} the host's requested maximum
 * @param rows {int} the host's terminal rows
 * @param cols {int} the host's terminal columns
 * @return {bool} true when the cap, rather than a terminal, set the size
 */
export func cappedByHost(t as Table, cap as view.Room, rows as int, cols as int) {
    def unlimited as view.Room init view.Room{width: rules.MAX_WIDTH, height: rules.MAX_HEIGHT};
    def free as view.Room init agreedField($t, $unlimited, $rows, $cols);
    def held as view.Room init agreedField($t, $cap, $rows, $cols);
    return $held.width < $free.width or $held.height < $free.height;
}

/**
 * The field a game will actually be played on: what every terminal can show, held
 * inside what the chosen transport can describe.
 *
 * The transport part matters on UDP, where a whole `STATE` line has to fit one
 * datagram - so a very large field is a TCP game, and a host on a big display that
 * wants all of it should say `--mode tcp`. The title screen names whichever limit bound.
 * @param t {Table} the table to size for
 * @param opts {Options} the host's options, for the cap and the transport
 * @param rows {int} the host's terminal rows
 * @param cols {int} the host's terminal columns
 * @return {view.Room} the field to play on
 */
export func playableField(t as Table, opts as Options, rows as int, cols as int) {
    return view.withinArea(
        agreedField($t, capFrom($opts), $rows, $cols),
        link.maxFieldArea($opts.mode));
}

/**
 * Why the field is the size it is - which of the three limits actually bound. The title
 * screen says so, because "the largest every terminal here can show" is a claim that is
 * false whenever something else decided.
 * @param t {Table} the table
 * @param opts {Options} the host's options
 * @param rows {int} the host's terminal rows
 * @param cols {int} the host's terminal columns
 * @return {string} one of `BY_TERMINAL`, `BY_CAP`, or `BY_TRANSPORT`
 */
export func fieldLimit(t as Table, opts as Options, rows as int, cols as int) {
    def free as view.Room init agreedField($t, capFrom($opts), $rows, $cols);
    def played as view.Room init playableField($t, $opts, $rows, $cols);
    if ($played.width < $free.width or $played.height < $free.height) {
        return BY_TRANSPORT;
    }
    if (cappedByHost($t, capFrom($opts), $rows, $cols)) {
        return BY_CAP;
    }
    return BY_TERMINAL;
}

/**
 * The field is as large as every terminal at the table can show.
 */
export def const BY_TERMINAL as string init "terminal";

/**
 * The field was held down by the host's own `--width` / `--height`.
 */
export def const BY_CAP as string init "cap";

/**
 * The field was held down by what one `STATE` line can carry on this transport.
 */
export def const BY_TRANSPORT as string init "transport";

/**
 * Whether this player's terminal can show a field of the agreed size. The lobby says
 * so beside their name, because a player who cannot see the walls needs to resize
 * their window before the game starts, not after.
 * @param t {Table} the table
 * @param p {Player} the seat to check
 * @return {bool} true when that player can draw the game, or reported no terminal
 */
export func canPlay(t as Table, p as Player) {
    if ($p.rows <= 0 and $p.cols <= 0) {
        return true;
    }
    return view.canShow($p.rows, $p.cols, $t.capacity, $t.game.specials);
}

/**
 * Put the table on a field of exactly this size, with everybody still in their seat.
 *
 * The lobby seats players on a provisional field while the size is still being
 * negotiated, so starting the game means rebuilding the game at the agreed size and
 * placing every snake again. Scores are zero at this point by definition - the game
 * has not started - so nothing is lost by rebuilding.
 * @param t {Table} the table to start
 * @param room {view.Room} the agreed field size
 * @param seed {int} the game's random seed
 * @param round {int} which game this is, counted from 1, so a client can tell it from the last
 * @return {Table} the table on its final field, everyone placed
 */
export func startGame(t as Table, room as view.Room, seed as int, round as int) {
    def out as Table init $t;
    def specials as bool init $out.game.specials;
    def lives as int init $out.game.lives;
    def wrapped as bool init $out.game.wrap;
    $out.game = rules.newGame($room.width, $room.height, $seed);
    if (not $specials) {
        $out.game = rules.withoutSpecials($out.game);
    }
    $out.game = rules.withLives($out.game, $lives);
    $out.game = rules.withWrap($out.game, $wrapped);
    $out.game = rules.withRound($out.game, $round);
    def seats as list of Player init $out.players;
    $out.players = [];
    for (def p in $seats) {
        $out = reseatPlayer($out, $p, 0);
    }
    return $out;
}

/**
 * The lobby roster to publish to every client.
 * @param t {Table} the table
 * @return {list of proto.Seat} one row per seated player
 */
export func roster(t as Table) {
    def seats as list of proto.Seat init [];
    for (def p in $t.players) {
        $seats[] = proto.Seat{
            id: $p.id,
            name: $p.name,
            kind: $p.kind,
            rows: $p.rows,
            cols: $p.cols
        };
    }
    return $seats;
}

/**
 * Run a host until the player quits or the terminal goes away.
 *
 * This is the only impure function in the module: it binds the sockets, takes
 * over the terminal, and drives the clock. Every decision it makes is delegated
 * to the pure functions above, which is why it is short enough to read.
 * @param opts {Options} how to run
 * @return {int} a process exit code: 0 for a clean quit, 2 when it could not start
 */
export func run(opts as Options) {
    if (not os.isTerminal("stdout")) {
        io.eprintf("jsnake: hosting needs a terminal; stdout is not one\n");
        return 2;
    }
    def wire as link.Host init link.listen($opts.mode, $opts.port);
    defer link.close($wire);
    def responder as beacon.Responder init tryAnnounce($opts, $wire.port);
    defer beacon.stop($responder);
    def announcing as bool init $responder.port == beacon.DISCOVERY_PORT;
    io.printf("jsnake host on %s port %d\n", $opts.mode, $wire.port);
    def state as term.State init screen.begin();
    defer screen.end($state);
    def input as screen.Input init screen.startInput();
    return rounds($opts, $wire, $responder, $input, note($wire, $announcing));
}

# rounds is the host's whole life: set a game up, play it, and when it ends offer another
# rather than ticking a finished field for ever.
#
# The players carry across. Their sockets never went anywhere, so the next title screen
# opens with them already seated, and nobody has to rejoin between rounds.
func rounds(
    opts as Options,
    wire as link.Host,
    responder as beacon.Responder,
    input as screen.Input,
    banner as string) {
    def current as Options init $opts;
    def net as link.Host init $wire;
    def keep as list of Player init [];
    def round as int init 0;
    def hosting as bool init true;
    while ($hosting) {
        $round = $round + 1;
        def opening as Opening init open(
            $current,
            $net,
            $responder,
            $input,
            $banner,
            $keep,
            $round);
        $net = $opening.net;
        if ($opening.quit) {
            return 0;
        }
        def finish as Finish init loop(
            $opening.table,
            $net,
            $responder,
            $input,
            $banner,
            $opening.opts);
        $net = $finish.net;
        $keep = people($finish.table);
        if ($finish.quit) {
            return 0;
        }
        # A round ended on its own. Whatever the host asked for the first game, the next
        # one is set up on the title screen: a `--now` host meant "do not make me set the
        # *first* game up", not "never show me a screen again".
        $current = $finish.opts;
        $current.lobby = true;
    }
    return 0;
}

# How a round ended: the table as it finished, the transport, the options the host was
# playing with, and whether they want to stop altogether.
def struct Finish {
    table as Table,
    net as link.Host,
    opts as Options,
    quit as bool
};

# What the title screen settled on: the table as it stood when the host pressed start,
# the transport with its peers, and the options as the host left them.
def struct Opening {
    table as Table,
    net as link.Host,
    opts as Options,
    quit as bool
};

# open settles the game to be played: through the title screen when the host wants
# one, or straight away when there is nobody to wait for (a solo game).
func open(
    opts as Options,
    wire as link.Host,
    responder as beacon.Responder,
    input as screen.Input,
    banner as string,
    keep as list of Player,
    round as int) {
    def setup as Setup init setupFrom($opts);
    if ($opts.lobby) {
        return lobby($opts, $wire, $responder, $input, $banner, $keep, $round);
    }
    def table as Table init tableFor($opts, $setup, $keep);
    def size as term.Size init screenSize();
    def room as view.Room init playableField($table, $opts, $size.rows, $size.cols);
    return Opening{
        table: startGame($table, $room, seedFrom($opts.seed), $round),
        net: $wire,
        opts: $opts,
        quit: false
    };
}

# lobby is the title screen: the host sets the game up while players arrive, and the
# game does not begin until the host says so.
#
# Players are seated here on a provisional field, because the field size is exactly
# what is still being negotiated - every client reports its terminal in its JOIN and
# the smallest one wins. `startGame` rebuilds the game at the agreed size once the
# host presses start.
func lobby(
    opts as Options,
    wire as link.Host,
    responder as beacon.Responder,
    input as screen.Input,
    banner as string,
    keep as list of Player,
    round as int) {
    def setup as Setup init setupFrom($opts);
    def table as Table init tableFor($opts, $setup, $keep);
    def net as link.Host init $wire;
    def frame as screen.Buffer init screen.newScreen(1, 1);
    def nextPublish as int init 0;
    def waiting as bool init true;
    while ($waiting) {
        while (screen.hasKey($input)) {
            $setup = pressed($setup, screen.pollKey($input));
        }
        if ($setup.quit) {
            $net = link.sendAll($net, audience($table), proto.encodeBye("host left"));
            return Opening{table: $table, net: $net, opts: $opts, quit: true};
        }
        # The setup can change the capacity and the food rules, which both change the
        # field everyone is agreeing on, so the table is rebuilt from it each pass.
        # Seated players keep their seats: `reseat` carries them across.
        $table = reseat($table, $opts, $setup);
        # The ceiling on computer players is whatever the people are not sitting in, and it
        # moves as they come and go - so the row is held down to it here, every pass, rather
        # than being allowed to advertise seats that do not exist.
        $setup = fitBots($setup, $table);
        def turn as Round init exchange($table, $net, withSetup($opts, $setup));
        $table = $turn.table;
        $net = $turn.net;
        beacon.serve($responder, len($table.players));
        def screen as term.Size init screenSize();
        def room as view.Room init playableField(
            $table,
            withSetup($opts, $setup),
            $screen.rows,
            $screen.cols);
        if (nowMs() >= $nextPublish) {
            $nextPublish = nowMs() + LOBBY_MS;
            $net = link.sendAll(
                $net,
                audience($table),
                proto.encodeLobby(
                    $room.width,
                    $room.height,
                    $setup.tickMs,
                    $table.capacity,
                    roster($table),
                    $round));
            $frame = paintTitle(
                $frame,
                $table,
                $setup,
                $room,
                $banner,
                fieldLimit($table, withSetup($opts, $setup), $screen.rows, $screen.cols));
        }
        if ($setup.start) {
            def ready as Table init startGame($table, $room, seedFrom($opts.seed), $round);
            return Opening{table: $ready, net: $net, opts: withSetup($opts, $setup), quit: false};
        }
        time.sleep(time.fromMilliseconds(IDLE_SLEEP_MS));
    }
    return Opening{table: $table, net: $net, opts: $opts, quit: true};
}

# blankTable is an empty table with the rules the setup asks for - the shape both the
# first lobby and every rebuild start from.
func blankTable(opts as Options, setup as Setup, seed as int) {
    def table as Table init newTable(
        $opts.width,
        $opts.height,
        $seed,
        $setup.capacity,
        $setup.tickMs);
    if (not $setup.specials) {
        $table.game = rules.withoutSpecials($table.game);
    }
    $table.game = rules.withLives($table.game, $setup.lives);
    $table.game = rules.withWrap($table.game, $setup.wrap);
    return $table;
}

# reseatPlayer puts an existing seat back on a rebuilt table, **keeping its player id**.
#
# That matters more than it looks. A client learns its id once, from its `WELCOME`, and
# uses it to find its own snake on every screen afterwards. Rebuilding the table with fresh
# ids - which is what happens if the people are re-seated in a different order from the one
# they arrived in - silently points every client at somebody else's snake. It did.
func reseatPlayer(t as Table, p as Player, tick as int) {
    def out as Table init $t;
    $out.game = rules.addSnake($out.game, $p.id, $p.name);
    def players as list of Player init $out.players;
    $players[] = Player{
        id: $p.id,
        peer: $p.peer,
        name: $p.name,
        lastSeen: $tick,
        local: $p.local,
        kind: $p.kind,
        level: $p.level,
        seed: $tick,
        rows: $p.rows,
        cols: $p.cols
    };
    $out.players = $players;
    return $out;
}

/**
 * The people at this table - everyone a computer is not driving. What carries from one
 * round to the next, since their sockets do.
 * @param t {Table} the table
 * @return {list of Player} the human seats, in order
 */
export func people(t as Table) {
    def out as list of Player init [];
    for (def p in $t.players) {
        if (not isBot($p)) {
            $out[] = $p;
        }
    }
    return $out;
}

# tableFor builds the lobby's table: the rules the setup asks for, the people in `keep`
# back in their seats, and the computer players the setup wants.
#
# `keep` is empty for the first game and holds the previous round's people for every one
# after it. That is what lets one round end and another be set up without everybody
# reconnecting: their sockets never went anywhere, so neither should their seats.
func tableFor(opts as Options, setup as Setup, keep as list of Player) {
    def size as term.Size init screenSize();
    def table as Table init blankTable($opts, $setup, seedFrom($opts.seed));
    if (len($keep) == 0) {
        if ($opts.play) {
            return seatBots(
                seatLocal($table, $opts.name, $size.rows, $size.cols),
                $setup.bots,
                $setup.botLevel);
        }
        return seatBots($table, $setup.bots, $setup.botLevel);
    }
    for (def p in $keep) {
        $table = reseatPlayer($table, $p, 0);
    }
    return seatBots($table, $setup.bots, $setup.botLevel);
}

# reseat rebuilds the table for a changed setup while keeping every human who has
# already joined. Computer players are rebuilt from the setup, since their number and
# skill are exactly what the host is adjusting.
func reseat(t as Table, opts as Options, setup as Setup) {
    if (unchanged($t, $setup)) {
        return $t;
    }
    def out as Table init blankTable($opts, $setup, $t.game.seed);
    for (def p in people($t)) {
        $out = reseatPlayer($out, $p, $p.lastSeen);
    }
    return seatBots($out, $setup.bots, $setup.botLevel);
}

# unchanged reports whether the table already matches the setup, so the common case -
# a pass in which the host pressed nothing - rebuilds nothing.
func unchanged(t as Table, setup as Setup) {
    if ($t.capacity != $setup.capacity or $t.tickMs != $setup.tickMs) {
        return false;
    }
    if ($t.game.specials != $setup.specials or $t.game.lives != $setup.lives) {
        return false;
    }
    if ($t.game.wrap != $setup.wrap) {
        return false;
    }
    return botCount($t) == $setup.bots and botsMatch($t, $setup.botLevel);
}

# botsMatch reports whether every computer player is already at the chosen skill.
func botsMatch(t as Table, level as string) {
    for (def p in $t.players) {
        if (isBot($p) and $p.level != $level) {
            return false;
        }
    }
    return true;
}

# capFrom is the host's own requested field size, which caps whatever the terminals
# would otherwise allow: a host that asked for a small field gets one. Left at the
# game's own maximum - which is what the command line defaults to - it never binds, and
# the terminals at the table decide the size between them.
func capFrom(opts as Options) {
    return view.Room{width: $opts.width, height: $opts.height};
}

# paintTitle draws the title screen and writes only what changed.
func paintTitle(
    previous as screen.Buffer,
    t as Table,
    setup as Setup,
    room as view.Room,
    banner as string,
    limit as string) {
    def size as term.Size init screenSize();
    def frame as screen.Buffer init view.message(
        TITLE,
        titleLines($t, $setup, $room, $banner, $limit, $size.rows, $size.cols),
        $size.rows,
        $size.cols);
    io.printf("%s", screen.diff($previous, $frame));
    return $frame;
}

/**
 * How much of the title screen to draw. Not every table fits every terminal: eight
 * players laid out generously need thirty-four rows, and on the ordinary 80x24 the
 * lines that fell off the bottom were the field size and `enter start` - the two a
 * first-time host most needs to see.
 *
 * So there is a short list of layouts and `titleLines` picks one. Note what gives way
 * and in what order: the logo first, then the blank lines between sections, and only
 * then the roster, which folds into columns and loses its long "at the keyboard"
 * wording. The settings never give way at all - they are what the screen is for.
 * @field logo {bool} whether to draw the logo above the settings
 * @field density {string} `AIRY`, `SNUG` or `DENSE` - how many blank separators to keep
 * @field columns {int} how many players to a roster row
 */
def struct Layout {
    logo as bool,
    density as string,
    columns as int
};

# Every section separated by a blank line - the roomy screen, on a terminal with room.
def const AIRY as string init "airy";

# Only the banner and the key line set apart, so the settings and the roster read as
# one block instead of four.
def const SNUG as string init "snug";

# No blank lines at all; every row is content.
def const DENSE as string init "dense";

# The layouts to try, most generous first. `titleLines` takes the first that fits.
def const TITLE_LAYOUTS as list of Layout init [
    Layout{logo: true, density: AIRY, columns: 1},
    Layout{logo: false, density: AIRY, columns: 1},
    Layout{logo: false, density: SNUG, columns: 1},
    Layout{logo: false, density: SNUG, columns: 2},
    Layout{logo: false, density: DENSE, columns: 2}
];

/**
 * The body of the host's title screen: the settings, who is waiting, the field
 * everyone has agreed on, and the keys. Pure, so what a host reads before starting is
 * pinned down by a test rather than by looking at it.
 *
 * `rows` and `cols` are the terminal this has to fit inside, because it does not always
 * fit - see `Layout`. The layout is chosen by *building* each candidate and measuring
 * it, from the most generous down, rather than by predicting a height in arithmetic
 * that could disagree with the lines actually returned. Five short builds at a quarter
 * of a second apart costs nothing, and the screen can never be a row taller than the
 * budget it was checked against.
 * @param t {Table} the table as it stands
 * @param setup {Setup} the settings as the host has them
 * @param room {view.Room} the agreed field size
 * @param banner {string} where the host is listening, for the top line
 * @param limit {string} which limit set the field size, from `fieldLimit`
 * @param rows {int} the terminal's height; 0 or less means assume the fallback
 * @param cols {int} the terminal's width; 0 or less means assume the fallback
 * @return {list of string} the lines to draw
 */
export func titleLines(
    t as Table,
    setup as Setup,
    room as view.Room,
    banner as string,
    limit as string,
    rows as int,
    cols as int) {
    def lines as list of string init [];
    for (def how in TITLE_LAYOUTS) {
        $lines = titleBody($t, $setup, $room, $banner, $limit, $how);
        if (titleFits($lines, $rows, $cols)) {
            return $lines;
        }
    }
    # Smaller than even the tightest layout, which `view.message` will clip. `$lines`
    # holds that tightest build, so what survives the clip is as much of the screen as
    # there was room for - returning the roomiest would clip away the roster and the keys.
    return $lines;
}

# titleFits reports whether a built body fits a terminal, both ways round. `view.message`
# frames it with a border and a blank row on each side, which is the +4 on each axis.
func titleFits(lines as list of string, rows as int, cols as int) {
    def high as int init view.FALLBACK_ROWS;
    if ($rows > 0) {
        $high = $rows;
    }
    def wide as int init view.FALLBACK_COLS;
    if ($cols > 0) {
        $wide = $cols;
    }
    if (len($lines) + 4 > $high) {
        return false;
    }
    return longest($lines) + 4 <= $wide;
}

# longest is the width of the widest line, which is what `view.message` sizes its box to.
func longest(lines as list of string) {
    def n as int init len(TITLE);
    for (def line in $lines) {
        if (len($line) > $n) {
            $n = len($line);
        }
    }
    return $n;
}

# titleBody lays the screen out one particular way. Everything that differs between a
# roomy screen and a cramped one is decided here, from `how` alone - which is what lets
# `titleLines` measure a candidate instead of predicting its size.
func titleBody(
    t as Table,
    setup as Setup,
    room as view.Room,
    banner as string,
    limit as string,
    how as Layout) {
    def out as list of string init [];
    if ($how.logo) {
        for (def line in view.LOGO) {
            $out[] = $line;
        }
        $out[] = "";
    }
    $out[] = $banner;
    if ($how.density != DENSE) {
        $out[] = "";
    }
    for (def i as int init 0; $i < len(SETUP_ROWS); $i = $i + 1) {
        $out[] = view.menuRow(SETUP_ROWS[$i], setupValue($setup, $i), $i == $setup.row);
    }
    if ($how.density == AIRY) {
        $out[] = "";
    }
    $out[] = fieldLine($room, $limit);
    if ($how.density == AIRY) {
        $out[] = "";
    }
    $out[] = io.sprintf("players %d of %d", len($t.players), $t.capacity);
    for (def line in rosterLines($t, $how.columns)) {
        $out[] = $line;
    }
    if ($how.columns > 1 and anyTooSmall($t)) {
        $out[] = TOO_SMALL_LEGEND;
    }
    if ($how.density != DENSE) {
        $out[] = "";
    }
    $out[] = "up/down choose   left/right change   enter start   " + keys.ESCAPE_LABEL + " quit";
    return $out;
}

# rosterLines lists who is waiting: one player per line, or folded several to a line when
# that is what it takes to fit. Folding is why `playerCell` exists beside `playerLine`.
func rosterLines(t as Table, columns as int) {
    def out as list of string init [];
    if ($columns <= 1) {
        for (def p in $t.players) {
            $out[] = playerLine($t, $p);
        }
        return $out;
    }
    def row as string init "";
    for (def i as int init 0; $i < len($t.players); $i = $i + 1) {
        $row = $row + playerCell($t, $t.players[$i]);
        if (($i + 1) % $columns == 0) {
            $out[] = strings.trimRight($row);
            $row = "";
        }
    }
    if (len($row) > 0) {
        $out[] = strings.trimRight($row);
    }
    return $out;
}

# anyTooSmall reports whether somebody at the table cannot show the agreed field, which is
# what makes the `!` legend worth a line of its own.
func anyTooSmall(t as Table) {
    for (def p in $t.players) {
        if (not canPlay($t, $p)) {
            return true;
        }
    }
    return false;
}

# What the `!` on a folded roster entry means, spelled out - but only on a screen that
# folded and only when somebody is actually flagged, so it usually costs nothing.
def const TOO_SMALL_LEGEND as string init "!  TERMINAL TOO SMALL for the agreed field";

# fieldLine says how big the field is and, honestly, what decided it - a cap the host
# asked for, or the smallest terminal at the table.
func fieldLine(room as view.Room, limit as string) {
    def size as string init io.sprintf("field %d x %d", $room.width, $room.height);
    match ($limit) {
        when BY_CAP { return $size + ", capped by --width / --height"; }
        when BY_TRANSPORT { return $size + ", limited by udp datagram size - try --mode tcp"; }
        else { return $size + ", the largest every terminal here can show"; }
    }
}

# playerCell is one player on a folded roster: their name, who is driving in three to
# five characters, and a `!` when their terminal cannot show the agreed field. The long
# wording `playerLine` uses would not go two to a row, which is the whole point of
# folding; `TOO_SMALL_LEGEND` carries the words the `!` stands in for.
func playerCell(t as Table, p as Player) {
    def tag as string init "cpu";
    if ($p.kind == HUMAN) {
        $tag = "human";
        if ($p.local) {
            $tag = "you";
        }
    }
    if (not canPlay($t, $p)) {
        $tag = $tag + "!";
    }
    return io.sprintf("  %s|pad=13 %s|pad=7", $p.name, $tag);
}

# playerLine describes one waiting player: who they are, what is driving them, and -
# when it is a problem - that their terminal is too small for the agreed field.
func playerLine(t as Table, p as Player) {
    def where as string init "at the keyboard";
    if (not $p.local) {
        $where = $p.kind;
    }
    def note as string init "";
    if (not canPlay($t, $p)) {
        $note = "  TERMINAL TOO SMALL";
    }
    return io.sprintf("  %s|pad=14 %s|pad=10 %s", $p.name, $where, $note);
}

# tryAnnounce claims the well-known discovery port if it can. A host that cannot
# be discovered is still perfectly playable by address, so a busy port is a note
# in the status line rather than a reason to refuse to start. A host started
# `--private` binds an ephemeral port it never advertises, so `stop` has something
# to close either way.
func tryAnnounce(opts as Options, gamePort as int) {
    if (not $opts.discoverable) {
        return beacon.announceOn(0, $gamePort, $opts.mode, $opts.name, $opts.capacity);
    }
    try {
        return beacon.announce($gamePort, $opts.mode, $opts.name, $opts.capacity);
    } catch (e) {
        return beacon.announceOn(0, $gamePort, $opts.mode, $opts.name, $opts.capacity);
    }
}

/**
 * The heading on the host's title screen.
 */
export def const TITLE as string init "waiting to start";

/**
 * How often the host publishes a lobby snapshot to its clients, in milliseconds.
 * Often enough that a joining player sees the roster fill, rarely enough that the
 * title screen is not redrawn continuously.
 */
export def const LOBBY_MS as int init 250;

# screenSize is the terminal as it is right now, or a conventional one when there is no
# usable answer - the same fallback the renderer uses, kept here so the size negotiation
# and the drawing can never disagree about how big the screen is.
#
# Two ways there is no answer, and both have to be handled: `term.size` *throws* when
# stdout is not a terminal, and reports zero on a pty opened without a window size. A
# host refuses to start off a terminal, so neither should happen in a real game - but
# this is also the arithmetic the pure sizing functions are fed, and something that
# throws cannot be called from a test.
func screenSize() {
    try {
        def size as term.Size init screen.size();
        if ($size.rows > 0 and $size.cols > 0) {
            return $size;
        }
    } catch (e) {
        return conventionalSize();
    }
    return conventionalSize();
}

# conventionalSize is the 80x24 every terminal has been at least as big as since 1978.
func conventionalSize() {
    return term.Size{rows: view.FALLBACK_ROWS, cols: view.FALLBACK_COLS};
}

# nowMs is the wall clock in milliseconds - the host's only notion of time, used
# to decide when the next tick is due.
func nowMs() {
    return time.unixMillis(time.now());
}

# seedFrom turns a requested seed into a real one: 0 means "surprise me", which
# the clock supplies.
func seedFrom(requested as int) {
    if ($requested != 0) {
        return $requested;
    }
    return time.unixMillis(time.now());
}

# loop is the host's main pass: input, network, discovery, tick, draw, sleep.
func loop(
    start as Table,
    wire as link.Host,
    responder as beacon.Responder,
    input as screen.Input,
    banner as string,
    opts as Options) {
    def table as Table init $start;
    def net as link.Host init $wire;
    def frame as screen.Buffer init screen.newScreen(1, 1);
    def nextTick as int init nowMs();
    def running as bool init true;
    while ($running) {
        def keys as Intent init readKeys($input);
        if ($keys.quit) {
            $net = link.sendAll($net, audience($table), proto.encodeBye("host left"));
            return Finish{table: $table, net: $net, opts: $opts, quit: true};
        }
        if ($keys.back) {
            # Escape goes back one level - to the title screen when there is one behind this
            # game, and out of the program when there is not. `jsnake solo` and
            # `host --now` start straight into a round, so backing out of it has nowhere to
            # land, and dropping a solo player onto a lobby they deliberately skipped would
            # be a worse answer than leaving. `rounds` sets `lobby` for every round after
            # the first, so by then there genuinely is a screen to go back to.
            if (not $opts.lobby) {
                $net = link.sendAll($net, audience($table), proto.encodeBye("host left"));
                return Finish{table: $table, net: $net, opts: $opts, quit: true};
            }
            # Clients are told nothing here: the next lobby carries a higher round number,
            # which is what they follow.
            return Finish{table: $table, net: $net, opts: $opts, quit: false};
        }
        if (len($keys.dir) > 0) {
            $table = steerLocal($table, $keys.dir);
        }
        def turn as Round init exchange($table, $net, $opts);
        $table = $turn.table;
        $net = $turn.net;
        beacon.serve($responder, len($table.players));
        if (nowMs() >= $nextTick) {
            $nextTick = nowMs() + $table.tickMs;
            $table = steerBots($table);
            $table = advance($table);
            def swept as Reaction init sweep(
                $table,
                $table.game.tick,
                IDLE_TICKS,
                $opts.onLeave,
                $opts.botLevel);
            $table = $swept.table;
            $net = deliver($net, $swept);
            $net = link.sendAll($net, audience($table), stateLine($table));
            $frame = paint($frame, $table, banner($table, $banner));
        }
        # A finished game stops being a game. Ticking an empty field for ever with
        # GAME OVER in the corner leaves a host with nothing to do but kill the program,
        # so the round ends here and the standings are shown.
        if (rules.isOver($table.game)) {
            return standings($table, $net, $input, $opts);
        }
        time.sleep(time.fromMilliseconds(IDLE_SLEEP_MS));
    }
    return Finish{table: $table, net: $net, opts: $opts, quit: true};
}

# standings shows the final scores and waits for the host to choose: another round, or
# stop. Clients are left where they are - the next lobby will call them back.
func standings(t as Table, wire as link.Host, input as screen.Input, opts as Options) {
    def size as term.Size init screenSize();
    io.printf(
        "%s%s",
        screen.clear(),
        screen.render(view.message(OVER_TITLE, standingsLines($t), $size.rows, $size.cols)));
    def waiting as bool init true;
    while ($waiting) {
        def k as screen.Key init screen.waitKey($input);
        if (keys.isAbort($k)) {
            def net as link.Host init link.sendAll(
                $wire,
                audience($t),
                proto.encodeBye("host left"));
            return Finish{table: $t, net: $net, opts: $opts, quit: true};
        }
        # Enter and Escape both land on the title screen - one says "another round", the
        # other says "back" - and from there Escape again leaves.
        if (keys.isConfirm($k) or keys.isBack($k)) {
            return Finish{table: $t, net: $wire, opts: $opts, quit: false};
        }
    }
    return Finish{table: $t, net: $wire, opts: $opts, quit: true};
}

/**
 * The heading on the host's end-of-round screen.
 */
export def const OVER_TITLE as string init "jsnake - game over";

/**
 * The final standings, best score first, as body lines for a message screen. Pure, so
 * what a table reads at the end of a round is settled by a test.
 * @param t {Table} the finished table
 * @return {list of string} the lines to draw
 */
export func standingsLines(t as Table) {
    def out as list of string init [];
    def ranked as list of Player init byScore($t);
    for (def i as int init 0; $i < len($ranked); $i = $i + 1) {
        def s as rules.Snake init rules.snakeById($t.game, $ranked[$i].id);
        $out[] = io.sprintf(
            "%d|pad=2  %s|pad=14 %d|pad=6  %d death(s)",
            $i + 1,
            $s.name,
            $s.score,
            $s.deaths);
    }
    if (len($ranked) == 0) {
        $out[] = "nobody played";
    }
    $out[] = "";
    $out[] = "enter  another round      " + keys.ESCAPE_LABEL + "  menu";
    return $out;
}

# byScore ranks the seats, highest score first, ties going to the lower player id so the
# order is stable rather than whatever the list happened to hold.
func byScore(t as Table) {
    def ranked as list of Player init [];
    def taken as map of int to bool init {};
    for (def n as int init 0; $n < len($t.players); $n = $n + 1) {
        def best as int init -1;
        for (def i as int init 0; $i < len($t.players); $i = $i + 1) {
            if (not maps.has($taken, $i) and beats($t, $i, $best)) {
                $best = $i;
            }
        }
        $taken[$best] = true;
        $ranked[] = $t.players[$best];
    }
    return $ranked;
}

# beats reports whether seat `i` should rank above the best found so far.
func beats(t as Table, i as int, best as int) {
    if ($best < 0) {
        return true;
    }
    def mine as int init rules.snakeById($t.game, $t.players[$i].id).score;
    def theirs as int init rules.snakeById($t.game, $t.players[$best].id).score;
    if ($mine != $theirs) {
        return $mine > $theirs;
    }
    return $t.players[$i].id < $t.players[$best].id;
}

# What one pass of the keyboard came to: the last direction pressed, and whether the host
# asked to stop altogether (Ctrl-C) or to back out of this round (Escape).
def struct Intent {
    dir as string,
    quit as bool,
    back as bool
};

# A table and its transport, threaded together through one exchange.
def struct Round {
    table as Table,
    net as link.Host
};

# readKeys drains every key waiting and reduces them to one intent: the last
# direction pressed this pass, and whether the player asked to leave. Draining
# rather than reading one key means a burst of arrows cannot build up a backlog
# that steers the snake several ticks after the fact.
func readKeys(input as screen.Input) {
    def dir as string init "";
    while (screen.hasKey($input)) {
        def k as screen.Key init screen.pollKey($input);
        if (keys.isAbort($k)) {
            return Intent{dir: $dir, quit: true, back: false};
        }
        if (keys.isBack($k)) {
            return Intent{dir: $dir, quit: false, back: true};
        }
        def pressed as string init keys.directionOf($k);
        if (len($pressed) > 0) {
            $dir = $pressed;
        }
    }
    return Intent{dir: $dir, quit: false, back: false};
}

# exchange polls the transport once and applies everything that arrived.
func exchange(t as Table, wire as link.Host, opts as Options) {
    def batch as link.Batch init link.poll($wire);
    def table as Table init $t;
    def net as link.Host init $batch.host;
    for (def peer in $batch.gone) {
        # A socket that closed is a departure nobody chose, so the host's policy
        # decides: the player forfeits, or a computer player takes the snake on.
        $table = onLeave($table, $peer, $opts.onLeave, $opts.botLevel);
    }
    for (def packet in $batch.packets) {
        def r as Reaction init handle($table, $packet.peer, $packet.body, $table.game.tick);
        $table = $r.table;
        $net = deliver($net, $r);
    }
    return Round{table: $table, net: $net};
}

# deliver performs a reaction's I/O: send each reply, then forget each dropped
# peer. This is the whole of the bridge between the pure half and the sockets.
func deliver(wire as link.Host, r as Reaction) {
    def net as link.Host init $wire;
    for (def packet in $r.replies) {
        $net = link.send($net, $packet.peer, $packet.body);
    }
    for (def peer in $r.dropped) {
        $net = link.drop($net, $peer);
    }
    return $net;
}

# paint draws the next frame and writes only what changed since the last one.
func paint(previous as screen.Buffer, t as Table, note as string) {
    def size as term.Size init screenSize();
    def frame as screen.Buffer init view.render(
        $t.game,
        localId($t),
        $note,
        $size.rows,
        $size.cols);
    io.printf("%s", screen.diff($previous, $frame));
    return $frame;
}

# banner is the header note during play: where the host is listening, plus a word when
# every player has spent their last life and the game has nothing left to decide.
func banner(t as Table, listening as string) {
    if (rules.isOver($t.game)) {
        return $listening + "  GAME OVER";
    }
    return $listening;
}

# note is the host's own header line: where it is listening and whether it can be
# found by broadcast. Computed once, since none of it changes while it runs.
func note(wire as link.Host, announcing as bool) {
    # "public" / "private" rather than "discoverable" / "(not discoverable)": the header
    # shares one row with the tick, the player count and - once the game ends - a
    # game-over note, and `screen` clips a row rather than wrapping it. The short words
    # keep the whole line inside 80 columns, which is the narrowest terminal that can
    # host a game at all.
    def where as string init io.sprintf("hosting %s:%d", $wire.mode, $wire.port);
    if ($announcing) {
        return $where + "  public";
    }
    return $where + "  private";
}
