// The 3-D spectrum field behind the page: a waterfall of bars, newest row in front, older rows
// receding into the fog. WebGL2 with instanced drawing, no libraries. One texture holds the
// magnitudes (bins across, time rows down); the vertex shader reads the height of each bar from it.

export const BINS = 96;
export const ROWS = 72;

const VERT = `#version 300 es
precision highp float;
in vec3 a_pos;      // unit box, y in 0..1
in vec3 a_nrm;
in vec2 a_cell;     // (bin, age) — age 0 is the newest row
uniform mat4 u_vp;
uniform sampler2D u_mag;   // R8: x = bin, y = ring row
uniform float u_bins, u_rows, u_head, u_hover, u_time, u_height;
out vec3 v_color;
out vec3 v_nrm;
out float v_fog;

// The palette of the app: warm lows, yellow and green mids, cyan presence, blue and violet air.
vec3 ramp(float f) {
  vec3 c0 = vec3(0.98, 0.45, 0.22);   // sub
  vec3 c1 = vec3(1.00, 0.72, 0.25);   // bass
  vec3 c2 = vec3(0.80, 0.90, 0.30);   // low mid
  vec3 c3 = vec3(0.30, 0.85, 0.55);   // mid
  vec3 c4 = vec3(0.25, 0.80, 0.95);   // presence
  vec3 c5 = vec3(0.30, 0.50, 1.00);   // brilliance
  vec3 c6 = vec3(0.60, 0.45, 0.95);   // air
  float x = f * 6.0;
  if (x < 1.0) return mix(c0, c1, x);
  if (x < 2.0) return mix(c1, c2, x - 1.0);
  if (x < 3.0) return mix(c2, c3, x - 2.0);
  if (x < 4.0) return mix(c3, c4, x - 3.0);
  if (x < 5.0) return mix(c4, c5, x - 4.0);
  return mix(c5, c6, x - 5.0);
}

void main() {
  float bin = a_cell.x;
  float age = a_cell.y;
  float row = mod(u_head - age + u_rows, u_rows);
  float mag = texelFetch(u_mag, ivec2(int(bin), int(row)), 0).r;
  // A little smoothing along time keeps the field calm.
  float rowB = mod(row + 1.0, u_rows);
  float magB = texelFetch(u_mag, ivec2(int(bin), int(rowB)), 0).r;
  mag = (age < u_rows - 1.0) ? mix(mag, magB, 0.25) : mag;
  mag = pow(mag, 1.15);

  float h = max(mag * u_height, 0.05);
  float gapX = 0.26, gapZ = 0.30;
  float x = (bin - u_bins * 0.5 + 0.5) + a_pos.x * (1.0 - gapX);
  float z = -age + a_pos.z * (1.0 - gapZ);
  float y = a_pos.y * h;
  gl_Position = u_vp * vec4(x, y, z, 1.0);

  float f = bin / (u_bins - 1.0);
  vec3 base = ramp(f);
  float glow = smoothstep(0.55, 1.0, mag);
  vec3 c = base * (0.22 + 0.95 * mag) + vec3(0.35) * glow * glow;
  // The column under the pointer lights up.
  float hover = 1.0 - smoothstep(0.5, 2.5, abs(bin - u_hover));
  c += hover * vec3(0.25, 0.30, 0.35) * (0.5 + mag);
  v_color = c;
  v_nrm = a_nrm;
  float t = age / u_rows;
  v_fog = smoothstep(0.15, 1.0, t);
}`;

const FRAG = `#version 300 es
precision highp float;
in vec3 v_color;
in vec3 v_nrm;
in float v_fog;
uniform vec3 u_bg;
out vec4 o_color;
void main() {
  vec3 n = normalize(v_nrm);
  float key = max(dot(n, normalize(vec3(0.35, 0.9, 0.45))), 0.0);
  float fill = max(dot(n, normalize(vec3(-0.6, 0.3, 0.7))), 0.0);
  float light = 0.42 + 0.58 * key + 0.18 * fill;
  vec3 c = v_color * light;
  c = mix(c, u_bg, v_fog);
  o_color = vec4(c, 1.0);
}`;

// Unit box without its bottom: top and four sides. y runs 0..1 so the shader can scale it.
function boxGeometry() {
  const faces = [
    { n: [0, 1, 0], q: [[-.5, 1, .5], [.5, 1, .5], [.5, 1, -.5], [-.5, 1, -.5]] },
    { n: [0, 0, 1], q: [[-.5, 0, .5], [.5, 0, .5], [.5, 1, .5], [-.5, 1, .5]] },
    { n: [0, 0, -1], q: [[.5, 0, -.5], [-.5, 0, -.5], [-.5, 1, -.5], [.5, 1, -.5]] },
    { n: [1, 0, 0], q: [[.5, 0, .5], [.5, 0, -.5], [.5, 1, -.5], [.5, 1, .5]] },
    { n: [-1, 0, 0], q: [[-.5, 0, -.5], [-.5, 0, .5], [-.5, 1, .5], [-.5, 1, -.5]] },
  ];
  const pos = [], nrm = [], idx = [];
  faces.forEach((f, i) => {
    f.q.forEach(p => { pos.push(...p); nrm.push(...f.n); });
    const b = i * 4;
    idx.push(b, b + 1, b + 2, b, b + 2, b + 3);
  });
  return { pos: new Float32Array(pos), nrm: new Float32Array(nrm), idx: new Uint16Array(idx) };
}

// Small matrix helpers (column-major, like WebGL).
const M = {
  perspective(fovY, aspect, near, far) {
    const f = 1 / Math.tan(fovY / 2), nf = 1 / (near - far);
    return new Float32Array([f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0]);
  },
  lookAt(eye, at, up) {
    const z = norm(sub(eye, at)), x = norm(cross(up, z)), y = cross(z, x);
    return new Float32Array([x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0,
      -dot(x, eye), -dot(y, eye), -dot(z, eye), 1]);
  },
  mul(a, b) {
    const o = new Float32Array(16);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
      o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
    }
    return o;
  },
  invert(m) {
    const o = new Float32Array(16);
    const [a00, a01, a02, a03, a10, a11, a12, a13, a20, a21, a22, a23, a30, a31, a32, a33] = m;
    const b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
    const b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
    const b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
    const b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    let det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    if (!det) return null;
    det = 1 / det;
    o[0] = (a11 * b11 - a12 * b10 + a13 * b09) * det;
    o[1] = (a02 * b10 - a01 * b11 - a03 * b09) * det;
    o[2] = (a31 * b05 - a32 * b04 + a33 * b03) * det;
    o[3] = (a22 * b04 - a21 * b05 - a23 * b03) * det;
    o[4] = (a12 * b08 - a10 * b11 - a13 * b07) * det;
    o[5] = (a00 * b11 - a02 * b08 + a03 * b07) * det;
    o[6] = (a32 * b02 - a30 * b05 - a33 * b01) * det;
    o[7] = (a20 * b05 - a22 * b02 + a23 * b01) * det;
    o[8] = (a10 * b10 - a11 * b08 + a13 * b06) * det;
    o[9] = (a01 * b08 - a00 * b10 - a03 * b06) * det;
    o[10] = (a30 * b04 - a31 * b02 + a33 * b00) * det;
    o[11] = (a21 * b02 - a20 * b04 - a23 * b00) * det;
    o[12] = (a11 * b07 - a10 * b09 - a12 * b06) * det;
    o[13] = (a00 * b09 - a01 * b07 + a02 * b06) * det;
    o[14] = (a31 * b01 - a30 * b03 - a32 * b00) * det;
    o[15] = (a20 * b03 - a21 * b01 + a22 * b00) * det;
    return o;
  },
  transform(m, v) {
    const x = m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12] * v[3];
    const y = m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13] * v[3];
    const z = m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14] * v[3];
    const w = m[3] * v[0] + m[7] * v[1] + m[11] * v[2] + m[15] * v[3];
    return [x, y, z, w];
  },
};
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = a => { const l = Math.hypot(...a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

export class SpectrumScene {
  /** Throws when WebGL2 is not there; the page then keeps its plain background. */
  constructor(canvas, { background = [0.027, 0.039, 0.07] } = {}) {
    this.canvas = canvas;
    const gl = canvas.getContext('webgl2', { antialias: true, alpha: false, powerPreference: 'low-power' });
    if (!gl) throw new Error('no WebGL2');
    this.gl = gl;
    this.bg = background;
    this.head = 0;
    this.hover = -1;
    this.pointer = { x: 0, y: 0 };      // -1..1, eased
    this.target = { x: 0, y: 0 };
    this.vp = null;
    this.invVp = null;
    this.dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    this.reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    this.program = program;
    this.u = {};
    for (const name of ['u_vp', 'u_mag', 'u_bins', 'u_rows', 'u_head', 'u_hover', 'u_time', 'u_height', 'u_bg']) {
      this.u[name] = gl.getUniformLocation(program, name);
    }

    const geo = boxGeometry();
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const attr = (name, data, size, divisor = 0) => {
      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(program, name);
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, size, gl.FLOAT, false, 0, 0);
      gl.vertexAttribDivisor(loc, divisor);
    };
    attr('a_pos', geo.pos, 3);
    attr('a_nrm', geo.nrm, 3);
    const cells = new Float32Array(BINS * ROWS * 2);
    for (let age = 0, i = 0; age < ROWS; age++) for (let bin = 0; bin < BINS; bin++) { cells[i++] = bin; cells[i++] = age; }
    attr('a_cell', cells, 2, 1);
    const ibo = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, geo.idx, gl.STATIC_DRAW);
    this.vao = vao;
    this.indexCount = geo.idx.length;

    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, BINS, ROWS, 0, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(BINS * ROWS));
    this.tex = tex;
    this.rowBytes = new Uint8Array(BINS);

    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
    gl.cullFace(gl.BACK);
    gl.clearColor(background[0], background[1], background[2], 1);

    this.resize();
    if (window.ResizeObserver) new ResizeObserver(() => this.resize()).observe(canvas);
    else window.addEventListener('resize', () => this.resize(), { passive: true });
    window.addEventListener('pointermove', e => {
      const r = canvas.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
      this.target.x = Math.max(-1, Math.min(1, x * 2 - 1));
      this.target.y = Math.max(-1, Math.min(1, y * 2 - 1));
      const inside = x >= 0 && x <= 1 && y >= 0 && y <= 1;
      this.pointerPx = inside ? [e.clientX - r.left, e.clientY - r.top, r.width, r.height] : null;
    }, { passive: true });
    window.addEventListener('pointerleave', () => { this.pointerPx = null; });
    window.addEventListener('blur', () => { this.pointerPx = null; });
  }

  resize() {
    const w = Math.floor(this.canvas.clientWidth * this.dpr), h = Math.floor(this.canvas.clientHeight * this.dpr);
    if (!w || !h) return;
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    this.gl.viewport(0, 0, w, h);
  }

  /** Adds one row of magnitudes (0..1, BINS values) in front of the field. */
  pushRow(values) {
    const b = this.rowBytes;
    for (let i = 0; i < BINS; i++) {
      const v = values[i];
      b[i] = v <= 0 ? 0 : v >= 1 ? 255 : (v * 255) | 0;
    }
    this.head = (this.head + 1) % ROWS;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, this.head, BINS, 1, gl.RED, gl.UNSIGNED_BYTE, b);
  }

  /** The bin under the pointer, or -1. Uses the camera of the last frame. */
  binAtPointer() {
    if (!this.pointerPx || !this.invVp) return -1;
    const [px, py, pw, ph] = this.pointerPx;
    const nx = (px / pw) * 2 - 1;
    const ny = 1 - (py / ph) * 2;
    const a = M.transform(this.invVp, [nx, ny, -1, 1]);
    const b = M.transform(this.invVp, [nx, ny, 1, 1]);
    const p0 = [a[0] / a[3], a[1] / a[3], a[2] / a[3]];
    const p1 = [b[0] / b[3], b[1] / b[3], b[2] / b[3]];
    const d = sub(p1, p0);
    // The plane of the bar tops at a typical height reads better than the floor.
    const planeY = 1.2;
    if (Math.abs(d[1]) < 1e-6) return -1;
    const t = (planeY - p0[1]) / d[1];
    if (t < 0) return -1;
    const x = p0[0] + d[0] * t, z = p0[2] + d[2] * t;
    if (z > 0.6 || z < -ROWS) return -1;
    const bin = Math.floor(x + BINS * 0.5);
    return bin >= 0 && bin < BINS ? bin : -1;
  }

  draw(timeSeconds) {
    const gl = this.gl;
    const ease = this.reducedMotion ? 1 : 0.06;
    this.pointer.x += (this.target.x - this.pointer.x) * ease;
    this.pointer.y += (this.target.y - this.pointer.y) * ease;

    const aspect = this.canvas.width / this.canvas.height;
    const sway = this.reducedMotion ? 0 : Math.sin(timeSeconds * 0.11) * 0.06;
    const yaw = sway + this.pointer.x * 0.14;
    const elevation = 0.46 - this.pointer.y * 0.06;
    // Far enough back that the whole width fits; a phone sees the middle of the field.
    const fov = 0.72;
    const dist = Math.min(Math.max((BINS * 0.5 + 10) / (Math.tan(fov / 2) * aspect), 70), 135);
    const at = [0, 2, -ROWS * 0.5];
    const eye = [
      at[0] + Math.sin(yaw) * dist * Math.cos(elevation),
      at[1] + Math.sin(elevation) * dist,
      at[2] + Math.cos(yaw) * dist * Math.cos(elevation),
    ];
    const proj = M.perspective(fov, aspect, 1, 400);
    const view = M.lookAt(eye, at, [0, 1, 0]);
    this.vp = M.mul(proj, view);
    this.invVp = M.invert(this.vp);
    this.hover = this.binAtPointer();

    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.uniform1i(this.u.u_mag, 0);
    gl.uniformMatrix4fv(this.u.u_vp, false, this.vp);
    gl.uniform1f(this.u.u_bins, BINS);
    gl.uniform1f(this.u.u_rows, ROWS);
    gl.uniform1f(this.u.u_head, this.head);
    gl.uniform1f(this.u.u_hover, this.hover);
    gl.uniform1f(this.u.u_time, timeSeconds);
    gl.uniform1f(this.u.u_height, 14);
    gl.uniform3f(this.u.u_bg, this.bg[0], this.bg[1], this.bg[2]);
    gl.drawElementsInstanced(gl.TRIANGLES, this.indexCount, gl.UNSIGNED_SHORT, 0, BINS * ROWS);
  }
}
