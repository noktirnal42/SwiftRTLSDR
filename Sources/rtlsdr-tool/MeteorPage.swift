// SPDX-License-Identifier: GPL-2.0-or-later

/// The live Meteor-M dashboard served by `rtlsdr-tool meteor --web`: one self-contained page (no external files) fed by
/// Server-Sent Events from `/events` and image strips from `/strip`.
let meteorPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meteor LRPT Live</title>
<style>
:root {
  --bg: #0b0f14; --panel: #121821; --panel-2: #0f141b; --line: #1f2a37; --text: #d7e1ec; --muted: #7d8da1;
  --accent: #4cc9f0; --ok: #2ec4a6; --warn: #f4a261; --bad: #ef476f; --idle: #3a4656;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.4 var(--sans); }
header { display: flex; align-items: center; gap: 16px; padding: 12px 20px; border-bottom: 1px solid var(--line);
  background: linear-gradient(180deg, #111822, #0b0f14); position: sticky; top: 0; z-index: 5; flex-wrap: wrap; }
header h1 { font-size: 16px; margin: 0; letter-spacing: .08em; text-transform: uppercase; font-weight: 650; }
header .sub { color: var(--muted); font-family: var(--mono); font-size: 12px; }
header .spacer { flex: 1; }
.pill { font-family: var(--mono); font-size: 12px; padding: 4px 10px; border-radius: 999px; border: 1px solid var(--line);
  display: inline-flex; align-items: center; gap: 8px; }
.pill .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--idle); box-shadow: 0 0 0 0 transparent; }
.pill.live .dot { background: var(--ok); animation: pulse 1.6s infinite; }
@keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(46,196,166,.6); } 70% { box-shadow: 0 0 0 8px rgba(46,196,166,0); } 100% { box-shadow: 0 0 0 0 rgba(46,196,166,0); } }
main { padding: 16px 20px 28px; display: grid; gap: 16px; grid-template-columns: minmax(0, 2fr) minmax(320px, 1fr); align-items: start; }
.imagery { position: sticky; top: 72px; }
@media (max-width: 980px) { .imagery { position: static; } }
@media (max-width: 980px) { main { grid-template-columns: minmax(0, 1fr); padding: 12px 16px; } }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; min-width: 0; }
.panel h2 { font-size: 11px; letter-spacing: .12em; text-transform: uppercase; color: var(--muted); margin: 0; font-weight: 600; }
.panel .head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px;
  border-bottom: 1px solid var(--line); background: var(--panel-2); flex-wrap: wrap; }
.panel .body { padding: 12px 14px; }
.pipeline { grid-column: 1 / -1; display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; }
@media (max-width: 760px) { .pipeline { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.stage { position: relative; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px 10px; min-width: 0; }
.stage::before { content: ""; position: absolute; inset: 0 auto 0 0; width: 3px; border-radius: 12px 0 0 12px; background: var(--idle); transition: background .3s; }
.stage.ok::before { background: var(--ok); } .stage.warn::before { background: var(--warn); } .stage.bad::before { background: var(--bad); }
.stage .label { font-size: 11px; letter-spacing: .12em; text-transform: uppercase; color: var(--muted); display: flex; justify-content: space-between; }
.stage .value { font-family: var(--mono); font-size: 22px; font-weight: 600; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.stage .value small { font-size: 12px; color: var(--muted); font-weight: 400; margin-left: 4px; }
.stage .detail { font-family: var(--mono); font-size: 11px; color: var(--muted); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.stage canvas { width: 100%; height: 26px; display: block; margin-top: 6px; }
.tabs { display: flex; gap: 4px; flex-wrap: wrap; }
.tabs button { font: 12px var(--mono); color: var(--muted); background: transparent; border: 1px solid var(--line); border-radius: 6px; padding: 4px 9px; cursor: pointer; }
.tabs button.active { color: var(--bg); background: var(--accent); border-color: var(--accent); }
.tabs button:disabled { opacity: .35; cursor: default; }
.viewer { position: relative; height: min(calc(100vh - 190px), 900px); min-height: 360px; overflow: auto; background: #06090d; }
.viewer canvas { display: block; width: 100%; image-rendering: auto; }
.viewer .empty { position: absolute; inset: 0; display: grid; place-items: center; color: var(--muted); font-family: var(--mono); font-size: 13px; text-align: center; padding: 20px; }
.scan { position: absolute; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, transparent, var(--accent), transparent);
  box-shadow: 0 0 12px 2px rgba(76,201,240,.55); pointer-events: none; transition: top .4s ease; }
.toolbar { display: flex; gap: 10px; align-items: center; font-family: var(--mono); font-size: 12px; color: var(--muted); flex-wrap: wrap; }
.toolbar label { display: inline-flex; gap: 6px; align-items: center; cursor: pointer; }
.toolbar a { color: var(--accent); text-decoration: none; }
.side { display: grid; gap: 16px; align-content: start; min-width: 0; }
.square { position: relative; aspect-ratio: 1 / 1; width: 100%; background: #06090d; border-radius: 8px; overflow: hidden; }
.square canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
.stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin-top: 10px; }
.stat { background: var(--panel-2); border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; min-width: 0; }
.stat .k { font-size: 10px; letter-spacing: .1em; text-transform: uppercase; color: var(--muted); }
.stat .v { font-family: var(--mono); font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
canvas.wide { width: 100%; display: block; border-radius: 6px; background: #06090d; }
.ribbon-legend { display: flex; gap: 12px; font-size: 11px; color: var(--muted); margin-top: 8px; flex-wrap: wrap; }
.ribbon-legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 4px; vertical-align: -1px; }
.apids { display: grid; gap: 6px; }
.apid { display: grid; grid-template-columns: 56px minmax(0, 1fr) 64px; gap: 8px; align-items: center; font-family: var(--mono); font-size: 12px; }
.apid .bar { height: 8px; background: var(--panel-2); border-radius: 4px; overflow: hidden; border: 1px solid var(--line); }
.apid .bar span { display: block; height: 100%; background: linear-gradient(90deg, var(--accent), var(--ok)); width: 0; transition: width .4s; }
.apid .n { text-align: right; color: var(--muted); }
footer { color: var(--muted); font-size: 12px; padding: 0 20px 20px; font-family: var(--mono); }
</style>
</head>
<body>
<header>
  <h1>Meteor-M LRPT</h1>
  <span class="sub" id="radio">–</span>
  <span class="spacer"></span>
  <span class="pill" id="clock">T+00:00</span>
  <span class="pill" id="state"><span class="dot"></span><span id="stateText">connecting</span></span>
</header>
<main>
  <section class="pipeline" aria-label="Receive chain">
    <div class="stage" id="stRF"><div class="label"><span>RF</span><span id="rfTag"></span></div><div class="value" id="rfValue">–</div><div class="detail" id="rfDetail">input level</div><canvas id="sparkRF"></canvas></div>
    <div class="stage" id="stCarrier"><div class="label"><span>Carrier</span><span id="carTag"></span></div><div class="value" id="carValue">–</div><div class="detail" id="carDetail">offset · Doppler</div><canvas id="sparkCar"></canvas></div>
    <div class="stage" id="stSymbols"><div class="label"><span>Symbols</span><span id="symTag"></span></div><div class="value" id="symValue">–</div><div class="detail" id="symDetail">SNR · clock</div><canvas id="sparkSNR"></canvas></div>
    <div class="stage" id="stFrames"><div class="label"><span>Frames</span><span id="frTag"></span></div><div class="value" id="frValue">–</div><div class="detail" id="frDetail">Viterbi · Reed-Solomon</div><canvas id="sparkFR"></canvas></div>
    <div class="stage" id="stImage"><div class="label"><span>Imagery</span><span id="imTag"></span></div><div class="value" id="imValue">–</div><div class="detail" id="imDetail">MSU-MR lines</div><canvas id="sparkIM"></canvas></div>
  </section>

  <section class="panel imagery">
    <div class="head">
      <h2>MSU-MR imagery</h2>
      <div class="tabs" id="tabs"></div>
    </div>
    <div class="viewer" id="viewer">
      <canvas id="image" width="1568" height="8"></canvas>
      <div class="scan" id="scan" hidden></div>
      <div class="empty" id="empty">Waiting for image packets…<br>Lines appear here as they are decoded.</div>
    </div>
    <div class="body toolbar">
      <label><input type="checkbox" id="follow" checked> follow newest line</label>
      <label><input type="checkbox" id="enhance"> stretch contrast</label>
      <span id="imageInfo"></span>
      <span class="spacer" style="flex:1"></span>
      <a id="download" href="#" download>download PNG</a>
    </div>
  </section>

  <aside class="side">
    <section class="panel">
      <div class="head"><h2>Constellation</h2><span class="sub" id="evm" style="font-family:var(--mono);font-size:12px;color:var(--muted)"></span></div>
      <div class="body">
        <div class="square"><canvas id="constellation" width="480" height="480"></canvas></div>
        <div class="stats">
          <div class="stat"><div class="k">SNR</div><div class="v" id="sSNR">–</div></div>
          <div class="stat"><div class="k">Carrier</div><div class="v" id="sCar">–</div></div>
          <div class="stat"><div class="k">Clock</div><div class="v" id="sClock">–</div></div>
        </div>
      </div>
    </section>
    <section class="panel">
      <div class="head"><h2>Spectrum &amp; waterfall</h2><span class="sub" id="span" style="font-family:var(--mono);font-size:12px;color:var(--muted)"></span></div>
      <div class="body"><canvas class="wide" id="spectrum" width="512" height="110"></canvas><canvas class="wide" id="waterfall" width="512" height="170" style="margin-top:6px"></canvas></div>
    </section>
    <section class="panel">
      <div class="head"><h2>Frame ribbon</h2><span class="sub" id="ribbonInfo" style="font-family:var(--mono);font-size:12px;color:var(--muted)"></span></div>
      <div class="body">
        <canvas class="wide" id="ribbon" width="512" height="84"></canvas>
        <div class="ribbon-legend"><span><i style="background:var(--ok)"></i>clean</span><span><i style="background:var(--warn)"></i>repaired</span><span><i style="background:var(--bad)"></i>lost</span></div>
      </div>
    </section>
    <section class="panel">
      <div class="head"><h2>Pass history</h2></div>
      <div class="body"><canvas class="wide" id="history" width="512" height="150"></canvas></div>
    </section>
    <section class="panel">
      <div class="head"><h2>Packets by APID</h2><span class="sub" id="pktInfo" style="font-family:var(--mono);font-size:12px;color:var(--muted)"></span></div>
      <div class="body"><div class="apids" id="apids"></div></div>
    </section>
  </aside>
</main>
<footer id="foot">rtlsdr-tool meteor · live data from this receiver</footer>
<script>
"use strict";
const $ = id => document.getElementById(id);
const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const COLORS = { ok: css('--ok'), warn: css('--warn'), bad: css('--bad'), accent: css('--accent'), muted: css('--muted'), line: css('--line'), idle: css('--idle') };
const CHANNEL_NAMES = { 64: 'Ch 1 · 0.5–0.7 µm', 65: 'Ch 2 · 0.7–1.1 µm', 66: 'Ch 3 · 1.6–1.8 µm', 67: 'Ch 4 · 3.5–4.1 µm', 68: 'Ch 5 · 10.5–11.5 µm', 69: 'Ch 6 · 11.5–12.5 µm' };

const history = { t: [], snr: [], car: [], level: [], valid: [], lines: [], locked: [] };
let last = null, selected = 'rgb', drawn = {}, imageHeight = 0, ribbon = [];

function fmtTime(s) { s = Math.max(0, Math.floor(s)); const m = Math.floor(s / 60), h = Math.floor(m / 60);
  return (h ? h + ':' + String(m % 60).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(s % 60).padStart(2, '0'); }
function sizeCanvas(c) { const r = c.getBoundingClientRect(), d = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; } return c.getContext('2d'); }

function spark(id, values, color, min, max) {
  const c = $(id), g = sizeCanvas(c), w = c.width, h = c.height; g.clearRect(0, 0, w, h);
  const v = values.slice(-120); if (v.length < 2) return;
  const lo = min ?? Math.min(...v), hi = max ?? Math.max(...v), span = (hi - lo) || 1;
  g.beginPath(); v.forEach((x, i) => { const px = i / (v.length - 1) * w, py = h - 2 - (x - lo) / span * (h - 4); i ? g.lineTo(px, py) : g.moveTo(px, py); });
  g.strokeStyle = color; g.lineWidth = 1.5 * (window.devicePixelRatio || 1); g.stroke();
  g.lineTo(w, h); g.lineTo(0, h); g.closePath(); g.globalAlpha = .12; g.fillStyle = color; g.fill(); g.globalAlpha = 1;
}
function stage(id, level) { $(id).className = 'stage ' + (level || ''); }

// Constellation: a density map with persistence, drawn into an offscreen buffer that fades each frame.
const cons = $('constellation'), consBuffer = document.createElement('canvas'); consBuffer.width = consBuffer.height = 240;
const cb = consBuffer.getContext('2d'), heat = new Float32Array(240 * 240);
const SCALE = 100 / 127, IDEAL = 67;           // soft-symbol units: the AGC puts the ideal points at ±67
function drawConstellation(points, locked) {
  for (let i = 0; i < heat.length; i++) heat[i] *= 0.86;
  for (let k = 0; k + 1 < points.length; k += 2) {
    const x = Math.round(120 + points[k] * SCALE), y = Math.round(120 - points[k + 1] * SCALE);
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      const xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= 240 || yy >= 240) continue;
      heat[yy * 240 + xx] += (dx || dy) ? 0.35 : 1;
    }
  }
  const img = cb.createImageData(240, 240);
  for (let i = 0; i < heat.length; i++) {
    const v = Math.min(1, heat[i] / 6); if (v <= 0.003) continue;
    // inferno-like ramp: deep violet → magenta → orange → pale yellow
    const r = Math.min(255, 40 + 420 * v), g2 = Math.max(0, Math.min(255, -80 + 360 * v * v + 60 * v)), b = Math.max(0, Math.min(255, 110 + 200 * v - 380 * v * v));
    img.data[i * 4] = r; img.data[i * 4 + 1] = g2; img.data[i * 4 + 2] = b; img.data[i * 4 + 3] = Math.min(255, 60 + 900 * v);
  }
  cb.putImageData(img, 0, 0);
  const g = sizeCanvas(cons), w = cons.width; g.fillStyle = '#06090d'; g.fillRect(0, 0, w, w);
  g.strokeStyle = COLORS.line; g.lineWidth = 1; g.beginPath(); g.moveTo(w / 2, 0); g.lineTo(w / 2, w); g.moveTo(0, w / 2); g.lineTo(w, w / 2); g.stroke();
  const ideal = IDEAL * SCALE / 240 * w;
  g.strokeStyle = locked ? 'rgba(46,196,166,.55)' : 'rgba(125,141,161,.4)';
  for (const sx of [-1, 1]) for (const sy of [-1, 1]) { g.beginPath(); g.arc(w / 2 + sx * ideal, w / 2 - sy * ideal, w * 0.035, 0, 2 * Math.PI); g.stroke(); }
  g.imageSmoothingEnabled = true; g.drawImage(consBuffer, 0, 0, w, w);
}

// Spectrum and waterfall
const wf = $('waterfall');
function drawSpectrum(bins, carrier, span, coarse) {
  if (!bins || !bins.length) return;
  const g = sizeCanvas($('spectrum')), c = $('spectrum'), w = c.width, h = c.height;
  const lo = Math.min(...bins), hi = Math.max(...bins), floor = lo, top = Math.max(hi, lo + 20);
  g.fillStyle = '#06090d'; g.fillRect(0, 0, w, h);
  g.strokeStyle = COLORS.line; g.lineWidth = 1;
  for (let i = 1; i < 4; i++) { g.beginPath(); g.moveTo(0, h * i / 4); g.lineTo(w, h * i / 4); g.stroke(); }
  g.beginPath(); bins.forEach((v, i) => { const x = i / (bins.length - 1) * w, y = h - 4 - (v - floor) / (top - floor) * (h - 10); i ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.strokeStyle = COLORS.accent; g.lineWidth = 1.5 * (window.devicePixelRatio || 1); g.stroke();
  g.lineTo(w, h); g.lineTo(0, h); g.closePath(); const grad = g.createLinearGradient(0, 0, 0, h); grad.addColorStop(0, 'rgba(76,201,240,.35)'); grad.addColorStop(1, 'rgba(76,201,240,0)'); g.fillStyle = grad; g.fill();
  const cx = w / 2 + (carrier / span) * w;
  g.strokeStyle = 'rgba(244,162,97,.9)'; g.setLineDash([4, 4]); g.beginPath(); g.moveTo(cx, 0); g.lineTo(cx, h); g.stroke(); g.setLineDash([]);
  // the coarse estimate (the signal's fourth power), as a marker on the top edge once its line is clear
  if (coarse && coarse.db >= 9) { const kx = w / 2 + (coarse.hz / span) * w, s = 5 * (window.devicePixelRatio || 1);
    g.fillStyle = COLORS.accent; g.beginPath(); g.moveTo(kx - s, 0); g.lineTo(kx + s, 0); g.lineTo(kx, 1.6 * s); g.closePath(); g.fill(); }
  // waterfall row
  const wg = sizeCanvas(wf), ww = wf.width, wh = wf.height;
  const shift = Math.max(1, Math.round(2 * (window.devicePixelRatio || 1)));
  wg.drawImage(wf, 0, shift); const row = wg.createImageData(ww, shift);
  for (let x = 0; x < ww; x++) {
    const v = Math.max(0, Math.min(1, (bins[Math.floor(x / ww * bins.length)] - floor) / (top - floor)));
    const r = 255 * Math.min(1, v * 1.6), g2 = 255 * Math.max(0, v * 1.4 - 0.35), b = 255 * Math.max(0, 0.6 - v) + 40 * v;
    for (let y = 0; y < shift; y++) { const o = (y * ww + x) * 4; row.data[o] = r; row.data[o + 1] = g2; row.data[o + 2] = b; row.data[o + 3] = 255; }
  }
  wg.putImageData(row, 0, 0);
  wg.fillStyle = 'rgba(244,162,97,.95)'; wg.fillRect(Math.round(cx) - 1, 0, 2, shift);
}

// Frame ribbon: one cell per frame, newest at the right.
function drawRibbon() {
  const c = $('ribbon'), g = sizeCanvas(c), w = c.width, h = c.height, d = window.devicePixelRatio || 1;
  const cell = 6 * d, gap = 1 * d, rows = 3, perRow = Math.floor(w / (cell + gap)), capacity = perRow * rows;
  g.fillStyle = '#06090d'; g.fillRect(0, 0, w, h);
  const start = Math.max(0, ribbon.length - capacity), view = ribbon.slice(start);
  const cellH = (h - (rows - 1) * gap * 3) / rows;
  view.forEach((code, i) => {
    const row = Math.floor(i / perRow), col = i % perRow;
    g.fillStyle = code === 1 ? COLORS.ok : code === 2 ? COLORS.warn : COLORS.bad;
    g.globalAlpha = 0.35 + 0.65 * (i + 1) / view.length;
    g.fillRect(col * (cell + gap), row * (cellH + gap * 3), cell, cellH);
  });
  g.globalAlpha = 1;
  const lost = ribbon.filter(x => x === 0).length, fixed = ribbon.filter(x => x === 2).length;
  $('ribbonInfo').textContent = ribbon.length + ' frames · ' + fixed + ' repaired · ' + lost + ' lost';
}

// Pass history: SNR (left axis) and carrier offset (right axis), with loss of lock shaded.
function drawHistory() {
  const c = $('history'), g = sizeCanvas(c), w = c.width, h = c.height, d = window.devicePixelRatio || 1, n = history.t.length;
  g.fillStyle = '#06090d'; g.fillRect(0, 0, w, h); if (n < 2) return;
  const t0 = history.t[0], t1 = history.t[n - 1], X = t => (t - t0) / ((t1 - t0) || 1) * (w - 8 * d) + 4 * d;
  for (let i = 1; i < n; i++) if (!history.locked[i]) { g.fillStyle = 'rgba(239,71,111,.10)'; g.fillRect(X(history.t[i - 1]), 0, X(history.t[i]) - X(history.t[i - 1]) + 1, h); }
  const line = (vals, color, lo, hi) => { g.beginPath(); vals.forEach((v, i) => { const x = X(history.t[i]), y = h - 6 * d - (v - lo) / ((hi - lo) || 1) * (h - 18 * d); i ? g.lineTo(x, y) : g.moveTo(x, y); });
    g.strokeStyle = color; g.lineWidth = 1.6 * d; g.stroke(); };
  const sLo = Math.min(0, ...history.snr), sHi = Math.max(15, ...history.snr);
  const cLo = Math.min(...history.car) - 50, cHi = Math.max(...history.car) + 50;
  line(history.snr, COLORS.ok, sLo, sHi); line(history.car, COLORS.warn, cLo, cHi);
  g.font = (11 * d) + 'px ' + css('--mono'); g.fillStyle = COLORS.ok; g.fillText('SNR ' + history.snr[n - 1].toFixed(1) + ' dB', 6 * d, 13 * d);
  g.fillStyle = COLORS.warn; const lab = 'carrier ' + (history.car[n - 1] >= 0 ? '+' : '') + history.car[n - 1].toFixed(0) + ' Hz'; g.fillText(lab, w - g.measureText(lab).width - 6 * d, 13 * d);
  g.fillStyle = COLORS.muted; g.fillText(fmtTime(t1 - t0), w - g.measureText(fmtTime(t1 - t0)).width - 6 * d, h - 4 * d);
}

// Imagery
const view = $('image'), vg = view.getContext('2d');
function channelsFrom(data) { return (data.channels || []).map(c => c.apid); }
function renderTabs(data) {
  const tabs = $('tabs'), apids = channelsFrom(data), wanted = ['rgb', ...apids.map(String)];
  if (tabs.dataset.key === wanted.join(',')) return;
  tabs.dataset.key = wanted.join(','); tabs.innerHTML = '';
  for (const key of wanted) {
    const b = document.createElement('button'); b.textContent = key === 'rgb' ? (data.composite?.name || 'RGB') : 'APID ' + key;
    b.title = key === 'rgb' ? 'colour composite' : (CHANNEL_NAMES[key] || ''); b.disabled = key === 'rgb' && !data.composite;
    b.onclick = () => select(key); if (key === selected) b.classList.add('active'); tabs.appendChild(b);
  }
}
function select(key) { selected = key; drawn = {}; imageHeight = 0; view.height = 8; vg.clearRect(0, 0, view.width, view.height);
  [...$('tabs').children].forEach(b => b.classList.toggle('active', b.textContent.includes(key) || (key === 'rgb' && b.title === 'colour composite')));
  $('download').href = '/image?apid=' + key; $('download').download = 'meteor-' + key + '.png'; if (last) updateImage(last); }
// Lines that are final in every channel shown: the composite waits for its slowest channel, so that no row is drawn
// while one of its colours is still to come.
function readyLines(data) {
  const lines = Object.fromEntries((data.channels || []).map(c => [c.apid, c.lines]));
  if (selected !== 'rgb') return lines[selected] || 0;
  const used = (data.composite?.apids || []).filter(a => a);
  return used.length ? Math.min(...used.map(a => lines[a] || 0)) : 0;
}
let loading = false;
async function updateImage(data) {
  const height = readyLines(data); if (!height) return;
  $('empty').hidden = true; $('scan').hidden = false;
  if (loading) return; const have = drawn[selected] || 0; if (have >= height) return;
  loading = true;
  try {
    const to = Math.min(height, have + 400), res = await fetch('/strip?apid=' + selected + '&from=' + have + '&to=' + to);
    if (res.ok) {
      const bmp = await createImageBitmap(await res.blob());
      if (view.height < to) { const old = document.createElement('canvas'); old.width = view.width; old.height = view.height; old.getContext('2d').drawImage(view, 0, 0);
        view.height = Math.max(to, Math.ceil(view.height * 1.5)); vg.drawImage(old, 0, 0); }
      vg.drawImage(bmp, 0, have); drawn[selected] = to; imageHeight = to; applyEnhance();
      const scale = view.getBoundingClientRect().width / view.width, y = to * scale;
      $('scan').style.top = y + 'px';
      if ($('follow').checked) { const vw = $('viewer'); vw.scrollTop = Math.max(0, y - vw.clientHeight + 24); }
      $('imageInfo').textContent = to + ' lines · ' + (selected === 'rgb' ? (data.composite?.name || '') : (CHANNEL_NAMES[selected] || ''));
    }
  } finally { loading = false; }
  if ((drawn[selected] || 0) < height) setTimeout(() => updateImage(last), 30);
}
function applyEnhance() { view.style.filter = $('enhance').checked ? 'contrast(1.6) brightness(1.1)' : ''; }
$('enhance').onchange = applyEnhance;

function update(data) {
  last = data; const dt = data.t;
  $('radio').textContent = (data.frequency / 1e6).toFixed(3) + ' MHz · ' + data.mode + ' · ' + (data.sampleRate / 1e3).toFixed(0) + ' kS/s · ' + data.source;
  $('clock').textContent = 'T+' + fmtTime(dt);
  history.t.push(dt); history.snr.push(data.snr); history.car.push(data.carrier); history.level.push(data.level);
  history.valid.push(data.frames.valid); history.lines.push(data.height || 0); history.locked.push(data.locked);
  if (history.t.length > 5000) for (const k in history) history[k].shift();
  (data.ribbon || []).forEach(x => ribbon.push(x)); if (ribbon.length > 4000) ribbon.splice(0, ribbon.length - 4000);

  // pipeline
  const hasSignal = data.snr > 3;
  stage('stRF', data.level > -45 ? 'ok' : data.level > -60 ? 'warn' : 'bad');
  $('rfValue').innerHTML = data.level.toFixed(1) + '<small>dBFS</small>'; $('rfDetail').textContent = 'gain ×' + data.gain.toFixed(2);
  spark('sparkRF', history.level, COLORS.accent);
  stage('stCarrier', data.locked ? 'ok' : 'warn'); $('carTag').textContent = data.locked ? 'LOCK' : 'SEARCH';
  $('carValue').innerHTML = (data.carrier >= 0 ? '+' : '') + data.carrier.toFixed(0) + '<small>Hz</small>';
  const n = history.car.length, rate = n > 10 ? (history.car[n - 1] - history.car[n - 11]) / ((history.t[n - 1] - history.t[n - 11]) || 1) : 0;
  const coarse = data.coarse && data.coarse.db >= 9 ? ' · x⁴ ' + (data.coarse.hz >= 0 ? '+' : '') + data.coarse.hz.toFixed(0) : '';
  $('carDetail').textContent = 'Doppler ' + (rate >= 0 ? '+' : '') + rate.toFixed(1) + ' Hz/s' + coarse; spark('sparkCar', history.car, COLORS.warn);
  $('carDetail').title = data.coarse ? 'coarse estimate from the fourth power: ' + data.coarse.hz.toFixed(1) + ' Hz, line ' + data.coarse.db.toFixed(1) + ' dB' : '';
  stage('stSymbols', data.snr > 8 ? 'ok' : data.snr > 4 ? 'warn' : 'bad');
  $('symValue').innerHTML = data.snr.toFixed(1) + '<small>dB</small>'; $('symDetail').textContent = 'clock ' + (data.symbolRate / 1e3).toFixed(3) + ' kS/s';
  spark('sparkSNR', history.snr, COLORS.ok, 0);
  const f = data.frames, pct = f.total ? 100 * f.valid / f.total : 0, recent = ribbon.slice(-40), recentOK = recent.filter(x => x).length / (recent.length || 1);
  stage('stFrames', !f.total ? '' : recentOK > .8 ? 'ok' : recentOK > .3 ? 'warn' : 'bad'); $('frTag').textContent = f.total ? pct.toFixed(0) + '%' : '';
  $('frValue').innerHTML = f.valid + '<small>/ ' + f.total + '</small>'; $('frDetail').textContent = 'Viterbi ' + f.viterbi + ' · RS fixed ' + f.corrected;
  spark('sparkFR', history.valid.map((v, i, a) => i ? v - a[i - 1] : 0), COLORS.ok, 0);
  stage('stImage', data.height ? 'ok' : ''); $('imValue').innerHTML = (data.height || 0) + '<small>lines</small>';
  $('imDetail').textContent = (data.channels || []).map(c => c.apid).join(' · ') || 'no image packets yet';
  spark('sparkIM', history.lines, COLORS.accent, 0);

  const live = data.locked && recentOK > .3, text = !data.locked ? (hasSignal ? 'acquiring' : 'searching') : recentOK > .8 ? 'decoding' : recentOK > .3 ? 'marginal' : 'no frames';
  $('state').className = 'pill' + (live ? ' live' : ''); $('stateText').textContent = text;

  drawConstellation(data.constellation || [], data.locked);
  $('evm').textContent = data.locked ? 'locked' : 'unlocked';
  $('sSNR').textContent = data.snr.toFixed(1) + ' dB'; $('sCar').textContent = (data.carrier >= 0 ? '+' : '') + data.carrier.toFixed(0) + ' Hz';
  const nominal = data.nominalRate || 72000; $('sClock').textContent = ((data.symbolRate - nominal) / nominal * 1e6).toFixed(0) + ' ppm';
  if (data.spectrum) { drawSpectrum(data.spectrum.bins, data.carrier, data.spectrum.span, data.coarse); $('span').textContent = '±' + (data.spectrum.span / 2e3).toFixed(0) + ' kHz'; }
  drawRibbon(); drawHistory();
  // APIDs
  const apids = Object.entries(data.packets || {}).sort((a, b) => a[0] - b[0]), maxN = Math.max(1, ...apids.map(a => a[1]));
  $('apids').innerHTML = apids.map(([k, v]) => '<div class="apid"><span>' + k + '</span><div class="bar"><span style="width:' + (100 * v / maxN).toFixed(1) + '%"></span></div><span class="n">' + v + '</span></div>').join('') || '<span style="color:var(--muted);font-size:12px">none yet</span>';
  $('pktInfo').textContent = (data.packetsTotal || 0) + ' total';
  renderTabs(data); updateImage(data);
  $('foot').textContent = 'rtlsdr-tool meteor · ' + (data.spacecraft != null ? 'spacecraft ' + data.spacecraft + ' · ' : '') + 'frame counter ' + (f.counter ?? '–');
}

function connect() {
  const events = new EventSource('/events');
  events.addEventListener('telemetry', e => update(JSON.parse(e.data)));
  events.onerror = () => { $('state').className = 'pill'; $('stateText').textContent = 'reconnecting'; };
}
select('rgb'); connect();
window.addEventListener('resize', () => { if (last) { drawRibbon(); drawHistory(); } });
</script>
</body>
</html>
"""#
