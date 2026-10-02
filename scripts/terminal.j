#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: net
#
# Answer "why is my field smaller than my screen?" by printing what jsnake sees.
#
#     ./scripts/terminal.j
#
# The first line is the size the terminal reports through its own ioctl - the same
# number `stty size` and `tput cols` read. If that is smaller than the window looks,
# the shortfall is between the terminal and the window (a split, a pane, an
# unmaximized window), not in the game: no program can use columns the terminal does
# not report. If it matches the window, the table below shows what the game does with
# them, and which limit is spending them.

use io;
use term;
use os;

import "../src/rules.j" as rules;
import "../src/view.j" as view;
import "../src/link.j" as link;

if (not os.isTerminal("stdout")) {
    io.eprintf("scripts/terminal.j: run this in a terminal\n");
    exit 2;
}

def size as term.Size init term.size("stdout");
io.printf("the terminal reports %d rows x %d columns\n", $size.rows, $size.cols);
io.printf("  cross-check with: stty size   (rows cols)\n\n");
io.printf("%s\n", "  players   field        on udp       scoreboard");
for (def players in [2, 4, 6, 8]) {
    def room as view.Room init view.maxField($size.rows, $size.cols, $players, true);
    def udp as view.Room init view.withinArea($room, link.maxFieldArea(link.UDP));
    # The pair is composed first: a `pad` modifier lines up one number, not "W x H".
    def both as string init io.sprintf("%d x %d", $room.width, $room.height);
    def onUdp as string init io.sprintf("%d x %d", $udp.width, $udp.height);
    io.printf("  %d|pad=7   %s|pad=12 %s|pad=12 %d\n", $players, $both, $onUdp, $players);
}
io.printf("\nTwo columns go to the field's border. Five rows go to the header, the\n");
io.printf("border, the key line and the food key - and one more per seat, reserved\n");
io.printf("whether or not it is taken, so the field never shrinks when somebody\n");
io.printf("joins. That is what --players buys back.\n\n");
io.printf(
    "sanity limits: %d x %d cells. On udp a whole STATE line must fit one\n",
    rules.MAX_WIDTH,
    rules.MAX_HEIGHT);
io.printf(
    "datagram, which caps the area at %d cells; --mode tcp has no such limit.\n",
    link.maxFieldArea(link.UDP));
