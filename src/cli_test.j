# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# White-box tests for cli.j. `parse` is pure, so the entire command line - every
# flag, every default, every way to get it wrong - is checked here without
# starting a game. Run with:
#
#     jennifer test src/cli_test.j

use testing;
use fs;
use toml;
use maps;

# cli has no need of geom; this overlay does, to read a number tolerantly.
import "./geom.j" as geom;
use lists;

# argv builds a command line the way os.ARGS arrives: script path first.
func argv(words as list of string) {
    def out as list of string init ["bin/jsnake"];
    for (def w in $words) {
        $out[] = $w;
    }
    return $out;
}

# plan parses a command line given as words after the program name.
func plan(words as list of string) {
    return parse(argv($words));
}

# --- no arguments and the built-in actions ----------------------------------

func testNoArgumentsPrintsUsageAndFails() {
    def p as Plan init plan([]);
    testing.assertEqual($p.action, "");
    testing.assertTrue(len($p.text) > 0);
    testing.assertEqual($p.code, 1);
    testing.assertTrue(strings.contains($p.text, PROGRAM));
}

func testUsageMentionsEverySubcommand() {
    def text as string init plan([]).text;
    for (def command in [HOST, JOIN, SOLO, LIST]) {
        testing.assertTrue(strings.contains($text, $command));
    }
}

func testHelpIsPrintedAndSucceeds() {
    def p as Plan init plan(["--help"]);
    testing.assertEqual($p.action, "");
    testing.assertEqual($p.code, 0);
    testing.assertTrue(len($p.text) > 0);
}

func testVersionIsPrintedAndSucceeds() {
    def p as Plan init plan(["--version"]);
    testing.assertEqual($p.code, 0);
    testing.assertTrue(strings.contains($p.text, VERSION));
}

func testAnUnknownFlagIsAUsageErrorNotACrash() {
    def p as Plan init plan([HOST, "--wobble"]);
    testing.assertEqual($p.action, "");
    testing.assertEqual($p.code, 2);
    testing.assertTrue(strings.contains($p.text, PROGRAM));
}

func testAnUnknownSubcommandIsAUsageError() {
    def p as Plan init plan(["dance"]);
    testing.assertEqual($p.action, "");
    testing.assertTrue($p.code > 0);
}

func testABadNumberIsAUsageError() {
    def p as Plan init plan([HOST, "--port", "soon"]);
    testing.assertEqual($p.code, 2);
}

# --- host --------------------------------------------------------------------

func testHostDefaults() {
    def p as Plan init plan([HOST]);
    testing.assertEqual($p.action, HOST);
    testing.assertEqual($p.hostOpts.mode, link.UDP);
    testing.assertEqual($p.hostOpts.port, link.DEFAULT_PORT);
    # The field flags are a cap, and by default they do not bind: the terminals at the
    # table decide the size between them.
    testing.assertEqual($p.hostOpts.width, rules.MAX_WIDTH);
    testing.assertEqual($p.hostOpts.height, rules.MAX_HEIGHT);
    testing.assertEqual($p.hostOpts.tickMs, host.DEFAULT_TICK_MS);
    testing.assertEqual($p.hostOpts.capacity, rules.MAX_PLAYERS);
    testing.assertEqual($p.hostOpts.bots, 0);
    testing.assertEqual($p.hostOpts.botLevel, bot.DEFAULT_LEVEL);
    testing.assertEqual($p.hostOpts.onLeave, host.DEFAULT_ON_LEAVE);
    testing.assertTrue($p.hostOpts.play);
    testing.assertTrue($p.hostOpts.discoverable);
}

func testHostTakesEveryLongFlag() {
    def p as Plan init plan([
        HOST,
        "--mode",
        "tcp",
        "--port",
        "50000",
        "--name",
        "kitchen",
        "--width",
        "30",
        "--height",
        "12",
        "--tick",
        "90",
        "--players",
        "4",
        "--bots",
        "2",
        "--bot-level",
        "expert",
        "--on-leave",
        "takeover",
        "--seed",
        "77"
    ]);
    testing.assertEqual($p.action, HOST);
    testing.assertEqual($p.hostOpts.mode, link.TCP);
    testing.assertEqual($p.hostOpts.port, 50000);
    testing.assertEqual($p.hostOpts.name, "kitchen");
    testing.assertEqual($p.hostOpts.width, 30);
    testing.assertEqual($p.hostOpts.height, 12);
    testing.assertEqual($p.hostOpts.tickMs, 90);
    testing.assertEqual($p.hostOpts.capacity, 4);
    testing.assertEqual($p.hostOpts.bots, 2);
    testing.assertEqual($p.hostOpts.botLevel, bot.EXPERT);
    testing.assertEqual($p.hostOpts.onLeave, host.TAKEOVER);
    testing.assertEqual($p.hostOpts.seed, 77);
}

func testHostTakesTheShortFlags() {
    def p as Plan init plan([
        HOST,
        "-m",
        "tcp",
        "-p",
        "50001",
        "-n",
        "ada",
        "-w",
        "22",
        "-b",
        "1",
        "-l",
        "hard"
    ]);
    testing.assertEqual($p.hostOpts.mode, link.TCP);
    testing.assertEqual($p.hostOpts.port, 50001);
    testing.assertEqual($p.hostOpts.name, "ada");
    testing.assertEqual($p.hostOpts.width, 22);
    testing.assertEqual($p.hostOpts.bots, 1);
    testing.assertEqual($p.hostOpts.botLevel, bot.HARD);
}

func testHostAcceptsFlagEqualsValue() {
    def p as Plan init plan([HOST, "--mode=tcp", "--port=50002"]);
    testing.assertEqual($p.hostOpts.mode, link.TCP);
    testing.assertEqual($p.hostOpts.port, 50002);
}

func testWatchMeansRefereeOnly() {
    testing.assertFalse(plan([HOST, "--watch"]).hostOpts.play);
    testing.assertTrue(plan([HOST]).hostOpts.play);
}

func testPrivateMeansNotDiscoverable() {
    testing.assertFalse(plan([HOST, "--private"]).hostOpts.discoverable);
    testing.assertTrue(plan([HOST]).hostOpts.discoverable);
}

func testTheModeIsCaseInsensitive() {
    testing.assertEqual(plan([HOST, "--mode", "TCP"]).hostOpts.mode, link.TCP);
    testing.assertEqual(plan([HOST, "--mode", "Udp"]).hostOpts.mode, link.UDP);
}

func testAnUnknownModeIsRefusedWithTheChoicesNamed() {
    def p as Plan init plan([HOST, "--mode", "sctp"]);
    testing.assertEqual($p.action, "");
    testing.assertEqual($p.code, 2);
    testing.assertTrue(strings.contains($p.text, link.TCP));
    testing.assertTrue(strings.contains($p.text, link.UDP));
}

func testAnUnknownBotLevelIsCorrectedRatherThanRefused() {
    # A mistyped skill should still give a game, with a sane opponent.
    def p as Plan init plan([HOST, "--bot-level", "unbeatable"]);
    testing.assertEqual($p.action, HOST);
    testing.assertEqual($p.hostOpts.botLevel, bot.DEFAULT_LEVEL);
}

func testEveryBotLevelIsAccepted() {
    for (def level in bot.LEVELS) {
        testing.assertEqual(plan([HOST, "--bot-level", $level]).hostOpts.botLevel, $level);
    }
}

func testTheBotLevelIsCaseInsensitive() {
    testing.assertEqual(plan([HOST, "--bot-level", "HARD"]).hostOpts.botLevel, bot.HARD);
}

func testAnUnknownLeavePolicyIsCorrectedRatherThanRefused() {
    testing.assertEqual(
        plan([HOST, "--on-leave", "shrug"]).hostOpts.onLeave,
        host.DEFAULT_ON_LEAVE);
}

func testEveryLeavePolicyIsAccepted() {
    for (def policy in host.LEAVE_POLICIES) {
        testing.assertEqual(plan([HOST, "--on-leave", $policy]).hostOpts.onLeave, $policy);
    }
}

func testANegativeBotCountBecomesNone() {
    testing.assertEqual(plan([HOST, "--bots", "-3"]).hostOpts.bots, 0);
}

func testAnAbsurdFieldIsTheHostsToClampNotTheClis() {
    # The cli passes the number through; rules.newGame is the one place the field
    # limits live, so there is exactly one answer to "how small is too small".
    def p as Plan init plan([HOST, "--width", "2", "--height", "1"]);
    testing.assertEqual($p.hostOpts.width, 2);
    def t as host.Table init host.newTable($p.hostOpts.width, $p.hostOpts.height, 1, 4, 200);
    testing.assertEqual($t.game.width, rules.MIN_WIDTH);
    testing.assertEqual($t.game.height, rules.MIN_HEIGHT);
}

# --- solo --------------------------------------------------------------------

func testSoloDefaultsToAPrivateGameWithOpponents() {
    def p as Plan init plan([SOLO]);
    testing.assertEqual($p.action, SOLO);
    testing.assertEqual($p.hostOpts.bots, SOLO_BOTS);
    testing.assertFalse($p.hostOpts.discoverable);
    testing.assertTrue($p.hostOpts.play);
    testing.assertEqual($p.hostOpts.port, 0);
}

func testSoloAlwaysHasAtLeastOneOpponent() {
    # A solo game with nobody to play against is not a game.
    testing.assertEqual(plan([SOLO, "--bots", "0"]).hostOpts.bots, 1);
    testing.assertEqual(plan([SOLO, "--bots", "-5"]).hostOpts.bots, 1);
}

func testSoloTakesTheFieldAndSkillFlags() {
    def p as Plan init plan([
        SOLO,
        "--width",
        "26",
        "--height",
        "11",
        "--tick",
        "80",
        "--bots",
        "5",
        "--bot-level",
        "expert"
    ]);
    testing.assertEqual($p.hostOpts.width, 26);
    testing.assertEqual($p.hostOpts.height, 11);
    testing.assertEqual($p.hostOpts.tickMs, 80);
    testing.assertEqual($p.hostOpts.bots, 5);
    testing.assertEqual($p.hostOpts.botLevel, bot.EXPERT);
}

func testSoloIsRunByTheSameHostAsAHostedGame() {
    # Solo is a host that binds an ephemeral port and answers no broadcasts, not a
    # second game loop that could disagree with the real one.
    def p as Plan init plan([SOLO]);
    def t as host.Table init host.seatBots(
        host.seatLocal(
            host.newTable(
                $p.hostOpts.width,
                $p.hostOpts.height,
                1,
                $p.hostOpts.capacity,
                $p.hostOpts.tickMs),
            "me",
            24,
            80),
        $p.hostOpts.bots,
        $p.hostOpts.botLevel);
    testing.assertEqual(host.humanCount($t), 1);
    testing.assertEqual(host.botCount($t), SOLO_BOTS);
}

# --- join --------------------------------------------------------------------

func testJoinDefaultsToLookingForAGame() {
    def p as Plan init plan([JOIN]);
    testing.assertEqual($p.action, JOIN);
    testing.assertEqual($p.guestOpts.address, "");
    testing.assertEqual($p.guestOpts.mode, link.UDP);
    testing.assertEqual($p.guestOpts.name, guest.DEFAULT_NAME);
    testing.assertEqual($p.guestOpts.discoverMs, beacon.DISCOVER_MS);
}

func testJoinTakesAnAddress() {
    def words as list of string init [JOIN, "--host", "192.168.1.5:47475", "--mode", "tcp"];
    def p as Plan init plan(lists.concat($words, ["--name", "bob"]));
    testing.assertEqual($p.guestOpts.address, "192.168.1.5:47475");
    testing.assertEqual($p.guestOpts.mode, link.TCP);
    testing.assertEqual($p.guestOpts.name, "bob");
}

func testJoinTakesTheShortFlags() {
    def p as Plan init plan([JOIN, "-H", "10.0.0.2:47475", "-m", "tcp", "-n", "eve", "-t", "1500"]);
    testing.assertEqual($p.guestOpts.address, "10.0.0.2:47475");
    testing.assertEqual($p.guestOpts.mode, link.TCP);
    testing.assertEqual($p.guestOpts.name, "eve");
    testing.assertEqual($p.guestOpts.discoverMs, 1500);
}

func testJoinTrimsTheAddress() {
    testing.assertEqual(
        plan([JOIN, "--host", "  10.0.0.2:47475 "]).guestOpts.address,
        "10.0.0.2:47475");
}

func testJoinRefusesAnUnknownMode() {
    testing.assertEqual(plan([JOIN, "--mode", "pigeon"]).code, 2);
}

func testAZeroTimeoutBecomesAWorkableOne() {
    testing.assertTrue(plan([JOIN, "--timeout", "0"]).guestOpts.discoverMs > 0);
    testing.assertTrue(plan([JOIN, "--timeout", "-9"]).guestOpts.discoverMs > 0);
}

func testAJoinAddressIsTakenApartByTheSameCodeThatDialsIt() {
    def p as Plan init plan([JOIN, "--host", "192.168.1.5:47475"]);
    testing.assertEqual(link.hostOf($p.guestOpts.address), "192.168.1.5");
    testing.assertEqual(link.portOf($p.guestOpts.address), 47475);
}

# --- list --------------------------------------------------------------------

func testListDefaults() {
    def p as Plan init plan([LIST]);
    testing.assertEqual($p.action, LIST);
    testing.assertEqual($p.timeoutMs, beacon.DISCOVER_MS);
}

func testListTakesATimeout() {
    testing.assertEqual(plan([LIST, "--timeout", "250"]).timeoutMs, 250);
    testing.assertEqual(plan([LIST, "-t", "250"]).timeoutMs, 250);
}

func testListClampsAnImpossibleTimeout() {
    testing.assertTrue(plan([LIST, "--timeout", "0"]).timeoutMs > 0);
}

# --- the shape of every plan -------------------------------------------------

func testEverySubcommandProducesExactlyOneAction() {
    for (def command in [HOST, JOIN, SOLO, LIST]) {
        def p as Plan init plan([$command]);
        testing.assertEqual($p.action, $command);
        testing.assertEqual($p.text, "");
    }
}

func testEveryPlanIsEitherAnActionOrAMessage() {
    def lines as list of list of string init [
        [],
        ["--help"],
        ["--version"],
        ["nonsense"],
        [HOST],
        [HOST, "--mode", "bogus"],
        [JOIN],
        [SOLO],
        [LIST]
    ];
    for (def words in $lines) {
        def p as Plan init plan($words);
        def acting as bool init len($p.action) > 0;
        def talking as bool init len($p.text) > 0;
        testing.assertFalse($acting and $talking);
        testing.assertTrue($acting or $talking);
    }
}

func testEveryHostPlanIsRunnableByTheHost() {
    # Whatever the flags, the options must be ones host.newTable will accept.
    def lines as list of list of string init [
        [HOST],
        [HOST, "--players", "99"],
        [HOST, "--players", "0"],
        [HOST, "--tick", "1"],
        [HOST, "--tick", "999999"],
        [SOLO],
        [SOLO, "--bots", "99"]
    ];
    for (def words in $lines) {
        def o as host.Options init plan($words).hostOpts;
        def t as host.Table init host.seatBots(
            host.newTable($o.width, $o.height, 1, $o.capacity, $o.tickMs),
            $o.bots,
            $o.botLevel);
        testing.assertTrue($t.capacity >= 1 and $t.capacity <= rules.MAX_PLAYERS);
        testing.assertTrue($t.tickMs >= host.MIN_TICK_MS and $t.tickMs <= host.MAX_TICK_MS);
        testing.assertTrue(len($t.players) <= $t.capacity);
        testing.assertTrue(bot.isLevel($o.botLevel));
        testing.assertTrue(host.isLeavePolicy($o.onLeave));
    }
}

func testTheVersionIsSemver() {
    def parts as list of string init strings.split(VERSION, ".");
    testing.assertEqual(len($parts), 3);
    for (def part in $parts) {
        testing.assertTrue(len($part) > 0);
    }
}

# --- main's exit codes -------------------------------------------------------
#
# `bin/jsnake` is literally `exit cli.main(os.ARGS);`, so these codes are the
# program's contract with a shell and with CI. The four cases below print as they
# run - that is what they are testing - so some help text and a version number
# appear in the middle of this suite's output on purpose.
#
# The `host`, `solo`, and `join` branches are deliberately absent: each takes over
# the terminal and runs until a key is pressed, so a unit test cannot call them.
# They are covered by running the game.

func testMainSucceedsForVersion() {
    testing.assertEqual(main(argv(["--version"])), 0);
}

func testMainSucceedsForHelp() {
    testing.assertEqual(main(argv(["--help"])), 0);
}

func testMainFailsForNoArguments() {
    testing.assertEqual(main(argv([])), 1);
}

func testMainReportsAUsageErrorWithCodeTwo() {
    testing.assertEqual(main(argv([HOST, "--mode", "pigeon"])), 2);
}

func testMainReturnsOneWhenListFindsNothing() {
    # An exit code a script can branch on: "no games here" is not success.
    testing.assertEqual(main(argv([LIST, "--timeout", "1"])), 1);
}

# --- special food ------------------------------------------------------------

func testSpecialFoodIsOnByDefault() {
    testing.assertTrue(plan([HOST]).hostOpts.specials);
    testing.assertTrue(plan([SOLO]).hostOpts.specials);
}

func testPlainTurnsTheSpecialsOff() {
    testing.assertFalse(plan([HOST, "--plain"]).hostOpts.specials);
    testing.assertFalse(plan([SOLO, "--plain"]).hostOpts.specials);
}

func testAPlainGameReallyHasNoSpecials() {
    def o as host.Options init plan([SOLO, "--plain"]).hostOpts;
    def t as host.Table init host.newTable($o.width, $o.height, 1, $o.capacity, $o.tickMs);
    def g as rules.Game init rules.withoutSpecials($t.game);
    testing.assertFalse($g.specials);
    for (def kind in rules.SPECIAL_KINDS) {
        testing.assertEqual(rules.foodCount($g, $kind), 0);
    }
}

# --- the title screen --------------------------------------------------------

func testHostShowsTheTitleScreenByDefault() {
    testing.assertTrue(plan([HOST]).hostOpts.lobby);
}

func testNowSkipsTheTitleScreen() {
    testing.assertFalse(plan([HOST, "--now"]).hostOpts.lobby);
}

func testSoloStartsAtOnceByDefault() {
    # There is nobody to wait for, so a solo game plays rather than asking first.
    testing.assertFalse(plan([SOLO]).hostOpts.lobby);
}

func testSetupAsksForTheTitleScreenInASoloGame() {
    testing.assertTrue(plan([SOLO, "--setup"]).hostOpts.lobby);
}

func testEveryHostPlanCarriesALobbyDecision() {
    for (def words in [[HOST], [HOST, "--now"], [SOLO], [SOLO, "--setup"]]) {
        def p as Plan init plan($words);
        testing.assertEqual($p.action, $words[0]);
    }
}

# --- the field flags are a cap, not a request --------------------------------

func testTheFieldFlagsDefaultToNoLimit() {
    for (def command in [HOST, SOLO]) {
        def o as host.Options init plan([$command]).hostOpts;
        testing.assertEqual($o.width, rules.MAX_WIDTH);
        testing.assertEqual($o.height, rules.MAX_HEIGHT);
    }
}

func testTheFieldFlagsStillCapWhenGiven() {
    def o as host.Options init plan([HOST, "--width", "30", "--height", "12"]).hostOpts;
    testing.assertEqual($o.width, 30);
    testing.assertEqual($o.height, 12);
}

func testTheHelpCallsTheFieldFlagsAMaximum() {
    # The flag changed meaning, so the help text has to say so or it lies.
    def text as string init plan([HOST, "--help"]).text;
    testing.assertTrue(strings.contains($text, "maximum field width"));
    testing.assertTrue(strings.contains($text, "maximum field height"));
}

# --- lives -------------------------------------------------------------------

func testLivesDefaultsToThree() {
    for (def command in [HOST, SOLO]) {
        testing.assertEqual(plan([$command]).hostOpts.lives, rules.DEFAULT_LIVES);
    }
}

func testLivesTakesANumber() {
    testing.assertEqual(plan([HOST, "--lives", "5"]).hostOpts.lives, 5);
    testing.assertEqual(plan([SOLO, "--lives", "1"]).hostOpts.lives, 1);
}

func testZeroLivesMeansUnlimited() {
    testing.assertEqual(plan([HOST, "--lives", "0"]).hostOpts.lives, rules.UNLIMITED_LIVES);
}

func testAnImpossibleLivesCountIsCorrectedNotRefused() {
    # A mistyped number should still give a playable game, as with every other setting.
    testing.assertEqual(plan([HOST, "--lives", "-4"]).hostOpts.lives, 1);
    testing.assertEqual(plan([HOST, "--lives", "999"]).hostOpts.lives, rules.MAX_LIVES);
}

func testEveryHostPlanCarriesRunnableLives() {
    for (def words in [
        [HOST],
        [HOST, "--lives", "0"],
        [HOST, "--lives", "99"],
        [SOLO],
        [SOLO, "--lives", "1"]
    ]) {
        def o as host.Options init plan($words).hostOpts;
        testing.assertEqual($o.lives, rules.livesOr($o.lives));
        def t as host.Table init host.newTable($o.width, $o.height, 1, $o.capacity, $o.tickMs);
        def g as rules.Game init rules.withLives($t.game, $o.lives);
        testing.assertEqual($g.lives, $o.lives);
    }
}

# --- the build's identity ----------------------------------------------------

func testTheVersionComesFromTheGeneratedReleaseModule() {
    # One source of truth: `scripts/release.sh` writes it from git, and nothing else
    # should carry a version string that could drift from the tag.
    testing.assertEqual(VERSION, release.VERSION);
}

func testTheVersionIsSemverPossiblyWithBuildMetadata() {
    # `1.2.0` on a release tag, `1.2.0+7.gabc1234` anywhere else. The `+` form is SemVer
    # build metadata, which is ignored when versions are compared - so a dev build never
    # sorts above the release it descends from.
    def parts as list of string init strings.split(VERSION, "+");
    testing.assertTrue(len($parts) <= 2);
    def core as list of string init strings.split($parts[0], ".");
    testing.assertEqual(len($core), 3);
    for (def n in $core) {
        testing.assertTrue(len($n) > 0);
        testing.assertTrue(geom.toIntOr($n, -1) >= 0);
    }
}

func testAReleaseBuildCarriesNoBuildMetadata() {
    if (release.RELEASE) {
        testing.assertFalse(strings.contains(VERSION, "+"));
    } else {
        testing.assertTrue(len(release.COMMIT) > 0);
    }
}

func testTheVersionIsWhatDashDashVersionPrints() {
    def p as Plan init plan(["--version"]);
    testing.assertTrue(strings.contains($p.text, VERSION));
    testing.assertEqual($p.code, 0);
}

# --- the description is stated once -----------------------------------------

func testTheUsageHeaderIsTheDescriptionWithALineBreak() {
    # The header is derived from DESCRIPTION rather than written out again, so changing the
    # wording in one place cannot leave the other behind. Undo the break and the two must be
    # the same words.
    testing.assertEqual(strings.replace(USAGE_HELP, "\n", " "), DESCRIPTION);
}

func testTheUsageHeaderBreaksAtAWordBoundary() {
    # `args` prints the help verbatim and a terminal soft-wraps mid-word, which reads as a
    # typo. Every line of the header has to fit the narrowest terminal that can host a game.
    def lines as list of string init strings.split(USAGE_HELP, "\n");
    testing.assertEqual(len($lines), 2);
    for (def line in $lines) {
        testing.assertTrue(len($line) <= 80);
        testing.assertFalse(strings.startsWith($line, " "));
        testing.assertFalse(strings.endsWith($line, " "));
    }
}

func testTheDescriptionMatchesTheDeckManifest() {
    # The manifest is what a registry and a package build read; the constant is what the
    # program prints. They describe the same game, so they say the same thing - and this is
    # the only thing that would notice if somebody updated one of them.
    def manifest as toml.Value init toml.decode(fs.readString("deck.toml"));
    testing.assertEqual(toml.asString(toml.get($manifest, "/package/description")), DESCRIPTION);
}

func testTheManPageDocumentsEveryFlag() {
    # The man page is the one piece of documentation nobody reads while editing the
    # grammar, so it is the one most likely to go quietly stale. Walk the real parser and
    # insist every flag it declares is named in `man/jsnake.1` - adding a flag to cli.j
    # then fails the suite until the page catches up.
    def page as string init fs.readString("man/jsnake.1");
    for (def c in grammar().commands) {
        for (def a in $c.parser.args) {
            if ($a.kind != "flag" or $a.name == "help") {
                continue;
            }
            testing.assertTrue(strings.contains($page, roffFlag($a.name)));
        }
    }
}

func testTheManPageNamesTheVersionItDocuments() {
    # `man` prints the `.TH` line's version in the footer of every page, so a stale one
    # is a page claiming to describe a release it does not. `release.sh` rewrites it
    # alongside the manifest; this is what notices if that ever stops happening. The
    # comparison drops build metadata, since a dev build's `+7.gabc` has no business in
    # a manual page.
    def bare as string init VERSION;
    if (strings.contains($bare, "+")) {
        $bare = strings.split($bare, "+")[0];
    }
    testing.assertTrue(strings.contains(fs.readString("man/jsnake.1"), '"jsnake ' + $bare + '"'));
}

func testTheManPageInventsNoFlags() {
    # And the other direction, which is the one that misleads a reader: a flag described
    # in the page that the program would reject. Every `\-\-name` in the page has to be a
    # flag some subcommand declares.
    def page as string init fs.readString("man/jsnake.1");
    def known as map of string to bool init {"help": true, "version": true};
    for (def c in grammar().commands) {
        for (def a in $c.parser.args) {
            if ($a.kind == "flag") {
                $known[$a.name] = true;
            }
        }
    }
    for (def named in roffFlagsIn($page)) {
        testing.assertTrue(maps.has($known, $named));
    }
}

# roffFlag is how `man/jsnake.1` has to spell a long flag: roff needs a literal hyphen
# escaped as `\-`, or it may typeset it as a line-breakable dash.
func roffFlag(name as string) {
    return '\-\-' + strings.replace($name, "-", '\-');
}

# roffFlagsIn pulls every long flag named in a roff source back out of it, undoing the
# escaping, so the page can be checked against the parser in both directions.
func roffFlagsIn(page as string) {
    def out as list of string init [];
    def parts as list of string init strings.split($page, '\-\-');
    for (def i as int init 1; $i < len($parts); $i = $i + 1) {
        def word as string init "";
        def chars as list of string init strings.chars($parts[$i]);
        for (def n as int init 0; $n < len($chars); $n = $n + 1) {
            def ch as string init $chars[$n];
            if ($ch == '\' and $n + 1 < len($chars) and $chars[$n + 1] == "-") {
                $word = $word + "-";
                $n = $n + 1;
            } elseif (isFlagChar($ch)) {
                $word = $word + $ch;
            } else {
                break;
            }
        }
        if (len($word) > 0) {
            $out[] = $word;
        }
    }
    return $out;
}

# isFlagChar is the character class a long flag name is built from.
func isFlagChar(ch as string) {
    return strings.contains("abcdefghijklmnopqrstuvwxyz", $ch);
}

func testTheLicenceFilesAreTheTextsTheManifestNames() {
    # Every source file claims LGPL-3.0-only in its SPDX header and the manifest repeats
    # it, which is worth nothing unless the terms actually ship. LGPL-3.0 is additional
    # permissions over GPL-3.0 and incorporates it by reference, so a lone LGPL file would
    # be an incomplete licence - both have to be here, and both have to be the real text
    # rather than a stub or a link.
    def manifest as toml.Value init toml.decode(fs.readString("deck.toml"));
    testing.assertEqual(toml.asString(toml.get($manifest, "/package/license")), "LGPL-3.0-only");

    def lesser as string init fs.readString("LICENSE");
    testing.assertTrue(strings.contains($lesser, "GNU LESSER GENERAL PUBLIC LICENSE"));
    testing.assertTrue(strings.contains($lesser, "Version 3, 29 June 2007"));
    testing.assertTrue(strings.contains(
        $lesser,
        "incorporates\nthe terms and conditions of version 3 of the GNU General Public"));

    def general as string init fs.readString("LICENSE.GPL-3.0");
    testing.assertTrue(strings.contains($general, "GNU GENERAL PUBLIC LICENSE"));
    testing.assertTrue(strings.contains($general, "Version 3, 29 June 2007"));
}

func testTheDescriptionIsShortEnoughToBeUsedAnywhere() {
    # Under 200 so it fits a repository blurb, a registry card and an AUR pkgdesc.
    testing.assertTrue(len(DESCRIPTION) <= 200);
    testing.assertTrue(len(DESCRIPTION) > 0);
}

func testTheDescriptionNamesWhatTheGameIs() {
    for (def word in ["Multiplayer", "snake", "Jennifer", "UDP", "TCP"]) {
        testing.assertTrue(strings.contains(DESCRIPTION, $word));
    }
}
