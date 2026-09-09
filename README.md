# panelpon4

A Panel de Pon-style falling/rising block matching game for the [WASM-4](https://wasm4.org) fantasy console, written in Zig.

## Building

Requires Zig 0.16+.

```sh
zig build --release=small
```

The cart is written to `zig-out/bin/cart.wasm`.

For a debug build with safety checks enabled (bigger binary, useful while developing):

```sh
zig build
```

## Running

Install the WASM-4 CLI (requires Node/npm) and run the cart. The npm package is called `wasm4`
(it provides a `w4` command), so on a machine without it already resolved, use `-p wasm4` to be
explicit about which package to fetch:

```sh
npx --yes -p wasm4 w4 run zig-out/bin/cart.wasm
```

This serves the cart at `http://localhost:4444` and opens it in your browser, with hot-reload on rebuild.

### Standalone web bundle

To produce a single self-contained HTML file (playable offline, no server needed):

```sh
npx --yes -p wasm4 w4 bundle zig-out/bin/cart.wasm --html web/panelpon4.html --title "panelpon4"
```

## How to play

Each board is the traditional Panel de Pon size, 6 columns by 12 rows. You play against an opponent, each
with your own full board -- yours at normal size on the left, the opponent's at a simplified micro scale in
the side panel. Both run the exact same rules and physics.

### Game modes

Right after the title screen, a mode-select screen (**left/right** to cycle, **X** to confirm) picks one of
3 top-level modes (see `src/game_modes.zig`, `state.GameMode`):

- **1P story**: face every character in turn, one stage per opponent, in a fixed order (including a "mirror
  match" against whichever character you yourself picked, if it comes up in the order -- no different from
  any other stage). Each stage is a single game, not a best-of-3 series -- win to advance, lose and it just
  retries that same stage (never restarting the whole run from stage 1), tallying a running game-over count
  for the run. Pick a difficulty **tier** instead of a numeric level (Easy/Medium/Hard, cycled with
  left/right on their own screen) -- the CPU's own strength ramps up across the 7 stages within whichever
  tier you picked (see `game_modes.storyDifficultyFor`), and the tier also retunes the board's own feel:
  stack rise speed, how long a match lingers before it actually pops, and how long the top-loss forgiveness
  timer gives you once you're in danger (see `game_modes.applyStoryProfile` -- Easy is slower and more
  forgiving on all three, Hard compresses them). Clearing every stage on Hard without a single game over the
  whole run reveals a hint, on the tier-select screen from then on, that a secret harder tier exists --
  **X Hard** is "by tradition" never reachable by ordinary left/right cycling at all, only by holding **left**
  and pressing **Z** while sitting on Hard, whether or not you've ever earned that hint (the hint just tells
  you it's there -- the input itself always works). The hint (not the input) persists across sessions via
  WASM-4's disk API.
- **1P quick match**: the original single best-of-3 series against one CPU opponent -- pick a character,
  watch the CPU pick its own, set a numeric difficulty (1-10), play. Completely unchanged by any of the
  above; story mode's own difficulty-profile retuning always resets back to this exact baseline before a
  quick match begins (see `game_modes.applyDefaultProfile`), so switching modes mid-session never leaves a
  story tier's feel bleeding into a quick match.
- **2P versus**: a second real player takes over the side that's normally the CPU's, on a second controller
  (GAMEPAD2) -- either physically local (two controllers, one console) or remote via WASM-4's own built-in
  netplay (`w4 watch --host`/`--join`, or a netplay URL -- the cart itself doesn't implement any networking
  of its own; WASM-4's runtime keeps both peers' GAMEPAD1-4 states in sync transparently). No
  character/difficulty picking -- a confirm screen ("connect via netplay now, then press X") comes first
  instead, a deliberate manual gate rather than falling straight into a countdown: netplay's own connection
  handshake happens entirely outside the cart (sharing/opening the join link), and joining mid-match desyncs
  the two peers' simulations, so this makes sure that actually happens first. Each peer always sees
  *themselves* in the full-detail main seat regardless of which of the two boards their own real input
  happens to land in over the network (`wasm4.NETPLAY`'s low 2 bits say which slot -- 0 or 1 -- a peer's own
  controller is broadcast as; see `state.versus_render_swapped`, read only once the confirm screen is
  actually dismissed) -- but the actual simulation's own board identities and per-frame call order never
  change between peers, only which one gets rendered where, since that's what netplay's lockstep determinism
  actually depends on staying identical everywhere.

- **Arrow keys**: move the two-tile cursor -- a classic Panel de Pon-style corner bracket at each of its two
  tiles (like a photo mounted by its own four corner tabs), not one box traced around both, centered on the
  block it targets and sitting just outside its edges. Snaps to its contracted, resting size the instant it
  moves and only breathes out a pixel further once it's been sitting still for a while, so a fast-playing
  player never sees it breathe at all. While a swap is actually in progress, each side's brackets ride along
  with the block sliding underneath them instead of
  staying pinned to the two static tiles -- the cursor visibly swaps along with the blocks themselves.
- **X**: swap the two blocks under the cursor. Buffers a single press if the cursor's pair can't swap yet
  (still animating from the previous swap), firing it automatically the instant it can, so mashing X chains
  swaps at full speed instead of dropping presses that land at the wrong instant.
- **Touch/mouse**: swipe-only -- touching down targets the block under your finger directly (the cursor
  hides while you do, since you're aiming at that block, not steering a separate one -- it reappears the
  next time you press a real button); swiping left/right swaps that block with its neighbor in that
  direction, and swiping up/down retargets to the row above/below instead (there's no vertical swap).
  A continuous drag keeps swapping the same block further across the board as it travels; a tap alone does
  nothing.
- Match 3 or more blocks of the same color/pattern in a horizontal or vertical line to pop them. Each
  affected block gives you a heads-up first: it blinks rapidly, holds still for a beat, then actually
  starts popping (or, for garbage, recycling) -- a brief moment to read what's about to go before it does.
  A small burst of particles flies diagonally outward, in the block's own color, right as it actually
  disappears.
- Blocks above a pop fall and can chain into new matches for bonus score. A genuine chain ("x2", "x3", ...)
  or a combo (a single match bigger than 3 blocks, shown as a bare block count) flies a small badge into
  the score display. A chain multiplier also shows continuously next to the score for as long as it holds;
  a combo (having no ongoing state of its own to display) instead flashes a brief "COMBO" callout there.
- A big enough combo or chain drops garbage onto the *opponent's* board -- never your own -- but not
  immediately: it queues, and only actually lands once *both* sides are idle (never mid-match, on either
  end), and a still-growing chain only hands over its final size once the whole chain concludes -- an x4
  chain drops one block sized for x4 alone, not the sum of every step along the way. Garbage is inert
  (colorless, unswappable, unmatchable) until a match pops right next to it, which starts *recycling* it:
  one garbage block at a time, bottom-right to top-left (rows first) so the block nearest your active area
  reads first, with a short delay between each (after the same blink-then-pause heads-up as a real pop),
  cracks open into a fresh, plain-looking normal block -- no animation beyond that, just an instant reveal,
  and never in a color that would complete an accidental 3-in-a-row -- so you can read the color lineup
  forming and plan your next move before the whole connected group finishes and every recycled block
  becomes active together. A pop still spreads through a whole physically-touching clump of garbage, even
  across two separate drops merely resting against each other -- but each garbage drop stays its own piece
  for the rest of its life regardless of what it ends up touching, and a piece taller than one row only ever
  converts its own bottom row per match: the rest just flashes the same heads-up and stays garbage, falling
  to rest on the newly-revealed row below it, ready to be peeled again by a future match -- independent of
  whatever *other* piece happens to be resting against it, which keeps (and follows) its own bottom-row rule
  the same way. A connected clump of garbage falls and lands as one rigid piece (a piece touching
  down stops the whole clump at once), rendering as a single seamless bezeled slab rather than individual
  tiles -- which on its own would make two different pieces resting against each other indistinguishable
  from one bigger piece, so each settled piece additionally gets its own small mark at its center, one per
  piece even within a shared slab.
- The single new row rising in from below isn't playable yet: it's marked with a sparse dither overlay and
  can't be matched into (or match on its own) until it's fully risen into the lowest row you can actually
  reach with the cursor, at which point the dithering clears and it's live like any other row.
- A column with blocks near the top wobbles its symbols in place as a warning that it's close to the rise
  hazard -- only the symbols move, never the blocks themselves, so nothing else keyed to a block's actual
  position (like the hidden row's dither overlay above) can ever fall out of sync with it.
- Each board's floor rises forever, faster as that board's own score climbs -- true for the CPU too, so a
  CPU that's playing efficiently is also accelerating its own rise. Topping out isn't instant, though: once
  a board is idle with a block at or above the ceiling, a one-second forgiveness timer starts, and only
  running it out actually ends the match for that side (clearing the danger row, or the board going busy
  again, resets it) -- a real beat to recover from a close call rather than an instant loss the moment a
  rise happens to touch the top. Whoever's forgiveness timer runs out first loses (both on the same frame
  is a draw). The instant that timer actually starts running, every settled block's own symbol switches from
  the ordinary wobble above to rendering visibly squashed instead (the block itself stays completely
  untouched, same as the wobble) -- a plain, unmistakably different look (not another animated bounce)
  specifically for this more urgent warning, so it's obvious at a glance the clock is
  genuinely running and the stack needs clearing now, not just that a column is getting tall.
- **Z**: manually raise your own floor by one row right away (finishes in a third of a second instead of
  waiting for the automatic pace) -- useful for deliberately forcing a rise when you want fresh blocks, or
  to bail out of a bad board shape. On a cooldown (two thirds of a second) so it can't be spammed -- hold it
  down to keep raising row after row as soon as each cooldown clears, instead of having to tap repeatedly.
- Quick match and versus are both a best of 3 -- first to 2 match wins takes the whole series (see
  `constants.POINTS_TO_WIN`). A small row of pips next to each side's own score fills in as they win matches;
  losing a match doesn't end the series, just that one match -- press X to move straight into the next one,
  same difficulty, running score carried over as pips, not reset. Story mode plays single-game stages
  instead (see Game modes above) -- that same pip row is replaced by a running stage counter there.
- A branded **title** screen (press X to continue) leads into mode-select (see Game modes above), then each
  mode's own setup: quick match's is 3 steps in order -- pick your **character**, watch the **CPU** pick its
  own, then set the **difficulty** -- each its own screen rather than everything crammed onto one; story's is
  2 steps (character, then its own difficulty **tier** screen, no CPU reveal -- its opponents are
  predetermined, not rolled); versus's own single step is a confirm screen ("connect via netplay, then press
  X") rather than a countdown straight away. On quick match's difficulty screen,
  **left/right** sets it, 1-10, shown as a filled-in bar rather than a bare number (press X to begin). Every
  level runs the same move-search
  engine (see `src/cpu_engine.zig`) and always plays
  its actual best-scored move -- never a random or deliberately mistaken one. Weaker levels play *correctly*,
  just *myopically*: a shallower search, a slower reaction time, and a much lower preference for a chain over
  an equivalently-sized flat match, so they settle for slowly grabbing whatever match is right in front of
  them rather than reasoning their way toward a bigger chain; stronger levels see further ahead, react
  quicker, and keep chasing chains decisively. The engine can also choose to raise its own floor by a row
  instead of swapping (see the Z button above) when it's running low on real blocks to work with -- weighed
  the same way as any swap, so it only does this when it's actually short on material, not just because
  nothing else looks great -- and never when its own stack (or, after the raise, what its own stack would
  become) is already dangerously close to the top, however short on material it is. The very top levels
  additionally get a small extra preference for raising while there's comfortably more headroom than that
  danger check requires, so they keep building up more material for a bigger combo instead of only ever
  raising out of necessity -- gated well clear of the danger threshold, so it can never itself run a stack
  into the ceiling. Difficulty and character are both fixed for the whole series, but revisitable in setup
  again once one concludes.
- The character screen shows all 7 selectable characters at once, wrapped into two rows since they're too wide
  for one (see `src/characters.zig`) -- a lizard, a mermaid, a bug, a cloud puff, a slime blob, a crow, and a
  robot, each a real pixel-art figure, not just a colored square. **Left/right** cycles your own pick
  (highlighted with a dithered outline, rethemeing the screen's own menu panel border to match live); pressing
  **X** blinks that outline a few times (a short, explicit "confirmed" flash) before moving on. The CPU screen
  right after plays out its own pick as a brief reveal, not an instant assignment -- its portrait spins through
  the roster once per tick, each tick held a little longer than the last (a slot machine slowing to a stop),
  before landing for good on a genuinely random pick (never the same character as yours, but otherwise no more
  likely to be any one of the other 6 -- see `characters.cpuPickFor`) with no further input needed. Every
  pre-game screen shares the same background (a slow diagonal-scrolling drift of faint blocks) and an
  identically-positioned menu panel that stays perfectly still -- no bobbing or other idle motion -- so
  nothing shifts around between steps except the content itself.
- Your chosen character themes your own main-frame border (its own color and a distinct border pattern --
  solid, checkered, dashed, or a thin double outline) and gives you an animated portrait next to your score,
  sitting inside its own small themed frame (the same color/pattern treatment as the main board frame, just
  scaled down) rather than floating bare next to the score text. It reacts to what's actually happening: idle
  otherwise, excited on a combo or chain (a quick up/down bounce, not just a change of expression), wincing
  and jittering side to side for a moment right after taking a garbage attack, and bouncing and celebrating on
  the game-over screen if you won (the losing side's own character shows there too, wincing, rather than only
  the winner appearing) -- both characters stay visible and animated straight through the countdown and
  closing-wipe transitions between matches, never just popping in once gameplay resumes. Whichever character
  the CPU picked (see the reveal screen above) themes its own mini board's border the same way and gets the
  identical framed, animated portrait treatment next to its own score. A chain/combo also flies a small badge
  from the match itself to whichever side's score it belongs to -- the CPU's own board now gets this too, not
  just the player's -- so both scores get the same floating callout instead of the CPU's activity only ever
  being readable from its board's own icons; the old static yellow "COMBO"/"x2" text under the player's score
  is gone, since the badge (and the character's own bounce) already say the same thing without permanently
  eating panel space.
- Press **X** to (re)start a match -- both boards reset immediately, but simulation stays frozen behind a
  brief "3 2 1 START" countdown first (each number rises up a couple pixels then holds for about a second;
  "START" rises the same way but then blinks a few times) before the match actually begins. Losing plays out
  the same way in reverse: once someone tops out, every row pops top to bottom across both boards before a
  "MATCH OVER" screen names the winner and the running series score -- and, once the series itself is
  decided, who took it, before returning all the way back to the title screen.

## Notes on the block colors

WASM-4's hardware only supports 4 simultaneous on-screen colors (the palette has exactly 4 slots), one of which is
spent on the background. That leaves 3 real hues to work with. To get 5 distinguishable block colors out of them,
2 of the 5 are drawn as a 1px checkerboard dither blending two adjacent hues, so the board reads as 3 solid colors
plus 2 dithered blends. This is a deliberate adaptation to the console's real constraints.

## Project layout

- `src/wasm4.zig` — bindings for the WASM-4 host API (drawing, input, memory-mapped registers), including
  `NETPLAY` (the low 2 bits are which player slot -- 0-3 -- *this* peer's own local input is broadcast as
  under netplay; bit 2 says netplay is active at all) -- see `state.versus_render_swapped`/`main.zig`'s
  versus mode, the only thing that reads it.
- `src/constants.zig` — layout/timing constants shared across modules. `POP_FRAMES`/`PRE_POP_BLINK_FRAMES`/
  `PRE_POP_PAUSE_FRAMES`/`PRE_POP_TOTAL_FRAMES`/`DANGER_FORGIVENESS_FRAMES`/`RISE_SPEED_SCALE_PCT` are `var`s,
  not `const`s -- the only thing that ever writes them is `game_modes.applyProfile` (story mode's own "stack
  rise speed, pop delay, top loss timer" tuning per difficulty tier), but every read site elsewhere keeps
  using the exact same plain `c.FIELD` access either way, so making them runtime-configurable needed no
  call-site changes at all.
- `src/symbols.zig` — pixel-art symbol data drawn on each block color.
- `src/state.zig` — the `Board` struct (grid, cursor, score/chain, rise state, its own RNG stream, its own
  match-popup pool, its own particle pool -- `Board.spawnPopParticles`/`tickParticles`, a short burst of 4
  small particles flying diagonally outward from a real block's own center, in its own color, right as
  *that* block's own staggered pop animation actually starts shrinking away (called from `sim.simulate`'s
  per-cell timer handling at the exact frame `render.drawPoppingCell`'s own elapsed time crosses from its
  initial flash wobble into the shrink-to-nothing phase -- the same instant its pop-tick sound plays -- not
  once for the whole match at once, and not once each block has already finished shrinking and vanished
  either, so each block's own burst plays out *alongside* it visibly shrinking, not before or after. A
  garbage cell bursts too, on its own different timing: right as its own staggered turn actually begins
  (`render.drawRecyclingCell`'s own elapsed == 0, the instant a converting cell hard-cuts to looking like a
  plain block and a non-converting one starts its own oscillating flash), rather than at the real-block
  threshold above, which would land partway through a garbage cell's already-started reveal instead of at
  the start of it. A non-converting cell (see `Cell.garbage_reveals`) never gets a real color assigned, so
  its burst uses garbage's own muted teal instead of a block color -- this is what makes even the members of
  a taller clump that don't personally convert still visibly react at their own turn, instead of just sitting
  there through the whole event while only the bottom row visibly does anything);
  `s.player`'s own pool is drawn by `render.drawParticles`; purely cosmetic, exactly like `MatchPopup`) plus
  its small methods (ring-buffer indexing, RNG, board-busy query), and the two live
  instances of it, `player`/`cpu`. Every other module takes an explicit `*Board` rather than reaching into
  an implicit global, so the exact same logic drives both sides of a vs-CPU match. `physRow` (the logical-to-
  physical row translation) is piecewise: logical rows below `constants.SPAWN_ROWS` are a fixed, non-rotating
  offscreen garbage staging area (see `sim_garbage.spawnGarbage`) that maps straight through regardless of
  `top`; everything from `SPAWN_ROWS` on is the actual rotating ring (the ceiling, the visible board, and the
  one hidden buffer row rising in from below), exactly as the whole board used to work before the staging
  area existed, just starting at that offset. Cursor-facing code (`input.zig`, `cpu_ai.zig`) stays in
  visible-relative row terms (0 = ceiling) and only converts to an absolute logical row at the point it
  actually touches the grid (`sim.trySwap`, `input.canSwapAt`). Also home to `GameMode`/`StoryTier` (see
  `game_modes.zig`, which owns all the actual logic built on top of them) and the rest of the per-match mode
  state: `story_tier`/`story_stage`/`story_game_overs` for the current story run, `versus_render_swapped` for
  which side a versus peer's own real input actually lands in (see `render.zig`), and a second, parallel copy
  of the player's own cursor-movement fields (`cpu_held_dir`/`cpu_das_counter`/`cpu_button_pending_swap`/
  `cpu_cursor_idle_frames`) used only in versus mode, where GAMEPAD2 drives `cpu` as a real second player
  through the exact same `input.zig` functions the player's own input already uses.
- `src/board.zig` — row generation, the rising floor (automatic and the Z-button manual raise),
  `updateDangerTimer` (the actual loss condition -- a forgiveness timer gated on the board being idle with
  a block at or above the ceiling, rather than an instant check right after a rise), and (re)starting a
  game, each taking the `*Board` to act on. Rising rows are drawn from a *shared* sequence
  (`state.shared_rows`/`shared_rows_count`, generated via `rowForIndex`), not either board's own RNG stream:
  whichever board first reaches a given row index generates and caches it, and the other board just replays
  that exact result whenever it reaches the same index, however much later -- so the Nth row either board has
  ever seen rise in is identical regardless of which board got there first, predetermined the instant
  `resetSharedRows` runs at match start rather than depending on either board's own stack. `resetSharedRows`
  is deliberately called once per match (see `main.zig`), never from inside `resetGame` itself, since that
  runs once *per board* and resetting the shared cache a second time would discard whatever the first board
  already generated for index 0.
- `src/sim.zig` — the core simulation: swaps, pops, landings, and per-cell gravity, each taking `self`
  (and, for simulate, `opponent`) -- tests in the companion `src/sim_test.zig`.
- `src/sim_matches.zig` — match detection, chain/combo scoring, and garbage queueing (re-exported from
  `sim.zig` as `checkMatches`); a big enough combo/chain on `self` queues garbage for `opponent`, never
  `self` -- garbage is never self-inflicted in vs-CPU play. A pop still propagates through a whole
  physically-touching clump of garbage the same way it always has, including crossing from one drop into a
  completely separate one it merely happens to be resting against -- but which cells actually *convert* is
  decided per garbage *piece* (see `Cell.garbage_group` -- one persistent id per combo/chain that spawned it,
  assigned in `sim_garbage.spawnGarbage`), not by that event's overall touching shape: only a piece's own
  bottom row per column converts (`Cell.garbage_reveals`), independent of whatever other piece happens to be
  touching it. Also picks each converting cell's color to never complete a run of 3, mirroring
  `board.generateRowInto`'s own reasoning -- tests for all of this, plus the bottom-right-to-top-left stagger
  order, in the companion `src/sim_recycle_test.zig`. A cell is match-eligible as soon as it's `.landing`, not
  only once it fully settles to `.normal` -- real-block gravity and garbage's rigid-body gravity are
  independent systems, so two pieces that land "together" rarely finish on the exact same frame, and without
  this a match could be detected and pop before an adjacent, still-bouncing cell was ever considered. A
  separate late-join sweep additionally lets a garbage cell that finishes falling *after* an adjacent match
  has already started popping still join that same still-active group (inheriting its current
  timer/pop_group_end rather than being missed forever because the match it touches is no longer a fresh
  color-run, just an ongoing `.popping`/`.recycling` one) -- but only while that group is still in its shared
  pre-pop preamble (`Cell.pre_pop_timer > 0`), not once it's already progressed into its own staggered reveal
  cascade, so a piece that only happens to land on an already-resolving clump much later doesn't get swept
  into a pop it was never actually part of. Real matched cells resolve (clear to empty, freeing their space
  for gravity) on their own schedule -- the longest stagger among just the *real* members of a group -- not
  the mixed group's as a whole: a garbage clump pulled into the same event by propagation can legitimately
  take much longer to finish its own staggered reveal, but that never holds the real match's own space
  hostage in the meantime (`real_group_end` vs. `group_end` in `checkMatches`) -- the garbage itself is
  entirely unaffected by this and keeps resolving (staying put, converting or reverting in place) exactly as
  it always has, on the full group's schedule. The one hidden ring-buffer row still rising in from below
  (`constants.ROWS - 1`) never seeds a match or gets pulled into one via propagation/late-join, even though
  gravity treats it like any other row -- it only becomes matchable once a rise promotes it into the lowest
  row the cursor can actually reach (see `render.drawBoard`'s dithered overlay for the matching visual cue).
  A qualifying match's popup spawn point (`Board.spawnMatchPopup`) is computed in whichever board's own
  coordinate system actually matched -- the player's full-scale one, or (checked by pointer identity against
  the `s.cpu` singleton) the CPU's differently-scaled/positioned micro board (see `render_cpu.zig`) -- rather
  than always the player's, now that `render_cpu.zig` actually draws the CPU's own popups too.
- `src/sim_garbage.zig` — garbage's rigid-body group gravity (a connected clump falls and lands as one piece,
  computed by connectivity fresh every frame), its spawn placement, and the queueing lifecycle between the
  two (`queueChainGarbage`/`queueComboGarbage` record what a combo or a still-growing chain would send,
  `resolveChainEnd` seals and hands off a concluded chain's final size to the opponent once `self` goes
  idle, and `releaseIncomingGarbage` actually spawns whatever's queued for a board once *that* board goes
  idle too -- driven once per frame per board from `main.zig`, so garbage from either side never lands
  while a match or chain is still resolving, on the sending board or the receiving one) -- tests in the
  companion `src/sim_garbage_test.zig`. `spawnGarbage` places a piece entirely within the offscreen spawn
  buffer (logical rows below `constants.SPAWN_ROWS`), never directly onto the visible board, and falls back
  to gravity from there like any other garbage -- and it's all-or-nothing: if any cell the piece would
  occupy is already taken, the whole piece is skipped rather than placed with a hole around whatever's in
  the way (a partial placement could snag on a free-standing block and deadlock both). `releaseIncomingGarbage`
  leaves a piece queued and retries it next frame if `spawnGarbage` reports it didn't fit yet.
- `src/cpu_ai.zig` — the CPU opponent's move picker, branching on `state.difficulty` (see `configFor`): every
  level from 1-10 runs `cpu_engine.zig`'s actual search and always plays its actual best-scored move -- no
  randomness, no deliberate mistakes. Levels differ in reaction speed (`move_interval`), search depth, and how
  much they specifically value a chain over an equivalently-sized flat match (`chain_weight`, set on
  `cpu_engine.chain_weight` right before each decide call -- see that module's own doc comment for why it's a
  plain global instead of an extra parameter threaded through the whole recursive search); the very top levels
  also get a small preference for raising while there's plenty of headroom (`raise_bias`, likewise set on
  `cpu_engine.raise_bias`). Doesn't wait for the whole board to go idle before thinking/acting -- like a
  player, whose own input is never blocked by unrelated activity elsewhere (see `input.updateSwap`) -- it
  reasons about and can act on whatever's true right now, including cells still falling/landing/mid-swap
  elsewhere (see `cpu_grid.Grid.fromBoard`). Crucially, the engine only
  ever *decides* a target cell -- the CPU cursor then walks toward it one cell at a time, at the same pace a
  player's own cursor moves, only actually swapping once it's genuinely arrived (giving up and re-deciding if
  the board changes underneath it while walking over, e.g. the target cell fell away or popped); it can never
  teleport straight to any two cells on the board the way it used to. `sim.trySwap`'s own per-cell check
  still decides whether a given swap actually succeeds, exactly as it does for the player, so this never
  lets the CPU do anything a player couldn't also do from the same position.
- `src/cpu_engine.zig` — the actual move-search engine behind the CPU: snapshots the board into a small
  `Grid`, tries every *legal* swap on a copy (`legalSwap` excludes not just garbage/both-empty pairings but
  also two cells of the identical color -- a strict no-op that leaves the grid unchanged, so at depth > 1 it
  could otherwise still collect a full discounted lookahead credit for whatever already was the board's best
  next move, a bonus that had nothing to do with this swap ever being played -- letting a true no-op
  occasionally outscore every real option and trap the CPU reselecting, and "playing", the exact same no-op
  swap forever, since playing it never actually changes the board), resolves each one's full logical cascade
  (gravity, matches, garbage propagation, repeated for chains) to score it, and adds a bitboard-driven
  structural heuristic (same-color adjacency, column height) so moves that don't pop anything yet are still
  ranked sensibly --
  plus a discounted look at the best follow-up move (a shallow best-first search, compounding the same
  discount again each ply deeper) for the higher levels, rewarding a setup move that enables a strong reply
  over a shallow immediate pop. Each cascade pass's real-block score scales with the *cube* of chain depth at
  full strength (not just its square), so a genuine multi-link chain decisively outranks an equally-sized
  pile of unconnected single matches rather than merely edging it out -- but only the chain-continuation
  *bonus* above a flat match's own face value actually scales with `chain_weight` (set per difficulty by
  `cpu_ai.configFor`, 100 reproducing the fixed cube curve exactly): a first, non-chaining pass is always
  worth its full per-block value no matter the difficulty, so a low-`chain_weight` (weak) CPU still values
  real matches correctly, it just stops specifically hunting for a chain setup it's unlikely to search deep
  enough to capitalize on. The *lookahead* -- never the top-level decision itself, which always weighs every
  legal candidate -- is beam-pruned (see `BEAM_WIDTH`): only the most promising handful of a ply's candidates
  get a real recursive search of their own, the rest keep just their immediate value, which is what keeps a
  beam-searched depth 3-4 roughly as cheap as an exhaustive depth 2 used to be (memory was never the
  constraint -- `Grid` is 72 bytes with no heap allocation, and recursion depth maps straight to a handful of
  small stack frames -- the branching factor is). Also weighs raising the stack (see `raiseValue`) against
  the best available swap: worth more the fewer real blocks are left on the board, worth less than any real
  match regardless, so it only wins when the board is genuinely short on material and has nothing better to
  do -- and it's judged against the height a raise would actually leave the tallest column at, not the
  current one, so a materially-poor but dangerously tall, skinny stack doesn't get raised straight into
  topping out (the same steep height-danger penalty also discourages any *swap* that would leave a column
  that close to the top, not just raising). `raise_bias` (also set per difficulty, only nonzero for the
  strongest levels) nudges that raise value up a little further, but only while the post-raise height would
  still sit comfortably clear of the danger check -- 2 rows more headroom than that check itself requires --
  so it can only ever encourage building up more material while it's genuinely safe to, never push a raise
  into dangerous territory itself. `bestAction` weighs both the best swap and raising against simply doing
  nothing (the board's own current structural score, `NO_OP_EPSILON` apart): when neither meaningfully
  improves on the status quo, it returns `.none` rather than shuffling blocks back and forth forever chasing
  a razor-thin, meaningless edge -- the fix for a reported "spins in place endlessly" bug on boards with no
  genuinely good option. Deliberately its own small simulator rather than reusing `sim.zig` directly -- see
  the module's own doc comment for why -- tests in the companion `src/cpu_engine_test.zig`.
- `src/cpu_grid.zig` — the engine's board snapshot (`Grid`), split out into its own file purely so
  `cpu_engine.zig` and `cpu_engine_garbage.zig` can each depend on it without depending on each other.
  `fromBoard` reads `.falling`/`.landing`/`.swapping` real cells as their true color (they already have
  their final logical position decided -- only the visual animation is still catching up), not holes, so
  the engine can reason about a board that isn't fully idle yet; `.popping`/`.recycling` still read as
  empty, since what they resolve to is genuinely undecided from here.
- `src/cpu_engine_garbage.zig` — garbage's rigid-body gravity for the engine's `Grid`, a port of
  `sim_garbage.zig`'s own algorithm into the engine's instant, no-animation model: a connected garbage
  body falls and lands as one piece (so a wide slab resting unevenly across towers of different heights
  settles at the height its *tallest* support dictates, not each column sinking to its own depth), and
  connectivity is recomputed fresh every settle step, so a body a match has eaten into is free to keep
  falling as however many independent pieces are left -- cross-validated against the real board's own
  gravity (for plain falling/landing, where nothing is random) in the companion
  `src/cpu_engine_garbage_test.zig`.
- `src/audio.zig` — sound effects.
- `src/input.zig` — gamepad (cursor movement with DAS, swap triggering, itself one-deep buffered -- a press
  that lands mid-swap is remembered and applied the instant it's possible) and touch (swipe-only: aims
  directly at the touched block, swipes left/right swap it, up/down retarget rows -- with its own one-deep
  input buffering so a fast continuous drag chains swaps at max speed). The gamepad functions take an
  explicit target `*Board` plus that board's own DAS/buffering fields, rather than always assuming
  `state.player` -- almost always called with the player's own (see `main.zig`'s ordinary single-player call
  sites), but versus mode (`state.GameMode`) calls them a second time with `&state.cpu` and its own parallel
  fields (`state.cpu_held_dir` etc.), since GAMEPAD2 drives a real second player there instead of `cpu_ai`.
  Touch has no second-player equivalent -- still always the player's own board. `justPressed` takes the
  relevant previous-frame gamepad snapshot as an explicit parameter too (`state.prev_gamepad` for the player,
  `state.cpu_prev_gamepad` for versus's second player) rather than always reading `state.prev_gamepad` --
  an earlier version always read that one regardless of whose input was being checked, which meant the
  second player's own swap button was being compared against the *first* player's press history (almost
  always all-zero, since the host usually isn't also holding X), so it read as "just pressed" on every single
  frame the second player merely held X down, not just the one frame they first pressed it -- symptom: their
  swap rapidly flickered back and forth on what should have been a single press.
- `src/render.zig` — most drawing: the player's board (in full detail) at normal size, the cursor, panel,
  and title/setup/game-over screens. A column wobbles its settled blocks' *symbols* in place as a stress
  warning (`isColumnStressed`/`stressBounceOffset`, applied as `drawNormalCell`'s `sym_bounce`) once it has
  any content within `STRESS_WARNING_ROWS` rows of the ceiling (logical row `constants.SPAWN_ROWS`), not only
  once it's already touching the top -- matching other Panel de Pon clients' more generous warning zone. Only
  the symbol glyph moves; the block underneath it (and anything keyed to a block's actual position, like the
  hidden row's dither overlay) stays perfectly still. The bounce itself is an explicit per-frame timing chart
  (`BOUNCE_KEYFRAMES`), not a plain linear triangle wave -- it holds longest on the highest position and
  second-longest on the next-highest, spending comparatively little time in the quick transit between them,
  standard slow-in/slow-out keyframe spacing for a bounce rather than constant-speed motion. Once
  `Board.danger_timer` is actually running (a strictly more urgent condition than the ordinary stress
  warning), the bounce is replaced entirely: every settled real block's own symbol instead renders vertically
  compressed by `PANIC_SQUISH_AMOUNT` pixels (`drawSymbolSquished`, simple nearest-row sampling re-centered in
  the glyph's normal space, driven by `drawNormalCell`'s `squash` -- mutually exclusive with `sym_bounce`) --
  the block itself (bevel, fill, position) is left completely untouched either way, only ever the symbol drawn
  on top of it. A constant squash rather than another animated effect, since the point is a look that's
  unmistakably *different* at a glance, not one that has to be watched to be read. The cursor
  itself is a classic Panel de Pon-style corner bracket at each of its two tiles (`drawCursorCorners`),
  centered on the block it targets and sitting just outside its edges, not a single box around both -- it
  alternates between two discrete sizes for its idle breathing (contracted right when the cursor moves, same
  2-frame-animation idiom as `render_character.currentFrame` -- a gradual pixel-by-pixel slide instead reads
  as the dithered checkerboard's two hues swapping in place rather than an actual size change, since which
  hue lands on a given pixel depends on its absolute position) and, while a swap is actually in progress,
  offsets each side's brackets to ride along with the block sliding underneath it (the same offset formula
  as `drawSwappingCell`), rather than sitting still while the
  blocks trade places. `drawFrame`'s main-frame border is themed by whichever character the player picked on
  the setup screen
  (`drawThemedBand`, see `characters.BorderStyle`) -- color and fill pattern both. `drawPanel` frames the
  player's own portrait in that same theme at a small scale (`rchar.drawFrame`, see `render_character.zig`)
  and positions the score text a fixed `rchar.FRAME_MARGIN` clear of the frame's own right edge
  (`CHAR_TEXT_X`, also reused as the match-popup badge's fly-to target below) -- previously the score text's
  x offset used the sprite's *height* instead of its width by mistake, so it started 1px inside the
  portrait's own right edge; adding the frame forced fixing this properly rather than just nudging the old
  number. The old static "COMBO"/"xN" text under the portrait is gone entirely, superseded by the match-popup
  badge (now flown to `CHAR_TEXT_X` for both the player and, via `render_cpu.zig`, the CPU) plus the
  character's own combo/win bounce. `drawModeSelectScreen`/`drawStoryTierScreen` are the two new pre-game
  screens `game_modes.zig`'s mode system added (see `state.MenuPhase`). `drawFrame`/`drawCursor`/`drawPanel`
  all take an explicit board/character (not always `state.player`'s own) -- `render()` itself resolves which
  is "main" (full detail) vs "mini" (via `render_cpu.draw`, also now parameterized) through
  `mainBoard`/`miniBoard`/`mainCharacter`/`miniCharacter`, which read `state.versus_render_swapped`: normally
  that's always `player`/`cpu` respectively, but a versus peer whose own real input is GAMEPAD2 needs to see
  *itself* in the main seat, which means seeing `cpu` there instead (see versus mode's own doc comment
  above). A match-popup badge's spawn coordinates are baked in at match time in whichever board's own native
  coordinate system it actually happened in (full-scale for `player`, micro-scale for `cpu` -- see
  `sim_matches.checkMatches`) -- for a swapped versus peer this can mismatch which coordinate system the
  *render* call actually uses, so both `render()` and `render_cpu.draw`'s own badge calls are guarded to
  silently skip drawing rather than ever draw one in the wrong place in that one edge case.
  `drawGameOverPortraits`/`drawStoryGameOver` split story mode's own single-stage game-over text (stage
  clear/game over/story clear, no running series score) out of `drawGameOver`, and the latter's own
  "YOU WIN"/"YOU LOSE" text is resolved against whichever `Winner` value the *main* side actually corresponds
  to (see above), not always assumed to be `.player`, so it reads correctly for a swapped versus peer too.
- `src/render_garbage.zig` — garbage's full-detail rendering (the muted checkerboard fill and the linked-
  clump bezel look), split out from render.zig to keep that file under the project's ~500-line guideline,
  mirroring the sim.zig/sim_garbage.zig split. `drawLinkedFlash` is a phase-inverted variant of the same
  checkerboard, used by `render.drawRecyclingCell` to give a garbage row that's caught up in a pop event but
  won't actually convert (see `Cell.garbage_reveals`) a purely cosmetic "still being processed" flash instead
  of sitting there looking untouched while the rest of the clump pops. `drawMark` draws a small solid filled
  disc (`w4.Oval`, in background color) centered exactly on whichever pixel `garbage_pieces.pieceCenters`
  computed for each currently-settled piece -- a plain filled shape, not a bitmap glyph, since a bitmap
  reactively touching the checkerboard's own alternating fill would only actually change the half of its own
  pixels that started out teal, breaking the shape up into an illegible scatter instead of one solid mark.
- `src/garbage_pieces.zig` — groups settled garbage cells into their individual pieces (by `Cell.garbage_group`,
  4-connected) and computes each piece's own true pixel-space centroid -- the mean position of every one of
  its member cells, not just its bounding box's midpoint (identical for a solid rectangle, the common case,
  but meaningfully different for a piece eaten into an irregular shape) -- for `render_garbage.zig` to mark.
  Split out specifically so this pure grouping logic can be unit tested without render_garbage.zig's own w4
  draw-call dependency (see `tests.zig`'s own doc comment on why render.zig/render_garbage.zig can't be
  tested directly). This is what lets two different pieces resting against each other, rendered as one
  seamless slab with no visible seam (see `render_garbage.drawLinked`/`isAttached`, which merge on pure
  spatial adjacency, not piece identity), still read as visually distinct blocks instead of one bigger one.
  Takes the same `wiped` row count as `drawBoard`'s own closing-wipe skip (0 during ordinary play) and treats
  a cell in a wiped row as though it isn't there at all, so a piece's mark shrinks/recenters in sync as the
  wipe eats into it and disappears entirely once the whole piece -- or, once a match concludes, the whole
  board -- has been wiped, rather than a mark computed from the board's real underlying data hanging in the
  air over a wipe that's already visually cleared the piece it belonged to.
- `src/characters.zig` — the 7 selectable characters: a real pixel-art sprite each (same text-art bitmap
  convention as `symbols.zig`) -- a lizard, a mermaid, a bug, a cloud puff, a slime blob, a crow, and a robot --
  plus a hue/dither pair, a main-frame border style, and a `face` anchor (where `render_character.zig`'s
  shared expression logic centers on top of that sprite). Only 3 real hues exist, so there are only 6 distinct
  looks total (3 solid, 3 dithered pairs); the robot deliberately reuses the mermaid's solid teal (the real
  in-game garbage block's own accent color, a fitting match for a "garbage themed" character) and `border_style`
  cycles back through its 4 options a second time -- a completely different sprite silhouette carries each
  character's own identity regardless. `cpuPickFor(player_pick, roll)` picks uniformly among the characters
  that aren't `player_pick`, using `roll` (any value; only taken mod `COUNT - 1`) to choose which -- called
  once in `main.zig` with a fresh `s.player.rngNext()` right as the character screen's confirm flash finishes,
  so the CPU's pick genuinely varies run to run (never the player's own, but otherwise no more likely to be any one
  of the other 3) rather than always being "the next one in the list".
- `src/render_character.zig` — shared character-portrait rendering: draws a character's own sprite in its
  own hue(s), then an animated face reacting to `stateFor` (a board's own `garbage_punish_timer`/
  `combo_display_timer`/`chain` decide punish/combo/normal; `win` is passed explicitly by the game-over
  screen) centered on its `face` anchor -- the same expression logic for every character, just recolored and
  repositioned, rather than a fully separate hand-animated face per character. `draw` also offsets the whole
  sprite+face by `bounceOffset(state)` before drawing anything -- an explicit per-frame keyframe table per
  state (`COMBO_BOUNCE`/`WIN_BOUNCE` an up/down hop, `PUNISH_JITTER` a side-to-side flinch; `normal` is always
  `{0, 0}`), read straight off `s.frame_count` rather than the slower `currentFrame()` toggle so the motion
  itself feels snappier than the face's own blink/mouth cadence -- kept within `FRAME_PAD` so the sprite never
  visibly pokes through its own frame (below) while bouncing. `drawFrame(x, y, char_index)` frames the sprite
  that will be drawn at that same `x, y` in the character's own themed border (`characters.BorderStyle`) at a
  small in-game scale -- a self-contained analog of `render.zig`'s `drawThemedPanelBorder` (can't import that
  directly: `render.zig` already imports this file), with `FRAME_MARGIN` (`FRAME_PAD` clearance plus
  `FRAME_THICKNESS`) of space around the sprite. Used identically by `render.zig` (the player) and
  `render_cpu.zig` (the CPU), both now framing the in-game portrait this way, not just the setup screens'
  larger panels.
- `src/render_cpu.zig` — the "mini" side of the panel: `draw` takes an explicit board/character/points now
  (ordinarily `state.cpu`'s own, but see `render.zig`'s own doc comment above for versus mode's swapped
  case) rather than always reaching into `state.cpu*` directly, so this file no longer knows or cares whose
  perspective it's drawing. Its character portrait (now framed the same way the
  player's is, see `render_character.drawFrame`) /score and its board at a simplified micro scale (dithered
  colors, tiny per-color icons, smooth rise scrolling, a cursor, popping/recycling animation -- just
  abstracted down to fit: no bevels, linked-garbage slab, or landing squash). Its own mini board's border is
  themed the same way the player's main frame is (see `render.zig`), just simplified to 1px thick. Also draws
  this side's own chain/combo match-popup badge (`badge.drawMatchPopups(&board.match_popups, ...)`, flown to
  `TEXT_X`/`LABEL_Y + 10` -- this side's own score) -- previously skipped for lack of room, but the badge is
  small enough at this scale to read fine; `sim_matches.checkMatches` computes its spawn point in this file's
  own `CPU_MICRO_TILE`/`CPU_BOARD_Y` coordinate system (promoted to `constants.zig` so sim code can use them
  without importing rendering code) whenever the match happened on `&s.cpu` specifically (checked by pointer
  identity against that process-wide singleton), rather than always using the player's much larger-scale
  board coordinates the way it used to (harmless back when the CPU's own popup was never rendered at all) --
  only actually drawn when `board == &s.cpu` (see `render.zig`'s own doc comment on why that guard exists).
- `src/render_badge.zig` — the chain/combo popup badge, plus the shared checkerboard-blit dithering
  primitive it's built on (reusable for any future dithered-highlight effect). `drawMatchPopups` takes its
  fly-to `target_x`/`target_y` as parameters rather than a fixed constant, since the player and CPU panels
  put their score at different positions and scales (see `render.zig`'s `CHAR_TEXT_X` and `render_cpu.zig`'s
  `TEXT_X` call sites). Also home to
  `drawGarbageQueueIcons`: small warm-dithered pips in the gutter beside each board, one per queued incoming
  garbage attack (`Board.incoming_garbage`), width scaled to the attack's own column width -- a lightweight
  heads-up that an attack is about to land the instant that board goes idle, visible without reading the
  board itself. Drawn for the player in the gap between its frame and the panel column, and for the CPU in
  the panel's own leftover width to the right of its mini board. `drawPoints` (best-of-N series pips, next to
  each side's own score) lives here too, shared between `render.zig` and `render_cpu.zig`.
- `src/render_bg.zig` — the slow diagonal-drifting background behind the title/setup menu screens: faint
  speckled squares in a fixed, comptime-shuffled layout (no runtime RNG involved, since nothing ever reads it
  back), independent of every other RNG stream in the game.
- `src/debug.zig` — debug-only helpers (set up a board scenario, read back cell/chain/winner state) for
  scripted testing, each taking a `board` selector (0 = player, else = cpu); only exported as WASM functions
  in Debug builds (see the `comptime` block in `main.zig`) -- `zig build --release=small` never includes
  this surface. Used via `tools/wasm4-harness.js`.
- `src/main.zig` — wires the above together behind the WASM-4 `start`/`update` entry points: drives both
  boards' input/simulation/rise each frame, and tracks who wins once either tops out. Before a match begins,
  `state.menu_phase` steps through the title screen, mode-select (see `state.GameMode`/`game_modes.zig`), and
  then whichever setup steps that mode actually needs (see
  `render.drawTitleScreen`/`drawModeSelectScreen`/`drawSetupCharacterScreen`/`drawSetupCpuRevealScreen`/
  `drawSetupDifficultyScreen`/`drawStoryTierScreen`/`drawVersusConfirmScreen`) -- quick match visits all of
  character/CPU-reveal/difficulty; story visits character then its own tier screen instead (no CPU reveal --
  its opponent sequence is predetermined, not rolled -- see `game_modes.storyOpponentFor`); versus visits its
  own confirm screen instead ("connect via netplay, then press X" -- a deliberate manual gate, not a
  countdown right away, so `wasm4.NETPLAY` is only ever read and a countdown only ever begun once the player
  has confirmed the second peer/controller is actually ready; joining mid-match desyncs netplay). The
  character screen's own confirm flash (`state.setup_flash_timer`) and the CPU reveal
  screen's own spin (`state.cpu_reveal_tick`/`cpu_reveal_timer`) both gate input and just count down each
  frame until they're done, the same "freeze input, drive purely off a timer" shape as the countdown/
  closing-wipe overlays below; between a countdown and real gameplay sits a frozen "3 2 1 START" overlay
  (`state.countdown_timer`, started by `board.beginCountdown`); between a match ending and the winner overlay
  sits a frozen closing wipe (`state.closing_timer`, started by `board.beginClosing`) -- both gate simulation
  entirely, only ever calling `render.render()` (which reads board state passively) plus their own overlay on
  top. Quick match and versus both still run `board.awardMatchPoint`, which tallies the best-of-N series
  score and decides `state.set_winner` once one side has won enough matches to take the whole series; story
  mode skips it entirely (a stage is a single game) and instead advances/retries `state.story_stage` directly
  off `state.winner` once its own closing wipe finishes, tallying `state.story_game_overs` on a loss and
  calling `game_modes.maybeRevealXhard` the instant the final stage's own win is detected. Versus mode's
  `cpu` board is driven by a second real player on GAMEPAD2 (through the same `input.zig` functions as the
  player's own, just with a parallel set of DAS/buffering fields -- see `state.cpu_held_dir` etc.) instead of
  `cpu_ai.update` -- GAMEPAD1 always drives `player` and GAMEPAD2 always drives `cpu` regardless of which
  netplay slot is "mine" (see `render.zig`'s own doc comment for the rendering-side swap that actually makes
  each peer see themselves in the main seat), so the simulate/resolve/release/rise call order below stays
  byte-for-byte identical on every peer no matter who's "mine" locally -- the one thing that actually has to
  stay in lockstep for netplay determinism.
- `src/game_modes.zig` — the mode/difficulty-tier system behind story mode (see `state.GameMode`/
  `state.StoryTier`, though the enums themselves live in `state.zig` alongside the rest of the per-match mode
  state): `storyDifficultyFor` linearly ramps a tier's own (lo, hi) CPU difficulty (`cpu_ai.configFor`'s
  1-10 scale) across the 7 stages, `xhard` flat at 10 instead of ramping (meant to be brutal from the first
  opponent on); `storyOpponentFor` is just the stage index into `characters.ALL`, in order (a "mirror match"
  against the player's own pick, if it comes up, is no different from any other stage); `applyStoryProfile`/
  `applyDefaultProfile` retune `constants.zig`'s runtime-configurable POP_FRAMES/PRE_POP_*/
  DANGER_FORGIVENESS_FRAMES/RISE_SPEED_SCALE_PCT (see that file's own doc comment) to a tier's own "stack rise
  speed, pop delay, top loss timer" feel, or back to today's untouched baseline for quick match/versus.
  `xhard_revealed` (persisted across sessions via `w4.Diskr`/`Diskw`, a tiny fixed-format blob) is purely a
  cosmetic hint unlocked by `maybeRevealXhard` once a run clears Hard with zero game overs -- the secret
  hold-left-plus-Z input that actually reaches X Hard (see `main.zig`'s `story_tier_select` handling) always
  works regardless of whether this has ever been earned; earning it just adds an on-screen hint, on the
  tier-select screen from then on, that the input exists at all.
- `build.zig` / `build.zig.zon` — builds `src/main.zig` into a freestanding `wasm32` cart with the memory layout
  WASM-4 expects, and wires up `zig build test`.
- `tools/wasm4-harness.js` — a shared Node harness for driving a compiled cart headlessly (scripted board
  scenarios via `src/debug.zig`, screenshots, fuzzing input). See the comment at the top of the file for usage.

## Testing

`state.zig`, `board.zig`, `sim.zig`/`sim_matches.zig`/`sim_garbage.zig`, `cpu_ai.zig`,
`cpu_engine.zig`/`cpu_engine_garbage.zig`, and `garbage_pieces.zig` have Zig `test` blocks — `sim.zig`'s live
in the companion `src/sim_test.zig`, garbage-specific ones in `src/sim_garbage_test.zig`, recycle-specific
ones (stagger order, the bottom-row-only-converts rule, and the no-accidental-match color guarantee) in
`src/sim_recycle_test.zig`, `cpu_engine.zig`'s in `src/cpu_engine_test.zig`, `cpu_engine_garbage.zig`'s
(including its cross-validation against the real board) in `src/cpu_engine_garbage_test.zig`, and
`garbage_pieces.zig`'s inline in the same file, to keep each module under ~500 lines. These run natively (not
compiled into the cart) and are excluded from `input.zig`/`render.zig`/`render_garbage.zig`/`render_cpu.zig`,
which touch WASM-4's real host functions and only make sense under an actual WASM-4 host --
`garbage_pieces.zig` is deliberately split out from `render_garbage.zig` specifically so its own pure
grouping logic doesn't inherit that exclusion.

```sh
zig build test
```

This also runs in CI on every push, before the cart is built.
