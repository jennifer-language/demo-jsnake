# jsnake

Multiplayer snake game for the Linux console, written in
[Jennifer](https://jennifer-lang.dev). Players find each other by UDP broadcast, so
nobody types an address; the game itself runs over **either TCP or UDP**, and empty seats
can be filled by CPU opponents at four difficulty levels.

```
jsnake  tick 122    5 player(s)  hosting udp:47475  public
┌──────────────────────────────────────────────────────────────────────────────┐
│         * **                                  @                              │
│        %%%%* * * *                                                           │
│        %%%%                                                                  │
│     V  %%        * *                                                         │
│        %%%                                                                   │
│        % %%        *                                                         │
│        %            *                                                        │
│        @                                      C         OOOOOO               │
│                                                @        O    O         *     │
│                                                +++      O    @      @XX      │
│                                                  +      OOO           X      │
│                                              +   +                    XX     │
│         !                                    +++ ++                    XXXXXX│
│                                                ++++ *                        │
└──────────────────────────────────────────────────────────────────────────────┘
> O ada              50  len  14  ♥2  alive
  X cpu1-normal      40  len  12  ♥2  alive
 *# cpu2-normal      90  len   4  ♥2  alive
  % cpu3-normal      70  len  18  ♥3  alive
  + cpu4-normal      60  len  16  ♥3  alive
arrows / wasd steer    esc esc  menu    ^C  quit
* food  C candy +3  V veg -3  ! toadstool!  G ghost
```

<sup>A real capture, not a mockup: five players on an 80x24 terminal, `ada` at the keyboard
against four `normal` bots. Candy, vegetables and a toadstool are on the field alongside
the plain food, and the key line shows the whole control surface — steer, back out, stop.</sup>

## Playing

```sh
jsnake solo                       # against the computer, no network
jsnake host                       # host a game others can find
jsnake join                       # find a game on this network and join it
jsnake list                       # just show what is out there, draw nothing
```

Arrow keys or WASD steer. **Escape is the only other key you need**: it backs out of
wherever you are, and what that comes to depends on where that is.

| Where you are | Escape |
| ------------- | ------ |
| playing, as a host who came from the title screen | ends the round, back to the title screen |
| on the host's title screen | leaves — there is nothing behind it |
| on the final standings | back to the title screen (Enter plays another round) |
| playing, as a client | leaves — a client has no screen of its own behind the game |
| playing `jsnake solo`, or a host started with `--now` | leaves — you never saw a title screen |
| on the join menu | leaves |

So Escape repeated always gets you out, one screen at a time, and there is no table of
exit keys to remember. Ctrl-C stops the program immediately from anywhere; it is the
terminal's own convention rather than one of the game's keys. No plain letter is a
command — the letters steer.

> **Escape needs two presses.** `screen.nextKey` reads a second byte unconditionally after
> an `ESC` and `term` has no timed read, so a lone Escape is never delivered; press it
> twice and the pair arrives as one `escape`. That is why every key legend says `esc esc`
> rather than `esc` — the legend is built from `keys.ESCAPE_NEEDS_TWO`, so the day a single
> press works, one constant changes and the screens follow. See **Known limitation**
> below.

### The title screen

`jsnake host` opens on a title screen rather than dropping you into a game. You change
the settings there while players arrive, and the game starts when you say so:

```


      ┌─ waiting to start ──────────────────────────────────────────────┐
      │                                                                 │
      │       ╭──╮  ╭──╮                                                │
      │    @──╯  ╰──╯  ╰──                                              │
      │     ╦ ╔═╗╔╗╔╔═╗╦╔═╔═╗                                           │
      │     ║ ╚═╗║║║╠═╣╠╩╗║╣                                            │
      │    ╚╝ ╚═╝╝╚╝╩ ╩╩ ╩╚═╝                                           │
      │                                                                 │
      │ hosting udp:47475  public                                       │
      │                                                                 │
      │   speed              100 ms per move                            │
      │ > players            6                                          │
      │   lives              3                                          │
      │   edges              wrap around                                │
      │   computer players   3                                          │
      │   computer skill     normal                                     │
      │   on disconnect      forfeit                                    │
      │   special food       on                                         │
      │                                                                 │
      │ field 78 x 23, the largest every terminal here can show         │
      │                                                                 │
      │ players 4 of 6                                                  │
      │   ada            at the keyboard                                │
      │   cpu1-normal    computer                                       │
      │   cpu2-normal    computer                                       │
      │   cpu3-normal    computer                                       │
      │                                                                 │
      │ up/down choose   left/right change   enter start   esc esc quit │
      │                                                                 │
      └─────────────────────────────────────────────────────────────────┘
```

<sup>`jsnake host --bots 3 --players 6 --name ada --tick 100 --wrap`, captured on an
80x34 terminal. Six seats, four taken, the cursor on `players`, and `edges` already
switched to `wrap around`.</sup>

Up and down pick a row, left and right change it, Enter starts. Everything on that
list can be changed right up to the moment you start, including adding and removing
computer players — the table is rebuilt as you go, and anyone who has already joined
keeps their seat.

Joined players see the same roster on their own waiting screen, so nobody has to ask
whether they got in. `--now` skips the title screen for a host in a hurry, and
`jsnake solo --setup` shows it for a solo game, which otherwise starts at once.

**It fits the terminal it is drawn on.** The screen above wants 34 rows with eight
players, which an ordinary 80x24 does not have — so there is a short list of layouts and
the host takes the first that fits. What gives way, in order: the logo, then the blank
lines between sections, then the roster folds into two columns and trades
`at the keyboard` for `you`. The settings never give way, because they are what the
screen is for. On 80x24 with a full table:

```
┌─ waiting to start ──────────────────────────────────────────────┐
│                                                                 │
│ hosting udp:47475  public                                       │
│                                                                 │
│ > speed              125 ms per move                            │
│   players            8                                          │
│   lives              3                                          │
│   edges              walls                                      │
│   computer players   7                                          │
│   computer skill     normal                                     │
│   on disconnect      forfeit                                    │
│   special food       on                                         │
│ field 78 x 11, the largest every terminal here can show         │
│ players 8 of 8                                                  │
│   ada           you      cpu1-normal   cpu                      │
│   cpu2-normal   cpu      cpu3-normal   cpu                      │
│   cpu4-normal   cpu      cpu5-normal   cpu                      │
│   cpu6-normal   cpu      cpu7-normal   cpu                      │
│                                                                 │
│ up/down choose   left/right change   enter start   esc esc quit │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

A folded entry still says who is driving, and still flags a window too small for the
agreed field — as a `!`, with one legend line spelling it out, which is cheaper than the
words on every row. Give the host a taller terminal and the logo and the long wording
come back on their own.

The layout is chosen by *building* each candidate and measuring it rather than by
predicting a height, so the screen cannot be a row taller than the budget it was checked
against. `testTheTitleScreenFitsEveryTableOnEveryTerminal` asserts that for every seat
count from 1 to 8 against every terminal from 20 to 40 rows, and three more tests assert
that what survives the shrinking is the part that matters.

### The field sizes itself to the table

Nobody picks a field size. Every player reports the terminal they are sitting at when
they join, and the host plays on **the largest field the smallest terminal can show** —
separately in each direction, so a short wide terminal decides the height and a tall
narrow one the width. The title screen shows the current answer and updates as people
arrive.

Two consequences worth knowing:

- Scoreboard rows are reserved for a **full** table, not for whoever happens to be
  present. The field therefore never changes because somebody joined, which is what
  stops a mid-game join from breaking anyone's display. Host with `--players 2` and you
  get the spare rows back as playing space.
- `--width` and `--height` are a **cap**, not a request: they can make the field smaller
  than the terminals would allow, never bigger. They default to the game's own sanity
  limit (240 x 100), so out of the box they do not bind and the terminals decide.
- **On UDP the field area is capped** at about 9,300 cells, because a whole `STATE` line
  has to fit one datagram. On a very large display that binds before your terminal does;
  `--mode tcp` has no such limit, since a stream reassembles a line across reads.
- The title screen always names whichever of the three limits actually bound - your
  terminals, your cap, or the datagram - so a field smaller than your display tells you
  which knob would change it.
- The host's own window always counts, seat or no seat: a `--watch` referee draws the
  same game everybody else does.

A player whose window is too small for the agreed field is flagged on the title screen
with `TERMINAL TOO SMALL` before the game starts, so they can resize it then rather
than discover it once everyone else is playing.

If the field comes out smaller than you expected, `./scripts/terminal.j` prints what
the game sees: the size your terminal reports, what each player count costs in
scoreboard rows, and where the UDP limit would bite. When the reported size is smaller
than the window looks, the shortfall is between the terminal and the window - a split,
a pane, an unmaximized window - and `stty size` will confirm it.

A snake that hits a wall, another snake, or a body dies, drops half of itself as food,
and comes back a few seconds later with its score intact — so a mistake costs you the
lead, not the evening.

### Walls, or no walls

```sh
jsnake host --wrap
```

With `--wrap` the border is not a border: step off one edge and you arrive at the
opposite one, the way you do in Pac-Man. The only things that can kill you are each
other. The frame is drawn **dashed** in that mode rather than solid, because a rule you
cannot see until you walk into it needs to be visible before you do:

```
·┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄·          ┌───────────────┐
┊   @OOO        ┊          │   @OOO        │
┊               ┊          │               │
·┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄·          └───────────────┘
   wrap around                   walls
```

It is also a row on the title screen (`edges`), and the computer players understand it:
they take the short way round the edges and their flood fill follows the field's real
shape, so a wrapped game is no easier against them than a walled one.

### Lives

You get **three lives**. Spend them all and you become a **spectator**: you keep your
seat, your name and your score, you keep watching the game, but you do not come back.
The scoreboard shows what everyone has left (`♥2`) and says `spectating` rather than
`dead` for anyone who is out — those are different things and the difference matters.

```sh
jsnake host --lives 5      # more forgiving
jsnake host --lives 1      # one mistake each
jsnake host --lives 0      # unlimited: the endless game, no spectators
```

Lives are also a row on the title screen, so they can be changed up to the moment the
game starts.

When the last player runs out, the **round ends**: the host gets the final standings and
a choice.

```
                  ┌─ jsnake - game over ────────────────────┐
                  │                                         │
                  │  1  cpu4-normal       300  2 death(s)   │
                  │  2  cpu3-normal       280  2 death(s)   │
                  │  3  cpu1-normal       100  2 death(s)   │
                  │  4  cpu2-normal       100  2 death(s)   │
                  │  5  ada                 0  2 death(s)   │
                  │                                         │
                  │ enter  another round      esc esc  menu │
                  │                                         │
                  └─────────────────────────────────────────┘
```

<sup>The same five-player game played out to its end with `--lives 2`, captured on an
80x24 terminal: every seat ranked by score, with the deaths that got them there, and the
host's two ways on. Nothing is still ticking behind this panel — the round is over.</sup>

Enter (or Escape) goes back to the title screen with everyone still seated — nobody
reconnects between rounds, because their sockets never went anywhere, and **nobody's
player id changes**, so every client still knows which snake is its own. From there
Escape again leaves.

A host can also end a round early by pressing Escape while playing. Either way the joined
players follow it back to their own waiting screen, which they work out from the **round
number** carried on both `STATE` and `LOBBY`: a lobby for the round they are in, or a
later one, is the host moving on, while a lobby for an earlier round is a stale message
that overtook a game state on UDP. Comparing two numbers needs nothing to be delivered
reliably, which is why it is done that way rather than with a "round over" message.

### Food

`*` plain food stays until somebody eats it and lengthens you a little. The rest
appear on their own, each at its own rate, and each vanishes again after its own
countdown — so a special is a chance to take, not a thing to plan around:

| | Item | Does | Lives | Turns up about every |
| --- | --- | --- | --- | --- |
| `C` | candy | three segments longer, and worth triple | 10s | 11s |
| `V` | vegetables | three segments **shorter** — fatal if you cannot spare them | 15s | 14s |
| `!` | toadstool | sudden death, however long you are | 15s | 17s |
| `G` | ghost | for 10s you slip through other snakes' **bodies** | 12s | 25s |

A ghost does not make you invulnerable, and that is the interesting part: another
snake's *head* still kills you, your own body still kills you, and so does a wall.
It gets you out of being surrounded, not out of being careless. It works one way
only — everyone else still hits you.

The countdowns are counted in **moves**, not seconds, so an item is worth the same
on a fast host as on a slow one; the seconds above are at the default tick. Only
one of each special is ever on the field at a time.

`--plain` turns all of it off for a table that wants the classic game.

### Hosting

```sh
jsnake host --mode tcp --port 47475 --name kitchen
jsnake host --bots 3 --bot-level hard        # fill the field with opponents
jsnake host --on-leave takeover              # a dropout's snake keeps playing
jsnake host --watch                          # referee only, do not play
jsnake host --private                        # do not answer discovery broadcasts
jsnake host --width 60 --height 24 --tick 90  # a bigger, faster field
jsnake host --plain                          # classic rules, plain food only
jsnake host --now                            # skip the title screen
```

Most of these are on the title screen too, so the command line is only needed to script
a host or to set what the title screen does not offer: the transport, the port, the
name, and the field cap.

`jsnake host --help` lists every flag with its default.

**`--on-leave`** decides what happens when somebody's network drops:

| Policy     | What happens                                                      |
| ---------- | ----------------------------------------------------------------- |
| `forfeit`  | the seat is freed and the snake leaves the field (the default)     |
| `takeover` | a computer player inherits the snake, its body, and its score      |

A player who leaves with Escape always forfeits, whatever the policy: choosing to leave
is not the same as being cut off, and nobody asked a computer to play on for them.

### Computer players

`--bot-level` sets the skill. The levels differ in what they are allowed to look
at, not in how much they cheat — none of them sees anything you cannot:

| Level    | How it plays                                                              |
| -------- | ------------------------------------------------------------------------- |
| `easy`   | wanders, avoiding what it can see is fatal. Ignores food.                  |
| `normal` | heads for the nearest food. Will happily seal itself into a pocket.        |
| `hard`   | as `normal`, but floods the space ahead and refuses a move with no room.   |
| `expert` | as `hard`, and treats a cell another head is entering as fatal, not risky. |

`easy` and `normal` cannot tell a toadstool from a crumb and will eat one on the
way to something else — which is a large part of why they are beatable. `hard` and
`expert` read each item's recipe and avoid a cell holding something that would hurt
them as firmly as they avoid a wall, and all of them will go out of their way for a
candy. None of them knows what to do with a ghost spell; they play on as if solid.

`hard` is the one that stops being beatable by accident: the room check is what
keeps a snake from trapping itself in its own coils.

### Joining a game by address

Discovery needs a broadcast that reaches you. Across a VPN, a bridged container,
or a firewall that eats `255.255.255.255`, name the host instead:

```sh
jsnake join --host 192.168.1.5:47475 --mode udp
```

`jsnake list` is the quickest way to tell a discovery problem from a game problem:
it prints what answered and exits, and needs no terminal, so it works over `ssh`
and in a pipe.

## How it fits together

Two rules shape the whole codebase, and everything else follows from them.

**One authority.** The host owns the only real game. Clients send a direction and
draw the `STATE` they are sent; they never simulate anything. With one authority
there is nothing to reconcile, so two players never see different games.

**Decisions are pure; only the edges do I/O.** Every rule, every protocol message,
every frame, and every computer-player decision is a pure function over a value.
The result is that the game is testable without a socket or a terminal — which is
why the suite below has no fixed sleeps in it and does not flake.

| Module      | What it owns                                                          |
| ----------- | --------------------------------------------------------------------- |
| `geom.j`    | cells, the four directions, and grid arithmetic                        |
| `rules.j`   | the game: one tick, collisions, food kinds, respawns, lives. Pure, seeded |
| `bot.j`     | the computer player: how an undriven snake chooses. Pure                |
| `proto.j`   | the wire protocol, one message per line. Pure, and total on garbage     |
| `link.j`    | moving messages over TCP **or** UDP behind one surface                  |
| `beacon.j`  | finding games by UDP broadcast                                         |
| `keys.j`    | what a keypress means, shared by host and guest                         |
| `view.j`    | drawing a frame with the `screen` module. Pure                          |
| `host.j`    | the authoritative side: the title screen, seats, ticks, policy          |
| `guest.j`   | the client side: join, wait in the lobby, steer, draw                   |
| `cli.j`     | the command line; `bin/jsnake` is only a launcher                       |

### Why one `Recipe` per food kind

Every special is a row in `rules.recipeFor` — its lifetime, its rate, what it does
to a body, whether it kills, how much ghosting it grants. Nothing else branches on
a kind: the tick applies a recipe, the renderer looks up a glyph, and the computer
player reads `fatal` and `grow` to decide whether an item is a trap. Adding a kind
is a row in that table and a glyph, not an edit in five files — and a kind this
version has never heard of, arriving from a newer peer, reads as plain food rather
than crashing anything.

### Why `maxField` is the inverse of `fit`

`view.fit` answers "will this game fit that terminal"; `view.maxField` answers "what is
the largest game that would". They are inverses, and a test asserts exactly that across
a grid of terminal sizes and player counts — which is what makes the negotiation
trustworthy. If they ever disagreed, the host would settle on a field some player could
not draw, and the only symptom would be one person staring at "terminal too small"
while everyone else played.

### Why the first `STATE` is what starts the game

There is no "go" message. A client leaves the lobby when the first `STATE` arrives,
because a dedicated start message would be one more thing to lose on UDP — and losing
it would leave a player watching a waiting screen while their snake was already on the
field. A `LOBBY` that arrives late, out of order, is ignored once play has begun, for
the same reason.

### Why the protocol is text

A tick is a few hundred bytes, so a line of text costs nothing a binary frame
would save and can be read with `nc` while debugging a host across the room. The
separators never nest: `|` between fields, `;` between records, `,` inside a
record, a space between body cells. Player names are scrubbed at the host's door,
which is what makes that grammar unambiguous rather than usually-unambiguous.

### Why UDP is offered at all

A `STATE` message is a complete picture rather than a delta, so a lost datagram is
a dropped frame that the next tick repairs, and steering is idempotent. That is
what makes the protocol survive UDP without sequence numbers — and why both
transports can sit behind one interface that the game above cannot tell apart.

### Why every decoder is total

Anything arriving from the network is untrusted. Decoding never throws and never
blocks: a line that cannot be understood becomes a `BAD` message and is dropped. A
host stopped by a malformed datagram would not survive its first port scan.

## Versions and releases

The **git tag is the version**. Nothing is hand-edited:

| Build | Version |
| ----- | ------- |
| on a clean release tag | `1.2.0` |
| anywhere else | `1.2.0+7.gd754881` — the tag it descends from, commits since, commit |
| no tags yet | `0.0.0+12.g1a2b3c4` |

The `+` form is SemVer **build metadata**, which is ignored when versions are compared —
so a dev build sorts equal to the release it came after, never above it. A prerelease
suffix (`-7.gabc`) would sort *below* the tag, which is wrong for a build made later.

```sh
sh scripts/version.sh        # what this checkout is
sh scripts/release.sh        # write it into src/release.j and deck.toml
sh scripts/build-tarball.sh  # dist/jsnake-<version>.tar.gz plus a .sha256
```

`src/release.j` is generated and committed with a real value, so `jsnake --version` works
before anyone runs a script. `build-tarball.sh` reads the version from *there* rather than
from git, because `release.sh` leaves the tree dirty and a second look at git would label
a tagged build as a dev one.

The tarball is the runtime tree and nothing else — `bin/`, `src/` without its test
overlays, `deck.toml`, `README.md`, both licence texts, the terminal diagnostic —
unpacking to `jsnake-<version>/` with `bin/` and `src/` as siblings, which is what the
launcher's relative import needs and the same layout `jvc app install` leaves behind.
jvc installs from a git tag rather than from this archive; the tarball is what distro
packaging builds on and what a by-hand install unpacks.

### CI

`.github/workflows/ci.yml` runs on every push and weekly: format check, lint at zero
findings, the whole suite, coverage (reported, not gated), the smoke script, and a tarball
that is unpacked and run. It builds **Jennifer from `main`**, not a release — the game's
floor is 0.25.0 and that is not released yet, so a dev build is the only interpreter that
can run it. That makes CI an early warning for the language too — a breaking change
upstream shows up here before anyone hits it by hand.

`.github/workflows/release.yml` runs on a SemVer tag: it injects the version, checks the
injected value actually equals the tag, re-runs every check, verifies the tarball runs
through a symlink the way `jvc app install` leaves it, and publishes it with its checksum.

## Building and testing

There is nothing to build — it is source.

```sh
jennifer test src/rules_test.j     # one module
for f in src/*_test.j; do jennifer test "$f"; done   # everything: 846 tests, ~35s
jennifer lint src/*.j bin/jsnake   # must stay at zero findings
jennifer fmt -l src/*.j            # must print nothing
jennifer test --coverage src/rules_test.j            # statement coverage
sh scripts/smoke.sh                # run the game for real; needs a pty
./bin/jsnake solo                  # watch it run; needs a terminal
```

**`scripts/smoke.sh` is not optional.** `host.run`, `host.lobby` and `guest.session` are
the one part of the program `jennifer test` cannot reach: they take over the terminal,
open sockets, and run until a key is pressed. Jennifer checks argument types when a call
*executes*, not when it parses, so a signature changed in one of those loops is invisible
to both the suite and `lint` - it surfaces the first time that line runs, as a game that
will not start. A `_test.j` overlay makes it worse: its own `use` declarations are in scope
for the module under test, so a namespace the module forgot to declare resolves under the
suite and nowhere else.

The script drives twenty paths through the real binary under a pty and fails on any runtime
error. Three force a known terminal size with `stty` inside the pty and assert the title
screen was not cut off, because a screen that only breaks at 80x24 otherwise breaks nowhere
you can reproduce; four drive Escape in each of the contexts where it means something
different, since the loop that decides is one of the unreachable ones.

Most of those seconds are two files earning their keep: `bot_test.j` plays
several two-hundred-tick games to prove a careful computer player does not trap
itself, and `beacon_test.j` runs real discovery windows over loopback. The other
nine modules together take well under a second.

Statement coverage, which is where the purity pays off:

| 100% | Nearly | Lower, on purpose |
| ---- | ------ | ----------------- |
| `geom` `bot` `proto` `keys` `view` | `rules` 99.1% · `cli` 97.2% · `link` 96.8% · `beacon` 96.5% | `host` 75% · `guest` 43% |

The "nearly" modules are short of 100% only on one-line branches that cannot be provoked
from a test without lying to the kernel — a `catch` that ignores a failed close, a fallback
for a cell walled in on all four sides. `host` and `guest` are lower because their `run`
and `loop` functions *are* the I/O layer: sockets, the clock, and raw-mode input. Everything
they decide lives in the pure functions beside them, which are fully covered, and the loops
themselves are checked by `scripts/smoke.sh` running the real game.

Each module has a co-located `MODULE_test.j` white-box overlay, which is where
`jennifer test` expects it: the runner finds the module under test by stripping
`_test` from the overlay's own path, and co-location is what gives the overlay
access to the module's private names.

The loopback tests in `link_test.j` and `beacon_test.j` bind port 0 on
`127.0.0.1`, so they never fight another process — or each other — over a fixed
number, and they poll for data rather than sleeping on a timer.

## Requirements

Jennifer **0.25.0 or newer**, the default `jennifer` binary. Not `jennifer-tiny`: it stubs
`net` (no sockets to play over) and `term` (no raw-mode keyboard).

0.25.0 is where the two interfaces the game is built on arrive — `screen.startInput`, the
background keyboard reader a free-running loop polls instead of blocking on a keypress, and
`net.setReadDeadline`, which turns a blocking socket read into the per-tick poll the whole
transport layer depends on.

The floor is checked twice over. Every source file carries
`# pragma-jennifer-version: >=0.25.0` and the interpreter checks it at read time, so the
wrong interpreter is a clear message rather than a puzzling failure mid-game; a dev build
satisfies any floor, which is why building from `main` works today. And `[engines]` in
`deck.toml` says the same thing to `jvc`, which gates it before downloading anything.

## Installing

### With jvc

jsnake is an **app**, not a deck — an unscoped name and a `[package] bin` — so
[jvc](https://github.com/jennifer-language/app-jvc), Jennifer's deck manager, installs
it once **per user onto your `PATH`** instead of vendoring it into a project:

```sh
jvc app install https://github.com/jennifer-language/demo-jsnake
```

```
installed jsnake 0.1.0
  from:    https://github.com/jennifer-language/demo-jsnake
  app:     ~/.local/share/jvc/apps/jsnake
  command: ~/.local/bin/jsnake
```

Then `jsnake host` and play. Useful variations:

```sh
jvc app install https://github.com/jennifer-language/demo-jsnake --version "^0.1"
jvc app install https://github.com/jennifer-language/demo-jsnake --scope system
jvc app update                      # reinstall every app at its newest version
jvc app uninstall jsnake            # command, directory and record
```

Things worth knowing about that install:

- **The version is a git tag.** jvc installs the newest SemVer tag satisfying
  `--version`, which is exactly the versioning scheme described above, so
  `jsnake --version` after an install names a tag and not a branch.
- **The whole tree is unpacked**, not just `src/` as it would be for a deck, because
  `bin/jsnake` imports `../src/cli.j` relative to its own file and the two must stay
  siblings. Nothing else is needed: `[decks]` is empty, so there is nothing to vendor.
- **The command is a symlink** into `~/.local/share/jvc/apps/jsnake/`, so `ls -l`
  shows where it really lives. `--scope system` puts it under `/usr/local` and needs
  privileges; jvc says so first rather than elevating itself.
- `[engines] jennifer = ">=0.25.0"` is checked **before** anything is downloaded, so a
  too-old interpreter is refused up front rather than part way through a game.

### On Arch Linux

From `packaging/archlinux/`:

```sh
makepkg -si                         # PKGBUILD, from a release tag
makepkg -si -p PKGBUILD-git         # PKGBUILD-git, from the tip of main
```

Both install the tree to `/usr/share/jsnake/` and symlink `/usr/bin/jsnake` to it —
the same sibling layout, for the same reason. The tagged `PKGBUILD` builds from the
release tarball described above rather than from GitHub's generated source archive, so
what gets installed is the curated runtime tree with no tests or CI config in it.

Both also install **`man/jsnake.1`**, so `man jsnake` works after either one. The page
covers every flag, the keys, the food, how the field is sized, the two ports, and the
Escape limitation below. It cannot drift: `testTheManPageDocumentsEveryFlag` walks the
real `args.Parser` and fails if a flag is missing from the page, and
`testTheManPageInventsNoFlags` fails if the page names one the program would reject.

Their `check()` functions differ on purpose. `PKGBUILD-git` has a full checkout, so it
runs the whole suite and the smoke script; the tagged one builds from the curated
tarball, which carries neither the test overlays nor `scripts/smoke.sh`, so it checks
what it actually has — that the tree lints and that the launcher runs under the
interpreter on the build host.

### By hand

The release tarball is self-contained and needs no build step:

```sh
tar xzf jsnake-0.1.0.tar.gz
./jsnake-0.1.0/bin/jsnake solo
```

Put it anywhere and symlink `bin/jsnake` onto your `PATH`; keep `bin/` and `src/`
together. `man/jsnake.1` is in there too — `man -l man/jsnake.1` reads it without
installing it anywhere.

## Known limitation

**Escape takes two presses.** A lone `ESC` is never delivered: `screen.nextKey` reads a
second byte unconditionally after it — to tell a bare Escape from the start of an
arrow-key sequence — and `term` has no timed read, so that read blocks until you press
something else. Press Escape twice and the pair decodes as one `escape`, which is why
Escape works at all.

What a terminal sends, and what the game receives:

| keys sent | delivered |
| --------- | --------- |
| `ESC` | *nothing, ever* |
| `ESC` `ESC` | `escape` |
| `ESC` then any printable key | `alt-<key>` — both presses lost |
| `ESC` then Ctrl-C | `ctrl-c` |

The last row is why Ctrl-C is the safety net: it is the one key that still arrives after a
swallowed Escape, so a player who pressed Escape once and saw nothing happen is never
stuck.

Fixing it needs a timed read in `term`, which has none — a change deep enough in the
interpreter that this is a long-lived workaround rather than a stopgap. Until then every key
legend says `esc esc`: one constant (`keys.ESCAPE_NEEDS_TWO`) drives that wording and
`testTheEscapeLabelMatchesWhetherOnePressIsEnough` keeps the two in step, so adopting the
fix here is a one-line change. Reported upstream with reproductions.

## License

LGPL-3.0-only. Copyright (C) 2026 mplx <jennifer@mplx.dev>.

The full text is in [`LICENSE`](LICENSE). LGPL-3.0 is written as a set of additional
permissions on top of GPL-3.0 and incorporates it by reference, so the GPL text it
refers to ships alongside it in [`LICENSE.GPL-3.0`](LICENSE.GPL-3.0). Every source
file carries an SPDX header rather than a copy of either.
