// Engine checks for O(1) Snake.
// Open index.html in a browser, paste this whole file into the DevTools console and press Enter.
// It prints PASS or the list of failures. Takes about a second.
(() => {
  const { Snake, W, H } = window.O1Snake;
  const N = W * H, fails = [];
  const fail = msg => { if (fails.length < 20) fails.push(msg); };

  // Free list, occupancy and ring buffer must agree with each other.
  const consistent = (s, label) => {
    let occ = 0;
    for (let c = 0; c < N; c++) occ += s.occ[c];
    if (occ !== s.len) return fail(`${label}: ${occ} occupied cells but len ${s.len}`);
    if (s.nFree + s.len !== N) return fail(`${label}: nFree ${s.nFree} + len ${s.len} != ${N}`);
    for (let i = 0; i < s.nFree; i++) {
      const c = s.free[i];
      if (s.occ[c] || s.slot[c] !== i) return fail(`${label}: free list broken at ${i}`);
    }
    for (let i = 0, p = s.tp; i < s.len; i++, p = (p + 1) % N)
      if (!s.occ[s.body[p]]) return fail(`${label}: body cell ${s.body[p]} not marked occupied`);
    if (s.food >= 0 && s.occ[s.food]) fail(`${label}: apple on the body`);
  };

  // 1. The autopilot loop visits every cell once, and each step is to a neighbour.
  const s0 = new Snake(W, H), at = new Int32Array(N).fill(-1);
  for (let c = 0; c < N; c++) {
    if (at[s0.ord[c]] !== -1) fail(`loop: position ${s0.ord[c]} used twice`);
    at[s0.ord[c]] = c;
  }
  for (let k = 0; k < N; k++) {
    const a = at[k], b = at[(k + 1) % N];
    if (Math.abs(a % W - b % W) + Math.abs(((a / W) | 0) - ((b / W) | 0)) !== 1) fail(`loop: step ${k} is not to a neighbour`);
  }
  if (!s0.ordered()) fail('start position is not in loop order');

  // 2. Random manual play keeps every structure consistent, including moves into the tail cell.
  let manualMoves = 0;
  for (let game = 0; game < 300; game++) {
    const s = new Snake(W, H);
    for (let r = 0; r <= 1;) {
      let d = (Math.random() * 4) | 0;
      if (d === (s.dir ^ 2)) d = s.dir;
      r = s.step(d); manualMoves++;
      consistent(s, `manual game ${game}`);
      if (fails.length) break;
    }
  }

  // 3. Autopilot clears the board every time and never breaks loop order.
  let autoMoves = 0, cleared = 0;
  const games = 200, t0 = performance.now();
  for (let game = 0; game < games; game++) {
    const s = new Snake(W, H), watch = game < 3;
    let r = 0;
    while (r <= 1 && s.moves < N * N) {
      r = s.step(s.auto());
      if (watch && !s.ordered()) { fail(`auto game ${game}: body left loop order at move ${s.moves}`); break; }
    }
    autoMoves += s.moves;
    if (r === 3) cleared++; else fail(`auto game ${game}: ended with result ${r} at length ${s.len}`);
    consistent(s, `auto game ${game}`);
  }
  const ms = performance.now() - t0;

  console.log(fails.length ? 'FAIL\n' + fails.join('\n') : 'PASS');
  console.log(`manual: 300 games, ${manualMoves} moves checked`);
  console.log(`autopilot: ${cleared}/${games} boards cleared, ${Math.round(autoMoves / games)} moves per game on average, ${(autoMoves / ms / 1000).toFixed(1)}M moves/s`);
  return fails.length ? 'FAIL' : 'PASS';
})();
