// A small analytic example: replace sample() and draw() with the process at hand.
// Frames are local. Only deliberate changes to phase/parameters are shared.
(() => {
  const $ = id => document.getElementById(id);
  const cycle = value => ((value % 1) + 1) % 1;
  const number = (value, fallback) => Number.isFinite(value) ? value : fallback;
  const format = value => (Math.abs(value) < 0.005 ? 0 : value).toFixed(2).replace('.', ',');
  let state, playing = false, frame = 0, previous = null;
  const sample = x => state.amplitude * Math.sin(2 * Math.PI * (x - state.phase));

  function draw() {
    const points = [];
    for (let px = 76; px <= 700; px += 3) points.push(`${px === 76 ? 'M' : 'L'}${px},${150 - 62 * sample((px - 76) / 240)}`);
    $('curve').setAttribute('d', points.join(' '));
    const y = sample(1), py = 150 - 62 * y;
    $('particle').setAttribute('cy', py);
    $('particle-value').setAttribute('y', py - 14);
    $('particle-value').textContent = `y = ${format(y)}`;
    $('phase').value = state.phase;
    $('amplitude').value = state.amplitude;
    $('speed').value = state.speed;
    $('phase-value').textContent = `${format(state.phase)} цикла`;
    $('amplitude-value').textContent = format(state.amplitude);
    $('play').textContent = playing ? 'Пауза' : 'Пуск';
  }
  function stop() {
    playing = false; previous = null; cancelAnimationFrame(frame);
  }
  function tick(now) {
    if (!playing) return;
    if (previous !== null) state.phase = cycle(state.phase + (now - previous) / 4000 * state.speed);
    previous = now; draw(); frame = requestAnimationFrame(tick);
  }
  function save() { notebook.commit({...state}); }
  function jump(delta) { stop(); state.phase = cycle(state.phase + delta); draw(); save(); }
  function restore() {
    stop();
    const value = notebook.state ?? {};
    state = {phase:cycle(number(value.phase, 0)),
      amplitude:Math.max(0, Math.min(1.5, number(value.amplitude, 1))),
      speed:[0.25, 0.5, 1, 2].includes(value.speed) ? value.speed : 1};
    draw();
  }
  $('play').addEventListener('click', () => {
    if (playing) { stop(); draw(); save(); }
    else { playing = true; previous = null; draw(); frame = requestAnimationFrame(tick); }
  });
  $('back').addEventListener('click', () => jump(-0.25));
  $('forward').addEventListener('click', () => jump(0.25));
  for (const key of ['phase', 'amplitude']) {
    $(key).addEventListener('input', event => { stop(); state[key] = Number(event.target.value); draw(); });
    $(key).addEventListener('change', save);
  }
  $('speed').addEventListener('change', event => { state.speed = Number(event.target.value); previous = null; draw(); save(); });
  addEventListener('notebookstate', restore);
  document.addEventListener('visibilitychange', () => { if (document.hidden) { stop(); draw(); } });
  notebook.ready(Promise.resolve().then(restore));
})();
