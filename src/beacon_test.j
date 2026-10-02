# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# White-box tests for beacon.j: the pure merge / describe / offer logic, and a
# real discovery round trip over loopback - a responder and a client in one
# process, on an ephemeral port, so the suite never touches the well-known port
# or depends on the machine having a usable broadcast route. Run with:
#
#     jennifer test src/beacon_test.j

use testing;
use task;
use strings;

# poke runs the responder until it has answered `want` queries or the attempts
# run out. `serve` is non-blocking by design, so a test drives it the way a host
# does - repeatedly - rather than waiting on it.
# Host is link.Host; the overlay names it through the module alias.
func poke(r as Responder, players as int, want as int) {
    def total as int init 0;
    for (def i as int init 0; $i < 200; $i = $i + 1) {
        $total = $total + serve($r, $players);
        if ($total >= $want) {
            return $total;
        }
    }
    return $total;
}

# sameGame returns the entry describing the host named `name`, after checking there is at
# least one and that every entry claiming that name describes the *same* game.
#
# No test pins how many entries discovery returns, because that is not a property of the
# code. `discoverOn` sends its query twice - once to the broadcast address and once to
# loopback - so a responder both paths reach answers twice, from two different source
# addresses, and `merge` dedupes on address, so one game arrives as two entries. How many
# paths reach a host depends on the machine's interfaces, and a CI runner has more of them
# than a desktop; another job answering on the same port adds more again.
#
# What the code *does* promise is that those entries agree about the game, which is what
# makes the duplicate harmless. That is the invariant asserted here.
func sameGame(found as list of Found, name as string) {
    def hits as list of Found init [];
    for (def f in $found) {
        if ($f.name == $name) {
            $hits[] = $f;
        }
    }
    testing.assertTrue(len($hits) >= 1);
    for (def f in $hits) {
        testing.assertEqual($f.mode, $hits[0].mode);
        testing.assertEqual($f.players, $hits[0].players);
        testing.assertEqual($f.capacity, $hits[0].capacity);
        testing.assertEqual(link.portOf($f.address), link.portOf($hits[0].address));
    }
    return $hits[0];
}

# named reports whether any entry describes a host of that name - for asserting absence.
func named(found as list of Found, name as string) {
    for (def f in $found) {
        if ($f.name == $name) {
            return true;
        }
    }
    return false;
}

# findOne queries a responder's own port while that responder is answering on it.
# The search runs in a spawned task and the responder is driven from this flow, so
# the answer always lands inside the search window - no test depends on two
# independent timers lining up.
func findOne(r as Responder, players as int) {
    def port as int init $r.port;
    def searching as task of list of Found init spawn {
        return discoverOn($port, 500);
    };
    poke($r, $players, 1);
    return task.wait($searching);
}

# offer builds an OFFER message the way a host would, for the pure tests.
func offer(port as int, mode as string, name as string, players as int, capacity as int) {
    return proto.decode(proto.encodeOffer($port, $mode, $name, $players, $capacity));
}

# --- fromOffer ---------------------------------------------------------------

func testFromOfferTakesTheIpFromTheDatagramNotThePayload() {
    # The security-relevant one: a host describes its port, never its address.
    def m as proto.Message init offer(47475, "tcp", "kitchen", 1, 8);
    def f as Found init fromOffer($m, "192.168.1.5:47474");
    testing.assertEqual($f.address, "192.168.1.5:47475");
    testing.assertEqual($f.name, "kitchen");
    testing.assertEqual($f.mode, "tcp");
    testing.assertEqual($f.players, 1);
    testing.assertEqual($f.capacity, 8);
}

func testFromOfferHandlesAnIpv6Source() {
    def f as Found init fromOffer(offer(47475, "udp", "v6", 0, 4), "[fe80::1]:47474");
    testing.assertEqual($f.address, "[fe80::1]:47475");
}

# --- merge -------------------------------------------------------------------

func testMergeAddsANewHost() {
    def found as list of Found init [];
    $found = merge($found, fromOffer(offer(1, "tcp", "a", 0, 8), "10.0.0.1:47474"));
    testing.assertEqual(len($found), 1);
}

func testMergeIgnoresADuplicateAddress() {
    # A query goes out twice, so a host on this machine answers twice.
    def one as Found init fromOffer(offer(47475, "tcp", "a", 0, 8), "127.0.0.1:47474");
    def found as list of Found init merge(merge([], $one), $one);
    testing.assertEqual(len($found), 1);
}

func testMergeKeepsTwoHostsOnDifferentPortsOfOneMachine() {
    def a as Found init fromOffer(offer(47475, "tcp", "a", 0, 8), "127.0.0.1:47474");
    def b as Found init fromOffer(offer(47476, "udp", "b", 0, 8), "127.0.0.1:47474");
    def found as list of Found init merge(merge([], $a), $b);
    testing.assertEqual(len($found), 2);
}

func testMergeKeepsTheFirstAnswer() {
    def first as Found init fromOffer(offer(47475, "tcp", "first", 1, 8), "10.0.0.1:47474");
    def second as Found init fromOffer(offer(47475, "udp", "second", 7, 8), "10.0.0.1:47474");
    def found as list of Found init merge(merge([], $first), $second);
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].name, "first");
}

# --- hasRoom -----------------------------------------------------------------

func testHasRoomWhenBelowCapacity() {
    testing.assertTrue(hasRoom(Found{
        name: "a",
        address: "x:1",
        mode: "tcp",
        players: 3,
        capacity: 8
    }));
}

func testHasNoRoomAtCapacity() {
    testing.assertFalse(hasRoom(Found{
        name: "a",
        address: "x:1",
        mode: "tcp",
        players: 8,
        capacity: 8
    }));
}

func testAnUnstatedCapacityCountsAsRoom() {
    # An older or terser host said nothing; let it refuse the join itself.
    testing.assertTrue(hasRoom(Found{
        name: "a",
        address: "x:1",
        mode: "tcp",
        players: 9,
        capacity: 0
    }));
}

# --- describe ----------------------------------------------------------------

func testDescribeMentionsEverythingAPlayerPicksBy() {
    def line as string init describe(Found{
        name: "kitchen",
        address: "192.168.1.5:47475",
        mode: "udp",
        players: 2,
        capacity: 8
    });
    testing.assertTrue(strings.contains($line, "kitchen"));
    testing.assertTrue(strings.contains($line, "udp"));
    testing.assertTrue(strings.contains($line, "2/8"));
    testing.assertTrue(strings.contains($line, "192.168.1.5:47475"));
}

func testDescribeIsOneLine() {
    def line as string init describe(Found{
        name: "a",
        address: "x:1",
        mode: "tcp",
        players: 0,
        capacity: 8
    });
    testing.assertFalse(strings.contains($line, "\n"));
}

# --- isQuery -----------------------------------------------------------------

func testIsQueryAcceptsARealQuery() {
    testing.assertTrue(isQuery(convert.bytesFromString(proto.wire(proto.encodeQuery()), "utf-8")));
}

func testIsQueryRejectsEverythingElse() {
    testing.assertFalse(isQuery(convert.bytesFromString("QUERY|99\n", "utf-8")));
    testing.assertFalse(isQuery(convert.bytesFromString("OFFER|1|1|tcp|a|0|8\n", "utf-8")));
    testing.assertFalse(isQuery(convert.bytesFromString("", "utf-8")));
    testing.assertFalse(isQuery(convert.bytesFromString("GET / HTTP/1.1\r\n\r\n", "utf-8")));
}

func testIsQueryRejectsBinaryNoise() {
    def noise as bytes;
    $noise[] = 200;
    $noise[] = 201;
    testing.assertFalse(isQuery($noise));
}

# --- a real round trip over loopback ----------------------------------------

func testAResponderBindsAnEphemeralPort() {
    def r as Responder init announceOn(0, 47475, "tcp", "kitchen", 8);
    defer stop($r);
    testing.assertTrue($r.port > 0);
    testing.assertEqual($r.gamePort, 47475);
    testing.assertEqual($r.name, "kitchen");
}

func testAResponderScrubsItsOwnName() {
    def r as Responder init announceOn(0, 47475, "tcp", "bad|name;here", 8);
    defer stop($r);
    testing.assertEqual($r.name, "badnamehere");
}

func testServeAnswersNothingWhenNobodyAsks() {
    def r as Responder init announceOn(0, 47475, "tcp", "quiet", 8);
    defer stop($r);
    testing.assertEqual(serve($r, 0), 0);
}

func testAClientDiscoversARealResponder() {
    def r as Responder init announceOn(0, 47475, link.TCP, "kitchen", 8);
    defer stop($r);
    # The client's window has to outlast the responder's polling, so the query is
    # sent first and answered while `collect` is still listening. Driving both
    # sides from one flow means the answer is served from the spawned task below.
    def mine as Found init sameGame(findOne($r, 3), "kitchen");
    testing.assertEqual($mine.mode, link.TCP);
    testing.assertEqual($mine.players, 3);
    testing.assertEqual($mine.capacity, 8);
    testing.assertEqual(link.portOf($mine.address), 47475);
}

func testADiscoveredHostIsReachableAtTheAddressReported() {
    # The address discovery hands back must be one `link.dial` can actually use.
    def h as link.Host init link.listen(link.UDP, 0);
    defer link.close($h);
    def r as Responder init announceOn(0, $h.port, link.UDP, "playable", 8);
    defer stop($r);
    def mine as Found init sameGame(findOne($r, 0), "playable");
    def c as link.Client init link.dial($mine.mode, $mine.address, 500);
    defer link.hangUp($c);
    $c = link.tell($c, proto.encodeJoin("ada", 24, 80));
    def arrived as bool init false;
    def host as link.Host init $h;
    for (def i as int init 0; $i < 100; $i = $i + 1) {
        def batch as link.Batch init link.poll($host);
        $host = $batch.host;
        if (len($batch.packets) > 0) {
            testing.assertEqual(proto.decode($batch.packets[0].body).text, "ada");
            $arrived = true;
        }
        if ($arrived) {
            testing.assertTrue($arrived);
            return;
        }
    }
    testing.assertTrue($arrived);
}

func testOneGameReachedTwoWaysIsOneGame() {
    # The shape a multi-homed machine produces: the same responder answers the broadcast
    # query and the loopback query, so two offers arrive with different source addresses and
    # `merge` keeps both. They must still describe one game - same port, mode, players and
    # capacity - because that is what lets a caller use either entry and what stops a test
    # from having to know how many interfaces the machine has.
    def one as Found init fromOffer(offer(47475, link.TCP, "kitchen", 3, 8), "127.0.0.1:47474");
    def two as Found init fromOffer(offer(47475, link.TCP, "kitchen", 3, 8), "10.0.2.15:47474");
    def both as list of Found init merge(merge([], $one), $two);
    testing.assertEqual(len($both), 2);
    def mine as Found init sameGame($both, "kitchen");
    testing.assertEqual($mine.players, 3);
    testing.assertEqual(link.portOf($mine.address), 47475);
}

# twoDifferentGames is the subject of the test below, as a named method because
# `assertThrows` invokes one by name rather than evaluating an expression.
func twoDifferentGames() {
    def one as Found init fromOffer(offer(47475, link.TCP, "jsnake", 3, 8), "10.0.2.15:47474");
    def two as Found init fromOffer(offer(47999, link.TCP, "jsnake", 3, 8), "10.0.2.99:47474");
    return sameGame(merge(merge([], $one), $two), "jsnake");
}

func testTwoDifferentGamesAreNotOneGame() {
    # The other direction: `sameGame` must not paper over two hosts that really differ. Two
    # offers sharing a name but disagreeing about the game are a failure, not a duplicate -
    # and `jsnake` is the default name, so that collision is the likely one.
    testing.assertThrows("twoDifferentGames", "assertion");
}

func testDiscoveryFindsNobodyOnAPortNobodyAnswers() {
    def free as Responder init announceOn(0, 47475, "tcp", "x", 8);
    def port as int init $free.port;
    stop($free);
    # Absence of *that* responder, rather than an empty list: on a shared network another
    # job's host could answer on the same port, and that would not mean this one did.
    testing.assertFalse(named(discoverOn($port, 60), "x"));
}

func testTwoRespondersCanBeToldApart() {
    def a as Responder init announceOn(0, 40001, link.TCP, "alpha", 4);
    defer stop($a);
    def b as Responder init announceOn(0, 40002, link.UDP, "beta", 6);
    defer stop($b);
    def fromA as list of Found init findOne($a, 1);
    def fromB as list of Found init findOne($b, 2);
    # Each responder listens on its own discovery port, so a query to one must not be
    # answered by the other - that is what "told apart" means here.
    testing.assertEqual(link.portOf(sameGame($fromA, "alpha").address), 40001);
    testing.assertEqual(link.portOf(sameGame($fromB, "beta").address), 40002);
    testing.assertFalse(named($fromA, "beta"));
    testing.assertFalse(named($fromB, "alpha"));
}

func testAResponderIgnoresAProbeThatIsNotAQuery() {
    def r as Responder init announceOn(0, 47475, link.TCP, "kitchen", 8);
    defer stop($r);
    def prober as net.UDPSocket init net.listenUDP(":0");
    defer net.close($prober);
    net.sendTo(
        $prober,
        link.address(LOOPBACK_ADDRESS, $r.port),
        convert.bytesFromString("GET / HTTP/1.1\r\n\r\n", "utf-8"));
    net.sendTo(
        $prober,
        link.address(LOOPBACK_ADDRESS, $r.port),
        convert.bytesFromString("QUERY|42\n", "utf-8"));
    testing.assertEqual(poke($r, 0, 1), 0);
}

func testStopIsIdempotent() {
    def r as Responder init announceOn(0, 47475, "tcp", "x", 8);
    stop($r);
    stop($r);
    testing.assertTrue($r.port > 0);
}

# --- the well-known-port wrappers -------------------------------------------

func testDiscoverUsesTheWellKnownPort() {
    # A one-millisecond window: this only checks that `discover` delegates to
    # `discoverOn(DISCOVERY_PORT, ...)`, which is all it does. Finding nothing is
    # the expected result on a machine with no host running.
    testing.assertEqual(len(discover(1)), 0);
}

func testAnnounceClaimsTheWellKnownPortOrSaysItCannot() {
    # Both outcomes are correct: the port is free and gets bound, or another
    # jsnake already has it and the bind is a catchable error the host reports.
    try {
        def r as Responder init announce(47475, link.UDP, "wellknown", 8);
        testing.assertEqual($r.port, DISCOVERY_PORT);
        testing.assertEqual($r.gamePort, 47475);
        stop($r);
    } catch (e) {
        testing.assertTrue(len($e.message) > 0);
    }
}

# --- a datagram that is not text --------------------------------------------

func testAbsorbDropsADatagramThatIsNotUtf8() {
    # This socket sits on a well-known port and will be probed with anything.
    def noise as bytes;
    $noise[] = 200;
    $noise[] = 201;
    $noise[] = 202;
    def d as net.Datagram init net.Datagram{data: $noise, peer: "10.0.0.1:47474"};
    testing.assertEqual(len(absorb([], $d)), 0);
}

func testAbsorbReadsAnOfferOutOfARealDatagram() {
    def payload as bytes init convert.bytesFromString(
        proto.wire(proto.encodeOffer(47475, link.TCP, "kitchen", 1, 8)),
        "utf-8");
    def d as net.Datagram init net.Datagram{data: $payload, peer: "10.0.0.9:47474"};
    def got as list of Found init absorb([], $d);
    testing.assertEqual(len($got), 1);
    testing.assertEqual($got[0].address, "10.0.0.9:47475");
    testing.assertEqual($got[0].name, "kitchen");
}

func testAbsorbIgnoresAnOfferWithNoUsablePort() {
    def payload as bytes init convert.bytesFromString("OFFER|1|0|tcp|x|0|8\n", "utf-8");
    def d as net.Datagram init net.Datagram{data: $payload, peer: "10.0.0.9:47474"};
    testing.assertEqual(len(absorb([], $d)), 0);
}

func testAbsorbIgnoresAnOfferNamingAnUnknownTransport() {
    def payload as bytes init convert.bytesFromString("OFFER|1|47475|pigeon|x|0|8\n", "utf-8");
    def d as net.Datagram init net.Datagram{data: $payload, peer: "10.0.0.9:47474"};
    testing.assertEqual(len(absorb([], $d)), 0);
}

func testAbsorbIgnoresADatagramThatIsNotAnOffer() {
    def payload as bytes init convert.bytesFromString(proto.wire(proto.encodeQuery()), "utf-8");
    def d as net.Datagram init net.Datagram{data: $payload, peer: "10.0.0.9:47474"};
    testing.assertEqual(len(absorb([], $d)), 0);
}
