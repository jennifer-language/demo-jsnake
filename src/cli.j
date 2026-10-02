# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net

/**
 * The command line: `jsnake host`, `join`, `solo`, and `list`.
 *
 * All the logic lives here rather than in `bin/jsnake`, which is a three-line
 * launcher, so the argument handling can be tested like anything else. `parse`
 * turns an argv into a `Plan` and touches nothing else - no socket, no terminal,
 * no exit - so every flag, every default, and every bad input is covered by a
 * test below. `main` is the thin part that acts on a `Plan`.
 *
 * **Bad input is corrected, not refused, wherever there is an obvious right
 * answer.** A field of 2 cells becomes the smallest playable one; an unknown bot
 * level becomes the default. A player who mistypes a number should get a game,
 * not a usage message. The exceptions are the things that have no sensible
 * correction - an unknown transport or an unreadable flag - which are errors with
 * a message naming the choices.
 * @module cli
 * @author mplx <jennifer@mplx.dev>
 * @license LGPL-3.0-only
 * @example
 * # bin/jsnake is only this:
 * import "../src/cli.j" as cli;
 * exit cli.main(os.ARGS);
 */

use io;
use strings;

import "args.j" as args;
import "./release.j" as release;
import "./rules.j" as rules;
import "./bot.j" as bot;
import "./link.j" as link;
import "./beacon.j" as beacon;
import "./host.j" as host;
import "./guest.j" as guest;

/**
 * The program's version, reported by `--version`. Generated into `src/release.j` from git
 * by `scripts/release.sh`, so a build says which commit it came from rather than whatever
 * somebody last remembered to edit by hand.
 */
export def const VERSION as string init release.VERSION;

/**
 * The game's one-line description - the same words the deck manifest carries, so the two
 * cannot drift. A test compares them.
 */
export def const DESCRIPTION as string init "Multiplayer snake game for Linux console, " +
    "written in Jennifer, over UDP/TCP, with UDP discovery, CPU opponents, special food.";

# The description as the usage header shows it, broken at a word boundary.
#
# `args` prints the help text verbatim, and 125 characters soft-wraps mid-word on an
# 80-column terminal - the narrowest that can host a game - which reads as a typo. The
# break is derived from `DESCRIPTION` rather than written out again: change the wording and
# it follows, and if that phrase ever goes away the replace is a no-op and the line simply
# soft-wraps.
def const USAGE_HELP as string init strings.replace(DESCRIPTION, "UDP/TCP, with", "UDP/TCP,\nwith");

/**
 * The command name, as it appears in usage text.
 */
export def const PROGRAM as string init "jsnake";

/**
 * The subcommand that hosts a game others can join.
 */
export def const HOST as string init "host";

/**
 * The subcommand that joins somebody else's game.
 */
export def const JOIN as string init "join";

/**
 * The subcommand that plays against computer players alone, with no network.
 */
export def const SOLO as string init "solo";

/**
 * The subcommand that lists the games on this network and exits, drawing nothing.
 */
export def const LIST as string init "list";

/**
 * How many computer players `solo` seats when none was asked for. Three makes a
 * lively field on a default-sized board without crowding it.
 */
export def const SOLO_BOTS as int init 3;

/**
 * What the command line asked for. One of `host`, `join`, `solo`, or `list` is
 * chosen; `text` carries the message to print for `--help`, `--version`, and for
 * an argument error.
 * @field action {string} the subcommand chosen, or "" when there is only text to print
 * @field hostOpts {host.Options} how to host, for `host` and `solo`
 * @field guestOpts {guest.Options} how to join, for `join`
 * @field timeoutMs {int} how long `list` listens for hosts
 * @field text {string} the message to print, or ""
 * @field code {int} the exit code to use when `action` is ""
 */
export def struct Plan {
    action as string,
    hostOpts as host.Options,
    guestOpts as guest.Options,
    timeoutMs as int,
    text as string,
    code as int
};

/**
 * Turn an argv into a `Plan`. Pure: it reads `argv` and returns what to do,
 * performing no I/O and never exiting, which is what makes the whole command line
 * testable.
 *
 * `argv` is `os.ARGS`, whose first element is the script path.
 * @param argv {list of string} the command line, script path first
 * @return {Plan} what to do, or the text to print instead
 */
export func parse(argv as list of string) {
    def p as args.Parser init grammar();
    def r as args.Result init args.Result{
        command: "",
        values: {},
        lists: {},
        counts: {},
        present: {},
        helpText: "",
        done: false
    };
    try {
        $r = args.parse($p, $argv);
    } catch (e) {
        return message(usageError($e.message, $p), 2);
    }
    if ($r.done) {
        return message($r.helpText, 0);
    }
    if ($r.command == "") {
        return message(args.usage($p), 1);
    }
    return planFor($r);
}

# message is a plan that only prints something and stops.
func message(text as string, code as int) {
    return Plan{
        action: "",
        hostOpts: host.defaults(),
        guestOpts: guest.defaults(),
        timeoutMs: beacon.DISCOVER_MS,
        text: $text,
        code: $code
    };
}

# usageError puts the parser's own complaint above a reminder of the usage, which
# is what a person who mistyped a flag actually wants to see.
func usageError(complaint as string, p as args.Parser) {
    return PROGRAM + ": " + $complaint + "\n\n" + args.usage($p);
}

# grammar builds the whole command line. Kept as one function so every flag, its
# default, and its help text sit on one screen.
func grammar() {
    def p as args.Parser init args.version(args.parser(PROGRAM, USAGE_HELP), VERSION);
    $p = args.command($p, HOST, "host a game others can join", hostGrammar());
    $p = args.command($p, JOIN, "join a game on this network", joinGrammar());
    $p = args.command($p, SOLO, "play against the computer, no network", soloGrammar());
    $p = args.command($p, LIST, "list the games on this network and exit", listGrammar());
    return $p;
}

func hostGrammar() {
    def p as args.Parser init args.parser(PROGRAM + " " + HOST, "host a game");
    $p = args.flag($p, "mode", "m", link.UDP, "transport: tcp or udp");
    $p = args.intFlag($p, "port", "p", link.DEFAULT_PORT, "game port to listen on");
    $p = args.flag($p, "name", "n", host.DEFAULT_NAME, "your name, shown to others");
    $p = withFieldFlags($p);
    $p = args.intFlag($p, "players", "", rules.MAX_PLAYERS, "how many players to allow");
    $p = withBotFlags($p, 0);
    $p = args.flag(
        $p,
        "on-leave",
        "",
        host.DEFAULT_ON_LEAVE,
        "when a player drops out: forfeit or takeover");
    $p = withLivesFlag($p);
    $p = args.boolFlag($p, "plain", "", "classic rules: plain food only, no specials");
    $p = args.boolFlag($p, "now", "", "skip the title screen and start at once");
    $p = args.intFlag($p, "seed", "", 0, "random seed; 0 picks one from the clock");
    $p = args.boolFlag($p, "watch", "", "referee only, do not play yourself");
    return args.boolFlag($p, "private", "", "do not answer discovery broadcasts");
}

func joinGrammar() {
    def p as args.Parser init args.parser(PROGRAM + " " + JOIN, "join a game");
    $p = args.flag($p, "host", "H", "", "host address as ip:port; omit to go looking");
    $p = args.flag($p, "mode", "m", link.UDP, "transport when --host is given");
    $p = args.flag($p, "name", "n", guest.DEFAULT_NAME, "your name, shown to others");
    return args.intFlag(
        $p,
        "timeout",
        "t",
        beacon.DISCOVER_MS,
        "how long to look for games, in ms");
}

func soloGrammar() {
    def p as args.Parser init args.parser(PROGRAM + " " + SOLO, "play the computer");
    $p = args.flag($p, "name", "n", host.DEFAULT_NAME, "your name on the scoreboard");
    $p = withFieldFlags($p);
    $p = withLivesFlag($p);
    $p = args.boolFlag($p, "plain", "", "classic rules: plain food only, no specials");
    $p = args.boolFlag($p, "setup", "", "show the title screen before starting");
    return withBotFlags($p, SOLO_BOTS);
}

func listGrammar() {
    def p as args.Parser init args.parser(PROGRAM + " " + LIST, "list games");
    return args.intFlag(
        $p,
        "timeout",
        "t",
        beacon.DISCOVER_MS,
        "how long to look for games, in ms");
}

# withFieldFlags and withBotFlags are the flag groups more than one subcommand
# offers, so `host --width` and `solo --width` cannot drift apart.
func withFieldFlags(p as args.Parser) {
    # A cap, not a request: left at the game's own maximum it never binds, and the
    # terminals at the table decide the field size between them.
    def out as args.Parser init args.intFlag(
        $p,
        "width",
        "w",
        rules.MAX_WIDTH,
        "maximum field width; by default the terminals at the table decide");
    $out = args.intFlag(
        $out,
        "height",
        "",
        rules.MAX_HEIGHT,
        "maximum field height; by default the terminals at the table decide");
    return args.intFlag(
        $out,
        "tick",
        "",
        host.DEFAULT_TICK_MS,
        "milliseconds per move; lower is faster");
}

# withLivesFlag is the lives option, offered by every subcommand that hosts a game so
# `host --lives` and `solo --lives` cannot drift apart.
# withLivesFlag is the two rules-of-the-game options every hosting subcommand offers, so
# `host` and `solo` cannot drift apart on them.
func withLivesFlag(p as args.Parser) {
    def out as args.Parser init args.intFlag(
        $p,
        "lives",
        "",
        rules.DEFAULT_LIVES,
        "lives per player before they are a spectator; 0 for unlimited");
    return args.boolFlag(
        $out,
        "wrap",
        "",
        "no walls: off one edge and in at the opposite one, like pac-man");
}

func withBotFlags(p as args.Parser, deflt as int) {
    def out as args.Parser init args.intFlag(
        $p,
        "bots",
        "b",
        $deflt,
        "how many computer players to add");
    return args.flag(
        $out,
        "bot-level",
        "l",
        bot.DEFAULT_LEVEL,
        "computer skill: easy, normal, hard, or expert");
}

# planFor turns a parsed result into the plan for its subcommand.
func planFor(r as args.Result) {
    match ($r.command) {
        when HOST { return hostPlan($r); }
        when SOLO { return soloPlan($r); }
        when JOIN { return joinPlan($r); }
        when LIST { return listPlan($r); }
        else { return message(PROGRAM + ": unknown command", 2); }
    }
}

func hostPlan(r as args.Result) {
    def mode as string init strings.lower(args.asString($r, "mode"));
    if (not link.isTransport($mode)) {
        return message(badTransport($mode), 2);
    }
    def out as Plan init message("", 0);
    $out.action = HOST;
    $out.hostOpts = host.Options{
        mode: $mode,
        port: args.asInt($r, "port"),
        name: args.asString($r, "name"),
        width: args.asInt($r, "width"),
        height: args.asInt($r, "height"),
        tickMs: args.asInt($r, "tick"),
        capacity: args.asInt($r, "players"),
        seed: args.asInt($r, "seed"),
        play: not args.asBool($r, "watch"),
        discoverable: not args.asBool($r, "private"),
        bots: atLeast(args.asInt($r, "bots"), 0),
        botLevel: bot.levelOr(strings.lower(args.asString($r, "bot-level"))),
        onLeave: host.leavePolicyOr(strings.lower(args.asString($r, "on-leave"))),
        specials: not args.asBool($r, "plain"),
        lobby: not args.asBool($r, "now"),
        lives: rules.livesOr(args.asInt($r, "lives")),
        wrap: args.asBool($r, "wrap")
    };
    return $out;
}

# soloPlan is a host that binds an ephemeral port, answers no broadcasts, and
# starts with computer players already on the field - a one-player game that
# reuses the whole host, rather than a second code path that could disagree with it.
func soloPlan(r as args.Result) {
    def out as Plan init message("", 0);
    $out.action = SOLO;
    $out.hostOpts = host.Options{
        mode: link.UDP,
        port: 0,
        name: args.asString($r, "name"),
        width: args.asInt($r, "width"),
        height: args.asInt($r, "height"),
        tickMs: args.asInt($r, "tick"),
        capacity: rules.MAX_PLAYERS,
        seed: 0,
        play: true,
        discoverable: false,
        bots: atLeast(args.asInt($r, "bots"), 1),
        botLevel: bot.levelOr(strings.lower(args.asString($r, "bot-level"))),
        onLeave: host.FORFEIT,
        specials: not args.asBool($r, "plain"),
        lobby: args.asBool($r, "setup"),
        lives: rules.livesOr(args.asInt($r, "lives")),
        wrap: args.asBool($r, "wrap")
    };
    return $out;
}

func joinPlan(r as args.Result) {
    def mode as string init strings.lower(args.asString($r, "mode"));
    if (not link.isTransport($mode)) {
        return message(badTransport($mode), 2);
    }
    def out as Plan init message("", 0);
    $out.action = JOIN;
    $out.guestOpts = guest.Options{
        mode: $mode,
        address: strings.trim(args.asString($r, "host")),
        name: args.asString($r, "name"),
        discoverMs: atLeast(args.asInt($r, "timeout"), 1)
    };
    return $out;
}

func listPlan(r as args.Result) {
    def out as Plan init message("", 0);
    $out.action = LIST;
    $out.timeoutMs = atLeast(args.asInt($r, "timeout"), 1);
    return $out;
}

# badTransport names the choices rather than only rejecting the wrong one: there
# are exactly two and listing them is shorter than explaining the mistake.
func badTransport(mode as string) {
    return PROGRAM + ": unknown transport \"" + $mode + "\"; use " +
        strings.join(link.TRANSPORTS, " or ");
}

func atLeast(v as int, lo as int) {
    if ($v < $lo) {
        return $lo;
    }
    return $v;
}

/**
 * Run the command line: parse `argv`, then do what it asked.
 * @param argv {list of string} the command line, script path first (`os.ARGS`)
 * @return {int} the process exit code
 */
export func main(argv as list of string) {
    def plan as Plan init parse($argv);
    if (len($plan.text) > 0) {
        return report($plan);
    }
    match ($plan.action) {
        when HOST, SOLO { return host.run($plan.hostOpts); }
        when JOIN { return guest.run($plan.guestOpts); }
        when LIST { return printGames($plan.timeoutMs); }
        else { return 2; }
    }
}

# report prints a plan's message, on stderr when it is a complaint and on stdout
# when it is help the user asked for.
func report(plan as Plan) {
    if ($plan.code == 0) {
        io.printf("%s\n", $plan.text);
    } else {
        io.eprintf("%s\n", $plan.text);
    }
    return $plan.code;
}

# printGames prints the games it can find and exits. No terminal needed, so this is
# also the way to check discovery from a script or over ssh. Not named `list`:
# that is a type keyword.
func printGames(timeoutMs as int) {
    def found as list of beacon.Found init beacon.discover($timeoutMs);
    if (len($found) == 0) {
        io.printf("no games found on this network\n");
        return 1;
    }
    for (def h in $found) {
        io.printf("%s\n", beacon.describe($h));
    }
    return 0;
}
