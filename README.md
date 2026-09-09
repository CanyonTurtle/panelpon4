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

Each board is the traditional Panel de Pon size, 6 columns by 12 rows. You play against a CPU opponent,
each with your own full board -- yours at normal size on the left, the CPU's at a simplified micro scale in
the side panel. Both run the exact same rules and physics.

- **Arrow keys**: move the two-tile cursor.
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
  tiles.
- A column with blocks near the top bounces in place as a warning that it's close to the rise hazard.
- Each board's floor rises forever, faster as that board's own score climbs -- true for the CPU too, so a
  CPU that's playing efficiently is also accelerating its own rise. Topping out isn't instant, though: once
  a board is idle with a block at or above the ceiling, a one-second forgiveness timer starts, and only
  running it out actually ends the match for that side (clearing the danger row, or the board going busy
  again, resets it) -- a real beat to recover from a close call rather than an instant loss the moment a
  rise happens to touch the top. Whoever's forgiveness timer runs out first loses (both on the same frame
  is a draw).
- **Z**: manually raise your own floor by one row right away (finishes in a third of a second instead of
  waiting for the automatic pace) -- useful for deliberately forcing a rise when you want fresh blocks, or
  to bail out of a bad board shape. On a cooldown (two thirds of a second) so it can't be spammed -- hold it
  down to keep raising row after row as soon as each cooldown clears, instead of having to tap repeatedly.
- A match is a best of 3 -- first to 2 match wins takes the whole series (see `constants.POINTS_TO_WIN`). A
  small row of pips next to each side's own score fills in as they win matches; losing a match doesn't end
  the series, just that one match -- press X to move straight into the next one, same difficulty, running
  score carried over as pips, not reset.
- Two screens lead into a series: a branded **title** screen (press X to continue), then a **setup** screen
  where **left/right** sets the CPU's difficulty, 1-10, shown as a filled-in bar rather than a bare number
  (press X to begin). Every level runs the same move-search engine (see `src/cpu_engine.zig`) -- lower levels
  are simply worse at listening to it (far more likely to ignore its pick and play a random legal swap
  instead, a shallower search, and a slower reaction time), not a different kind of AI. The engine can also
  choose to raise its own floor by a row instead of swapping (see the Z button above) when it's running low
  on real blocks to work with -- weighed the same way as any swap, so it only does this when it's actually
  short on material, not just because nothing else looks great -- and never when its own stack (or, after
  the raise, what its own stack would become) is already dangerously close to the top, however short on
  material it is. Difficulty and character are both fixed for the whole series, but revisitable in setup
  again once one concludes.
- The setup screen also shows all 4 selectable characters at once (see `src/characters.zig`) -- a lizard, a
  mermaid, a bug, and a cloud puff, each a real pixel-art figure, not just a colored square. **Up/down**
  cycles your own pick (highlighted with a dithered outline); the CPU always auto-picks a different one (a
  small arrow marks its pick instead, never itself selectable), recomputed whenever yours changes. Switching
  rethemes the setup screen's own menu panel border to match your current pick live. Both screens share the
  same gently-bobbing panel (a true sine-wave ease, "personality") over a slow diagonal-scrolling background
  of faint drifting blocks.
- Your chosen character themes your own main-frame border (its own color and a distinct border pattern --
  solid, checkered, dashed, or a thin double outline) and gives you an animated portrait next to your score,
  reacting to what's actually happening: idle otherwise, excited on a combo or chain, wincing for a moment
  right after taking a garbage attack, and celebrating on the game-over screen if you won (the losing side's
  own character shows there too, wincing, rather than only the winner appearing) -- both characters stay
  visible and animated straight through the countdown and closing-wipe transitions between matches, never
  just popping in once gameplay resumes. The CPU picks its
  own character the same way, always a different one than yours (see `characters.cpuPickFor`), theming its
  own mini board's border and getting the identical portrait treatment next to its own score.
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

- `src/wasm4.zig` — bindings for the WASM-4 host API (drawing, input, memory-mapped registers).
- `src/constants.zig` — layout/timing constants shared across modules.
- `src/symbols.zig` — pixel-art symbol data drawn on each block color.
- `src/state.zig` — the `Board` struct (grid, cursor, score/chain, rise state, its own RNG stream, its own
  match-popup pool) plus its small methods (ring-buffer indexing, RNG, board-busy query), and the two live
  instances of it, `player`/`cpu`. Every other module takes an explicit `*Board` rather than reaching into
  an implicit global, so the exact same logic drives both sides of a vs-CPU match. `physRow` (the logical-to-
  physical row translation) is piecewise: logical rows below `constants.SPAWN_ROWS` are a fixed, non-rotating
  offscreen garbage staging area (see `sim_garbage.spawnGarbage`) that maps straight through regardless of
  `top`; everything from `SPAWN_ROWS` on is the actual rotating ring (the ceiling, the visible board, and the
  one hidden buffer row rising in from below), exactly as the whole board used to work before the staging
  area existed, just starting at that offset. Cursor-facing code (`input.zig`, `cpu_ai.zig`) stays in
  visible-relative row terms (0 = ceiling) and only converts to an absolute logical row at the point it
  actually touches the grid (`sim.trySwap`, `input.canSwapAt`).
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
  color-run, just an ongoing `.popping`/`.recycling` one).
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
- `src/cpu_ai.zig` — the CPU opponent's move picker, branching on `state.difficulty` (see `configFor`):
  every level from 1-10 runs `cpu_engine.zig`'s actual search, differing only in how often they listen to
  it (a steep chance to ignore its pick and play a random legal swap instead at the low end, falling to
  zero by level 10), search depth, and reaction speed. Doesn't wait for the whole board to go idle before
  thinking/acting -- like a player, whose own input is never blocked by unrelated activity elsewhere (see
  `input.updateSwap`) -- it reasons about and can act on whatever's true right now, including cells still
  falling/landing/mid-swap elsewhere (see `cpu_grid.Grid.fromBoard`); `sim.trySwap`'s own per-cell check
  still decides whether a given swap actually succeeds, exactly as it does for the player, so this never
  lets the CPU do anything a player couldn't also do from the same position.
- `src/cpu_engine.zig` — the actual move-search engine behind the CPU: snapshots the board into a small
  `Grid`, tries every legal swap on a copy, resolves each one's full logical cascade (gravity, matches,
  garbage propagation, repeated for chains) to score it, and adds a bitboard-driven structural heuristic
  (same-color adjacency, column height) so moves that don't pop anything yet are still ranked sensibly --
  plus a discounted look at the best follow-up move (a shallow best-first search, compounding the same
  discount again each ply deeper) for the higher levels, rewarding a setup move that enables a strong reply
  over a shallow immediate pop. The *lookahead* -- never the top-level decision itself, which always weighs
  every legal candidate -- is beam-pruned (see `BEAM_WIDTH`): only the most promising handful of a ply's
  candidates get a real recursive search of their own, the rest keep just their immediate value, which is
  what keeps a beam-searched depth 3-4 roughly as cheap as an exhaustive depth 2 used to be (memory was
  never the constraint -- `Grid` is 72 bytes with no heap allocation, and recursion depth maps straight to
  a handful of small stack frames -- the branching factor is). Also weighs
  raising the stack (see `raiseValue`) against the best available swap: worth more the fewer real blocks
  are left on the board, worth less than any real match regardless, so it only wins when the board is
  genuinely short on material and has nothing better to do -- and it's judged against the height a raise
  would actually leave the tallest column at, not the current one, so a materially-poor but dangerously
  tall, skinny stack doesn't get raised straight into topping out (the same steep height-danger penalty
  also discourages any *swap* that would leave a column that close to the top, not just raising). Deliberately
  its own small simulator rather than reusing `sim.zig` directly -- see the module's own doc comment for why
  -- tests in the companion `src/cpu_engine_test.zig`.
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
  input buffering so a fast continuous drag chains swaps at max speed) -- always drives `state.player`; the
  CPU has no real input (see `cpu_ai.zig`).
- `src/render.zig` — most drawing: the player's board (in full detail) at normal size, the cursor, panel,
  and title/setup/game-over screens. A column bounces in place as a stress warning (`isColumnStressed`) once
  it has any content within `STRESS_WARNING_ROWS` rows of the ceiling (logical row `constants.SPAWN_ROWS`),
  not only once it's already touching the top -- matching other Panel de Pon clients' more generous warning
  zone. `drawFrame`'s main-frame border is themed by whichever character the player picked on the setup
  screen (`drawThemedBand`, see `characters.BorderStyle`) -- color and fill pattern both.
- `src/render_garbage.zig` — garbage's full-detail rendering (the muted checkerboard fill and the linked-
  clump bezel look), split out from render.zig to keep that file under the project's ~500-line guideline,
  mirroring the sim.zig/sim_garbage.zig split. `drawLinkedFlash` is a phase-inverted variant of the same
  checkerboard, used by `render.drawRecyclingCell` to give a garbage row that's caught up in a pop event but
  won't actually convert (see `Cell.garbage_reveals`) a purely cosmetic "still being processed" flash instead
  of sitting there looking untouched while the rest of the clump pops.
- `src/characters.zig` — the 4 selectable characters: a real pixel-art sprite each (same text-art bitmap
  convention as `symbols.zig`) -- a lizard, a mermaid, a bug, and a cloud puff -- plus a hue/dither pair, a
  main-frame border style, and a `face` anchor (where `render_character.zig`'s shared expression logic
  centers on top of that sprite). `cpuPickFor` always returns a different character than whichever one is
  passed in, so the CPU's own pick (set in `main.zig` whenever the player changes theirs on the setup screen)
  never matches the player's.
- `src/render_character.zig` — shared character-portrait rendering: draws a character's own sprite in its
  own hue(s), then an animated face reacting to `stateFor` (a board's own `garbage_punish_timer`/
  `combo_display_timer`/`chain` decide punish/combo/normal; `win` is passed explicitly by the game-over
  screen) centered on its `face` anchor -- the same expression logic for every character, just recolored and
  repositioned, rather than a fully separate hand-animated face per character. Used identically by
  `render.zig` (the player) and `render_cpu.zig` (the CPU).
- `src/render_cpu.zig` — the CPU's side of the panel: its character portrait/score and its board at a
  simplified micro scale (dithered colors, tiny per-color icons, smooth rise scrolling, a cursor,
  popping/recycling animation -- just abstracted down to fit: no bevels, linked-garbage slab, landing squash,
  or popups). Its own mini board's border is themed the same way the player's main frame is (see
  `render.zig`), just simplified to 1px thick.
- `src/render_badge.zig` — the chain/combo popup badge, plus the shared checkerboard-blit dithering
  primitive it's built on (reusable for any future dithered-highlight effect). Also home to
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
  boards' input/simulation/rise each frame, and tracks who wins once either tops out. Before a series begins,
  `state.menu_phase` steps through the title and setup screens (see `render.drawTitleScreen`/
  `drawSetupScreen`); between a countdown and real gameplay sits a frozen "3 2 1 START" overlay
  (`state.countdown_timer`, started by `board.beginCountdown`); between a match ending and the winner overlay
  sits a frozen closing wipe (`state.closing_timer`, started by `board.beginClosing`) -- both gate simulation
  entirely, only ever calling `render.render()` (which reads board state passively) plus their own overlay on
  top. `board.awardMatchPoint` tallies the best-of-N series score and decides `state.set_winner` once one
  side has won enough matches to take the whole series.
- `build.zig` / `build.zig.zon` — builds `src/main.zig` into a freestanding `wasm32` cart with the memory layout
  WASM-4 expects, and wires up `zig build test`.
- `tools/wasm4-harness.js` — a shared Node harness for driving a compiled cart headlessly (scripted board
  scenarios via `src/debug.zig`, screenshots, fuzzing input). See the comment at the top of the file for usage.

## Testing

`state.zig`, `board.zig`, `sim.zig`/`sim_matches.zig`/`sim_garbage.zig`, `cpu_ai.zig`, and
`cpu_engine.zig`/`cpu_engine_garbage.zig` have Zig `test` blocks — `sim.zig`'s live in the companion
`src/sim_test.zig`, garbage-specific ones in `src/sim_garbage_test.zig`, recycle-specific ones (stagger
order, the bottom-row-only-converts rule, and the no-accidental-match color guarantee) in
`src/sim_recycle_test.zig`, `cpu_engine.zig`'s in `src/cpu_engine_test.zig`, and `cpu_engine_garbage.zig`'s
(including its cross-validation against the real board) in `src/cpu_engine_garbage_test.zig`, to keep each
module under ~500 lines. These run natively (not compiled into the
cart) and are excluded from `input.zig`/`render.zig`/`render_garbage.zig`/`render_cpu.zig`, which touch
WASM-4's real host functions and only make sense under an actual WASM-4 host.

```sh
zig build test
```

This also runs in CI on every push, before the cart is built.
