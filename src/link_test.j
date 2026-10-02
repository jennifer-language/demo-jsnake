# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# White-box tests for link.j. The pure helpers are tested directly; the
# transports are tested for real, over loopback, both of them, including the
# cases a game actually hits: a peer that leaves, a reply to a peer that has
# gone, and two messages arriving in one read. Run with:
#
#     jennifer test src/link_test.j
#
# Every host binds port 0, so the suite never fights another process - or
# another test - over a fixed number, and nothing here sleeps on a fixed timer:
# `awaitPackets` / `awaitLines` poll until the data shows up or a bounded number
# of attempts runs out, which is what keeps the suite fast and not flaky.

use testing;
use lists;

import "./geom.j" as geom;
import "./rules.j" as rules;

# The most polls a test will wait through before giving up on data. Each poll
# already waits POLL_MS on its deadline, so this is a bounded wall-clock budget.
def const WAIT_POLLS as int init 100;

# awaitPackets polls the host until at least `want` packets have arrived.
func awaitPackets(h as Host, want as int) {
    def host as Host init $h;
    def packets as list of Packet init [];
    def gone as list of string init [];
    for (def i as int init 0; $i < WAIT_POLLS; $i = $i + 1) {
        def batch as Batch init poll($host);
        $host = $batch.host;
        for (def p in $batch.packets) {
            $packets[] = $p;
        }
        for (def g in $batch.gone) {
            $gone[] = $g;
        }
        if (len($packets) >= $want and len($packets) > 0) {
            return Batch{host: $host, packets: $packets, gone: $gone};
        }
    }
    return Batch{host: $host, packets: $packets, gone: $gone};
}

# awaitGone polls the host until at least one peer has been reported as closed.
func awaitGone(h as Host) {
    def host as Host init $h;
    def gone as list of string init [];
    for (def i as int init 0; $i < WAIT_POLLS; $i = $i + 1) {
        def batch as Batch init poll($host);
        $host = $batch.host;
        for (def g in $batch.gone) {
            $gone[] = $g;
        }
        if (len($gone) > 0) {
            return Batch{host: $host, packets: [], gone: $gone};
        }
    }
    return Batch{host: $host, packets: [], gone: $gone};
}

# awaitLines polls the client until at least `want` lines have arrived.
func awaitLines(c as Client, want as int) {
    def client as Client init $c;
    def lines as list of string init [];
    for (def i as int init 0; $i < WAIT_POLLS; $i = $i + 1) {
        def inbox as Inbox init listenFor($client);
        $client = $inbox.client;
        for (def line in $inbox.lines) {
            $lines[] = $line;
        }
        if (len($lines) >= $want and len($lines) > 0) {
            return Inbox{client: $client, lines: $lines};
        }
    }
    return Inbox{client: $client, lines: $lines};
}

# loopback is the address a client dials to reach a host bound on this machine.
func loopback(h as Host) {
    return "127.0.0.1:" + convert.toString($h.port);
}

# --- pure helpers ------------------------------------------------------------

func testIsTransportAcceptsBoth() {
    testing.assertTrue(isTransport(TCP));
    testing.assertTrue(isTransport(UDP));
}

func testIsTransportRejectsAnythingElse() {
    testing.assertFalse(isTransport(""));
    testing.assertFalse(isTransport("sctp"));
    testing.assertFalse(isTransport("TCP"));
}

func testTransportsListsBoth() {
    testing.assertEqual(len(TRANSPORTS), 2);
    testing.assertTrue(lists.contains(TRANSPORTS, TCP));
    testing.assertTrue(lists.contains(TRANSPORTS, UDP));
}

func testConnPeerIsDistinctPerHandle() {
    testing.assertNotEqual(connPeer(1), connPeer(2));
    testing.assertEqual(connPeer(7), connPeer(7));
}

func testPortOfReadsTheTrailingPort() {
    testing.assertEqual(portOf("127.0.0.1:47475"), 47475);
    testing.assertEqual(portOf(":8080"), 8080);
}

func testPortOfHandlesIpv6() {
    # An IPv6 address carries colons of its own, so the port is the last field.
    testing.assertEqual(portOf("[::1]:9999"), 9999);
}

func testPortOfIsZeroWithoutAPort() {
    testing.assertEqual(portOf(""), 0);
    testing.assertEqual(portOf("localhost"), 0);
    testing.assertEqual(portOf("host:notaport"), 0);
}

func testCappedPassesAnOrdinaryBuffer() {
    testing.assertEqual(capped("PING|1"), "PING|1");
    testing.assertEqual(capped(""), "");
}

func testCappedDiscardsAFloodWithNoNewline() {
    def flood as string init strings.repeat("x", MAX_BUFFER + 1);
    testing.assertEqual(capped($flood), "");
}

func testDecodeUtf8ReadsText() {
    testing.assertEqual(decodeUtf8(convert.bytesFromString("PING|1", "utf-8")), "PING|1");
}

func testDecodeUtf8DropsBinaryNoise() {
    def noise as bytes;
    $noise[] = 255;
    $noise[] = 254;
    testing.assertEqual(decodeUtf8($noise), "");
}

func testListenRejectsAnUnknownTransport() {
    testing.assertThrows("listenOnNonsenseTransport", "value");
}

func listenOnNonsenseTransport() {
    def h as Host init listen("carrierpigeon", 0);
    close($h);
}

func testDialRejectsAnUnknownTransport() {
    testing.assertThrows("dialOnNonsenseTransport", "value");
}

func dialOnNonsenseTransport() {
    def c as Client init dial("carrierpigeon", "127.0.0.1:1", 100);
    hangUp($c);
}

# --- binding -----------------------------------------------------------------

func testListenOnUdpBindsARealPort() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    testing.assertEqual($h.mode, UDP);
    testing.assertTrue($h.port > 0);
    testing.assertEqual(len(peers($h)), 0);
}

func testListenOnTcpBindsARealPort() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    testing.assertEqual($h.mode, TCP);
    testing.assertTrue($h.port > 0);
    testing.assertEqual(len(peers($h)), 0);
}

func testPollOfAQuietHostReturnsNothing() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def batch as Batch init poll($h);
    testing.assertEqual(len($batch.packets), 0);
    testing.assertEqual(len($batch.gone), 0);
}

func testPollOfAQuietTcpHostReturnsNothing() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def batch as Batch init poll($h);
    testing.assertEqual(len($batch.packets), 0);
}

# --- UDP round trips ---------------------------------------------------------

func testUdpCarriesAMessageToTheHost() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    defer hangUp($c);
    $c = tell($c, proto.encodeJoin("ada", 24, 80));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len($batch.packets), 1);
    testing.assertEqual(proto.decode($batch.packets[0].body).kind, proto.JOIN);
    testing.assertEqual(proto.decode($batch.packets[0].body).text, "ada");
}

func testUdpCarriesAReplyBackToTheClient() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    defer hangUp($c);
    $c = tell($c, proto.encodeJoin("ada", 24, 80));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len($batch.packets), 1);
    def host as Host init send(
        $batch.host,
        $batch.packets[0].peer,
        proto.encodeWelcome(1, 20, 10, 100));
    testing.assertEqual($host.mode, UDP);
    def inbox as Inbox init awaitLines($c, 1);
    testing.assertEqual(len($inbox.lines), 1);
    testing.assertEqual(proto.decode($inbox.lines[0]).kind, proto.WELCOME);
    testing.assertEqual(proto.decode($inbox.lines[0]).id, 1);
}

func testUdpDeliversSeveralMessages() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    defer hangUp($c);
    $c = tell($c, proto.encodeDir(1, geom.UP));
    $c = tell($c, proto.encodeDir(1, geom.LEFT));
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 3);
    testing.assertEqual(len($batch.packets), 3);
    testing.assertEqual(proto.decode($batch.packets[2].body).kind, proto.PING);
}

func testUdpNeedsNoAcceptSoNoPeerTableGrows() {
    # The peer table is a TCP concern; a UDP host answers whoever wrote to it.
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    defer hangUp($c);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len(peers($batch.host)), 0);
    testing.assertTrue(len($batch.packets[0].peer) > 0);
}

func testUdpSendToAnUnreachablePeerDoesNotThrow() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    # Nothing is listening there; a datagram into the void is not an error.
    def after as Host init send($h, "127.0.0.1:1", proto.encodePing(1));
    testing.assertEqual($after.mode, UDP);
}

# --- TCP round trips ---------------------------------------------------------

func testTcpAcceptsAClientAndCarriesAMessage() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodeJoin("bob", 24, 80));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len($batch.packets), 1);
    testing.assertEqual(proto.decode($batch.packets[0].body).text, "bob");
    testing.assertEqual(len(peers($batch.host)), 1);
}

func testTcpCarriesAReplyBackToTheClient() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodeJoin("bob", 24, 80));
    def batch as Batch init awaitPackets($h, 1);
    def host as Host init send(
        $batch.host,
        $batch.packets[0].peer,
        proto.encodeWelcome(2, 30, 12, 120));
    def inbox as Inbox init awaitLines($c, 1);
    testing.assertEqual(len($inbox.lines), 1);
    testing.assertEqual(proto.decode($inbox.lines[0]).id, 2);
    testing.assertTrue($inbox.client.open);
    testing.assertEqual(len(peers($host)), 1);
}

func testTcpReassemblesTwoMessagesFromOneRead() {
    # Two writes may land in one read on a stream; framing has to split them.
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodeDir(1, geom.UP));
    $c = tell($c, proto.encodeDir(1, geom.RIGHT));
    def batch as Batch init awaitPackets($h, 2);
    testing.assertEqual(len($batch.packets), 2);
    testing.assertEqual(proto.decode($batch.packets[0].body).text, geom.UP);
    testing.assertEqual(proto.decode($batch.packets[1].body).text, geom.RIGHT);
}

func testTcpReportsAClientThatLeaves() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len(peers($batch.host)), 1);
    $c = hangUp($c);
    def after as Batch init awaitGone($batch.host);
    testing.assertEqual(len($after.gone), 1);
    testing.assertEqual(len(peers($after.host)), 0);
}

func testTcpServesSeveralClientsAtOnce() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def a as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($a);
    def b as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($b);
    $a = tell($a, proto.encodeJoin("ada", 24, 80));
    $b = tell($b, proto.encodeJoin("bob", 24, 80));
    def batch as Batch init awaitPackets($h, 2);
    testing.assertEqual(len($batch.packets), 2);
    testing.assertEqual(len(peers($batch.host)), 2);
    testing.assertNotEqual($batch.packets[0].peer, $batch.packets[1].peer);
}

func testSendAllReachesEveryClient() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def a as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($a);
    def b as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($b);
    $a = tell($a, proto.encodePing(1));
    $b = tell($b, proto.encodePing(2));
    def batch as Batch init awaitPackets($h, 2);
    def host as Host init sendAll($batch.host, peers($batch.host), proto.encodeBye("closing"));
    testing.assertEqual(len(peers($host)), 2);
    testing.assertEqual(proto.decode(awaitLines($a, 1).lines[0]).kind, proto.BYE);
    testing.assertEqual(proto.decode(awaitLines($b, 1).lines[0]).kind, proto.BYE);
}

func testSendToAnUnknownTcpPeerIsANoOp() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def after as Host init send($h, connPeer(9999), proto.encodePing(1));
    testing.assertEqual(len(peers($after)), 0);
}

func testDropForgetsAPeerAndIsIdempotent() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    def peer as string init $batch.packets[0].peer;
    def host as Host init drop($batch.host, $peer);
    testing.assertEqual(len(peers($host)), 0);
    $host = drop($host, $peer);
    testing.assertEqual(len(peers($host)), 0);
}

func testAClientNoticesTheHostGoingAway() {
    def h as Host init listen(TCP, 0);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    close($batch.host);
    def inbox as Inbox init awaitLines($c, 1);
    testing.assertFalse($inbox.client.open);
}

func testTellOnAClosedClientIsANoOp() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    $c = hangUp($c);
    def after as Client init tell($c, proto.encodePing(1));
    testing.assertFalse($after.open);
}

func testListenForOnAClosedClientReturnsNothing() {
    def h as Host init listen(UDP, 0);
    defer close($h);
    def c as Client init dial(UDP, loopback($h), 500);
    $c = hangUp($c);
    def inbox as Inbox init listenFor($c);
    testing.assertEqual(len($inbox.lines), 0);
    testing.assertFalse($inbox.client.open);
}

func testHangUpIsIdempotent() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    $c = hangUp($c);
    testing.assertFalse(hangUp($c).open);
}

# --- both transports, same behaviour ----------------------------------------

func testEveryTransportCarriesTheSameRoundTrip() {
    # The point of the module: the game above it cannot tell which one it got.
    for (def mode in TRANSPORTS) {
        def h as Host init listen($mode, 0);
        def c as Client init dial($mode, loopback($h), 1000);
        $c = tell($c, proto.encodeJoin("ada", 24, 80));
        def batch as Batch init awaitPackets($h, 1);
        testing.assertEqual(len($batch.packets), 1);
        def m as proto.Message init proto.decode($batch.packets[0].body);
        testing.assertEqual($m.kind, proto.JOIN);
        testing.assertEqual($m.text, "ada");
        def host as Host init send(
            $batch.host,
            $batch.packets[0].peer,
            proto.encodeWelcome(1, 20, 10, 100));
        def inbox as Inbox init awaitLines($c, 1);
        testing.assertEqual(len($inbox.lines), 1);
        testing.assertEqual(proto.decode($inbox.lines[0]).kind, proto.WELCOME);
        hangUp($inbox.client);
        close($host);
    }
}

func testHostOfDropsThePort() {
    testing.assertEqual(hostOf("192.168.1.5:47475"), "192.168.1.5");
    testing.assertEqual(hostOf(":8080"), "");
}

func testHostOfKeepsAnIpv6AddressWhole() {
    testing.assertEqual(hostOf("[::1]:9999"), "[::1]");
    testing.assertEqual(hostOf("[fe80::1%eth0]:47475"), "[fe80::1%eth0]");
}

func testHostOfPassesThroughAnAddressWithNoPort() {
    testing.assertEqual(hostOf("localhost"), "localhost");
    testing.assertEqual(hostOf(""), "");
}

func testAddressRoundTripsWithHostOfAndPortOf() {
    def a as string init address("192.168.1.5", 47475);
    testing.assertEqual($a, "192.168.1.5:47475");
    testing.assertEqual(hostOf($a), "192.168.1.5");
    testing.assertEqual(portOf($a), 47475);
}

func testAddressRoundTripsForIpv6() {
    def a as string init address("[::1]", 47475);
    testing.assertEqual(hostOf($a), "[::1]");
    testing.assertEqual(portOf($a), 47475);
}

# --- a client that never connected ------------------------------------------

func testClosedClientIsInertRatherThanThrowing() {
    # What `dial` would have returned had it succeeded, but closed - so a caller
    # can report a refused connection as a screen instead of catching an error.
    def c as Client init closedClient(TCP, "10.0.0.1:47475");
    testing.assertFalse($c.open);
    testing.assertEqual($c.mode, TCP);
    testing.assertEqual($c.server, "10.0.0.1:47475");
    testing.assertFalse(tell($c, proto.encodePing(1)).open);
    def inbox as Inbox init listenFor($c);
    testing.assertEqual(len($inbox.lines), 0);
    testing.assertFalse($inbox.client.open);
}

func testClosedClientWorksForEitherTransport() {
    for (def mode in TRANSPORTS) {
        testing.assertFalse(closedClient($mode, "x:1").open);
    }
}

# --- a peer that goes away mid-game -----------------------------------------

func testATcpSendToADeadPeerDropsIt() {
    # The "player pulled the cable" path: the host must not need a try around
    # every reply, and must not keep writing to a socket nobody is reading.
    def h as Host init listen(TCP, 0);
    defer close($h);
    def c as Client init dial(TCP, loopback($h), 1000);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    def peer as string init $batch.packets[0].peer;
    def host as Host init $batch.host;
    testing.assertEqual(len(peers($host)), 1);
    hangUp($c);
    # The first write after the peer goes may still be buffered by the kernel; the
    # one after it cannot be, so the peer is dropped within a couple of sends.
    for (def i as int init 0; $i < 20 and len(peers($host)) > 0; $i = $i + 1) {
        $host = send($host, $peer, proto.encodeState(rules.newGame(20, 10, 1)));
    }
    testing.assertEqual(len(peers($host)), 0);
}

func testTellClosesTheClientWhenTheHostHasGone() {
    def h as Host init listen(TCP, 0);
    def c as Client init dial(TCP, loopback($h), 1000);
    defer hangUp($c);
    $c = tell($c, proto.encodePing(1));
    def batch as Batch init awaitPackets($h, 1);
    testing.assertEqual(len($batch.packets), 1);
    close($batch.host);
    for (def i as int init 0; $i < 20 and $c.open; $i = $i + 1) {
        $c = tell($c, proto.encodePing(1));
    }
    testing.assertFalse($c.open);
}

func testBufferOfIsEmptyForAPeerWithNoTailYet() {
    def h as Host init listen(TCP, 0);
    defer close($h);
    testing.assertEqual(bufferOf($h, connPeer(999)), "");
}
