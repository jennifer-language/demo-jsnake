# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * Finding games on the local network, by UDP broadcast.
 *
 * A host binds the discovery port and answers `QUERY` datagrams with an `OFFER`
 * describing itself. A client broadcasts one `QUERY` and collects whatever
 * `OFFER`s come back inside a short window. Nobody configures an address, which
 * is the whole point: two people on the same network start `jsnake host` and
 * `jsnake join` and the game finds itself.
 *
 * **Why broadcast and not multicast.** A `255.255.255.255` datagram needs no
 * group membership, no TTL choice, and no router cooperation, and it reaches
 * exactly the scope this game wants - the one link everyone is sitting on.
 * Multicast would buy routing across subnets, which a console snake game played
 * in one room has no use for.
 *
 * **Loopback is always asked too.** A broadcast can be refused outright - a
 * container with no broadcast route, a firewall, a host without the privilege -
 * and then a host running on the same machine would be invisible for no good
 * reason. So every query goes to the broadcast address *and* to `127.0.0.1`,
 * and duplicate answers are merged by address. That also makes this module
 * testable end to end with no network at all.
 *
 * A discovered host is reported with the address it was *seen at*, not one it
 * claims: the IP comes from the datagram's own source address and only the port
 * comes from the payload, so a host cannot advertise somebody else's machine.
 * @module beacon
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * import "./beacon.j" as beacon;
 * def hosts as list of beacon.Found init beacon.discover(beacon.DISCOVER_MS);
 * for (def h in $hosts) {
 *     io.printf("%s\n", beacon.describe($h));
 * }
 */

use net;
use io;
use convert;

import "./proto.j" as proto;
import "./link.j" as link;

/**
 * The port hosts answer discovery queries on. Fixed rather than configurable,
 * because a client that had to be told the discovery port would defeat the
 * purpose of discovery.
 */
export def const DISCOVERY_PORT as int init 47474;

/**
 * The limited broadcast address: every host on this link, no routing, no group.
 */
export def const BROADCAST_ADDRESS as string init "255.255.255.255";

/**
 * The loopback address, asked alongside the broadcast so a host on this very
 * machine is found even where broadcast is refused.
 */
export def const LOOPBACK_ADDRESS as string init "127.0.0.1";

/**
 * How long a client listens for answers, in milliseconds. Long enough for a
 * switched LAN round trip several times over, short enough that the menu appears
 * while the player is still expecting it to.
 */
export def const DISCOVER_MS as int init 700;

/**
 * The datagram read size. An `OFFER` is well under a hundred bytes.
 */
export def const READ_SIZE as int init 2048;

/**
 * How long a single `serve` pass waits for a query before returning. A host calls
 * `serve` once per game tick, so this must stay far below one tick.
 */
export def const SERVE_MS as int init 1;

/**
 * A host's discovery responder: the socket it answers on, and the facts it
 * answers with.
 * @field sock {net.UDPSocket} the socket bound to the discovery port
 * @field port {int} the discovery port actually bound, useful when 0 was asked for
 * @field gamePort {int} the port the game itself is listening on
 * @field mode {string} the transport the game uses, `link.TCP` or `link.UDP`
 * @field name {string} the host's display name, already scrubbed
 * @field capacity {int} how many players the host accepts in total
 */
export def struct Responder {
    sock as net.UDPSocket,
    port as int,
    gamePort as int,
    mode as string,
    name as string,
    capacity as int
};

/**
 * A host a client found. `address` is where to connect, assembled from the IP the
 * answer arrived from and the port the answer named.
 * @field name {string} the host's display name
 * @field address {string} the game's `"host:port"`, ready for `link.dial`
 * @field mode {string} the transport the game uses
 * @field players {int} how many players were connected when it answered
 * @field capacity {int} how many players it accepts in total
 */
export def struct Found {
    name as string,
    address as string,
    mode as string,
    players as int,
    capacity as int
};

/**
 * Start answering discovery queries on `port`. A `port` of 0 binds an ephemeral
 * one, which the returned `Responder` reports - that is how the tests run a real
 * responder without claiming the well-known port.
 * @param port {int} the discovery port to bind, or 0 for any free port
 * @param gamePort {int} the port the game is listening on
 * @param mode {string} the transport the game uses
 * @param name {string} the host's display name; scrubbed before it is announced
 * @param capacity {int} how many players the host accepts
 * @return {Responder} the running responder
 * @throws {Error} a `net` error when the discovery port cannot be bound
 */
export func announceOn(
    port as int,
    gamePort as int,
    mode as string,
    name as string,
    capacity as int) {
    def sock as net.UDPSocket init net.listenUDP(":" + convert.toString($port));
    return Responder{
        sock: $sock,
        port: link.portOf(net.address($sock)),
        gamePort: $gamePort,
        mode: $mode,
        name: proto.cleanName($name),
        capacity: $capacity
    };
}

/**
 * Start answering discovery queries on the well-known `DISCOVERY_PORT`.
 *
 * The bind can fail when another jsnake host is already running on this machine,
 * which is not fatal: the caller can play on without being discoverable, and
 * should say so rather than refuse to start.
 * @param gamePort {int} the port the game is listening on
 * @param mode {string} the transport the game uses
 * @param name {string} the host's display name
 * @param capacity {int} how many players the host accepts
 * @return {Responder} the running responder
 * @throws {Error} a `net` error when the discovery port is already taken
 */
export func announce(gamePort as int, mode as string, name as string, capacity as int) {
    return announceOn(DISCOVERY_PORT, $gamePort, $mode, $name, $capacity);
}

/**
 * Answer every query waiting right now, reporting how many were answered.
 * Non-blocking, so a host calls this once per tick and carries on.
 *
 * A datagram that is not a well-formed current-version `QUERY` is dropped in
 * silence: this socket sits on a well-known port and will be probed.
 * @param r {Responder} the responder
 * @param players {int} how many players are connected at this moment
 * @return {int} how many queries were answered
 */
export func serve(r as Responder, players as int) {
    def answered as int init 0;
    def offer as string init proto.encodeOffer(
        $r.gamePort,
        $r.mode,
        $r.name,
        $players,
        $r.capacity);
    def payload as bytes init convert.bytesFromString(proto.wire($offer), "utf-8");
    net.setReadDeadline($r.sock, SERVE_MS);
    # A deadline is a read and write deadline both, so an expired one would make
    # the reply below fail; it is cleared on the way out of every path.
    defer net.setReadDeadline($r.sock, 0);
    def draining as bool init true;
    while ($draining) {
        try {
            def d as net.Datagram init net.recvFrom($r.sock, READ_SIZE);
            if (isQuery($d.data)) {
                # No need to drop the read deadline to answer: a read deadline governs
                # reads only, so the reply is not bound by the poll timer that just expired.
                sendQuietly($r.sock, $d.peer, $payload);
                $answered = $answered + 1;
            }
        } catch (e) {
            $draining = false;
        }
    }
    return $answered;
}

# isQuery reads a datagram and reports whether it holds a current-version QUERY.
# Total on any bytes at all - this port is on the public internet as far as it
# knows, and a malformed probe must cost nothing.
func isQuery(raw as bytes) {
    def text as string init "";
    try {
        $text = convert.stringFromBytes($raw, "utf-8");
    } catch (e) {
        return false;
    }
    def f as proto.Frames init proto.frames($text + proto.LINE_END);
    for (def line in $f.lines) {
        if (proto.decode($line).kind == proto.QUERY) {
            return true;
        }
    }
    return false;
}

# sendQuietly sends one datagram and ignores a failure: a client that vanished
# between asking and being answered is not the host's problem.
func sendQuietly(sock as net.UDPSocket, peer as string, payload as bytes) {
    try {
        net.sendTo($sock, $peer, $payload);
    } catch (e) {
        return;
    }
    return;
}

/**
 * Stop answering discovery queries.
 * @param r {Responder} the responder to shut down
 * @return {null} nothing
 */
export func stop(r as Responder) {
    try {
        net.close($r.sock);
    } catch (e) {
        return;
    }
    return;
}

/**
 * Look for hosts answering on `port`, listening for `timeoutMs` milliseconds.
 *
 * One query goes to the broadcast address and one to loopback; both are allowed to fail,
 * because either path may be the only one that works - a broadcast does not always reach a
 * listener on the same machine, and a remote host is not on loopback.
 *
 * Answers are collected until the window closes and merged by address. Note what that does
 * **not** promise: a host both copies reach answers twice, and the two replies carry
 * different source addresses - one from loopback, one from the interface the broadcast went
 * out of - so merging by address keeps both. The same game is then listed twice, under two
 * addresses that both work. How often that happens is a property of the machine's
 * interfaces, so nothing should assume a host answers exactly once.
 * @param port {int} the discovery port to query
 * @param timeoutMs {int} how long to listen for answers, in milliseconds
 * @return {list of Found} the hosts that answered, in the order they answered
 */
export func discoverOn(port as int, timeoutMs as int) {
    def sock as net.UDPSocket init net.listenUDP(":0");
    defer closeQuietly($sock);
    enableBroadcast($sock);
    def query as bytes init convert.bytesFromString(proto.wire(proto.encodeQuery()), "utf-8");
    sendQuietly($sock, link.address(BROADCAST_ADDRESS, $port), $query);
    sendQuietly($sock, link.address(LOOPBACK_ADDRESS, $port), $query);
    return collect($sock, $timeoutMs);
}

/**
 * Look for hosts on the well-known `DISCOVERY_PORT`.
 * @param timeoutMs {int} how long to listen for answers, in milliseconds
 * @return {list of Found} the hosts that answered
 */
export func discover(timeoutMs as int) {
    return discoverOn(DISCOVERY_PORT, $timeoutMs);
}

# collect gathers every OFFER arriving before the window closes. One absolute
# deadline covers the whole window, so the loop reads until it expires.
func collect(sock as net.UDPSocket, timeoutMs as int) {
    def found as list of Found init [];
    net.setReadDeadline($sock, $timeoutMs);
    def listening as bool init true;
    while ($listening) {
        try {
            def d as net.Datagram init net.recvFrom($sock, READ_SIZE);
            $found = absorb($found, $d);
        } catch (e) {
            $listening = false;
        }
    }
    return $found;
}

# absorb reads one datagram for OFFERs and merges each into the list.
func absorb(found as list of Found, d as net.Datagram) {
    def out as list of Found init $found;
    def text as string init "";
    try {
        $text = convert.stringFromBytes($d.data, "utf-8");
    } catch (e) {
        return $out;
    }
    def f as proto.Frames init proto.frames($text + proto.LINE_END);
    for (def line in $f.lines) {
        def m as proto.Message init proto.decode($line);
        if ($m.kind == proto.OFFER and $m.port > 0 and link.isTransport($m.text)) {
            $out = merge($out, fromOffer($m, $d.peer));
        }
    }
    return $out;
}

/**
 * Build the `Found` an `OFFER` describes. The IP is taken from `seenAt` - the
 * address the datagram actually came from - and only the port from the message,
 * so a host cannot point a client at a machine that is not its own.
 * @param m {proto.Message} a decoded `OFFER`
 * @param seenAt {string} the `"host:port"` the answer arrived from
 * @return {Found} the host description
 */
export func fromOffer(m as proto.Message, seenAt as string) {
    return Found{
        name: $m.name,
        address: link.address(link.hostOf($seenAt), $m.port),
        mode: $m.text,
        players: $m.players,
        capacity: $m.capacity
    };
}

/**
 * Add `extra` to `found` unless a host at the same address is already there -
 * the answer to a query that went out twice. The first answer wins, so the list
 * keeps the order hosts replied in.
 * @param found {list of Found} the hosts collected so far
 * @param extra {Found} a newly seen host
 * @return {list of Found} the list, with `extra` added at most once
 */
export func merge(found as list of Found, extra as Found) {
    for (def f in $found) {
        if ($f.address == $extra.address) {
            return $found;
        }
    }
    def out as list of Found init $found;
    $out[] = $extra;
    return $out;
}

/**
 * Whether a host has room for another player. A capacity of 0 means the host did
 * not say, which is taken as "room" rather than "full" - an older host should be
 * joinable, and the host refuses the join itself if it is not.
 * @param f {Found} the host
 * @return {bool} true when the host looks joinable
 */
export func hasRoom(f as Found) {
    return $f.capacity <= 0 or $f.players < $f.capacity;
}

/**
 * One line describing a host, for the join menu.
 * @param f {Found} the host to describe
 * @return {string} a single line, no terminator
 */
export func describe(f as Found) {
    return io.sprintf(
        "%s|pad=14 %s|pad=4 %d/%d  %s",
        $f.name,
        $f.mode,
        $f.players,
        $f.capacity,
        $f.address);
}

# closeQuietly closes a socket and ignores a failure.
func closeQuietly(sock as net.UDPSocket) {
    try {
        net.close($sock);
    } catch (e) {
        return;
    }
    return;
}

# enableBroadcast turns on SO_BROADCAST, tolerating a platform or a container
# that refuses it: the loopback query still goes out, so discovery degrades to
# "this machine only" instead of failing.
func enableBroadcast(sock as net.UDPSocket) {
    try {
        net.setBroadcast($sock, true);
    } catch (e) {
        return;
    }
    return;
}
