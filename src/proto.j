# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The jsnake wire protocol: one message per line, fields separated by `|`.
 *
 * Everything here is a **pure** string transformation, so the whole protocol -
 * including every way a peer can get it wrong - is testable without opening a
 * socket. `link` moves the bytes, `beacon` moves the discovery datagrams, and
 * neither of them knows what a message means.
 *
 * **Why text.** A snake tick is a few hundred bytes and the field is small, so
 * a line of text costs nothing a binary frame would save, and it can be read
 * with `nc` while debugging a host on the other side of the room. The separator
 * hierarchy is fixed and never nests: `|` between fields, `;` between records
 * in a field, `,` between a record's own values, and a space between the cells
 * of a body, each cell spelled by `geom.key`. A name that could contain any of
 * them is scrubbed by `cleanName` at the door, which is what makes the grammar
 * unambiguous rather than merely usually-unambiguous.
 *
 * **Every decoder is total.** A message arriving from the network is untrusted:
 * decoding one never throws and never blocks. A line that cannot be understood
 * decodes to a message of kind `BAD`, which callers drop. A host that could be
 * stopped by a malformed datagram would not survive its first port scan.
 * @module proto
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./proto.j" as proto;
 * def line as string init proto.encodeDir(3, geom.UP);        # "DIR|3|up"
 * def msg as proto.Message init proto.decode($line);
 * def dir as string init $msg.text;                           # "up"
 */

use strings;
use convert;

import "./geom.j" as geom;
import "./rules.j" as rules;

/**
 * The protocol version both ends must agree on. A peer announcing anything else
 * is refused at the door rather than half-understood.
 */
export def const VERSION as string init "1";

/**
 * The separator between a message's top-level fields.
 */
export def const FIELD_SEPARATOR as string init "|";

/**
 * The separator between the records of one field (snakes, food cells).
 */
export def const RECORD_SEPARATOR as string init ";";

/**
 * The separator between the values inside one record.
 */
export def const VALUE_SEPARATOR as string init ",";

/**
 * The separator between the cells of a snake's body.
 */
export def const CELL_SEPARATOR as string init " ";

/**
 * The line terminator every message ends with on the wire.
 */
export def const LINE_END as string init "\n";

/**
 * An upper bound on the bytes one occupied cell costs in a `STATE` line: its two
 * coordinates, their separator, and a share of the record overhead around them.
 *
 * Measured, not guessed. The worst case is a field entirely covered by snake, split
 * between `rules.MAX_PLAYERS` players so the per-snake overhead repeats as often as
 * possible, at the highest coordinates so every number takes its maximum digits. That
 * comes to 5.92 bytes a cell on a 120 x 48 field; 7 leaves room for the extra digit a
 * wider field adds. `link` divides a datagram by this to decide how large a UDP game
 * may be, and a test checks the real worst case stays under it.
 */
export def const STATE_BYTES_PER_CELL as int init 7;

# The largest field the rules allow, in cells. Declared before the constant below uses
# it: a `def const` is not hoisted, so order matters at the top level.
def const FIELD_CELLS as int init rules.MAX_WIDTH * rules.MAX_HEIGHT;

/**
 * The longest a `STATE` line can be, for the largest field the rules allow. What a
 * stream transport must be willing to buffer.
 */
export def const MAX_STATE_BYTES as int init FIELD_CELLS * STATE_BYTES_PER_CELL;

/**
 * The longest a player name may be, in runes. Long enough to tell players
 * apart in a scoreboard, short enough that eight of them fit one `STATE` line.
 */
export def const MAX_NAME as int init 12;

/**
 * The name given to a player who supplied none.
 */
export def const ANONYMOUS as string init "player";

/**
 * A client asking to join: `JOIN|<version>|<name>|<rows>|<cols>`.
 *
 * The terminal size travels with the join because the host sizes the field to the
 * smallest terminal at the table. A client reports what it *has*, not what field it
 * wants: the layout arithmetic belongs to the host, which is the only party that
 * knows how many scoreboard rows the game will need.
 */
export def const JOIN as string init "JOIN";

/**
 * A host admitting a player: `WELCOME|<id>|<width>|<height>|<tickMs>`.
 */
export def const WELCOME as string init "WELCOME";

/**
 * A host refusing a player: `DENY|<reason>`.
 */
export def const DENY as string init "DENY";

/**
 * A client steering: `DIR|<id>|<direction>`.
 */
export def const DIR as string init "DIR";

/**
 * A client leaving: `QUIT|<id>`.
 */
export def const QUIT as string init "QUIT";

/**
 * A client keepalive: `PING|<id>`. On UDP this is how a host learns a silent
 * player is still there rather than timing them out.
 */
export def const PING as string init "PING";

/**
 * A whole game state: `STATE|<tick>|<w>|<h>|<food>|<snakes>`.
 */
export def const STATE as string init "STATE";

/**
 * The host's waiting room: `LOBBY|<w>|<h>|<tickMs>|<capacity>|<roster>|<round>`, where the
 * roster is a `;`-separated list of `id,name,kind,rows,cols` records and `round` is the
 * game this lobby is setting up.
 *
 * Sent while the host is still setting the game up, so a client can show who else is
 * here and what field everyone has agreed on. The first `STATE` is what says the game
 * has begun - there is no separate "go" message to lose on UDP.
 */
export def const LOBBY as string init "LOBBY";

/**
 * A host ending a player's game: `BYE|<reason>`.
 */
export def const BYE as string init "BYE";

/**
 * A client looking for hosts, broadcast to the discovery port:
 * `QUERY|<version>`.
 */
export def const QUERY as string init "QUERY";

/**
 * A host answering a discovery query:
 * `OFFER|<version>|<port>|<mode>|<name>|<players>|<capacity>`.
 */
export def const OFFER as string init "OFFER";

/**
 * The kind a line decodes to when it is not a message this version knows.
 */
export def const BAD as string init "BAD";

# The characters a name may contain: ASCII letters, digits, and a few marks that
# read as part of a nickname. Raw `'...'`, because the set contains braces.
def const PRINTABLE as string init 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' +
    '0123456789-_+!?*#@=~()[]{}<>^';

/**
 * One decoded message. The fields are a union - which of them carry meaning
 * depends on `kind` - because Jennifer's structs are the cheap shape here and a
 * per-message struct per kind would need a `match` at every call site to reach
 * a single integer.
 *
 * By kind: `JOIN` uses `text` (the name); `WELCOME` uses `id`, `width`,
 * `height`, `tickMs`; `DENY` / `BYE` use `text` (the reason); `DIR` uses `id`
 * and `text` (the direction); `QUIT` / `PING` use `id`; `STATE` uses `game`;
 * `QUERY` uses nothing; `OFFER` uses `port`, `text` (the mode), `name`,
 * `players`, `capacity`; `BAD` uses `text` (the line that failed).
 * @field kind {string} the message kind, one of this module's kind constants
 * @field id {int} the player id a message is about
 * @field text {string} the message's single string payload
 * @field name {string} a host or player name
 * @field width {int} the field width
 * @field height {int} the field height
 * @field tickMs {int} the host's tick period in milliseconds
 * @field port {int} the game port a host offers
 * @field players {int} how many players a host has
 * @field capacity {int} how many players a host accepts
 * @field game {rules.Game} the decoded game state, for `STATE`
 * @field rows {int} a client's terminal rows, for `JOIN`
 * @field cols {int} a client's terminal columns, for `JOIN`
 * @field seats {list of Seat} the roster, for `LOBBY`
 * @field round {int} which game this is about, for `LOBBY` and `STATE`
 */
export def struct Message {
    kind as string,
    id as int,
    text as string,
    name as string,
    width as int,
    height as int,
    tickMs as int,
    port as int,
    players as int,
    capacity as int,
    game as rules.Game,
    rows as int,
    cols as int,
    seats as list of Seat,
    round as int
};

/**
 * One row of a `LOBBY` roster: who is at the table and what their terminal can do.
 * @field id {int} the player id
 * @field name {string} the player's display name
 * @field kind {string} what is driving the seat, as the host spells it
 * @field rows {int} that player's terminal rows, 0 when they did not say
 * @field cols {int} that player's terminal columns, 0 when they did not say
 */
export def struct Seat {
    id as int,
    name as string,
    kind as string,
    rows as int,
    cols as int
};

/**
 * The result of pulling whole lines out of a stream buffer: the lines that were
 * complete, and the partial line still waiting for its terminator.
 * @field lines {list of string} the complete lines, in order, terminators stripped
 * @field rest {string} the trailing partial line to carry into the next read
 */
export def struct Frames {
    lines as list of string,
    rest as string
};

# blank is the zero message every decoder starts from, so a field a kind does
# not use reads as a zero rather than as whatever the last message left there.
func blank(kind as string) {
    return Message{
        kind: $kind,
        id: 0,
        text: "",
        name: "",
        width: 0,
        height: 0,
        tickMs: 0,
        port: 0,
        players: 0,
        capacity: 0,
        game: rules.newGame(rules.MIN_WIDTH, rules.MIN_HEIGHT, 1),
        rows: 0,
        cols: 0,
        seats: [],
        round: 0
    };
}

/**
 * Scrub a player-supplied name into something safe to put in a message and on a
 * scoreboard: the protocol's separators and every control character are
 * dropped, the result is trimmed to `MAX_NAME` runes, and an empty result
 * becomes `ANONYMOUS`.
 *
 * This is the only place a name is sanitized, and it runs on the **host** when
 * a `JOIN` arrives - never trusting that the client did it - which is what lets
 * every other function here assume a name contains no separator.
 * @param raw {string} the name as the player supplied it
 * @return {string} a name safe to encode, never empty
 */
export func cleanName(raw as string) {
    def out as string init "";
    def chars as list of string init strings.chars($raw);
    for (def ch in $chars) {
        if (len($out) >= MAX_NAME) {
            return $out;
        }
        if (isNameSafe($ch)) {
            $out = $out + $ch;
        }
    }
    if (len(strings.trim($out)) == 0) {
        return ANONYMOUS;
    }
    return strings.trim($out);
}

# isNameSafe admits printable ASCII except the four separators - a deliberate
# allowlist, so a character class nobody thought about is excluded by default
# rather than included by accident.
func isNameSafe(ch as string) {
    if ($ch == FIELD_SEPARATOR or $ch == RECORD_SEPARATOR) {
        return false;
    }
    if ($ch == VALUE_SEPARATOR or $ch == CELL_SEPARATOR) {
        return false;
    }
    if ($ch == geom.KEY_SEPARATOR) {
        return false;
    }
    return strings.indexOf(PRINTABLE, $ch) >= 0;
}

/**
 * Split a stream buffer into whole lines plus the leftover partial line. TCP
 * hands over bytes, not messages, so a read can stop mid-line and the next one
 * has to continue it; UDP hands over whole datagrams, which this handles as the
 * degenerate case of a buffer that happens to end on a terminator.
 *
 * Surrounding whitespace - a carriage return from a CRLF peer included - is
 * stripped, and blank lines are dropped rather than decoded into `BAD`.
 * @param buffer {string} everything received and not yet consumed
 * @return {Frames} the complete lines and the partial remainder
 */
export func frames(buffer as string) {
    def lines as list of string init [];
    def parts as list of string init strings.split($buffer, LINE_END);
    for (def i as int init 0; $i < len($parts) - 1; $i = $i + 1) {
        def line as string init strings.trim($parts[$i]);
        if (len($line) > 0) {
            $lines[] = $line;
        }
    }
    return Frames{lines: $lines, rest: $parts[len($parts) - 1]};
}

/**
 * The kind of a line, without decoding the rest of it - the cheap test a
 * dispatcher wants before committing to a full decode.
 * @param line {string} the raw line
 * @return {string} the kind, or `BAD` when the line has no recognizable kind
 */
export func kindOf(line as string) {
    def parts as list of string init strings.split($line, FIELD_SEPARATOR);
    def head as string init strings.trim($parts[0]);
    if (isKnownKind($head)) {
        return $head;
    }
    return BAD;
}

# isKnownKind is the allowlist of message kinds this version speaks.
func isKnownKind(k as string) {
    match ($k) {
        when JOIN, WELCOME, DENY, DIR, QUIT { return true; }
        when PING, STATE, BYE, QUERY, OFFER { return true; }
        when LOBBY { return true; }
        else { return false; }
    }
}

# field reads the field at `idx`, answering "" when the line is shorter than
# that - which is what makes every decoder below total on a truncated message.
func field(parts as list of string, idx as int) {
    if ($idx < 0 or $idx >= len($parts)) {
        return "";
    }
    return $parts[$idx];
}

/**
 * Encode a join request. The name is scrubbed here too, so a client cannot
 * send a name its own scoreboard could not render.
 * @param name {string} the player's requested name
 * @param rows {int} the client's terminal rows
 * @param cols {int} the client's terminal columns
 * @return {string} the `JOIN` line, without its terminator
 */
export func encodeJoin(name as string, rows as int, cols as int) {
    def fields as list of string init [JOIN, VERSION, cleanName($name)];
    $fields[] = convert.toString($rows);
    $fields[] = convert.toString($cols);
    return join($fields);
}

/**
 * Encode the host's admission of a player.
 * @param id {int} the player id assigned
 * @param width {int} the field width in cells
 * @param height {int} the field height in cells
 * @param tickMs {int} the host's tick period in milliseconds
 * @return {string} the `WELCOME` line, without its terminator
 */
export func encodeWelcome(id as int, width as int, height as int, tickMs as int) {
    return join([
        WELCOME,
        convert.toString($id),
        convert.toString($width),
        convert.toString($height),
        convert.toString($tickMs)
    ]);
}

/**
 * Encode a refusal to admit a player.
 * @param reason {string} a short human-readable reason
 * @return {string} the `DENY` line, without its terminator
 */
export func encodeDeny(reason as string) {
    return join([DENY, oneLine($reason)]);
}

/**
 * Encode a steering command.
 * @param id {int} the player id steering
 * @param dir {string} the requested direction, a `geom` direction
 * @return {string} the `DIR` line, without its terminator
 */
export func encodeDir(id as int, dir as string) {
    return join([DIR, convert.toString($id), $dir]);
}

/**
 * Encode a player's departure.
 * @param id {int} the departing player's id
 * @return {string} the `QUIT` line, without its terminator
 */
export func encodeQuit(id as int) {
    return join([QUIT, convert.toString($id)]);
}

/**
 * Encode a keepalive.
 * @param id {int} the player id still present
 * @return {string} the `PING` line, without its terminator
 */
export func encodePing(id as int) {
    return join([PING, convert.toString($id)]);
}

/**
 * Encode the host ending a player's game.
 * @param reason {string} a short human-readable reason
 * @return {string} the `BYE` line, without its terminator
 */
export func encodeBye(reason as string) {
    return join([BYE, oneLine($reason)]);
}

/**
 * Encode a discovery query, the datagram a client broadcasts to find hosts.
 * @return {string} the `QUERY` line, without its terminator
 */
export func encodeQuery() {
    return join([QUERY, VERSION]);
}

/**
 * Encode a host's answer to a discovery query.
 * @param port {int} the port the host's game is listening on
 * @param mode {string} the transport the game uses, `"tcp"` or `"udp"`
 * @param name {string} the host's display name
 * @param players {int} how many players are connected now
 * @param capacity {int} how many players the host accepts in total
 * @return {string} the `OFFER` line, without its terminator
 */
export func encodeOffer(
    port as int,
    mode as string,
    name as string,
    players as int,
    capacity as int) {
    return join([
        OFFER,
        VERSION,
        convert.toString($port),
        $mode,
        cleanName($name),
        convert.toString($players),
        convert.toString($capacity)
    ]);
}

/**
 * Encode the host's waiting room.
 * @param width {int} the field width everyone has agreed on so far
 * @param height {int} the field height everyone has agreed on so far
 * @param tickMs {int} the tick period the host has set
 * @param capacity {int} how many players the host will seat
 * @param seats {list of Seat} who is at the table
 * @param round {int} the round this lobby is setting up, counted from 1
 * @return {string} the `LOBBY` line, without its terminator
 */
export func encodeLobby(
    width as int,
    height as int,
    tickMs as int,
    capacity as int,
    seats as list of Seat,
    round as int) {
    return join([
        LOBBY,
        convert.toString($width),
        convert.toString($height),
        convert.toString($tickMs),
        convert.toString($capacity),
        encodeSeats($seats),
        convert.toString($round)
    ]);
}

# encodeSeats spells the roster as one record per seat.
func encodeSeats(seats as list of Seat) {
    def records as list of string init [];
    for (def s in $seats) {
        $records[] = strings.join(
            [
                convert.toString($s.id),
                cleanName($s.name),
                $s.kind,
                convert.toString($s.rows),
                convert.toString($s.cols)
            ],
            VALUE_SEPARATOR);
    }
    return strings.join($records, RECORD_SEPARATOR);
}

# decodeSeats reads the roster back, skipping any record too short to be one.
func decodeSeats(text as string) {
    def seats as list of Seat init [];
    if (len($text) == 0) {
        return $seats;
    }
    for (def record in strings.split($text, RECORD_SEPARATOR)) {
        def values as list of string init strings.split($record, VALUE_SEPARATOR);
        if (len($values) >= 3) {
            $seats[] = Seat{
                id: geom.toIntOr($values[0], 0),
                name: $values[1],
                kind: $values[2],
                rows: geom.toIntOr(field($values, 3), 0),
                cols: geom.toIntOr(field($values, 4), 0)
            };
        }
    }
    return $seats;
}

func decodeLobby(parts as list of string) {
    def m as Message init blank(LOBBY);
    $m.width = geom.toIntOr(field($parts, 1), rules.MIN_WIDTH);
    $m.height = geom.toIntOr(field($parts, 2), rules.MIN_HEIGHT);
    $m.tickMs = geom.toIntOr(field($parts, 3), 0);
    $m.capacity = geom.toIntOr(field($parts, 4), 0);
    $m.seats = decodeSeats(field($parts, 5));
    $m.round = geom.toIntOr(field($parts, 6), 0);
    return $m;
}

/**
 * Encode a whole game state - the message a host sends every tick.
 *
 * The food field is a `;`-separated list of `kind,cell,life` records - the cell
 * spelled by `geom.key` and `life` the ticks it has left, `0` for food that stays.
 * A record holding only a cell key reads as plain food, so the terse form a
 * hand-typed test or a `nc` session produces still works. The snake field is a
 * `;`-separated list of `id,name,alive,score,deaths,dir,cells` records, where
 * `cells` is a space-separated list of cell keys running head first. A dead
 * snake has an empty cell list, which is exactly how `decodeState` reads it
 * back, so death needs no flag of its own beyond `alive`.
 *
 * The game's own `lives` setting is the last field rather than an early one, so adding
 * it did not move anything already in the line.
 * @param g {rules.Game} the state to send
 * @return {string} the `STATE` line, without its terminator
 */
export func encodeState(g as rules.Game) {
    return join([
        STATE,
        convert.toString($g.tick),
        convert.toString($g.width),
        convert.toString($g.height),
        encodeFood($g.food),
        encodeSnakes($g.snakes),
        convert.toString($g.lives),
        convert.toString($g.round)
    ]);
}

# encodeFood spells each item as `kind,cell,life`.
func encodeFood(food as list of rules.Item) {
    def records as list of string init [];
    for (def f in $food) {
        $records[] = strings.join(
            [$f.kind, geom.key($f.cell), convert.toString($f.life)],
            VALUE_SEPARATOR);
    }
    return strings.join($records, RECORD_SEPARATOR);
}

# decodeFood reads the food field back. A record is `kind,cell,life`; one holding a
# bare cell key is plain food, and a kind this version does not know reads as plain
# food too, so an item from a newer peer is a crumb rather than a crash.
func decodeFood(text as string) {
    def food as list of rules.Item init [];
    if (len($text) == 0) {
        return $food;
    }
    for (def record in strings.split($text, RECORD_SEPARATOR)) {
        if (len($record) > 0) {
            def values as list of string init strings.split($record, VALUE_SEPARATOR);
            if (len($values) == 1) {
                $food[] = rules.plainFood(geom.fromKey($values[0]));
            } else {
                $food[] = rules.Item{
                    kind: knownKind($values[0]),
                    cell: geom.fromKey($values[1]),
                    life: geom.toIntOr(field($values, 2), rules.PERMANENT)
                };
            }
        }
    }
    return $food;
}

# knownKind keeps an unrecognised kind out of the game state entirely, so nothing
# downstream has to guard against one.
func knownKind(kind as string) {
    if (rules.isFoodKind($kind)) {
        return $kind;
    }
    return rules.PLAIN;
}

# encodeCells spells a cell list with the given separator between cells.
func encodeCells(cells as list of geom.Point, separator as string) {
    def keys as list of string init [];
    for (def c in $cells) {
        $keys[] = geom.key($c);
    }
    return strings.join($keys, $separator);
}

# encodeSnakes spells the snake roster as one record per snake. The ghost timer
# travels with it so a client can show that a snake is currently untouchable - a
# player needs to know that about the snake heading for them.
func encodeSnakes(snakes as list of rules.Snake) {
    def records as list of string init [];
    for (def s in $snakes) {
        $records[] = strings.join(
            [
                convert.toString($s.id),
                $s.name,
                boolDigit($s.alive),
                convert.toString($s.score),
                convert.toString($s.deaths),
                $s.dir,
                convert.toString($s.ghost),
                convert.toString($s.lives),
                encodeCells($s.cells, CELL_SEPARATOR)
            ],
            VALUE_SEPARATOR);
    }
    return strings.join($records, RECORD_SEPARATOR);
}

# boolDigit / digitBool are the wire spelling of a bool: one character, so a
# roster of eight snakes does not spend 32 bytes saying "true".
func boolDigit(b as bool) {
    if ($b) {
        return "1";
    }
    return "0";
}

func digitBool(s as string) {
    return $s == "1";
}

# join assembles a message from its fields.
func join(fields as list of string) {
    return strings.join($fields, FIELD_SEPARATOR);
}

# oneLine flattens anything that would break the one-message-per-line rule or
# the field grammar, so a reason string can be written by a human without
# thinking about the wire format.
func oneLine(s as string) {
    def out as string init strings.replace($s, LINE_END, " ");
    $out = strings.replace($out, "\r", " ");
    return strings.replace($out, FIELD_SEPARATOR, "/");
}

/**
 * Decode one line into a `Message`. Total: any line at all decodes to
 * something, and a line this version does not understand decodes to kind `BAD`
 * with the offending text in `text`.
 *
 * A `JOIN`, `QUERY`, or `OFFER` carrying a protocol version other than
 * `VERSION` decodes to `BAD` as well - version skew is a refusal, not a
 * best-effort parse of fields that may have moved.
 * @param line {string} the raw line, with or without its terminator
 * @return {Message} the decoded message
 */
export func decode(line as string) {
    def trimmed as string init strings.trim($line);
    def parts as list of string init strings.split($trimmed, FIELD_SEPARATOR);
    def kind as string init strings.trim(field($parts, 0));
    if (not isKnownKind($kind)) {
        return bad($trimmed);
    }
    match ($kind) {
        when JOIN { return decodeJoin($parts, $trimmed); }
        when WELCOME { return decodeWelcome($parts); }
        when DENY, BYE { return decodeReason($kind, $parts); }
        when DIR { return decodeDir($parts); }
        when QUIT, PING { return decodeIdOnly($kind, $parts); }
        when STATE { return decodeState($parts); }
        when LOBBY { return decodeLobby($parts); }
        when QUERY { return decodeQuery($parts, $trimmed); }
        when OFFER { return decodeOffer($parts, $trimmed); }
        else { return bad($trimmed); }
    }
}

# bad wraps an unusable line so a caller can log what it dropped.
func bad(line as string) {
    def m as Message init blank(BAD);
    $m.text = $line;
    return $m;
}

func decodeJoin(parts as list of string, line as string) {
    if (field($parts, 1) != VERSION) {
        return bad($line);
    }
    def m as Message init blank(JOIN);
    $m.text = cleanName(field($parts, 2));
    $m.name = $m.text;
    $m.rows = geom.toIntOr(field($parts, 3), 0);
    $m.cols = geom.toIntOr(field($parts, 4), 0);
    return $m;
}

func decodeWelcome(parts as list of string) {
    def m as Message init blank(WELCOME);
    $m.id = geom.toIntOr(field($parts, 1), 0);
    $m.width = geom.toIntOr(field($parts, 2), 0);
    $m.height = geom.toIntOr(field($parts, 3), 0);
    $m.tickMs = geom.toIntOr(field($parts, 4), 0);
    return $m;
}

func decodeReason(kind as string, parts as list of string) {
    def m as Message init blank($kind);
    $m.text = field($parts, 1);
    return $m;
}

func decodeDir(parts as list of string) {
    def m as Message init blank(DIR);
    $m.id = geom.toIntOr(field($parts, 1), 0);
    $m.text = field($parts, 2);
    return $m;
}

func decodeIdOnly(kind as string, parts as list of string) {
    def m as Message init blank($kind);
    $m.id = geom.toIntOr(field($parts, 1), 0);
    return $m;
}

func decodeQuery(parts as list of string, line as string) {
    if (field($parts, 1) != VERSION) {
        return bad($line);
    }
    return blank(QUERY);
}

func decodeOffer(parts as list of string, line as string) {
    if (field($parts, 1) != VERSION) {
        return bad($line);
    }
    def m as Message init blank(OFFER);
    $m.port = geom.toIntOr(field($parts, 2), 0);
    $m.text = field($parts, 3);
    $m.name = field($parts, 4);
    $m.players = geom.toIntOr(field($parts, 5), 0);
    $m.capacity = geom.toIntOr(field($parts, 6), 0);
    return $m;
}

# decodeState rebuilds a whole game. The field dimensions go through
# `rules.newGame`, so a peer cannot announce a 2-billion-cell field and make the
# renderer allocate it; everything else is read tolerantly.
func decodeState(parts as list of string) {
    def m as Message init blank(STATE);
    def width as int init geom.toIntOr(field($parts, 2), rules.MIN_WIDTH);
    def height as int init geom.toIntOr(field($parts, 3), rules.MIN_HEIGHT);
    def g as rules.Game init rules.newGame($width, $height, 1);
    $g.tick = geom.toIntOr(field($parts, 1), 0);
    $g = rules.withLives($g, rules.UNLIMITED_LIVES);
    $g.lives = geom.toIntOr(field($parts, 6), rules.UNLIMITED_LIVES);
    $g.round = geom.toIntOr(field($parts, 7), 0);
    $g.food = decodeFood(field($parts, 4));
    $g.snakes = decodeSnakes(field($parts, 5));
    $m.game = $g;
    $m.width = $g.width;
    $m.height = $g.height;
    $m.round = $g.round;
    return $m;
}

# decodeCells reads a separated list of cell keys, skipping empty entries so a
# trailing or doubled separator is harmless.
func decodeCells(text as string, separator as string) {
    def cells as list of geom.Point init [];
    if (len($text) == 0) {
        return $cells;
    }
    for (def part in strings.split($text, $separator)) {
        if (len($part) > 0) {
            $cells[] = geom.fromKey($part);
        }
    }
    return $cells;
}

# decodeSnakes reads the roster, skipping any record too short to be one.
func decodeSnakes(text as string) {
    def snakes as list of rules.Snake init [];
    if (len($text) == 0) {
        return $snakes;
    }
    for (def record in strings.split($text, RECORD_SEPARATOR)) {
        def values as list of string init strings.split($record, VALUE_SEPARATOR);
        if (len($values) >= 9) {
            $snakes[] = rules.Snake{
                id: geom.toIntOr($values[0], 0),
                name: $values[1],
                cells: decodeCells($values[8], CELL_SEPARATOR),
                dir: $values[5],
                alive: digitBool($values[2]),
                score: geom.toIntOr($values[3], 0),
                deaths: geom.toIntOr($values[4], 0),
                respawn: 0,
                grow: 0,
                ghost: geom.toIntOr($values[6], 0),
                lives: geom.toIntOr($values[7], 0)
            };
        }
    }
    return $snakes;
}

/**
 * A message with its line terminator, ready to hand to `link`. Every send site
 * goes through here rather than appending `LINE_END` itself, so framing is
 * decided in exactly one place.
 * @param line {string} the encoded message
 * @return {string} the message plus its terminator
 */
export func wire(line as string) {
    return $line + LINE_END;
}
