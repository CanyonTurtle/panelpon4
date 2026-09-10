---
author: Cannon <CanyonTurtle>
date: {{DATE}}
---
# panelpon4

A Panel de Pon-style falling/rising block matching game for the
[WASM-4](https://wasm4.org) fantasy console, written in Zig.

Each board is the traditional Panel de Pon size, 6 columns by 12 rows. Swap
adjacent blocks to line up 3 or more of the same color/symbol -- chain
several matches together, or clear a big combo in one move, to send garbage
blocks over to your opponent's side. The floor keeps rising, so don't let
your stack reach the top.

Play 1P Story mode against a run of increasingly tough characters (with a
secret extra-hard difficulty tier for those who find it), 1P Quick Match
against a single CPU opponent, or 2P Versus -- locally on a second
controller, or remotely via WASM-4's own netplay.

Controls: arrow keys move the cursor, X swaps the two blocks under it, Z
manually raises the floor.
