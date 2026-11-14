# Tests

## The automated check (Windows, with Chrome or Edge installed)

```powershell
powershell -ExecutionPolicy Bypass -File tests/phone-check.ps1
```

Expect `RESULT: 61 passed, 0 failed`. It takes about 90 seconds and opens no window.

The script starts Chrome with a throwaway profile in `scratch/` (never your own profile), drives it through the DevTools
protocol on this computer only, and closes it again. It:

1. lays the page out on 14 screens (phones upright and sideways, tablets, a desktop) and measures that the board and the
   pad fit on the first screen, nothing spills sideways, the board is drawn pixel-exact and the buttons are big enough to tap;
2. plays the game with touch input on a phone-sized screen: taps, swipes, the pad, two taps inside one move, two fingers
   at once, turning the phone mid-game, hitting a wall, and the autopilot filling the whole board;
3. plays it with the keyboard and the mouse on a desktop-sized screen;
4. runs `engine-check.js` and the page's own benchmark;
5. fails if the browser logged a script error.

| Option | Meaning |
|---|---|
| `-Browser "<path>"` | another Chromium browser, for example `"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"` |
| `-Quick` | skip the 20-second autopilot game (3 fewer checks) |
| `-Headed` | show the browser window |
| `-Url <address>` | test a served copy instead of the local file |
| `-Port <number>` | DevTools port to use (default 9340) |

Results and screenshots land in `scratch/phone-check-<browser>/`, which is not committed.

**What this is not.** It is Chrome's phone emulation: phone screen sizes, real touch events and "I am a phone" signals,
but still Chrome's engine on a PC. It does not test Safari, Firefox or a real phone. Those are untested.

## The engine check by hand

Open `index.html`, paste the whole of `engine-check.js` into the browser's DevTools console and press Enter. Expect `PASS`.
It checks that the autopilot's loop visits every cell once, plays 300 random games while checking the game's data after
every move, and plays 200 autopilot games that must each fill the board.

## By eye

Open `index.html` and press `Q`, then `0`. The autopilot should fill the board (576 / 576) in about 20 seconds without dying.
Press **Run benchmark** and expect `10 of 10 boards cleared`.
