# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * Message transport for jsnake, over **either TCP or UDP**, behind one surface.
 * `proto` says what a message means; this module moves it and nothing else.
 *
 * **The shape of the loop.** A game cannot block on the network: the host has to
 * tick on a timer whether or not a player pressed anything, and the client has
 * to keep drawing. So reading here is a *poll with a deadline*, never a blocking
 * read: `net.setReadDeadline` arms a short timer, the read runs, and a timeout is
 * the ordinary "nothing waiting yet" answer rather than an error. That keeps the
 * whole data path on one flow of control - no reader task per peer, no shared
 * mutable state, nothing to race.
 *
 * The one thing that cannot be polled is `net.accept`, which has no deadline of
 * its own. A TCP host therefore spawns exactly one acceptor task that does
 * nothing but accept and hand the connection down a channel. `net.Conn` is an
 * integer handle whose underlying state is shared between copies, so the main
 * loop can read and write the connection the acceptor gave it.
 *
 * **Telling "nothing yet" from "gone".** With a deadline armed, a read that
 * times out means the peer is quiet; a read that returns **zero bytes** means
 * the peer has closed. Both are ordinary events in a game, and distinguishing
 * them is what lets a host drop a player who walked away without mistaking a
 * quiet one for a dead one.
 *
 * **What UDP gives up.** Datagrams may be lost, duplicated, or reordered. That
 * is survivable here precisely because a `STATE` message is a complete picture
 * rather than a delta: a lost tick is a dropped frame, and the next one repairs
 * it. Steering is idempotent for the same reason. This is why UDP is offered at
 * all, and why the protocol carries no sequence numbers.
 * @module link
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./link.j" as link;
 * def h as link.Host init link.listen(link.UDP, 47475);
 * def batch as link.Batch init link.poll($h);
 * for (def p in $batch.packets) {
 *     $batch.host = link.send($batch.host, $p.peer, "PING|1");
 * }
 */

use net;
use task;
use channel;
use convert;
use strings;
use maps;

import "./proto.j" as proto;

/**
 * The TCP transport: a stream per player, reliable and ordered.
 */
export def const TCP as string init "tcp";

/**
 * The UDP transport: one datagram per message, connectionless.
 */
export def const UDP as string init "udp";

/**
 * The port a jsnake host listens on for the game itself, unless told otherwise.
 */
export def const DEFAULT_PORT as int init 47475;

/**
 * The largest payload a UDP datagram can carry: 65535 less the 8-byte UDP header and
 * the 20-byte IPv4 header.
 */
export def const MAX_DATAGRAM as int init 65507;

/**
 * The read buffer size, deliberately larger than `MAX_DATAGRAM`.
 *
 * This matters more than it looks. A UDP read with a buffer smaller than the datagram
 * does not leave the remainder for the next read - the kernel **discards** it, so a
 * `STATE` line longer than the buffer arrives truncated, fails to decode, and is
 * dropped. The visible symptom is a client whose screen freezes while the game carries
 * on, and only on a large, busy field. Sizing the buffer past the largest datagram
 * that can exist removes the failure mode rather than making it rare.
 */
export def const READ_SIZE as int init 65536;

/**
 * How long a poll waits for data before reporting that nothing arrived. Short
 * enough not to eat into a tick, long enough that a packet already on its way
 * is usually seen this pass rather than the next.
 */
export def const POLL_MS as int init 2;

/**
 * The connection backlog the TCP acceptor task may run ahead by. A host that is
 * busy ticking still collects arrivals rather than making them wait on accept.
 */
export def const ACCEPT_BACKLOG as int init 16;

/**
 * The cap on how much unterminated text one peer may leave buffered. A peer that
 * streams megabytes with no newline is trying to exhaust the host's memory, not
 * to play; its buffer is dropped instead of grown.
 *
 * It has to exceed `proto.MAX_STATE_BYTES`, or a legitimate `STATE` line for a large
 * field would be mistaken for a flood and thrown away. A test asserts that it does.
 */
export def const MAX_BUFFER as int init 262144;

/**
 * The largest field, in cells, a game on this transport can describe - or `0` for "no
 * limit", which is what a stream transport means.
 *
 * On UDP a whole `STATE` line has to fit one datagram, so the field area is bounded by
 * `MAX_DATAGRAM` divided by what a cell costs. On TCP there is no datagram: the line is
 * framed by its terminator and reassembled across reads, so a field is limited only by
 * what the terminals at the table can show.
 *
 * The limit lives here rather than in `rules` because it is a property of the transport,
 * not of the game.
 * @param mode {string} the transport, `TCP` or `UDP`
 * @return {int} the maximum field area in cells, or 0 for unlimited
 */
export func maxFieldArea(mode as string) {
    if ($mode == UDP) {
        return MAX_DATAGRAM // proto.STATE_BYTES_PER_CELL;
    }
    return 0;
}

/**
 * Whether the host supports both transports on this build. The `net` library is
 * absent from `jennifer-tiny`, which is why this module declares the `net`
 * capability in its header.
 */
export def const TRANSPORTS as list of string init [TCP, UDP];

/**
 * One inbound message with the peer it came from. `peer` is opaque to callers:
 * it is whatever `send` needs to answer, a `"host:port"` for UDP and a
 * connection tag for TCP. Compare peers for equality, never parse them.
 * @field peer {string} the opaque address to answer on
 * @field body {string} one decoded line, terminator stripped
 */
export def struct Packet {
    peer as string,
    body as string
};

/**
 * A listening host: the sockets, the peers it has seen, and the partial lines it
 * is still assembling. Value-semantic, so every function that changes it returns
 * a new one - thread it through the loop rather than expecting a mutation.
 * @field mode {string} the transport, `TCP` or `UDP`
 * @field udp {net.UDPSocket} the datagram socket; unused in TCP mode
 * @field listener {net.Listener} the stream listener; unused in UDP mode
 * @field arrivals {channel of net.Conn} connections the acceptor task has taken
 * @field conns {map of string to int} peer tag to connection handle id, TCP only
 * @field buffers {map of string to string} peer tag to its unterminated tail
 * @field port {int} the port actually bound, useful when 0 was requested
 */
export def struct Host {
    mode as string,
    udp as net.UDPSocket,
    listener as net.Listener,
    arrivals as channel of net.Conn,
    conns as map of string to int,
    buffers as map of string to string,
    port as int
};

/**
 * A host and the messages one poll of it produced. Jennifer returns one value
 * and a poll changes the host (buffers fill, peers arrive and leave), so the
 * pair travels together.
 * @field host {Host} the host, with its buffers and peer table advanced
 * @field packets {list of Packet} everything that arrived this poll, in order
 * @field gone {list of string} peers that closed during this poll
 */
export def struct Batch {
    host as Host,
    packets as list of Packet,
    gone as list of string
};

/**
 * A client's end of the link.
 * @field mode {string} the transport, `TCP` or `UDP`
 * @field udp {net.UDPSocket} the datagram socket; unused in TCP mode
 * @field conn {net.Conn} the stream connection; unused in UDP mode
 * @field server {string} the host's `"host:port"`, the UDP send target
 * @field buffer {string} the unterminated tail of the inbound stream
 * @field open {bool} false once the host has closed or the link has been closed
 */
export def struct Client {
    mode as string,
    udp as net.UDPSocket,
    conn as net.Conn,
    server as string,
    buffer as string,
    open as bool
};

/**
 * A client and the messages one poll of it produced.
 * @field client {Client} the client, with its buffer advanced and `open` current
 * @field lines {list of string} everything that arrived this poll, in order
 */
export def struct Inbox {
    client as Client,
    lines as list of string
};

# One non-blocking read's worth of input. `more` says whether another read is
# worth trying this pass; `open` carries the peer's liveness, since a read of
# zero bytes is how a closed peer announces itself.
def struct Chunk {
    text as string,
    open as bool,
    more as bool
};

# readConn does one deadline-bounded read on a stream connection. The three
# outcomes a game loop has to tell apart, in one place: bytes arrived, the peer
# is quiet (a timeout), or the peer has closed (a read of zero bytes).
func readConn(conn as net.Conn, open as bool) {
    net.setReadDeadline($conn, POLL_MS);
    # Cleared on every exit path, including the throwing one, so the socket is left in a
    # known state rather than carrying an expired deadline into whatever reads it next.
    defer net.setReadDeadline($conn, 0);
    try {
        def raw as bytes init net.readBytes($conn, READ_SIZE);
        if (len($raw) == 0) {
            return Chunk{text: "", open: false, more: false};
        }
        return Chunk{text: decodeUtf8($raw), open: $open, more: true};
    } catch (e) {
        return Chunk{text: "", open: $open, more: false};
    }
}

# capped refuses to let one peer's unterminated tail grow without bound: past the
# cap the buffer is discarded, because a peer streaming megabytes with no newline
# is exhausting the host's memory rather than playing.
func capped(buffer as string) {
    if (len($buffer) > MAX_BUFFER) {
        return "";
    }
    return $buffer;
}

# closeQuietly closes a connection handle and ignores a failure: the only way a
# close fails is that the peer is already gone, which is the state we wanted.
func closeQuietly(id as int) {
    try {
        net.close(net.Conn{id: $id});
    } catch (e) {
        return;
    }
    return;
}

/**
 * Whether `mode` names a transport this module implements.
 * @param mode {string} the candidate transport name
 * @return {bool} true for `TCP` or `UDP`
 */
export func isTransport(mode as string) {
    return $mode == TCP or $mode == UDP;
}

/**
 * The opaque peer tag for a TCP connection handle. Tagged rather than addressed
 * by `"host:port"` because two connections from one NAT share a source address
 * on UDP but never share a handle on TCP.
 * @param id {int} the connection handle id
 * @return {string} the peer tag
 */
export func connPeer(id as int) {
    return "c" + convert.toString($id);
}

/**
 * Start listening for players on `port` using transport `mode`. A `port` of 0
 * asks the kernel for a free one, which the returned `Host` reports in `port` -
 * how the tests get a real host without fighting over a fixed number.
 *
 * In TCP mode this also spawns the one acceptor task the module needs. The task
 * is deliberately discarded: it blocks in `net.accept`, which no cancellation
 * can interrupt, so it is left to be reaped when the program exits.
 * @param mode {string} the transport, `TCP` or `UDP`
 * @param port {int} the port to bind, or 0 for any free port
 * @return {Host} the listening host
 * @throws {Error} kind "value" for an unknown transport, or a `net` error when the bind fails
 */
export func listen(mode as string, port as int) {
    if (not isTransport($mode)) {
        throw Error{
            kind: "value",
            message: "link.listen: unknown transport: " + $mode,
            file: "",
            line: 0,
            col: 0
        };
    }
    def address as string init ":" + convert.toString($port);
    if ($mode == UDP) {
        def sock as net.UDPSocket init net.listenUDP($address);
        return Host{
            mode: UDP,
            udp: $sock,
            listener: net.Listener{id: 0},
            arrivals: channel.make(1),
            conns: {},
            buffers: {},
            port: portOf(net.address($sock))
        };
    }
    def listener as net.Listener init net.listen($address);
    def arrivals as channel of net.Conn init channel.make(ACCEPT_BACKLOG);
    def acceptor as task of null init spawn {
        def running as bool init true;
        while ($running) {
            channel.send($arrivals, net.accept($listener));
        }
    };
    task.discard($acceptor);
    return Host{
        mode: TCP,
        udp: net.UDPSocket{id: 0},
        listener: $listener,
        arrivals: $arrivals,
        conns: {},
        buffers: {},
        port: portOf(net.address($listener))
    };
}

/**
 * The port number from a `"host:port"` address, or 0 when there is none. IPv6
 * addresses carry colons of their own, so the port is read from the last one.
 * @param address {string} an address as `net.address` spells it
 * @return {int} the port, or 0
 */
export func portOf(address as string) {
    def parts as list of string init strings.split($address, ":");
    if (len($parts) < 2) {
        return 0;
    }
    return geomIntOr($parts[len($parts) - 1]);
}

/**
 * The host part of a `"host:port"` address - everything before the last colon,
 * so an IPv6 address keeps its own colons and its brackets.
 * @param address {string} an address as `net.address` spells it
 * @return {string} the host part, or the whole string when there is no port
 */
export func hostOf(address as string) {
    def cut as int init lastColon($address);
    if ($cut < 0) {
        return $address;
    }
    return strings.substring($address, 0, $cut);
}

# lastColon is the rune index of the final ":" in s, or -1 when there is none.
func lastColon(s as string) {
    def chars as list of string init strings.chars($s);
    for (def i as int init len($chars) - 1; $i >= 0; $i = $i - 1) {
        if ($chars[$i] == ":") {
            return $i;
        }
    }
    return -1;
}

/**
 * The `"host:port"` address built from its two parts.
 * @param host {string} the host part, as `hostOf` returns it
 * @param port {int} the port number
 * @return {string} the joined address
 */
export func address(host as string, port as int) {
    return $host + ":" + convert.toString($port);
}

# geomIntOr keeps the tolerant integer read in one place without pulling geom
# into this module's imports just for it.
func geomIntOr(s as string) {
    try {
        return convert.toInt($s);
    } catch (e) {
        return 0;
    }
}

/**
 * Collect everything waiting for the host: new TCP connections, then one pass of
 * reads over every peer. Returns promptly whether or not anything arrived, so a
 * host can call this once per tick.
 * @param h {Host} the listening host
 * @return {Batch} the host advanced, the messages that arrived, and the peers that left
 */
export func poll(h as Host) {
    if ($h.mode == UDP) {
        return pollUdp($h);
    }
    return pollTcp($h);
}

# pollUdp drains the datagram socket until a read times out. Each datagram is a
# whole message (or several), so no buffer has to survive between calls.
func pollUdp(h as Host) {
    def out as Host init $h;
    # See readConn: the drain below leaves an expired read deadline on the socket, so it
    # is cleared on the way out.
    defer net.setReadDeadline($out.udp, 0);
    def packets as list of Packet init [];
    def draining as bool init true;
    while ($draining) {
        net.setReadDeadline($out.udp, POLL_MS);
        try {
            def d as net.Datagram init net.recvFrom($out.udp, READ_SIZE);
            def text as string init decodeUtf8($d.data);
            def f as proto.Frames init proto.frames($text + proto.LINE_END);
            for (def line in $f.lines) {
                $packets[] = Packet{peer: $d.peer, body: $line};
            }
        } catch (e) {
            $draining = false;
        }
    }
    return Batch{host: $out, packets: $packets, gone: []};
}

# pollTcp takes the acceptor's new connections, then reads one pass over each
# known connection, closing the ones that have gone.
func pollTcp(h as Host) {
    def out as Host init accepted($h);
    def packets as list of Packet init [];
    def gone as list of string init [];
    for (def peer in $out.conns) {
        def chunk as Chunk init readConn(net.Conn{id: $out.conns[$peer]}, true);
        if (not $chunk.open) {
            $gone[] = $peer;
        } else {
            def f as proto.Frames init proto.frames(capped(bufferOf($out, $peer) + $chunk.text));
            $out.buffers[$peer] = $f.rest;
            for (def line in $f.lines) {
                $packets[] = Packet{peer: $peer, body: $line};
            }
        }
    }
    for (def peer in $gone) {
        $out = drop($out, $peer);
    }
    return Batch{host: $out, packets: $packets, gone: $gone};
}

# accepted moves every connection the acceptor task has taken into the peer
# table. Non-blocking: only what is already queued is collected.
func accepted(h as Host) {
    def out as Host init $h;
    while (channel.len($out.arrivals) > 0) {
        def conn as net.Conn init channel.recv($out.arrivals);
        def peer as string init connPeer($conn.id);
        $out.conns[$peer] = $conn.id;
        $out.buffers[$peer] = "";
    }
    return $out;
}

# bufferOf is the peer's unterminated tail, or "" for a peer with none yet.
func bufferOf(h as Host, peer as string) {
    if (maps.has($h.buffers, $peer)) {
        return $h.buffers[$peer];
    }
    return "";
}

/**
 * Send one message to one peer. The message is framed by `proto.wire`, so
 * callers pass an encoded line and never think about terminators.
 *
 * A send to a peer that has gone is not an error the caller has to handle: the
 * peer is dropped from the host and the returned `Host` simply no longer has it.
 * A player pulling out a network cable is ordinary, and a game loop should not
 * need a `try` around every reply.
 * @param h {Host} the host
 * @param peer {string} the peer tag to answer, as a `Packet` carried it
 * @param line {string} the encoded message, without its terminator
 * @return {Host} the host, less the peer when the send failed
 */
export func send(h as Host, peer as string, line as string) {
    def payload as bytes init convert.bytesFromString(proto.wire($line), "utf-8");
    if ($h.mode == UDP) {
        try {
            net.sendTo($h.udp, $peer, $payload);
        } catch (e) {
            return $h;
        }
        return $h;
    }
    if (not maps.has($h.conns, $peer)) {
        return $h;
    }
    try {
        net.writeBytes(net.Conn{id: $h.conns[$peer]}, $payload);
    } catch (e) {
        return drop($h, $peer);
    }
    return $h;
}

/**
 * Send one message to every peer in `peers` - the host's per-tick broadcast.
 * @param h {Host} the host
 * @param peers {list of string} the peer tags to send to
 * @param line {string} the encoded message, without its terminator
 * @return {Host} the host, less any peer whose send failed
 */
export func sendAll(h as Host, peers as list of string, line as string) {
    def out as Host init $h;
    for (def peer in $peers) {
        $out = send($out, $peer, $line);
    }
    return $out;
}

/**
 * Forget a peer, closing its connection in TCP mode. Idempotent, so a caller
 * that drops a peer twice - once on a read that came back empty and once on the
 * `QUIT` that preceded it - is fine.
 * @param h {Host} the host
 * @param peer {string} the peer tag to forget
 * @return {Host} the host without that peer
 */
export func drop(h as Host, peer as string) {
    def out as Host init $h;
    if (maps.has($out.conns, $peer)) {
        closeQuietly($out.conns[$peer]);
        $out.conns = maps.delete($out.conns, $peer);
    }
    if (maps.has($out.buffers, $peer)) {
        $out.buffers = maps.delete($out.buffers, $peer);
    }
    return $out;
}

/**
 * Stop listening and close everything the host holds.
 * @param h {Host} the host to shut down
 * @return {null} nothing
 */
export func close(h as Host) {
    for (def peer in $h.conns) {
        closeQuietly($h.conns[$peer]);
    }
    try {
        if ($h.mode == UDP) {
            net.close($h.udp);
        } else {
            net.close($h.listener);
        }
    } catch (e) {
        return;
    }
    return;
}

/**
 * Connect to a host at `address` (`"host:port"`) using transport `mode`.
 *
 * UDP has no connection to make, so this binds a local socket and remembers
 * where to send; the host learns the client's address from its first datagram.
 * TCP dials, bounded by `timeoutMs` so an unreachable host fails promptly
 * instead of hanging the program before it has drawn anything.
 * @param mode {string} the transport, `TCP` or `UDP`
 * @param address {string} the host's `"host:port"`
 * @param timeoutMs {int} how long to allow the TCP dial, in milliseconds
 * @return {Client} the connected client
 * @throws {Error} kind "value" for an unknown transport, or a `net` error when the dial fails
 */
export func dial(mode as string, address as string, timeoutMs as int) {
    if (not isTransport($mode)) {
        throw Error{
            kind: "value",
            message: "link.dial: unknown transport: " + $mode,
            file: "",
            line: 0,
            col: 0
        };
    }
    if ($mode == UDP) {
        return Client{
            mode: UDP,
            udp: net.listenUDP(":0"),
            conn: net.Conn{id: 0},
            server: $address,
            buffer: "",
            open: true
        };
    }
    return Client{
        mode: TCP,
        udp: net.UDPSocket{id: 0},
        conn: net.connect($address, $timeoutMs),
        server: $address,
        buffer: "",
        open: true
    };
}

/**
 * A client that is not connected to anything - what `dial` would have returned if
 * it had succeeded, but closed. Callers that want to report a refused connection
 * as a screen rather than as a thrown error use this, so the zero socket handles
 * stay a detail of this module instead of being fabricated elsewhere.
 * @param mode {string} the transport that was attempted
 * @param address {string} the address that was attempted, for the message
 * @return {Client} a closed client; `tell` and `listenFor` on it do nothing
 */
export func closedClient(mode as string, address as string) {
    return Client{
        mode: $mode,
        udp: net.UDPSocket{id: 0},
        conn: net.Conn{id: 0},
        server: $address,
        buffer: "",
        open: false
    };
}

/**
 * Send one message to the host. A failed send closes the client rather than
 * throwing, so the game loop's next pass sees `open` is false and says so.
 * @param c {Client} the client
 * @param line {string} the encoded message, without its terminator
 * @return {Client} the client, closed when the send failed
 */
export func tell(c as Client, line as string) {
    if (not $c.open) {
        return $c;
    }
    def out as Client init $c;
    def payload as bytes init convert.bytesFromString(proto.wire($line), "utf-8");
    try {
        if ($out.mode == UDP) {
            net.sendTo($out.udp, $out.server, $payload);
        } else {
            net.writeBytes($out.conn, $payload);
        }
    } catch (e) {
        $out.open = false;
    }
    return $out;
}

/**
 * Collect everything the host has sent, without blocking. A read that comes
 * back empty means the host has closed, which clears `open`.
 * @param c {Client} the client
 * @return {Inbox} the client advanced, and the lines that arrived
 */
export func listenFor(c as Client) {
    def out as Client init $c;
    def lines as list of string init [];
    if (not $out.open) {
        return Inbox{client: $out, lines: $lines};
    }
    def draining as bool init true;
    while ($draining) {
        def chunk as Chunk init readFrom($out);
        $out.open = $chunk.open;
        $draining = $chunk.more;
        if (len($chunk.text) > 0) {
            def f as proto.Frames init proto.frames(capped($out.buffer + $chunk.text));
            $out.buffer = $f.rest;
            for (def line in $f.lines) {
                $lines[] = $line;
            }
        }
    }
    return Inbox{client: $out, lines: $lines};
}

# readFrom does one non-blocking read on whichever socket the client uses.
func readFrom(c as Client) {
    if ($c.mode == UDP) {
        net.setReadDeadline($c.udp, POLL_MS);
        defer net.setReadDeadline($c.udp, 0);
        try {
            def d as net.Datagram init net.recvFrom($c.udp, READ_SIZE);
            return Chunk{text: decodeUtf8($d.data) + proto.LINE_END, open: true, more: true};
        } catch (e) {
            return Chunk{text: "", open: $c.open, more: false};
        }
    }
    return readConn($c.conn, $c.open);
}

/**
 * Close the client's socket.
 * @param c {Client} the client to close
 * @return {Client} the client, marked closed
 */
export func hangUp(c as Client) {
    def out as Client init $c;
    $out.open = false;
    try {
        if ($out.mode == UDP) {
            net.close($out.udp);
        } else {
            net.close($out.conn);
        }
    } catch (e) {
        return $out;
    }
    return $out;
}

/**
 * The peer tags the host currently knows, in the order they were first seen.
 * @param h {Host} the host
 * @return {list of string} the peer tags
 */
export func peers(h as Host) {
    def out as list of string init [];
    for (def peer in $h.conns) {
        $out[] = $peer;
    }
    return $out;
}

# decodeUtf8 turns received bytes into text, answering "" for bytes that are not
# valid UTF-8 - a peer sending binary noise is dropped, not a thrown error in a
# game loop.
func decodeUtf8(raw as bytes) {
    try {
        return convert.stringFromBytes($raw, "utf-8");
    } catch (e) {
        return "";
    }
}
