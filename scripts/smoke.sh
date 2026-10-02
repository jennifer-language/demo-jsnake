#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Run the game for real, briefly, and fail on any runtime error.
#
# Why this exists: `host.run`, `host.lobby` and `guest.session` are the one part of the
# program `jennifer test` cannot reach - they take over the terminal, open sockets, and
# run until a key is pressed. Jennifer checks argument types when a call executes, not
# when it parses, so a signature changed in those loops is invisible to the suite and to
# `lint`: it surfaces the first time the line runs, as a game that will not start. That is
# why this script is part of verification rather than an optional extra.
#
#     sh scripts/smoke.sh
#
# Needs `script` (util-linux) for a pty, and a free port range around 47900.

set -u
here=$(dirname "$0")
jsnake="$here/../bin/jsnake"
log=$(mktemp -d)
trap 'rm -rf "$log"' EXIT
fails=0

# The words the title screen puts on the page, used to tell "waiting to start" from
# "already playing" below.
title_mark='waiting to start'

# run NAME TIMEOUT KEYS ARGS... - drive the game under a pty and check it stayed alive.
run() {
    name=$1
    shift
    seconds=$1
    shift
    keys=$1
    shift
    out="$log/$name.log"
    ( printf '%s' "$keys" | timeout "$seconds" script -qec "$jsnake $*" /dev/null ) \
        >"$out" 2>&1 || true
    if grep -qE 'runtime error|parse error|lex error' "$out"; then
        echo "FAIL $name"
        grep -m2 -E 'runtime error|parse error|lex error' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    else
        echo "ok   $name"
    fi
}

# timed NAME TIMEOUT SCRIPT ARGS... - drive the game with keys delivered *over time*.
#
# `run` pipes every key in before the program has entered raw mode, so the tty line
# discipline eats them and the game never sees them. That is fine for "start and let it
# tick", but it cannot test a sequence: pressing Enter and then Escape has to happen in that
# order, seconds apart. SCRIPT is shell run on the write end of the pipe, so it can sleep
# between keys.
#
# Use this, not `run`, for anything asserting a *transition*: with `run` the keys never
# arrive, so a check like "Escape goes back to the title screen" would pass against a host
# that had never left it.
timed() {
    name=$1
    shift
    seconds=$1
    shift
    keyscript=$1
    shift
    out="$log/$name.log"
    ( eval "$keyscript" | timeout "$seconds" script -qec "$jsnake $*" /dev/null ) \
        >"$out" 2>&1 || true
    if grep -qE 'runtime error|parse error|lex error' "$out"; then
        echo "FAIL $name"
        grep -m2 -E 'runtime error|parse error|lex error' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    else
        echo "ok   $name"
    fi
}

# returned NAME - assert the host went into a game and came back out to its title screen.
#
# Not just "a title screen appeared": it has to appear *after* the in-game key legend, or
# the check passes on a host that never started a round at all.
returned() {
    name=$1
    out="$log/$name.log"
    title=$(grep -bo "$title_mark" "$out" | tail -n1 | cut -d: -f1)
    game=$(grep -bo 'wasd steer' "$out" | tail -n1 | cut -d: -f1)
    if [ -z "$game" ]; then
        echo "FAIL $name never reached a game screen"
        fails=$((fails + 1))
    elif [ -z "$title" ] || [ "$title" -lt "$game" ]; then
        echo "FAIL $name did not come back to the title screen"
        fails=$((fails + 1))
    else
        echo "ok   $name went into a game and back to the title screen"
    fi
}

# left NAME - assert the program actually exited rather than being killed by the timeout.
#
# Leaving the alternate screen is the signal: `screen.end` emits it on the way out, and a
# process killed mid-game never does.
left() {
    name=$1
    out="$log/$name.log"
    if grep -q '1049l' "$out"; then
        echo "ok   $name exited on its own"
    else
        echo "FAIL $name was still running when the timeout killed it"
        fails=$((fails + 1))
    fi
}

# sized NAME TIMEOUT ROWS COLS KEYS ARGS... - the same, on a terminal of a known size.
#
# `script` gives the child whatever size the controlling terminal has, which in CI is
# whatever the runner felt like - so a screen that only breaks at 80x24 would break
# nowhere reproducible. `stty` inside the pty sets it before the game reads it.
sized() {
    name=$1
    shift
    seconds=$1
    shift
    rows=$1
    shift
    cols=$1
    shift
    keys=$1
    shift
    out="$log/$name.log"
    ( printf '%s' "$keys" \
        | timeout "$seconds" script -qec "stty rows $rows cols $cols; $jsnake $*" /dev/null ) \
        >"$out" 2>&1 || true
    if grep -qE 'runtime error|parse error|lex error' "$out"; then
        echo "FAIL $name"
        grep -m2 -E 'runtime error|parse error|lex error' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    else
        echo "ok   $name"
    fi
}

# fits NAME - assert the title screen was not cut off at the bottom.
#
# A screen too tall for the terminal does not error: `view.message` centres the box and
# the rows past the edge are simply never drawn. What goes missing first is the bottom of
# the box - the field size and the key line, which are the two things a host most needs -
# so their absence is the symptom to check for. A full table on an 80x24 terminal is the
# case that needs the tightest layout, which is why it is the one driven here.
fits() {
    name=$1
    out="$log/$name.log"
    missing=""
    grep -qF 'up/down choose' "$out" || missing="$missing key-line"
    grep -qE 'field [0-9]+ x [0-9]+' "$out" || missing="$missing field-size"
    grep -qF '└' "$out" || missing="$missing bottom-border"
    if [ -z "$missing" ]; then
        echo "ok   $name fits its terminal"
    else
        echo "FAIL $name was cut off, missing:$missing"
        fails=$((fails + 1))
    fi
}

# wants NAME title|game - assert which screen the last run actually opened on.
#
# This is not the same check as `run`: a mis-wired call that stops the title screen from
# being skipped crashes nothing, so "it did not error" says nothing about whether --now was
# honoured. Only looking at the screen does.
wants() {
    name=$1
    expect=$2
    out="$log/$name.log"
    if grep -qF "$title_mark" "$out"; then
        got=title
    else
        got=game
    fi
    if [ "$got" = "$expect" ]; then
        echo "ok   $name opens on the $expect screen"
    else
        echo "FAIL $name opened on the $got screen, expected $expect"
        fails=$((fails + 1))
    fi
}

echo "smoke: running the game for real (errors the test suite cannot see)"

# The title screen, then every setup row visited with an arrow, then start.
run "host-lobby"    6 "$(printf '\033[B\033[C\033[B\033[C\033[B\033[C\033[B\033[C\033[B\033[C\r')" \
    host --port 47901 --players 3 --name smoke
run "host-now"      5 ""  host --port 47902 --now --bots 1 --name smoke
run "host-tcp"      5 ""  host --port 47903 --now --mode tcp --bots 1 --name smoke
run "host-watch"    5 ""  host --port 47904 --now --watch --bots 2 --name smoke
run "host-plain"    5 ""  host --port 47905 --now --plain --bots 1 --name smoke
run "host-private"  5 ""  host --port 47906 --now --private --bots 1 --name smoke
run "solo"          5 ""  solo --bots 2
run "solo-setup"    5 "$(printf '\r')" solo --setup --bots 1
# Escape is the only way out, and it takes two presses: `screen.nextKey` blocks on the
# second byte after an ESC, so one press is swallowed and the pair decodes as a single
# `escape`. Sending two is what a player actually does.
run "solo-esc"      5 "$(printf '\033\033')" solo --bots 1
# What Escape does in each context, driven for real: which one you get depends on where you
# are, and the loop that decides is not reachable from the suite.
#
# A playing host goes back to its title screen and does NOT quit.
timed "host-esc-menu" 9 \
    "sleep 1.2; printf '\r'; sleep 2.5; printf '\033\033'; sleep 2" \
    host --port 47907 --players 2 --bots 1 --name smoke
# A host already on its title screen has nothing behind it, so it leaves.
timed "host-esc-exit" 7 \
    "sleep 1.5; printf '\033\033'; sleep 2" \
    host --port 47911 --players 2 --bots 1 --name smoke
# A solo player never saw a title screen, so Escape leaves rather than dropping them on one.
timed "solo-esc-exit" 7 "sleep 1.5; printf '\033\033'; sleep 2" solo --bots 1
# ...but `solo --setup` came from one, so Escape goes back to it.
timed "solo-setup-back" 9 \
    "sleep 1.2; printf '\r'; sleep 2.5; printf '\033\033'; sleep 2" \
    solo --setup --bots 1
# A single Escape is swallowed (see `keys.ESCAPE_NEEDS_TWO`), so the game must keep running
# rather than half-acting on it.
timed "solo-one-esc" 6 "sleep 1.5; printf '\033'; sleep 3" solo --bots 1
# And the letters we removed must do nothing at all.
timed "solo-qx-inert" 6 "sleep 1.5; printf 'qQxX'; sleep 3" solo --bots 1
# A full table on the ordinary terminal - the case the title screen's layouts exist for, and
# the only one that reaches the folded roster. It belongs here rather than in the suite
# because a `_test.j` overlay's own `use` declarations are in scope for the module under
# test, so a namespace the module itself forgot to declare resolves under the suite and
# nowhere else. Running the program is the only check that sees it.
sized "host-full-80x24"  6 24 80 "" host --port 47908 --players 8 --bots 7 --name smoke
sized "host-full-80x20"  6 20 80 "" host --port 47909 --players 8 --bots 7 --name smoke
sized "host-two-80x24"   6 24 80 "" host --port 47910 --players 2 --bots 1 --name smoke
run "join-nobody"   6 "$(printf '\033\033')" join --timeout 300
run "join-refused"  6 ""  join --host 127.0.0.1:47999 --mode tcp

# Which screen each one opened on - a title screen that cannot be skipped, or a game
# that never waits, are both bugs that error nowhere.
wants "host-lobby" title
wants "host-now"   game
wants "solo"       game
wants "solo-setup" title
returned "host-esc-menu"
returned "solo-setup-back"
left "host-esc-exit"
left "solo-esc-exit"

# The two that must NOT have exited: a single Escape, and the removed letters.
for inert in solo-one-esc solo-qx-inert; do
    if grep -q '1049l' "$log/$inert.log"; then
        echo "FAIL $inert left the game when it should have ignored the keys"
        fails=$((fails + 1))
    else
        echo "ok   $inert ignored the keys and kept playing"
    fi
done
wants "host-full-80x24" title

# And that the title screen it opened on was all there.
fits "host-full-80x24"
fits "host-full-80x20"
fits "host-two-80x24"

# `list` needs no terminal at all, so it is checked directly.
if "$jsnake" list --timeout 200 >"$log/list.log" 2>&1 || [ $? -eq 1 ]; then
    if grep -qE 'runtime error|parse error' "$log/list.log"; then
        echo "FAIL list"
        fails=$((fails + 1))
    else
        echo "ok   list"
    fi
fi

if [ "$fails" -gt 0 ]; then
    echo "smoke: $fails failed"
    exit 1
fi
echo "smoke: all clear"
