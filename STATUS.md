# Status

**Updated:** 2026-11-14 by Claude (Code tab, Windows cloud PC)
**Working folder / branch:** `%USERPROFILE%\Desktop\VibeCoding\snake\` / `main`
**GitHub:** not published. Committed locally and ready; waiting for 2Shay's word (see "Next action").

## Task and current state
O(1) Snake: a playable, single-file browser Snake where every move costs the same, with a never-crash autopilot.
On 14 Nov 2026 2Shay asked for it to be tested on phones, tidied up and given an open-source licence so it can be shared.
Done: phone layout and touch fixes, an automated check, a public README, the MIT licence, the first commit.

## Changes and checks (14 Nov 2026)
- `tests/phone-check.ps1` (new): drives Chrome or Edge in phone emulation. 14 screen sizes, real touch input (taps,
  swipes, two fingers), keyboard and mouse, then `tests/engine-check.js` and the benchmark.
  **Chrome 157: 61 passed, 0 failed. Edge 157: 61 passed, 0 failed.** Evidence: `scratch/phone-check-chrome/` and
  `scratch/phone-check-msedge/` (`results.json` and screenshots; not committed).
- What the first run found in the old page, all fixed in `index.html`:
  - phone held sideways: the board shrank to 16 px. Now the board is on the left and the pad on the right.
  - small phones: the pad was cut off. The board's width is now capped by the screen height.
  - a second finger on the board steered the snake. Now one finger steers (`pid` in the input code).
  - the pad's row blocked page scrolling. The pad is now only as wide as its buttons.
  - no autopilot control on a phone's first screen. The pad now has an AUTO button.
  - keyboard hints on phones. Touch screens now get touch hints.
  - buttons under 44 px on touch screens; `viewport-fit=cover` with no safe-area padding (removed).
- Measured benchmark in these runs: 23 to 28 million moves per second (36 to 43 ns per move), 10 of 10 boards filled.
  Engine check: 200 of 200 autopilot games filled the board, about 42,600 moves per game.
- `README.md` rewritten for outsiders; `LICENSE` is MIT (2Shay asked for open source; MIT was Claude's pick);
  the private artifact link moved out of the repo into the workspace `PROJECTS.md`.
- The autopilot idea is credited in the README to John Tapsell's 2015 write-up (found by web search on 14 Nov 2026).
- Inside the artifact host the page can run under a phone's notch and bars. Checked in Chrome with emulated insets
  (393 x 852 upright, 852 x 393 sideways): board and pad stay clear of them.
- The private claude.ai artifact copy was refreshed with this version on 14 Nov 2026, so 2Shay can try it on a real phone.
- Unused template folders (`assets/`, `src/`) and two `.gitkeep` files were moved to `_to_delete/`.

## Blockers and unknowns
- **Not tested:** any real phone or tablet, Safari, Firefox. Neither browser is installed on this PC and Safari does
  not exist for Windows. The phone results above are Chrome's emulation.
- Could not be checked in emulation: iPhone address-bar resizing, notch areas when held sideways, and whether Safari
  honours `touch-action:none` on the board the way Chrome does.
- Not tested on GitHub Pages.

## Next action
2Shay: try the private artifact copy on a real phone, then say whether to publish this repo (public or private).
