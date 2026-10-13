// The sound behind the page and the analysis that feeds the spectrum field.
//
// Three sources, one display:
//   - the groove: a short bossa nova loop, composed for this page and synthesized in the browser
//     with the Web Audio API. It is rendered once, offline, so the field moves to it before any click
//     (the browser plays no sound until you ask, but it may compute).
//   - your microphone, when you allow it. It stays in the browser; nothing is uploaded.
//   - a music file of yours, decoded and played locally.
//
// Nothing here talks to a server.

import { BINS } from './spectrum.js';

export const FMIN = 30, FMAX = 16000;
const FFT_SIZE = 4096;
export const freqOfBin = i => FMIN * Math.pow(FMAX / FMIN, i / (BINS - 1));
const edgeOfBin = i => FMIN * Math.pow(FMAX / FMIN, i / (BINS - 1));

// ---------------------------------------------------------------------------------------------
// FFT (radix-2, in place) and the map from its linear bins to the log bins of the display.

function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = a + len / 2;
        const tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr; im[a] += ti;
        const nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
}

class LogMapper {
  constructor(sampleRate) {
    const binHz = sampleRate / FFT_SIZE;
    this.ranges = [];
    for (let i = 0; i < BINS; i++) {
      this.ranges.push([edgeOfBin(i - 0.5) / binHz, edgeOfBin(i + 0.5) / binHz]);
    }
  }
  /** dB per linear FFT bin in, 0..1 per log bin out. Auto-gain: the loudest bin of the last seconds sits near the top. */
  map(db, out, state) {
    const n = db.length;
    let rowMax = -200;
    for (let i = 0; i < BINS; i++) {
      const [lo, hi] = this.ranges[i];
      let v;
      if (hi - lo < 1) {
        const c = Math.min(Math.max((lo + hi) * 0.5, 0), n - 2);
        const k = Math.floor(c), f = c - k;
        v = db[k] * (1 - f) + db[k + 1] * f;
      } else {
        v = -1000;
        for (let k = Math.max(0, Math.floor(lo)), end = Math.min(n, Math.ceil(hi)); k < end; k++) if (db[k] > v) v = db[k];
      }
      if (!isFinite(v)) v = -200;
      out[i] = v;
      if (v > rowMax) rowMax = v;
    }
    state.ceiling = Math.max(state.ceiling - 0.03, rowMax);
    const floor = state.ceiling - 58;
    for (let i = 0; i < BINS; i++) {
      const v = Math.min(Math.max((out[i] - floor) / 58, 0), 1);
      out[i] = v;
    }
  }
}

// ---------------------------------------------------------------------------------------------
// The groove. Original material: an eight-bar bossa nova progression in F, played twice with a
// second melody, and the usual parts — bass on root and fifth, guitar on the João pattern, rim
// click on the bossa clave, shaker, a soft surdo, and a flute-like lead.

const BPM = 124;
const BEAT = 60 / BPM, BAR = BEAT * 4, EIGHTH = BEAT / 2, SIXTEENTH = BEAT / 4;
const BARS = 16;
const hz = m => 440 * Math.pow(2, (m - 69) / 12);

// Each bar: chord segments, `at` in eighths. notes = guitar voicing, bass = the root.
const PROGRESSION = [
  [{ at: 0, bass: 41, notes: [57, 60, 64, 67] }],                                   // Fmaj9
  [{ at: 0, bass: 40, notes: [55, 58, 62, 65] }, { at: 4, bass: 45, notes: [61, 64, 67, 70] }], // Em7b5  A7b9
  [{ at: 0, bass: 38, notes: [53, 57, 60, 64] }],                                   // Dm9
  [{ at: 0, bass: 43, notes: [53, 59, 64, 69] }],                                   // G13
  [{ at: 0, bass: 36, notes: [52, 55, 59, 62] }],                                   // Cmaj9
  [{ at: 0, bass: 34, notes: [50, 56, 60, 64] }],                                   // Bb7#11
  [{ at: 0, bass: 43, notes: [58, 62, 65, 69] }],                                   // Gm9
  [{ at: 0, bass: 36, notes: [58, 62, 65, 67] }, { at: 4, bass: 36, notes: [58, 64, 67, 74] }], // C7sus  C9
];

// Melody: [bar, eighth, length in eighths, midi]
const MELODY = [
  [0, 1, 2, 69], [0, 3, 1, 67], [0, 4, 3, 64],
  [1, 0, 2, 62], [1, 5, 2, 61],
  [2, 1, 1, 64], [2, 2, 1, 65], [2, 3, 3, 69],
  [3, 2, 1, 69], [3, 3, 2, 71], [3, 6, 2, 64],
  [4, 1, 2, 67], [4, 4, 2, 71], [4, 6, 2, 74],
  [5, 1, 1, 72], [5, 2, 3, 68], [5, 6, 2, 76],
  [6, 0, 2, 74], [6, 3, 1, 70], [6, 4, 3, 69],
  [7, 1, 2, 65], [7, 4, 3, 64],
  [8, 1, 2, 72], [8, 3, 1, 69], [8, 4, 3, 67],
  [9, 0, 1, 65], [9, 1, 2, 62], [9, 5, 2, 64],
  [10, 1, 1, 69], [10, 2, 1, 72], [10, 3, 3, 76],
  [11, 2, 1, 74], [11, 3, 2, 71], [11, 6, 2, 69],
  [12, 1, 1, 67], [12, 2, 1, 64], [12, 3, 3, 62],
  [13, 1, 2, 60], [13, 4, 1, 64], [13, 5, 2, 68],
  [14, 0, 2, 69], [14, 3, 1, 65], [14, 4, 3, 62],
  [15, 1, 2, 64], [15, 4, 3, 60],
];

const CLAVE = [0, 3, 6, 10, 13];         // eighths over two bars
const COMP = [[0, 3, 6], [1, 4, 7]];     // guitar hits, odd and even bars

function makeNoise(ctx, seconds) {
  const buf = ctx.createBuffer(1, Math.floor(ctx.sampleRate * seconds), ctx.sampleRate);
  const d = buf.getChannelData(0);
  let s = 0x2545F491;
  for (let i = 0; i < d.length; i++) {
    s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
    d[i] = ((s >>> 0) / 4294967296) * 2 - 1;
  }
  return buf;
}

function pan(ctx, dest, value) {
  if (!ctx.createStereoPanner) return dest;
  const p = ctx.createStereoPanner();
  p.pan.value = value;
  p.connect(dest);
  return p;
}

// A small room: three comb delays and an allpass. Cheap, unlike a convolver, and enough for a backdrop.
function room(ctx, dest) {
  const input = ctx.createGain();
  const allpass = ctx.createDelay(0.1);
  allpass.delayTime.value = 0.0061;
  const apFeed = ctx.createGain(); apFeed.gain.value = 0.5;
  const apOut = ctx.createGain();
  for (const ms of [31.7, 39.1, 46.3]) {
    const d = ctx.createDelay(0.2); d.delayTime.value = ms / 1000;
    const fb = ctx.createGain(); fb.gain.value = 0.74;
    const damp = ctx.createBiquadFilter(); damp.type = 'lowpass'; damp.frequency.value = 3800;
    input.connect(d); d.connect(damp).connect(fb).connect(d);
    damp.connect(allpass);
  }
  allpass.connect(apFeed).connect(allpass);
  allpass.connect(apOut);
  apOut.connect(dest);
  return input;
}

// Every note is one or two sources and a gain for the envelope. Filters and panners are shared per
// instrument: a node per note that lives for the whole render makes the offline render slow.
class Band {
  constructor(ctx) {
    this.ctx = ctx;
    this.noise = makeNoise(ctx, 1);
    const master = ctx.createGain();
    master.gain.value = 0.9;
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -16; comp.ratio.value = 3; comp.attack.value = 0.008; comp.release.value = 0.22; comp.knee.value = 8;
    master.connect(comp).connect(ctx.destination);
    const wet = ctx.createGain();
    wet.gain.value = 0.16;
    wet.connect(master);
    const verb = room(ctx, wet);
    const filt = (type, frequency, Q, dest) => {
      const f = ctx.createBiquadFilter(); f.type = type; f.frequency.value = frequency; f.Q.value = Q; f.connect(dest); return f;
    };
    const bus = {
      bass: pan(ctx, master, 0),
      guitar: pan(ctx, master, 0.28),
      rim: pan(ctx, master, 0.15),
      shaker: pan(ctx, master, -0.35),
      surdo: pan(ctx, master, -0.05),
      lead: pan(ctx, master, -0.08),
    };
    for (const name of ['guitar', 'rim', 'lead']) bus[name].connect(verb);
    this.in = {
      bass: filt('lowpass', 420, 0.7, bus.bass),
      guitar: filt('lowpass', 2300, 0.9, bus.guitar),
      rimNoise: filt('bandpass', 2400, 5, bus.rim),
      rimTone: bus.rim,
      shaker: filt('highpass', 6500, 0.8, bus.shaker),
      surdo: bus.surdo,
      lead: filt('lowpass', 3200, 0.6, bus.lead),
    };
    // One vibrato for every lead note.
    const lfo = ctx.createOscillator(); lfo.frequency.value = 5.3;
    this.vibrato = ctx.createGain(); this.vibrato.gain.value = 7;
    lfo.connect(this.vibrato); lfo.start(0);
  }

  osc(type, f, t, stop, detune = 0) {
    const o = this.ctx.createOscillator();
    o.type = type; o.frequency.value = f; o.detune.value = detune;
    o.start(t); o.stop(stop);
    return o;
  }

  bass(midi, t, dur) {
    const { ctx } = this, f = hz(midi);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.55, t + 0.008);
    g.gain.exponentialRampToValueAtTime(0.22, t + 0.35);
    g.gain.setValueAtTime(0.22, t + dur - 0.06);
    g.gain.exponentialRampToValueAtTime(0.0005, t + dur);
    g.connect(this.in.bass);
    this.osc('sine', f, t, t + dur + 0.05).connect(g);
    const tri = this.osc('triangle', f, t, t + dur + 0.05);
    const g2 = ctx.createGain(); g2.gain.value = 0.35;
    tri.connect(g2).connect(g);
  }

  pluck(midi, t, dur, level = 0.11) {
    const { ctx } = this, f = hz(midi);
    // The saw is the attack and fades fast; the triangle is the body.
    const ga = ctx.createGain();
    ga.gain.setValueAtTime(0, t);
    ga.gain.linearRampToValueAtTime(level, t + 0.004);
    ga.gain.exponentialRampToValueAtTime(level * 0.08, t + 0.18);
    ga.gain.exponentialRampToValueAtTime(0.0003, t + dur + 0.04);
    ga.connect(this.in.guitar);
    this.osc('sawtooth', f, t, t + dur + 0.1, -4).connect(ga);
    const gb = ctx.createGain();
    gb.gain.setValueAtTime(0, t);
    gb.gain.linearRampToValueAtTime(level * 1.3, t + 0.006);
    gb.gain.exponentialRampToValueAtTime(level * 0.3, t + 0.45);
    gb.gain.exponentialRampToValueAtTime(0.0003, t + dur + 0.04);
    gb.connect(this.in.guitar);
    this.osc('triangle', f, t, t + dur + 0.1, 5).connect(gb);
  }

  rim(t) {
    const { ctx } = this;
    const n = ctx.createBufferSource(); n.buffer = this.noise;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.5, t);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.035);
    n.connect(g).connect(this.in.rimNoise);
    n.start(t, 0.1); n.stop(t + 0.05);
    const g2 = ctx.createGain();
    g2.gain.setValueAtTime(0.22, t);
    g2.gain.exponentialRampToValueAtTime(0.001, t + 0.05);
    g2.connect(this.in.rimTone);
    this.osc('sine', 1850, t, t + 0.06).connect(g2);
  }

  shaker(t, vel) {
    const { ctx } = this;
    const n = ctx.createBufferSource(); n.buffer = this.noise;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.075 * vel, t + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0005, t + 0.075);
    n.connect(g).connect(this.in.shaker);
    n.start(t, (t * 7.3) % 0.8); n.stop(t + 0.09);
  }

  surdo(t, vel) {
    const { ctx } = this;
    const o = ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(95, t);
    o.frequency.exponentialRampToValueAtTime(52, t + 0.09);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.42 * vel, t + 0.006);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.26);
    o.connect(g).connect(this.in.surdo);
    o.start(t); o.stop(t + 0.3);
  }

  lead(midi, t, dur) {
    const { ctx } = this, f = hz(midi);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.17, t + 0.045);
    g.gain.setValueAtTime(0.17, t + dur - 0.08);
    g.gain.exponentialRampToValueAtTime(0.0005, t + dur + 0.12);
    g.connect(this.in.lead);
    const o1 = this.osc('triangle', f, t, t + dur + 0.2);
    const o2 = this.osc('sine', f * 2, t, t + dur + 0.2);
    const g2 = ctx.createGain(); g2.gain.value = 0.08;
    o1.connect(g); o2.connect(g2).connect(g);
    this.vibrato.connect(o1.detune); this.vibrato.connect(o2.detune);
  }

  /** Schedules bars `from` (inclusive) to `to` (exclusive) so that bar `from` starts at `startAt`. */
  play(startAt, from, to) {
    for (let bar = from; bar < to; bar++) {
      const t0 = startAt + (bar - from) * BAR;
      const segments = PROGRESSION[bar % PROGRESSION.length];
      const chordAt = e => segments.filter(s => s.at <= e).pop();
      // Bass: root, root, fifth, fifth — the dotted bossa figure, per chord segment.
      segments.forEach((seg, i) => {
        const end = i + 1 < segments.length ? segments[i + 1].at : 8;
        const root = seg.bass, fifth = root + 7 <= 48 ? root + 7 : root - 5;
        if (end - seg.at >= 8) {
          this.bass(root, t0, 3 * EIGHTH); this.bass(root, t0 + 3 * EIGHTH, EIGHTH);
          this.bass(fifth, t0 + 4 * EIGHTH, 3 * EIGHTH); this.bass(fifth, t0 + 7 * EIGHTH, EIGHTH);
        } else {
          this.bass(root, t0 + seg.at * EIGHTH, 3 * EIGHTH);
          this.bass(fifth, t0 + (seg.at + 3) * EIGHTH, EIGHTH);
        }
      });
      // Guitar on the João pattern, a light strum.
      for (const e of COMP[bar % 2]) {
        const chord = chordAt(e);
        chord.notes.forEach((m, k) => this.pluck(m, t0 + e * EIGHTH + k * 0.009, 1.4 * EIGHTH));
      }
      // Clave on the rim, over two bars.
      for (const e of CLAVE) {
        const barOfHit = Math.floor(e / 8);
        if (bar % 2 === barOfHit) this.rim(t0 + (e - barOfHit * 8) * EIGHTH);
      }
      // Shaker in sixteenths, accents on the beat and the off-beat.
      for (let k = 0; k < 16; k++) {
        const vel = k % 4 === 0 ? 0.55 : k % 2 === 0 ? 0.9 : 0.3;
        this.shaker(t0 + k * SIXTEENTH, vel);
      }
      // Surdo: a soft pulse that doubles the bass figure.
      this.surdo(t0, 0.65); this.surdo(t0 + 3 * EIGHTH, 0.35);
      this.surdo(t0 + 4 * EIGHTH, 0.55); this.surdo(t0 + 7 * EIGHTH, 0.35);
    }
    for (const [bar, e, len, m] of MELODY) {
      if (bar >= from && bar < to) this.lead(m, startAt + (bar - from) * BAR + e * EIGHTH, len * EIGHTH - 0.03);
    }
  }
}

const TAIL_SECONDS = 2.4;

// One stretch of bars plus the tail that rings on after it.
async function renderPart(sampleRate, from, to) {
  const main = Math.round((to - from) * BAR * sampleRate);
  const tail = Math.round(TAIL_SECONDS * sampleRate);
  const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  const ctx = new Offline(2, main + tail, sampleRate);
  new Band(ctx).play(0, from, to);
  return { buffer: await ctx.startRendering(), main, tail };
}

/** Renders the loop once. Returns a seamless AudioBuffer of exactly 16 bars. */
export async function renderGroove(sampleRate = 44100) {
  // Two halves render at the same time; the tail of each is folded onto the start of the other.
  const [a, b] = await Promise.all([renderPart(sampleRate, 0, BARS / 2), renderPart(sampleRate, BARS / 2, BARS)]);
  const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  const out = new Offline(2, 1, sampleRate).createBuffer(2, a.main + b.main, sampleRate);
  let peak = 0;
  for (let c = 0; c < 2; c++) {
    const dst = out.getChannelData(c);
    const A = a.buffer.getChannelData(c), B = b.buffer.getChannelData(c);
    dst.set(A.subarray(0, a.main), 0);
    dst.set(B.subarray(0, b.main), a.main);
    for (let i = 0; i < a.tail; i++) dst[a.main + i] += A[a.main + i];   // A rings into B
    for (let i = 0; i < b.tail; i++) dst[i] += B[b.main + i];            // B rings into A (the loop)
    for (let i = 0; i < dst.length; i++) { const v = Math.abs(dst[i]); if (v > peak) peak = v; }
  }
  const gain = peak > 0 ? 0.89 / peak : 1;
  for (let c = 0; c < 2; c++) { const d = out.getChannelData(c); for (let i = 0; i < d.length; i++) d[i] *= gain; }
  return out;
}

// ---------------------------------------------------------------------------------------------
// The controller: which source feeds the field, and the clock that paces the rows.

export class Background {
  constructor(scene, { rowHz = 28 } = {}) {
    this.scene = scene;
    this.rowHz = rowHz;
    this.mode = 'silent';          // 'silent' | 'groove' | 'mic' | 'file'
    this.buffer = null;            // the rendered groove
    this.ctx = null;               // live AudioContext, made on the first click
    this.analyser = null;
    this.live = null;              // { kind, source, stream }
    this.t0 = performance.now();   // start of the silent clock
    this.offset = 0;               // seconds into the loop at t0
    this.rows = 0;
    this.row = new Float32Array(BINS);
    this.prev = new Float32Array(BINS);
    this.gainState = { ceiling: -12 };
    this.onchange = () => {};
    this.sampleRate = 44100;
    this.mapper = new LogMapper(this.sampleRate);
    this.window = new Float32Array(FFT_SIZE);
    for (let i = 0; i < FFT_SIZE; i++) this.window[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (FFT_SIZE - 1));
    this.re = new Float32Array(FFT_SIZE);
    this.im = new Float32Array(FFT_SIZE);
    this.db = new Float32Array(FFT_SIZE / 2);
    this.mono = null;
    this.ready = false;
    this.error = null;
  }

  async prepare() {
    try {
      const started = performance.now();
      this.buffer = await renderGroove(this.sampleRate);
      this.renderMs = performance.now() - started;
      const L = this.buffer.getChannelData(0), R = this.buffer.getChannelData(1);
      this.mono = new Float32Array(L.length);
      for (let i = 0; i < L.length; i++) this.mono[i] = (L[i] + R[i]) * 0.5;
      this.ready = true;
      this.t0 = performance.now();
      this.rows = 0;
    } catch (e) {
      this.error = e;
    }
    this.onchange();
  }

  get duration() { return this.buffer ? this.buffer.duration : BARS * BAR; }

  /** Seconds into the loop right now. */
  position(nowMs = performance.now()) {
    if (this.mode === 'groove' && this.live && this.ctx) {
      return (this.live.startOffset + (this.ctx.currentTime - this.live.startedAt)) % this.duration;
    }
    return (this.offset + (nowMs - this.t0) / 1000) % this.duration;
  }

  // Spectrum of the groove at `seconds`, from the rendered samples.
  spectrumAt(seconds) {
    const n = this.mono.length;
    const end = Math.floor((seconds % this.duration) * this.sampleRate);
    const start = end - FFT_SIZE;
    const re = this.re, im = this.im, w = this.window, mono = this.mono;
    for (let i = 0; i < FFT_SIZE; i++) {
      let k = start + i;
      if (k < 0) k += n;
      re[i] = mono[k] * w[i];
      im[i] = 0;
    }
    fft(re, im);
    const scale = 4 / FFT_SIZE;   // Hann coherent gain: a full-scale sine reads 0 dB
    for (let k = 0; k < FFT_SIZE / 2; k++) {
      const m = Math.hypot(re[k], im[k]) * scale;
      this.db[k] = 20 * Math.log10(m + 1e-9);
    }
    return this.db;
  }

  // Called every animation frame. Pushes the rows that are due.
  frame(nowMs) {
    const due = Math.floor((nowMs - this.t0) / 1000 * this.rowHz);
    if (due - this.rows > 6) this.rows = due - 2;    // the tab was hidden: skip ahead
    let pushed = 0;
    while (this.rows < due && pushed < 3) {
      this.rows++;
      pushed++;
      const isLive = this.mode !== 'silent' && this.analyser;
      let db;
      if (isLive) {
        db = this.liveDb || (this.liveDb = new Float32Array(this.analyser.frequencyBinCount));
        this.analyser.getFloatFrequencyData(db);
      } else if (this.ready) {
        db = this.spectrumAt(this.position(nowMs) - (due - this.rows) / this.rowHz);
      } else {
        this.idleRow(nowMs);
        continue;
      }
      const mapper = isLive ? this.liveMapper : this.mapper;
      mapper.map(db, this.row, this.gainState);
      this.finishRow();
    }
  }

  // Before the groove is rendered: a quiet breathing field.
  idleRow(nowMs) {
    const t = nowMs / 1000;
    for (let i = 0; i < BINS; i++) {
      const f = i / BINS;
      this.row[i] = 0.08 + 0.1 * (1 - f) * (0.5 + 0.5 * Math.sin(t * 1.3 + f * 9)) * (0.6 + 0.4 * Math.sin(t * 0.7 + i));
    }
    this.finishRow();
  }

  finishRow() {
    const r = this.row, p = this.prev;
    // Smooth across frequency, then a short release per bin so peaks hang a moment.
    let a = r[0];
    for (let i = 0; i < BINS; i++) {
      const b = r[i], c = i + 1 < BINS ? r[i + 1] : b;
      const v = a * 0.22 + b * 0.56 + c * 0.22;
      a = b;
      p[i] = Math.max(v, p[i] - 0.11);
    }
    this.scene.pushRow(p);
  }

  ensureContext() {
    if (this.ctx) return this.ctx;
    const AC = window.AudioContext || window.webkitAudioContext;
    const ctx = new AC();
    const analyser = ctx.createAnalyser();
    analyser.fftSize = FFT_SIZE;
    analyser.smoothingTimeConstant = 0.35;
    this.ctx = ctx;
    this.analyser = analyser;
    this.liveMapper = new LogMapper(ctx.sampleRate);
    return ctx;
  }

  stopLive() {
    if (!this.live) return;
    const { source, stream } = this.live;
    try { source && source.stop(); } catch (_) { /* already stopped */ }
    try { source && source.disconnect(); } catch (_) { /* fine */ }
    if (stream) stream.getTracks().forEach(t => t.stop());
    this.live = null;
  }

  /** Back to the silent groove. */
  silence() {
    const pos = this.position();
    this.stopLive();
    this.mode = 'silent';
    this.offset = pos;
    this.t0 = performance.now();
    this.rows = 0;
    this.onchange();
  }

  /** Plays the groove out loud, in step with the field. */
  async listen() {
    if (!this.ready) return;
    const ctx = this.ensureContext();
    if (ctx.state === 'suspended') await ctx.resume();
    const pos = this.position();
    this.stopLive();
    const source = ctx.createBufferSource();
    source.buffer = this.buffer;
    source.loop = true;
    source.connect(this.analyser);
    this.analyser.connect(ctx.destination);
    source.start(0, pos);
    this.live = { kind: 'groove', source, startOffset: pos, startedAt: ctx.currentTime };
    this.mode = 'groove';
    this.onchange();
  }

  /** The microphone, in the browser only. */
  async mic() {
    const ctx = this.ensureContext();
    if (ctx.state === 'suspended') await ctx.resume();
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    });
    this.stopLive();
    try { this.analyser.disconnect(); } catch (_) { /* fine */ }
    const source = ctx.createMediaStreamSource(stream);
    source.connect(this.analyser);        // not to the speakers: no feedback
    this.live = { kind: 'mic', source, stream };
    this.mode = 'mic';
    this.gainState.ceiling = -30;
    this.onchange();
  }

  /** A music file of the visitor, decoded and played locally. */
  async file(file) {
    const ctx = this.ensureContext();
    if (ctx.state === 'suspended') await ctx.resume();
    const bytes = await file.arrayBuffer();
    const buffer = await new Promise((ok, fail) => ctx.decodeAudioData(bytes, ok, fail));
    this.stopLive();
    try { this.analyser.disconnect(); } catch (_) { /* fine */ }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.loop = true;
    source.connect(this.analyser);
    this.analyser.connect(ctx.destination);
    source.start(0);
    this.live = { kind: 'file', source, name: file.name };
    this.mode = 'file';
    this.onchange();
  }
}
