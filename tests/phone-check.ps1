param(
  # Browser to drive. Chrome by default; Edge works too:
  #   -Browser "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
  [string]$Browser = "C:\Program Files\Google\Chrome\Application\chrome.exe",
  [string]$Url = "",     # default: this project's index.html, opened straight from disk
  [int]$Port = 9340,
  [switch]$Headed,       # show the browser window (default: no window)
  [switch]$Quick         # skip the slow part (autopilot filling a whole board)
)
# Phone and touch check for O(1) Snake.
#
# Drives a real Chrome or Edge on this computer through its DevTools protocol (localhost only) and
#   1. lays the page out on phone, tablet and desktop sized screens and measures it,
#   2. plays it with real touch input (taps, swipes, two fingers) on a phone-sized screen,
#   3. plays it with the keyboard and the mouse on a desktop-sized screen,
#   4. runs tests/engine-check.js and the in-page benchmark.
# The browser uses a throwaway profile in scratch/ (never your own profile) and is closed at the end.
#
# This is Chrome's phone emulation: the right screen size, touch input and "this is a phone" signals,
# but still Chrome's engine on a PC. It is not an iPhone, not Safari and not Firefox. See tests/README.md.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue
$root = Split-Path $PSScriptRoot -Parent
$exe = Split-Path $Browser -Leaf
$tag = [IO.Path]::GetFileNameWithoutExtension($exe)
$out = Join-Path $root "scratch\phone-check-$tag"
$prof = Join-Path $root "scratch\profile-$tag"
New-Item -ItemType Directory -Force $out, $prof | Out-Null
if (-not $Url) { $Url = ([Uri](Join-Path $root "index.html")).AbsoluteUri }

function Stop-TestBrowser {
  Get-CimInstance Win32_Process -Filter "Name='$exe'" | Where-Object { $_.CommandLine -like "*$prof*" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
}

# ---- DevTools protocol plumbing ----
$script:nextId = 0
$script:events = New-Object System.Collections.ArrayList
$ct = [Threading.CancellationToken]::None
function Receive-Msg([int]$timeoutMs = 30000) {
  $ms = New-Object IO.MemoryStream
  do {
    $buf = New-Object byte[] 262144
    $seg = New-Object 'ArraySegment[byte]' (, $buf)
    $task = $ws.ReceiveAsync($seg, $ct)
    if (-not $task.Wait($timeoutMs)) { throw "timed out waiting for the browser" }
    $r = $task.Result
    $ms.Write($buf, 0, $r.Count)
  } while (-not $r.EndOfMessage)
  $ser.DeserializeObject([Text.Encoding]::UTF8.GetString($ms.ToArray()))
}
function Invoke-Cdp([string]$method, $params = @{}) {
  $script:nextId++
  $id = $script:nextId
  $bytes = [Text.Encoding]::UTF8.GetBytes($ser.Serialize(@{ id = $id; method = $method; params = $params }))
  $ws.SendAsync((New-Object 'ArraySegment[byte]' (, $bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
  while ($true) {
    $obj = Receive-Msg
    if ($obj.ContainsKey('id')) {
      if ($obj['id'] -eq $id) {
        if ($obj.ContainsKey('error')) { throw ("$method failed: " + $ser.Serialize($obj['error'])) }
        return $obj['result']
      }
    } elseif ($obj.ContainsKey('method')) { [void]$script:events.Add($obj) }
  }
}
function Js([string]$expr) {
  $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
  if ($r.ContainsKey('exceptionDetails')) { throw ("page script failed: " + $ser.Serialize($r['exceptionDetails'])) }
  $r['result']['value']
}

# ---- results ----
$script:results = New-Object System.Collections.ArrayList
$script:layouts = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = "") {
  [void]$script:results.Add(@{ ok = $ok; name = $name; detail = $detail })
  $line = $(if ($ok) { "PASS  " } else { "FAIL  " }) + $name
  if ($detail) { $line += "  [" + $detail + "]" }
  Write-Host $line
}

# ---- device, page and touch helpers ----
function Set-Device([int]$w, [int]$h, [double]$dpr, [bool]$mobile) {
  $o = if ($w -gt $h) { @{ type = 'landscapePrimary'; angle = 90 } } else { @{ type = 'portraitPrimary'; angle = 0 } }
  [void](Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = $dpr; mobile = $mobile; screenWidth = $w; screenHeight = $h; screenOrientation = $o })
  [void](Invoke-Cdp 'Emulation.setTouchEmulationEnabled' @{ enabled = $mobile; maxTouchPoints = 5 })
}
function Open-Page {
  [void](Invoke-Cdp 'Page.navigate' @{ url = $Url })
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ready = $false
  while (-not $ready -and $sw.ElapsedMilliseconds -lt 15000) {
    Start-Sleep -Milliseconds 150
    try { $ready = [bool](Js "document.readyState === 'complete' && !!(window.O1Snake && window.O1Snake.game)") } catch {}
  }
  if (-not $ready) { throw "the page did not load: $Url" }
  [void](Js "Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 4000))]).then(() => true)")
  Start-Sleep -Milliseconds 300
}
function Shot([string]$file, [int]$w, [int]$h, [double]$dpr) {
  $r = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png'; clip = @{ x = 0; y = 0; width = $w; height = $h; scale = (1 / $dpr) } }
  [IO.File]::WriteAllBytes((Join-Path $out $file), [Convert]::FromBase64String($r['data']))
}
function Pt($x, $y, [int]$id = 0) { @{ x = [double]$x; y = [double]$y; id = $id; radiusX = 10; radiusY = 10; force = 0.5 } }
function Touch([string]$type, $points) { [void](Invoke-Cdp 'Input.dispatchTouchEvent' @{ type = $type; touchPoints = $points }) }
function Tap($x, $y) {
  Touch 'touchStart' @(, (Pt $x $y))
  Start-Sleep -Milliseconds 50
  Touch 'touchEnd' @()
  Start-Sleep -Milliseconds 80
}
function Swipe($x0, $y0, $x1, $y1, [int]$steps = 6) {
  Touch 'touchStart' @(, (Pt $x0 $y0))
  for ($i = 1; $i -le $steps; $i++) {
    Start-Sleep -Milliseconds 16
    Touch 'touchMove' @(, (Pt ($x0 + ($x1 - $x0) * $i / $steps) ($y0 + ($y1 - $y0) * $i / $steps)))
  }
  Start-Sleep -Milliseconds 16
  Touch 'touchEnd' @()
}
function Key([string]$code, [string]$key, [int]$vk) {
  [void](Invoke-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; code = $code; key = $key; windowsVirtualKeyCode = $vk })
  [void](Invoke-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; code = $code; key = $key; windowsVirtualKeyCode = $vk })
}
function Mouse([string]$type, $x, $y, [int]$buttons) {
  $button = if ($type -eq 'mouseMoved' -and $buttons -eq 0) { 'none' } else { 'left' }
  [void](Invoke-Cdp 'Input.dispatchMouseEvent' @{ type = $type; x = [double]$x; y = [double]$y; button = $button; buttons = $buttons; clickCount = 1 })
}
function Center([string]$sel, [bool]$scroll = $false) {
  $s = if ($scroll) { 'true' } else { 'false' }
  Js ("(function (sel, scroll) { var e = document.querySelector(sel); if (!e) return null; if (scroll) e.scrollIntoView({ block: 'center', behavior: 'instant' }); var r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height, shown: getComputedStyle(e).display !== 'none' && r.width > 0 }; })(" + $ser.Serialize($sel) + ", $s)")
}

$jsState = @'
(() => { const o = window.O1Snake, g = o.game, h = g.body[g.hp], ov = document.getElementById('ov');
  return { state: o.state, auto: o.auto, level: o.level, dir: g.dir, x: h % g.w, y: (h / g.w) | 0, len: g.len, moves: g.moves,
    ov: ov.hidden ? '' : document.getElementById('ovBig').textContent, small: ov.hidden ? '' : document.getElementById('ovSmall').textContent,
    tag: document.getElementById('tag').textContent, note: document.getElementById('note').textContent,
    scrollY: Math.round(scrollY), scale: window.visualViewport ? visualViewport.scale : 1,
    dead: document.getElementById('lcd').classList.contains('dead') }; })()
'@
$jsLayout = @'
(() => {
  const R = s => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect();
    return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, shown: getComputedStyle(e).display !== 'none' && r.width > 0 }; };
  const minSide = sel => { const a = Array.from(document.querySelectorAll(sel)).map(b => b.getBoundingClientRect()).filter(r => r.width > 0);
    return a.length ? Math.min.apply(null, a.map(r => Math.min(r.width, r.height))) : 0; };
  const top = document.querySelector('.lcd-top'), cv = document.getElementById('cv');
  return { iw: innerWidth, ih: innerHeight, dpr: devicePixelRatio, coarse: matchMedia('(pointer:coarse)').matches,
    scrollW: document.documentElement.scrollWidth, unit: R('.unit'), bezel: R('.bezel'), screen: R('#screen'), canvas: R('#cv'),
    dpad: R('#dpad'), panel: R('.panel'), autoBtn: R('#autoBtn'), autoPad: R('#autoPad'), cvPx: cv.width,
    padMin: minSide('#dpad button'), panelMin: minSide('.btn, .seg button'), topClip: top.scrollWidth - top.clientWidth,
    hint: document.getElementById('ovSmall').textContent };
})()
'@
function State { Js $jsState }
function Wait-State([scriptblock]$cond, [int]$timeoutMs = 3000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    $s = State
    if (& $cond $s) { return $s }
    Start-Sleep -Milliseconds 60
  } while ($sw.ElapsedMilliseconds -lt $timeoutMs)
  return $s
}
$dirName = @('up', 'right', 'down', 'left')
$vx = @(0, 1, 0, -1)
$vy = @(-1, 0, 1, 0)
function Check-Turn([string]$how, [int]$d) {
  $s = Wait-State { param($q) $q['dir'] -eq $d } 2500
  $m0 = $s['moves']; $x0 = $s['x']; $y0 = $s['y']
  $s2 = Wait-State { param($q) $q['moves'] -ge ($m0 + 1) } 2500
  $n = $s2['moves'] - $m0
  $went = ($n -ge 1) -and (($s2['x'] - $x0) -eq ($n * $vx[$d])) -and (($s2['y'] - $y0) -eq ($n * $vy[$d]))
  Check "$how sends the snake $($dirName[$d])" (($s['dir'] -eq $d) -and $went -and ($s2['state'] -eq 'run')) ("heading " + $dirName[[int]$s2['dir']] + ", moved " + ($s2['x'] - $x0) + "," + ($s2['y'] - $y0) + ", " + $s2['state'])
}
function New-Game {   # set-up step, not a thing under test: fresh game at level 1, started with a tap on the board
  [void](Js "document.getElementById('newBtn').click(); document.querySelector('#levels button').click(); scrollTo(0, 0)")
  Start-Sleep -Milliseconds 150
  $c = Center '#screen'
  Tap $c['x'] $c['y']
  [void](Wait-State { param($q) $q['state'] -eq 'run' -and $q['moves'] -ge 1 } 2500)
  $c
}

# ---- the screens to lay the page out on. Sizes are the part of the screen a browser shows with its bars visible (approximate). ----
$screens = @(
  @{ name = 'iPhone SE 1st gen, upright';  w = 320;  h = 454;  dpr = 2;     mobile = $true },
  @{ name = 'iPhone SE 2022, upright';     w = 375;  h = 548;  dpr = 2;     mobile = $true },
  @{ name = 'iPhone 13 mini, upright';     w = 375;  h = 629;  dpr = 3;     mobile = $true },
  @{ name = 'iPhone 15, upright';          w = 393;  h = 659;  dpr = 3;     mobile = $true },
  @{ name = 'iPhone 15 Pro Max, upright';  w = 430;  h = 739;  dpr = 3;     mobile = $true },
  @{ name = 'Android 360 wide, upright';   w = 360;  h = 672;  dpr = 3;     mobile = $true },
  @{ name = 'Pixel 8, upright';            w = 412;  h = 785;  dpr = 2.625; mobile = $true },
  @{ name = 'iPhone SE 2022, sideways';    w = 667;  h = 331;  dpr = 2;     mobile = $true },
  @{ name = 'iPhone 15, sideways';         w = 852;  h = 345;  dpr = 3;     mobile = $true },
  @{ name = 'iPhone 15 Pro Max, sideways'; w = 932;  h = 380;  dpr = 3;     mobile = $true },
  @{ name = 'Android 800 wide, sideways';  w = 800;  h = 280;  dpr = 3;     mobile = $true },
  @{ name = 'iPad mini, upright';          w = 744;  h = 1026; dpr = 2;     mobile = $true },
  @{ name = 'iPad 10th gen, sideways';     w = 1180; h = 716;  dpr = 2;     mobile = $true },
  @{ name = 'Desktop 1280 x 800, mouse';   w = 1280; h = 800;  dpr = 1;     mobile = $false }
)

function Check-Layout($p) {
  Set-Device $p.w $p.h $p.dpr $p.mobile
  Open-Page
  $L = Js $jsLayout
  $n = $p.name
  $board = [Math]::Round([double]$L['canvas']['w'])
  $fitsW = $L['scrollW'] -le $L['iw']
  $crisp = [Math]::Abs([double]$L['canvas']['w'] * [double]$L['dpr'] - [double]$L['cvPx']) -lt 1
  if ($p.mobile) {
    $padOn = $L['dpad']['shown'] -and ($L['dpad']['l'] -ge -0.5) -and ($L['dpad']['r'] -le $L['iw'] + 0.5)
    $fitsH = ($L['canvas']['t'] -ge 0) -and ($L['dpad']['b'] -le $L['ih'] + 0.5)
    $autoOn = ($L['autoPad'] -and $L['autoPad']['shown'] -and ($L['autoPad']['b'] -le $L['ih'] + 0.5)) -or ($L['autoBtn']['b'] -le $L['ih'] + 0.5)
    $side = $L['dpad']['l'] -ge ($L['bezel']['r'] - 1)
    $ok = $L['coarse'] -and $fitsW -and $padOn -and $fitsH -and $crisp -and ($board -ge 160) -and ($L['padMin'] -ge 44) -and ($L['panelMin'] -ge 44) -and ($L['topClip'] -le 0) -and $autoOn
    $why = @()
    if (-not $L['coarse']) { $why += 'not seen as a touch screen' }
    if (-not $fitsW) { $why += "page is wider than the screen ($($L['scrollW']) px)" }
    if (-not $padOn) { $why += 'pad missing or off the side' }
    if (-not $fitsH) { $why += "board and pad do not fit: pad ends at $([Math]::Round([double]$L['dpad']['b'])) of $($L['ih']) px" }
    if (-not $crisp) { $why += 'board not pixel-exact' }
    if ($board -lt 160) { $why += 'board under 160 px' }
    if ($L['padMin'] -lt 44) { $why += "pad buttons $([Math]::Round([double]$L['padMin'])) px" }
    if ($L['panelMin'] -lt 44) { $why += "smallest other button $([Math]::Round([double]$L['panelMin'])) px (want 44)" }
    if ($L['topClip'] -gt 0) { $why += 'score line clipped' }
    if (-not $autoOn) { $why += 'no autopilot button on the first screen' }
    $where = if ($side) { 'pad beside the board' } else { 'pad under the board' }
    Check ("layout: $n ($($p.w) x $($p.h))") $ok ("board $board px, $where" + $(if ($why.Count) { '; ' + ($why -join '; ') } else { '' }))
  } else {
    $ok = (-not $L['coarse']) -and $fitsW -and (-not $L['dpad']['shown']) -and ($L['panel']['l'] -ge $L['unit']['r']) -and ($L['unit']['b'] -le $L['ih']) -and $crisp
    Check ("layout: $n") $ok ("board $board px, no pad, panel beside the board: " + ($L['panel']['l'] -ge $L['unit']['r']) + ", fits: " + ($L['unit']['b'] -le $L['ih']))
  }
  [void]$script:layouts.Add(@{ name = $n; w = $p.w; h = $p.h; dpr = $p.dpr; board = $board; measured = $L })
  Shot ("layout-" + (($n -replace '[^A-Za-z0-9]+', '-').ToLower()) + ".png") $p.w $p.h $p.dpr
}

$exitCode = 1
$ws = $null
try {
  Stop-TestBrowser
  Start-Sleep -Milliseconds 400
  $flags = @("--user-data-dir=`"$prof`"", "--remote-debugging-port=$Port", "--no-first-run", "--no-default-browser-check",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "about:blank")
  if (-not $Headed) { $flags = @("--headless=new") + $flags }
  Start-Process $Browser -ArgumentList $flags
  $target = $null
  for ($i = 0; $i -lt 60 -and -not $target; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $list = Invoke-RestMethod "http://127.0.0.1:$Port/json"   # assign first: Windows PowerShell does not unroll this array into the pipeline
      $target = @($list) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    } catch {}
  }
  if (-not $target) { throw "the browser did not open its test port $Port" }
  $ver = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $ct).Wait()
  [void](Invoke-Cdp 'Page.enable')
  [void](Invoke-Cdp 'Runtime.enable')
  [void](Invoke-Cdp 'Log.enable')
  Write-Host ("Browser: " + $ver.Browser + "    Page: " + $Url)
  Write-Host ""

  # ---- 1. layout on every screen ----
  foreach ($p in $screens) { Check-Layout $p }
  Write-Host ""

  # ---- 2. touch play on a phone-sized screen (iPhone 15, upright) ----
  Set-Device 393 659 3 $true
  Open-Page
  [void](Js "try { localStorage.clear() } catch (e) {}")
  Open-Page
  $s = State
  Check "the page opens on the READY screen" (($s['state'] -eq 'ready') -and ($s['ov'] -eq 'READY')) ("hint: " + ($s['small'] -replace "`n", ' / '))

  $c = Center '#levels button:nth-child(1)' $true
  Tap $c['x'] $c['y']
  $s = State
  Check "tapping a level button changes the level" (($s['level'] -eq 1) -and ($s['tag'] -eq 'L1')) ("level " + $s['level'] + ", shows " + $s['tag'])
  [void](Js "scrollTo(0, 0)")
  Start-Sleep -Milliseconds 200
  $b = Center '#screen'
  Tap $b['x'] $b['y']
  $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
  Check "tapping the board starts the game" (($s['state'] -eq 'run') -and ($s['ov'] -eq '')) $s['state']
  Check-Turn 'the start' 1

  Swipe $b['x'] ($b['y'] + 40) $b['x'] ($b['y'] - 40)
  Check-Turn 'a swipe up' 0
  Swipe $b['x'] ($b['y'] - 40) $b['x'] ($b['y'] + 40)
  Start-Sleep -Milliseconds 700
  $s = State
  Check "a swipe straight back is ignored (the snake cannot reverse into itself)" (($s['dir'] -eq 0) -and ($s['state'] -eq 'run')) ("heading " + $dirName[[int]$s['dir']] + ", " + $s['state'])
  Swipe ($b['x'] + 40) $b['y'] ($b['x'] - 40) $b['y']
  Check-Turn 'a swipe left' 3
  Swipe $b['x'] ($b['y'] - 40) $b['x'] ($b['y'] + 40)
  Check-Turn 'a swipe down' 2
  Swipe ($b['x'] - 40) $b['y'] ($b['x'] + 40) $b['y']
  Check-Turn 'a swipe right' 1
  $s = State
  Check "swiping on the board never scrolls or zooms the page" (($s['scrollY'] -eq 0) -and ([Math]::Abs([double]$s['scale'] - 1) -lt 0.001)) ("scrolled " + $s['scrollY'] + " px, zoom " + $s['scale'])

  $b = New-Game
  $padC = @{}
  foreach ($d in 0..3) { $padC[$d] = Center ('#dpad [data-d="' + $d + '"]') }
  foreach ($t in @(@(0, 'Up'), @(3, 'Left'), @(2, 'Down'), @(1, 'Right'))) {
    Tap $padC[$t[0]]['x'] $padC[$t[0]]['y']
    Check-Turn ("the pad's " + $t[1] + " button") $t[0]
  }

  $b = New-Game
  $uturn = $false
  $detail = 'could not land both taps inside one move'
  for ($try = 0; $try -lt 5; $try++) {
    $a = State
    $d = [int]$a['dir']; $first = ($d + 3) % 4; $second = ($d + 2) % 4
    Touch 'touchStart' @(, (Pt $padC[$first]['x'] $padC[$first]['y']))
    Touch 'touchEnd' @()
    Touch 'touchStart' @(, (Pt $padC[$second]['x'] $padC[$second]['y']))
    Touch 'touchEnd' @()
    $z = State
    if ($z['moves'] -ne $a['moves']) { Start-Sleep -Milliseconds 800; continue }   # a move slipped in between the taps: try again
    $e = Wait-State { param($q) $q['moves'] -ge ($a['moves'] + 2) } 2500
    $k = $e['moves'] - $a['moves'] - 1
    $uturn = ($e['x'] -eq ($a['x'] + $vx[$first] + $k * $vx[$second])) -and ($e['y'] -eq ($a['y'] + $vy[$first] + $k * $vy[$second])) -and ($e['dir'] -eq $second) -and ($e['state'] -eq 'run')
    $detail = "from $($a['x']),$($a['y']) heading $($dirName[$d]) to $($e['x']),$($e['y']) heading $($dirName[[int]$e['dir']]) in $($e['moves'] - $a['moves']) moves"
    break
  }
  Check "two taps inside one move (a U-turn) are both obeyed, one move apart" $uturn $detail

  $b = New-Game
  $c = Center '#dpad .mid'
  Tap $c['x'] $c['y']
  $s = Wait-State { param($q) $q['state'] -eq 'pause' } 1500
  Check "the pad's middle button pauses" (($s['state'] -eq 'pause') -and ($s['ov'] -eq 'PAUSED')) ("hint: " + ($s['small'] -replace "`n", ' / '))
  $L = Js $jsLayout
  $sx = [Math]::Max(8, [double]$L['unit']['l'] + 14)
  $sy = [double]$L['dpad']['t'] + [double]$L['dpad']['h'] / 2
  Swipe $sx $sy $sx ($sy - 260) 10
  Start-Sleep -Milliseconds 700
  $s = State
  Check "dragging beside the pad scrolls the page (the game does not trap the finger)" ($s['scrollY'] -gt 60) ("scrolled " + $s['scrollY'] + " px")
  [void](Js "scrollTo(0, 0)")
  Start-Sleep -Milliseconds 300
  Tap $b['x'] $b['y']
  $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
  Check "tapping the board resumes" ($s['state'] -eq 'run') $s['state']

  # two fingers. (PowerShell variable names ignore case, so these must not be called $a and $b: $b is the board centre.)
  $b = New-Game
  $finger1 = Pt $b['x'] ($b['y'] + 50) 0
  $finger2 = Pt $b['x'] ($b['y'] - 50) 1
  Touch 'touchStart' @(, $finger1)
  Touch 'touchStart' @($finger1, $finger2)
  Touch 'touchMove' @((Pt ($b['x'] + 6) ($b['y'] + 50) 0), $finger2)   # finger 1 shifts 6 px: far too little for a swipe
  Start-Sleep -Milliseconds 750
  $s = State
  Check "a second finger resting on the board does not steer" (($s['dir'] -eq 1) -and ($s['state'] -eq 'run')) ("heading " + $dirName[[int]$s['dir']] + ", " + $s['state'])
  Touch 'touchMove' @((Pt ($b['x'] + 6) ($b['y'] + 5) 0), $finger2)    # finger 1 now swipes up 45 px
  Check-Turn 'the first finger, while a second one rests,' 0
  Touch 'touchEnd' @()

  # turn the phone sideways in the middle of a game, and back
  $b = New-Game
  Set-Device 852 345 3 $true
  Start-Sleep -Milliseconds 600
  $L = Js $jsLayout
  $s = State
  $crisp = [Math]::Abs([double]$L['canvas']['w'] * [double]$L['dpr'] - [double]$L['cvPx']) -lt 1
  Check "turning the phone sideways mid-game keeps the game going and redraws the board sharply" (($s['state'] -eq 'run') -and $crisp -and ($L['dpad']['b'] -le $L['ih'] + 0.5)) ("board " + [Math]::Round([double]$L['canvas']['w']) + " px, " + $s['state'])
  $b = New-Game
  $c = Center '#dpad [data-d="0"]'
  Tap $c['x'] $c['y']
  Check-Turn "sideways: the pad's Up button" 0
  $b2 = Center '#screen'
  Swipe ($b2['x'] + 40) $b2['y'] ($b2['x'] - 40) $b2['y']
  Check-Turn 'sideways: a swipe left' 3
  Shot 'play-sideways.png' 852 345 3
  Set-Device 393 659 3 $true
  Start-Sleep -Milliseconds 600
  $s = State
  Check "turning it upright again keeps the game going" (($s['state'] -eq 'run') -or ($s['state'] -eq 'over')) $s['state']

  # run into the wall
  [void](Js "document.getElementById('newBtn').click(); document.querySelector('#levels button:nth-child(9)').click(); scrollTo(0, 0)")
  Start-Sleep -Milliseconds 150
  $b = Center '#screen'
  Tap $b['x'] $b['y']
  $s = Wait-State { param($q) $q['state'] -eq 'over' } 4000
  Check "hitting the wall ends the game" (($s['state'] -eq 'over') -and ($s['ov'] -eq 'GAME OVER') -and $s['dead']) ("hint: " + ($s['small'] -replace "`n", ' / '))
  Shot 'play-game-over.png' 393 659 3
  Start-Sleep -Milliseconds 300
  Tap $b['x'] $b['y']
  $s = Wait-State { param($q) $q['state'] -eq 'ready' } 1500
  Check "tapping after GAME OVER gives a new game" (($s['state'] -eq 'ready') -and ($s['len'] -eq 3)) $s['state']

  # autopilot, switched on by touch
  $sel = '#autoBtn'
  $pad = Center '#autoPad'
  if ($pad -and $pad['shown']) { $sel = '#autoPad' }
  $c = Center $sel ($sel -eq '#autoBtn')
  Tap $c['x'] $c['y']
  $s = Wait-State { param($q) $q['auto'] -and $q['state'] -eq 'run' } 1500
  Check "tapping the autopilot button ($sel) hands over to autopilot" ($s['auto'] -and ($s['state'] -eq 'run') -and ($s['tag'] -like 'AUTO*')) ("shows " + $s['tag'])
  if (-not $Quick) {
    $c = Center '#levels button:nth-child(10)' $true
    Tap $c['x'] $c['y']
    [void](Js "scrollTo(0, 0)")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $s = Wait-State { param($q) $q['state'] -ne 'run' } 120000
    Check "autopilot fills the whole board without crashing" (($s['state'] -eq 'won') -and ($s['len'] -eq 576) -and ($s['ov'] -eq 'BOARD CLEARED')) ("$($s['len']) of 576 cells, $($s['moves']) moves, " + [Math]::Round($sw.Elapsed.TotalSeconds) + " s at MAX")
    Shot 'play-board-cleared.png' 393 659 3
    $b = Center '#screen'
    Tap $b['x'] $b['y']
    $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
    Swipe $b['x'] ($b['y'] + 40) $b['x'] ($b['y'] - 40)
    $s = Wait-State { param($q) -not $q['auto'] } 1500
    Check "a swipe takes the controls back from autopilot" ((-not $s['auto']) -and ($s['note'] -like 'You have the controls*')) $s['note']
    [void](Js "document.getElementById('newBtn').click()")
    Open-Page
    $hi = Js "document.getElementById('hi').textContent"
    Check "the best score survives a reload" ($hi -ne 'HI 0000') $hi
  }
  Write-Host ""

  # ---- 3. keyboard and mouse on a desktop-sized screen ----
  Set-Device 1280 800 1 $false
  Open-Page
  Key 'Digit1' '1' 49
  Key 'Space' ' ' 32
  $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
  Check "keyboard: 1 sets the level and Space starts the game" (($s['state'] -eq 'run') -and ($s['level'] -eq 1)) ("level " + $s['level'] + ", " + $s['state'])
  Check-Turn 'keyboard: the start' 1
  Key 'ArrowUp' 'ArrowUp' 38
  Check-Turn 'keyboard: Arrow Up' 0
  Key 'KeyA' 'a' 65
  Check-Turn 'keyboard: A' 3
  Key 'ArrowDown' 'ArrowDown' 40
  Check-Turn 'keyboard: Arrow Down' 2
  Key 'KeyD' 'd' 68
  Check-Turn 'keyboard: D' 1
  Key 'Space' ' ' 32
  $s = Wait-State { param($q) $q['state'] -eq 'pause' } 1500
  Check "keyboard: Space pauses" (($s['state'] -eq 'pause') -and ($s['small'] -like 'Space*')) ("hint: " + ($s['small'] -replace "`n", ' / '))
  Key 'Space' ' ' 32
  $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
  Check "keyboard: Space resumes" ($s['state'] -eq 'run') $s['state']
  $b = Center '#screen'
  Mouse 'mousePressed' $b['x'] ($b['y'] + 30) 1
  foreach ($i in 1..5) { Mouse 'mouseMoved' $b['x'] ($b['y'] + 30 - 12 * $i) 1; Start-Sleep -Milliseconds 16 }
  Mouse 'mouseReleased' $b['x'] ($b['y'] - 30) 0
  Check-Turn 'mouse: dragging up on the board' 0
  $before = State
  foreach ($i in 1..6) { Mouse 'mouseMoved' ($b['x'] - 90 + 30 * $i) ($b['y'] + 20) 0; Start-Sleep -Milliseconds 16 }
  Start-Sleep -Milliseconds 650
  $s = State
  Check "mouse: moving over the board without pressing does not steer" (($s['dir'] -eq 0) -and ($s['state'] -eq 'run') -and ($s['moves'] -gt $before['moves'])) ("heading " + $dirName[[int]$s['dir']] + ", " + $s['state'])
  Key 'KeyQ' 'q' 81
  $s = Wait-State { param($q) $q['auto'] -and $q['state'] -eq 'run' } 1500
  Check "keyboard: Q hands over to autopilot" ($s['auto'] -and ($s['state'] -eq 'run') -and ($s['tag'] -like 'AUTO*')) ("shows " + $s['tag'])
  Key 'KeyQ' 'q' 81
  $s = Wait-State { param($q) -not $q['auto'] } 1500
  Check "keyboard: Q takes the controls back" (-not $s['auto']) ("shows " + $s['tag'])
  Key 'Enter' 'Enter' 13
  $s = Wait-State { param($q) $q['state'] -eq 'ready' } 1500
  Check "keyboard: Enter gives a new game, with keyboard hints" (($s['state'] -eq 'ready') -and ($s['small'] -like 'Arrow keys*')) ("hint: " + ($s['small'] -replace "`n", ' / '))
  Mouse 'mousePressed' $b['x'] $b['y'] 1
  Mouse 'mouseReleased' $b['x'] $b['y'] 0
  $s = Wait-State { param($q) $q['state'] -eq 'run' } 1500
  Check "mouse: a click on the board starts the game" ($s['state'] -eq 'run') $s['state']
  Write-Host ""

  # ---- 4. engine check and benchmark ----
  Open-Page
  $mark = $script:events.Count
  $res = Js ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'engine-check.js')))
  $logs = @($script:events | Select-Object -Skip $mark | Where-Object { $_['method'] -eq 'Runtime.consoleAPICalled' } | ForEach-Object { $_['params']['args'][0]['value'] })
  Check "engine check (tests/engine-check.js)" ($res -eq 'PASS') ($logs -join ' | ')
  [void](Js "document.getElementById('benchBtn').click()")
  $txt = ''
  for ($i = 0; $i -lt 150; $i++) {
    Start-Sleep -Milliseconds 100
    $txt = Js "document.getElementById('benchOut').textContent"
    if ($txt -and $txt -notlike 'Running*') { break }
  }
  Check "the in-page benchmark clears 10 of 10 boards" ($txt -like '10 of 10 boards cleared*') ($txt -replace "`n", '; ')

  # ---- 5. anything the browser complained about ----
  $bad = @()
  $fontTrouble = 0
  foreach ($ev in $script:events) {
    $text = $null
    if ($ev['method'] -eq 'Runtime.exceptionThrown') { $text = 'exception: ' + $ser.Serialize($ev['params']['exceptionDetails']) }
    elseif ($ev['method'] -eq 'Runtime.consoleAPICalled' -and $ev['params']['type'] -eq 'error') { $text = 'console error: ' + $ser.Serialize($ev['params']['args']) }
    elseif ($ev['method'] -eq 'Log.entryAdded' -and $ev['params']['entry']['level'] -eq 'error') { $text = $ev['params']['entry']['text'] + ' ' + $ev['params']['entry']['url'] }
    if (-not $text) { continue }
    if ($text -match 'fonts\.(googleapis|gstatic)\.com') { $fontTrouble++ } else { $bad += $text }
  }
  $detail = if ($bad.Count) { $bad[0].Substring(0, [Math]::Min(300, $bad[0].Length)) } elseif ($fontTrouble) { "web fonts could not be fetched $fontTrouble times; the page used its fallback fonts" } else { '' }
  Check "no script errors in the browser log" ($bad.Count -eq 0) $detail

  $fails = @($script:results | Where-Object { -not $_.ok })
  $summary = @{ browser = $ver.Browser; url = $Url; when = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; passed = $script:results.Count - $fails.Count; failed = $fails.Count; checks = $script:results; layouts = $script:layouts }
  [IO.File]::WriteAllText((Join-Path $out 'results.json'), ($summary | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  Write-Host ""
  Write-Host ("RESULT: {0} passed, {1} failed. Screenshots and results.json: {2}" -f ($script:results.Count - $fails.Count), $fails.Count, $out)
  if ($fails.Count -eq 0) { $exitCode = 0 }
} finally {
  if ($ws) { try { $ws.Dispose() } catch {} }
  Stop-TestBrowser
}
exit $exitCode
