# O(1) Snake: agent instructions

Read `%USERPROFILE%\Desktop\VibeCoding\AGENTS.md` first (workspace rules). This file adds rules for this project only.

## What this is
A browser Snake game for 2Shay in one self-contained `index.html`. Every move runs in constant time (typed-array ring
buffer, O(1) free-cell set, neighbour lookup table), allocates nothing, and redraws at most three cells. It has a
never-crash autopilot (one loop through every cell, with safe shortcuts), a live readout, a benchmark, and touch
controls for phones (swipe, an on-screen pad, a sideways layout).
Sister project: `1-billion-games-of-snake\`, the same autopilot on a graphics card (https://github.com/2Shay96/1-Billion-games-of-Snake).

## How to run
Double-click `index.html` (any modern browser). No build, no dependencies. Fonts come from Google Fonts and fall back cleanly offline.

## How to test
```powershell
powershell -ExecutionPolicy Bypass -File tests/phone-check.ps1
```
Expect `RESULT: 61 passed, 0 failed` (about 90 seconds, no window). Run it again with
`-Browser "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"`. Details and by-hand checks: `tests/README.md`.
The check is Chrome's phone emulation. It is not a real phone, Safari or Firefox: say so when you report results.

## Project rules
- Keep the game a single self-contained `index.html`. The engine (`class Snake`) must stay allocation-free per move.
- `window.O1Snake` exposes the engine class, the live game and read-only state for the tests. Keep it.
- The board height must stay even (the autopilot loop needs it).
- Layout: the board must fit on the first screen at every size in `tests/phone-check.ps1`. If you change the CSS, rerun it.
- Touch: one finger steers (`pid` in the input code). Keep `touch-action:none` on the board and the pad only, so the
  rest of the page still scrolls.
- Public-facing text states measured facts only, and says plainly what is not tested.
- No secrets, no personal email and no local absolute paths in committed files. `scratch/` and `_to_delete/` are not committed.

## The private artifact copy
2Shay also keeps a private claude.ai artifact copy of this page. Its link is in the workspace `PROJECTS.md`, not here.
The `window.claude?.hot` lines at the end of `index.html` only matter there: they keep the game going across live updates.
The `claude:viewport-fit-sides` meta tag and the `env(safe-area-inset-*)` values in the CSS are also for that host, where
the page can run under a phone's notch and bars. In an ordinary browser tab those insets are zero and change nothing.
To refresh that copy after editing, drop the first 4 lines (doctype, `<html>`, the two `<meta>` tags) and the final
`</html>` line, because the artifact host adds its own document wrapper:
```powershell
$l = [IO.File]::ReadAllLines("index.html"); [IO.File]::WriteAllLines("$env:TEMP\o1-snake.html", $l[4..($l.Length-2)], (New-Object Text.UTF8Encoding($false)))
```

## Key files
- `index.html`: the whole game (engine, renderer, UI)
- `tests/phone-check.ps1`, `tests/engine-check.js`, `tests/README.md`: the automated check and how to run it
- `docs/screenshot.png`, `docs/phone.png`: pictures for `README.md`
- `STATUS.md`: current state and next action (update after meaningful work)
