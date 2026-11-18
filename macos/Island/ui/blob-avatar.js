"use strict";
(() => {
  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/contour.ts
  var make = (n) => ({ x: new Float64Array(n), y: new Float64Array(n) });
  var size = (c) => c.x.length;
  function resample(poly, n, { start: from = "top" } = {}) {
    let area = 0;
    for (let i = 0; i < poly.length; i++) {
      const [x1, y1] = poly[i];
      const [x2, y2] = poly[(i + 1) % poly.length];
      area += x1 * y2 - x2 * y1;
    }
    const pts = area < 0 ? [...poly].reverse() : poly;
    const key = ([x, y]) => from === "axis" ? [Math.abs(x), y] : [y, Math.abs(x)];
    let start = 0;
    for (let i = 1; i < pts.length; i++) {
      const [a, b] = key(pts[i]);
      const [c, d] = key(pts[start]);
      if (a < c - 1e-6 || Math.abs(a - c) <= 1e-6 && b < d) start = i;
    }
    const ring2 = [...pts.slice(start), ...pts.slice(0, start)];
    const lens = [0];
    for (let i = 1; i <= ring2.length; i++) {
      const [ax, ay] = ring2[i - 1];
      const [bx, by] = ring2[i % ring2.length];
      lens.push(lens[i - 1] + Math.hypot(bx - ax, by - ay));
    }
    const total = lens[ring2.length];
    const out = make(n);
    let j = 0;
    for (let k = 0; k < n; k++) {
      const d = k / n * total;
      while (j < ring2.length - 1 && lens[j + 1] < d) j++;
      const [ax, ay] = ring2[j];
      const [bx, by] = ring2[(j + 1) % ring2.length];
      const seg = lens[j + 1] - lens[j] || 1;
      const t = (d - lens[j]) / seg;
      out.x[k] = ax + (bx - ax) * t;
      out.y[k] = ay + (by - ay) * t;
    }
    return out;
  }
  function clone(c) {
    return { x: new Float64Array(c.x), y: new Float64Array(c.y) };
  }
  function blend(a, b, t, out = make(size(a))) {
    for (let i = 0; i < out.x.length; i++) {
      out.x[i] = a.x[i] + (b.x[i] - a.x[i]) * t;
      out.y[i] = a.y[i] + (b.y[i] - a.y[i]) * t;
    }
    return out;
  }
  function bounds(c) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (let i = 0; i < size(c); i++) {
      x0 = Math.min(x0, c.x[i]);
      x1 = Math.max(x1, c.x[i]);
      y0 = Math.min(y0, c.y[i]);
      y1 = Math.max(y1, c.y[i]);
    }
    return { x0, y0, x1, y1, w: x1 - x0, h: y1 - y0 };
  }
  var num = (v) => {
    const r = Math.round(v * 10) / 10;
    return (Object.is(r, -0) ? 0 : r).toString();
  };
  function toPath(c, tension = 1) {
    const n = size(c);
    const { x, y } = c;
    const k = tension / 6;
    let d = `M${num(x[0])} ${num(y[0])}`;
    for (let i = 0; i < n; i++) {
      const p0 = (i - 1 + n) % n;
      const p2 = (i + 1) % n;
      const p3 = (i + 2) % n;
      const c1x = x[i] + (x[p2] - x[p0]) * k;
      const c1y = y[i] + (y[p2] - y[p0]) * k;
      const c2x = x[p2] - (x[p3] - x[i]) * k;
      const c2y = y[p2] - (y[p3] - y[i]) * k;
      d += `C${num(c1x)} ${num(c1y)} ${num(c2x)} ${num(c2y)} ${num(x[p2])} ${num(y[p2])}`;
    }
    return d + "Z";
  }
  function toOpenPath(x, y) {
    const n = x.length;
    const at = (i) => Math.max(0, Math.min(n - 1, i));
    let d = `M${num(x[0])} ${num(y[0])}`;
    for (let i = 0; i < n - 1; i++) {
      const a = at(i - 1), b = i + 1, c = at(i + 2);
      d += `C${num(x[i] + (x[b] - x[a]) / 6)} ${num(y[i] + (y[b] - y[a]) / 6)} ${num(x[b] - (x[c] - x[i]) / 6)} ${num(y[b] - (y[c] - y[i]) / 6)} ${num(x[b])} ${num(y[b])}`;
    }
    return d;
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/glyphs.ts
  var EYE_POINTS = 28;
  var cache = /* @__PURE__ */ new Map();
  function capsule(w) {
    const key = Math.round(w * 200) / 200;
    const hit = cache.get(key);
    if (hit) return hit;
    const W = Math.max(0.05, key), H = 1;
    const r = Math.min(W, H) / 2;
    const sx = W / 2 - r, sy = H / 2 - r;
    const arcLen = Math.PI / 2 * r;
    const parts = [sx, arcLen, 2 * sy, arcLen, 2 * sx, arcLen, 2 * sy, arcLen, sx];
    const total = parts.reduce((a, b) => a + b, 0);
    const at = (d) => {
      let s = d;
      if (s <= parts[0]) return [s, -H / 2];
      s -= parts[0];
      const corner = (cx, cy, a0, u) => {
        const a = a0 + u / r;
        return [cx + r * Math.cos(a), cy + r * Math.sin(a)];
      };
      if (s <= parts[1]) return corner(sx, -sy, -Math.PI / 2, s);
      s -= parts[1];
      if (s <= parts[2]) return [W / 2, -sy + s];
      s -= parts[2];
      if (s <= parts[3]) return corner(sx, sy, 0, s);
      s -= parts[3];
      if (s <= parts[4]) return [sx - s, H / 2];
      s -= parts[4];
      if (s <= parts[5]) return corner(-sx, sy, Math.PI / 2, s);
      s -= parts[5];
      if (s <= parts[6]) return [-W / 2, sy - s];
      s -= parts[6];
      if (s <= parts[7]) return corner(-sx, -sy, Math.PI, s);
      s -= parts[7];
      return [-sx + s, -H / 2];
    };
    const c = make(EYE_POINTS);
    for (let i = 0; i < EYE_POINTS; i++) [c.x[i], c.y[i]] = at(i / EYE_POINTS * total);
    cache.set(key, c);
    return c;
  }
  var disc = (() => {
    const c = make(EYE_POINTS);
    for (let i = 0; i < EYE_POINTS; i++) {
      const a = i / EYE_POINTS * Math.PI * 2;
      c.x[i] = Math.sin(a);
      c.y[i] = -Math.cos(a);
    }
    return c;
  })();

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/math.ts
  var TAU = Math.PI * 2;
  var clamp = (v, lo, hi) => v < lo ? lo : v > hi ? hi : v;
  var lerp = (a, b, t) => a + (b - a) * t;
  var smooth = (t) => {
    const x = clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
  };
  var mod = (v, m) => (v % m + m) % m;
  var ease = {
    linear: (t) => t,
    in: (t) => t * t * t,
    out: (t) => 1 - (1 - t) ** 3,
    inOut: (t) => t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2,
    sine: (t) => 0.5 - 0.5 * Math.cos(Math.PI * t),
    /** overshoots then settles: the "jelly" landing */
    back: (t) => {
      const c = 1.9;
      return 1 + (c + 1) * (t - 1) ** 3 + c * (t - 1) ** 2;
    },
    /** a damped wobble that ends at 1 */
    spring: (t) => 1 - Math.exp(-6 * t) * Math.cos(t * 13)
  };

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/face.ts
  var EXPRESSIONS = [
    "neutral",
    "attentive",
    "focused",
    "surprised",
    "excited",
    "happy",
    "laughing",
    "wink",
    "angry",
    "sad",
    "worried",
    "scared",
    "suspicious",
    "confused",
    "curious",
    "proud",
    "smug",
    "shy",
    "unimpressed",
    "sleepy",
    "pleading",
    "determined",
    "tired",
    "crosseyed",
    "content",
    "dreamy"
  ];
  var E = (x, y, w, h, a, b, c, d) => ({ x, y, w, h, m: [a, b, c, d] });
  var WINK = { left: E(-0.345, -0.115, 0.24, 0.46, 0.94, 0.06, -0.1, 0.99), right: E(0.205, -0.065, 0.45, 0.09, 0.97, 0.12, -0.1, 0.99) };
  var FACES = {
    // looking up and to the right: the capsules sit high on the sphere, foreshortened
    neutral: { left: E(0.188, -0.406, 0.186, 0.412, 0.889, -0.314, 0.414, 0.857), right: E(0.618, -0.51, 0.186, 0.412, 0.667, -0.061, 0.414, 0.857) },
    attentive: { left: E(-0.212, -0.065, 0.21, 0.44, 0.973, -0.095, 0.08, 0.991), right: E(0.336, -0.106, 0.21, 0.44, 0.937, -0.046, 0.08, 0.991) },
    // a squint straight ahead, the inner ends a touch lower
    focused: { left: E(-0.208, -0.029, 0.28, 0.2, 0.969, 0.133, -0.136, 0.991), right: E(0.305, -0.048, 0.28, 0.2, 0.943, -0.124, 0.133, 0.991) },
    surprised: { left: E(-0.281, 0.047, 0.45, 0.47, 0.958, 0.021, -8e-3, 0.998), right: E(0.369, 0.051, 0.45, 0.47, 0.928, -0.012, -8e-3, 0.998) },
    excited: { left: E(-0.239, 0.234, 0.4, 0.56, 0.958, -0.091, 0.149, 0.967), right: E(0.425, 0.231, 0.4, 0.56, 0.887, 0.083, -0.176, 0.969) },
    happy: { left: E(-0.203, -0.155, 0.27, 0.17, 0.952, 0.198, -0.227, 0.967), right: E(0.378, -0.152, 0.27, 0.17, 0.894, -0.188, 0.233, 0.969) },
    laughing: { left: E(-0.236, -0.229, 0.34, 0.13, 0.919, 0.257, -0.31, 0.937), right: E(0.379, -0.232, 0.34, 0.13, 0.86, -0.265, 0.338, 0.934) },
    wink: WINK,
    angry: { left: E(-0.241, -0.114, 0.34, 0.15, 0.841, 0.47, -0.481, 0.874), right: E(0.343, -0.112, 0.34, 0.15, 0.81, -0.464, 0.472, 0.878) },
    sad: { left: E(-0.228, 0.214, 0.22, 0.4, 0.862, -0.406, 0.449, 0.887), right: E(0.322, 0.212, 0.22, 0.4, 0.831, 0.401, -0.452, 0.89) },
    // tilted like sad, but higher, looking up
    worried: { left: E(-0.352, -0.112, 0.24, 0.44, 0.9, -0.314, 0.258, 0.943), right: E(0.315, -0.142, 0.24, 0.44, 0.912, 0.318, -0.262, 0.938) },
    scared: { left: E(-0.322, 0.318, 0.4, 0.6, 0.945, 0.12, -0.011, 0.939), right: E(0.377, 0.319, 0.4, 0.6, 0.925, -0.118, -0.011, 0.939) },
    suspicious: { left: E(-0.073, -0.069, 0.21, 0.4, 0.989, -0.129, 0.124, 0.988), right: E(0.462, -0.127, 0.22, 0.15, 0.877, -0.073, 0.124, 0.988) },
    confused: { left: E(-0.508, -0.09, 0.2, 0.44, 0.851, -0.192, 0.122, 0.977), right: E(0.036, -0.01, 0.28, 0.17, 0.922, 0.384, -0.382, 0.923) },
    curious: { left: E(0, 0.22, 0.24, 0.46, 0.94, -0.332, 0.339, 0.916), right: E(0.532, 0.075, 0.2, 0.38, 0.783, -0.419, 0.317, 0.904) },
    proud: { left: E(-0.202, -0.279, 0.3, 0.15, 0.939, 0.214, -0.274, 0.935), right: E(0.379, -0.279, 0.3, 0.15, 0.87, -0.215, 0.313, 0.935) },
    // half shut, a sideways look up and to the right
    smug: { left: E(0.04, -0.12, 0.29, 0.14, 0.984, -0.168, 0.174, 0.979), right: E(0.479, -0.14, 0.27, 0.13, 0.873, -0.027, 0.092, 0.99) },
    shy: { left: E(-0.529, 0.265, 0.17, 0.3, 0.825, -0.054, 0.191, 0.961), right: E(-0.08, 0.209, 0.17, 0.3, 0.977, -0.171, 0.191, 0.961) },
    unimpressed: { left: E(-0.616, -0.036, 0.3, 0.12, 0.785, -0.012, -0.012, 1), right: E(-0.106, -0.037, 0.3, 0.12, 0.994, 8e-3, -0.012, 1) },
    // big, tall and glossy, looking up
    pleading: { left: E(-0.27, -0.16, 0.36, 0.6, 0.99, 0.06, -0.06, 0.99), right: E(0.33, -0.18, 0.36, 0.6, 0.99, -0.06, 0.06, 0.99) },
    // a squint between focused and angry, straight ahead
    determined: { left: E(-0.22, -0.05, 0.3, 0.19, 0.93, 0.3, -0.31, 0.95), right: E(0.32, -0.06, 0.3, 0.19, 0.93, -0.3, 0.31, 0.95) },
    // heavy, half shut, looking down, the outer ends drooping
    tired: { left: E(-0.24, 0.14, 0.3, 0.12, 0.95, -0.24, 0.24, 0.95), right: E(0.3, 0.13, 0.3, 0.12, 0.95, 0.24, -0.24, 0.95) },
    // both looking at the nose
    crosseyed: { left: E(-0.13, 0.02, 0.2, 0.42, 0.97, 0.12, -0.12, 0.97), right: E(0.19, 0.02, 0.2, 0.42, 0.97, -0.12, 0.12, 0.97) },
    // shut, calm, a little low
    content: { left: E(-0.24, 0.07, 0.3, 0.07, 0.99, 0.06, -0.06, 0.99), right: E(0.3, 0.07, 0.3, 0.07, 0.99, -0.06, 0.06, 0.99) },
    // half shut, looking up and to the left
    dreamy: { left: E(-0.5, -0.36, 0.26, 0.14, 0.86, 0.12, 0.3, 0.9), right: E(-0.02, -0.42, 0.26, 0.14, 0.97, 0.05, 0.3, 0.9) },
    // the same eyes as attentive, nearly shut
    sleepy: { left: E(-0.178, 0.163, 0.2, 0.42, 0.983, -1e-3, 0.033, 0.448), right: E(0.37, 0.137, 0.2, 0.42, 0.927, -0.041, 0.033, 0.448) }
  };
  var STATE_EYES = {
    wink: WINK,
    wide: { left: E(-0.175, 0.28, 0.36, 0.88, 0.96, 0.26, -0.22, 0.93), right: E(0.435, 0.385, 0.36, 0.88, 0.87, 0.05, -0.22, 0.93) },
    notification: { left: E(-0.68, 0.21, 0.5, 0.5, 0.68, -0.13, 0.24, 0.97), right: E(-0.12, 0.09, 0.5, 0.5, 0.96, -0.23, 0.24, 0.97) },
    egg: { left: E(0.16, -0.34, 0.16, 0.39, 0.88, -0.35, 0.44, 0.86), right: E(0.43, -0.41, 0.16, 0.39, 0.76, -0.19, 0.44, 0.86) },
    hexa: { left: E(0.14, -0.285, 0.18, 0.41, 0.92, -0.32, 0.37, 0.9), right: E(0.55, -0.42, 0.18, 0.41, 0.76, -0.15, 0.37, 0.9) },
    play: { left: E(-0.1, 0.13, 0.18, 0.34, 0.99, -0.07, 0.09, 0.99), right: E(0.35, 0.09, 0.18, 0.34, 0.92, -0.13, 0.09, 0.99) }
  };
  function blendEye(a, b, t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), w: lerp(a.w, b.w, t), h: lerp(a.h, b.h, t), m: [lerp(a.m[0], b.m[0], t), lerp(a.m[1], b.m[1], t), lerp(a.m[2], b.m[2], t), lerp(a.m[3], b.m[3], t)] };
  }
  var blendFace = (a, b, t) => t <= 0 ? a : t >= 1 ? b : { left: blendEye(a.left, b.left, t), right: blendEye(a.right, b.right, t) };
  function turnEye(p, yaw, pitch) {
    const r2 = p.x * p.x + p.y * p.y;
    const z = Math.sqrt(Math.max(0.0225, 1 - r2));
    if (!yaw && !pitch) return { pose: p, z };
    const [a, b, c, d] = p.m;
    const t1 = [a, b, -(a * p.x + b * p.y) / z];
    const t2 = [c, d, -(c * p.x + d * p.y) / z];
    const pos = [p.x, p.y, z];
    const rot = (v2) => {
      const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
      const x1 = v2[0] * cy + v2[2] * sy, z1 = -v2[0] * sy + v2[2] * cy;
      const y2 = v2[1] * cp + z1 * sp, z2 = -v2[1] * sp + z1 * cp;
      return [x1, y2, z2];
    };
    const q = rot(pos), u = rot(t1), v = rot(t2);
    return { pose: { ...p, x: q[0], y: q[1], m: [u[0], u[1], v[0], v[1]] }, z: q[2] };
  }
  function turnTo(x, y, tx, ty) {
    const z = Math.sqrt(Math.max(0.0225, 1 - x * x - y * y));
    const across = Math.hypot(x, z);
    const yaw = Math.asin(clamp(tx / across, -1, 1)) - Math.atan2(x, z);
    const z1 = Math.sqrt(Math.max(0, across * across - tx * tx));
    const pitch = Math.asin(clamp(ty / Math.hypot(y, z1), -1, 1)) - Math.atan2(y, z1);
    return [yaw, pitch];
  }
  var faceCenter = (f) => [(f.left.x + f.right.x) / 2, (f.left.y + f.right.y) / 2];
  function eyeOutline(p, open, cx = p.x, cy = p.y) {
    const g = capsule(p.w / Math.max(1e-3, p.h));
    const out = make(EYE_POINTS);
    const s = clamp(open, 0.02, 1);
    const [a, b, c, d] = p.m;
    for (let i = 0; i < EYE_POINTS; i++) {
      const lx = g.x[i] * p.h, ly = g.y[i] * p.h * s;
      out.x[i] = cx + a * lx + c * ly;
      out.y[i] = cy + b * lx + d * ly;
    }
    return out;
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/prng.ts
  function mix(a, b) {
    let x = (a ^ Math.imul(b + 2654435769, 2246822507)) >>> 0;
    x = Math.imul(x ^ x >>> 16, 2146121005) >>> 0;
    x = Math.imul(x ^ x >>> 15, 2221713035) >>> 0;
    return (x ^ x >>> 16) >>> 0;
  }
  var hash = (seed, k) => mix(seed | 0, k | 0) / 4294967296;

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/animations.ts
  var CLASSIC_ANIMS = ["idle", "thinking", "wink", "wide", "alert", "notification", "exclaim", "sleep", "egg", "hexagon", "play", "orbit", "burst", "comet"];
  var ANIMS = [...CLASSIC_ANIMS, "nod", "shake", "jump", "spin", "love", "party", "dizzy", "shiver", "melt", "snooze", "rain", "loading", "check", "question"];
  var DEFAULT_DUR = {
    idle: 2.4,
    thinking: 2.6,
    wink: 1.6,
    wide: 1.8,
    alert: 2.4,
    notification: 2.2,
    exclaim: 2,
    sleep: 2.4,
    egg: 1.8,
    hexagon: 1.6,
    play: 2,
    orbit: 3.4,
    burst: 2.6,
    comet: 2.4,
    jump: 1.6,
    spin: 1.6,
    nod: 1.4,
    shake: 1.4,
    love: 2,
    dizzy: 2.2,
    melt: 2.4,
    loading: 2,
    check: 1.8,
    question: 2,
    snooze: 2.6,
    rain: 2.4,
    party: 2,
    shiver: 1.4
  };
  var PART_SLOTS = 3;
  var TRAIL_SLOTS = 12;
  var TRAIL_POINTS = 18;
  var rest = () => ({
    tx: 0,
    ty: 0,
    sx: 1,
    sy: 1,
    scale: 1,
    rot: 0,
    anchor: 0,
    yaw: 0,
    pitch: 0,
    eyes: null,
    eyesW: 0,
    expr: null,
    exprW: 0,
    eyeAlpha: 1,
    shut: 0,
    fig: null,
    figW: 0,
    holeX: 0,
    holeY: 0,
    holeR: 0,
    parts: [],
    trails: []
  });
  function pastel(h) {
    const s = 0.55, l = 0.62;
    const k = (n) => (n + h / 30) % 12;
    const a = s * Math.min(l, 1 - l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
    return "#" + [f(0), f(8), f(4)].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  }
  var ramp = (h0, span2) => [pastel(mod(h0, 360)), pastel(mod(h0 + span2 / 2, 360)), pastel(mod(h0 + span2, 360))];
  var step = (t, a, b) => ease.inOut(clamp((t - a) / (b - a), 0, 1));
  var pop = (u) => u <= 0 ? 0 : u >= 1 ? 1 : 1 - Math.exp(-7 * u) * Math.cos(u * 11);
  function arc3d(r, tiltAxis, tilt, a0, span2, cx = 0, cy = 0) {
    const pts = [];
    const z = [];
    const ca = Math.cos(tiltAxis), sa = Math.sin(tiltAxis), ct = Math.cos(tilt), st = Math.sin(tilt);
    for (let i = 0; i < TRAIL_POINTS; i++) {
      const a = a0 + span2 * i / (TRAIL_POINTS - 1);
      const x0 = r * Math.cos(a), y0 = r * Math.sin(a) * ct, z0 = r * Math.sin(a) * st;
      pts.push([cx + x0 * ca - y0 * sa, cy + x0 * sa + y0 * ca]);
      z.push(z0);
    }
    return { pts, z };
  }
  function halves(arc, colors, width, alpha) {
    const fill = (keep) => {
      const kept = arc.pts.filter((_, i) => keep(arc.z[i]));
      if (kept.length < 2) return null;
      return Array.from({ length: TRAIL_POINTS }, (_, i) => kept[Math.round(i / (TRAIL_POINTS - 1) * (kept.length - 1))]);
    };
    const b = fill((z) => z < 0), f = fill((z) => z >= 0);
    return [
      { pts: b ?? arc.pts, colors, width, alpha: b ? alpha : 0, front: false },
      { pts: f ?? arc.pts, colors, width, alpha: f ? alpha : 0, front: true }
    ];
  }
  var wave = (v) => Math.sin(Math.PI * clamp(v, 0, 1));
  function hop(u, height = 0.33) {
    const a = clamp((u - 0.2) / 0.45, 0, 1);
    const e = 0.08 * wave(a) - 0.16 * wave(u / 0.22) - 0.09 * wave((u - 0.65) / 0.35);
    return { sx: 1 - 0.7 * e, sy: 1 + e, ty: 4 * height * a * (a - 1), anchor: 1 };
  }
  var span = (t, d, a = 0.15, b = 0.2) => clamp(t / a, 0, 1) * clamp((d - t) / b, 0, 1);
  function exclamation(x, y, rot, gap, dotR) {
    return {
      fig: "stem",
      figW: 1,
      rot,
      tx: x,
      ty: y,
      eyeAlpha: 0,
      parts: [{ x: x - gap * Math.sin(rot), y: y + gap * Math.cos(rot), r: dotR, alpha: 1, color: null }]
    };
  }
  var CLIPS = {
    // breathing, blinks and glances come from underneath (motion.ts)
    idle: () => ({}),
    // three dots; one at a time grows and darkens: right, left, middle, and again
    thinking: (t) => {
      const order = [2, 0, 1];
      const k = Math.floor((t + 0.23) / 0.5);
      const into = smooth((t + 0.23 - k * 0.5) / 0.13);
      const now = order[mod(k, 3)], before = order[mod(k - 1, 3)];
      const act = (j) => (j === now ? k === 0 ? 1 : into : 0) + (j === before && k > 0 ? 1 - into : 0);
      const r = (j) => lerp(0.164, 0.207, act(j));
      const o = (j) => lerp(0.55, 1, act(j));
      return {
        fig: "circle",
        figW: 1,
        scale: r(1),
        eyeAlpha: 0,
        parts: [
          { x: -0.555, y: 0, r: r(0), alpha: o(0), color: null },
          { x: 0.54, y: 0, r: r(2), alpha: o(2), color: null }
        ]
      };
    },
    // the right eye closes into a line
    wink: () => ({ eyes: STATE_EYES.wink, eyesW: 1 }),
    // big eyes, looking down and to the right
    wide: () => ({ eyes: STATE_EYES.wide, eyesW: 1 }),
    // a leaning "!" slides to the right, waits, and comes back
    alert: (t, d) => {
      const k = d / 2.4;
      const x = lerp(lerp(-0.07, 0.73, step(t, 0.5 * k, 1.4 * k)), 0.1, step(t, 1.6 * k, 2 * k));
      return exclamation(x, -0.33, 0.305, 0.6, 0.12);
    },
    // a blue badge pops in a gap at the top right; the eyes look away
    notification: (t) => {
      const p = pop(t / 0.3);
      return {
        eyes: STATE_EYES.notification,
        eyesW: 1,
        holeX: 0.75,
        holeY: -0.67,
        holeR: 0.205 * p,
        parts: [{ x: 0.75, y: -0.67, r: 0.15 * p, alpha: clamp(p * 4, 0, 1), color: "#2496e8" }]
      };
    },
    // an upright "!"
    exclaim: () => exclamation(0, -0.215, 0, 0.745, 0.11),
    // a small dot bobbing up and down
    sleep: (t) => ({ fig: "circle", figW: 1, scale: 0.16, ty: 0.11 - 0.19 * Math.cos(TAU * (t - 0.47) / 0.6), eyeAlpha: 0 }),
    egg: () => ({ fig: "egg", figW: 1, eyes: STATE_EYES.egg, eyesW: 1 }),
    hexagon: () => ({ fig: "hexa", figW: 1, eyes: STATE_EYES.hexa, eyesW: 1 }),
    // a play triangle, a ribbon of four colored lines going around it
    // the ribbon runs on a narrow tilted orbit: in front from the top right to the bottom left, then back behind
    play: (t, d) => {
      const w = clamp(t / 0.15, 0, 1) * clamp((d - t) / 0.2, 0, 1);
      const head = Math.PI * (t - 0.1) / 1.05;
      const trails = [0, 1, 2, 3].flatMap((k) => halves(arc3d(1.1 + 0.15 * k, -0.5, 1.45, head - 1.55, 1.55, 0.02, 0.05), ramp(95 + 62 * k, 100), 0.05, w));
      return { fig: "play", figW: 1, eyes: STATE_EYES.play, eyesW: 1, trails };
    },
    // the triangle spins while six rings turn around it
    orbit: (t, d) => {
      const trails = [0, 1, 2, 3, 4, 5].flatMap((k) => {
        const w = smooth((t - 0.15 - 0.08 * k) / 0.25) * clamp((d - t) / 0.3, 0, 1);
        const axis = k * Math.PI / 6 + 0.3 * t;
        const colors = ramp(4 + 60 * k, 62);
        const back = arc3d(1.37, axis, 1.25, Math.PI, Math.PI, 0, 0.03);
        const front = arc3d(1.37, axis, 1.25, 0, Math.PI, 0, 0.03);
        return [
          { pts: back.pts, colors, width: 0.055, alpha: w, front: false },
          { pts: front.pts, colors, width: 0.055, alpha: w, front: true }
        ];
      });
      const spin = smooth(t / 0.3) * smooth((d - t) / 0.4);
      const a = -9.1 * t * spin;
      return { fig: "play", figW: 1, eyes: STATE_EYES.play, eyesW: 1, rot: a, yaw: -a * 0.5, trails };
    },
    // shrinks to a dot that pulls in grey bits, then bursts back
    burst: (t, d, seed) => {
      const k = d / 2.6;
      const back = step(t, 1.75 * k, 2.1 * k);
      const parts = [0, 1, 2].map((i) => {
        const n = Math.floor((t - 0.1 - 0.15 * i) / 0.45);
        const u = (t - 0.1 - 0.15 * i - n * 0.45) / 0.45;
        const live2 = n >= 0 && t < 1.55 * k;
        const a = hash(seed, i * 31 + n) * TAU;
        const r = lerp(0.55, 0.08, ease.in(u));
        return { x: Math.sin(a) * r, y: -Math.cos(a) * r, r: lerp(0.04, 0.07, u), alpha: live2 ? smooth(u * 4) * (1 - smooth((u - 0.85) / 0.15)) : 0, color: null };
      });
      return { fig: "circle", figW: 1 - back, scale: lerp(0.165, 1, back), eyeAlpha: back, parts };
    },
    // a tiny dot with a rainbow tail circling it, in front and behind
    comet: (t, d) => {
      const k = d / 2.4;
      const back = step(t, 1.85 * k, 2.05 * k);
      const on = smooth((t - 0.12) / 0.15) * (1 - smooth((t - 1.8 * k) / (0.12 * k)));
      const head = 2.2 + (t - 0.27) * TAU / 1.65;
      const trails = [0, 1, 2, 3].flatMap((i) => halves(arc3d(0.82, 0.54, 1.45, head - 1.3, 1.3, 0, 0.02 + 0.04 * (i - 1.5)), ramp(4 + 88 * i, 85), 0.095, on));
      return { fig: "circle", figW: 1 - back, scale: lerp(0.13, 1, back), eyeAlpha: back, ty: 0.02 * (1 - back), trails };
    },
    // two hops, looking up in the air
    jump: (t, d) => {
      const u = t % (d / 2) / (d / 2);
      return { ...hop(u), pitch: -0.25 * wave((u - 0.2) / 0.45) };
    },
    // a full turn on the spot: the eyes go round the back, the body narrows side on
    spin: (t) => {
      const a = TAU * ease.inOut(clamp((t - 0.15) / 1.15, 0, 1));
      return { yaw: a, sx: 0.8 + 0.2 * Math.abs(Math.cos(a)), ty: -0.06 * wave((t - 0.15) / 1.15) };
    },
    // yes: two nods
    nod: (t) => {
      const u = clamp((t - 0.1) / 1, 0, 1);
      const n = Math.sin(TAU * 2 * u) * wave(u);
      return { pitch: 0.38 * Math.max(0, n) - 0.12 * Math.max(0, -n), ty: 0.03 * Math.max(0, n), sy: 1 - 0.03 * Math.max(0, n), anchor: 1 };
    },
    // no: shakes the head three times, smaller each time
    shake: (t) => {
      const u = clamp((t - 0.1) / 1.1, 0, 1);
      const n = Math.sin(TAU * 3 * u) * (1 - u) * smooth(u * 6);
      return { yaw: 0.5 * n, tx: 0.03 * n, rot: 0.03 * n };
    },
    // turns into a heart that beats twice a second, happy
    love: (t) => {
      const b = t % 1;
      const beat = 0.09 * wave(b / 0.16) + 0.06 * wave((b - 0.22) / 0.18);
      return { fig: "heart", figW: 1, scale: 1 + beat, expr: "happy", exprW: 1 };
    },
    // the eyes go round and round, the body sways
    dizzy: (t, d) => {
      const w = span(t, d, 0.3, 0.3);
      const a = TAU * 1.4 * t;
      return { yaw: 0.32 * Math.cos(a) * w, pitch: 0.26 * Math.sin(a) * w, rot: 0.12 * Math.sin(TAU * 0.7 * t) * w, tx: 0.05 * Math.sin(TAU * 0.7 * t) * w, expr: "confused", exprW: 0.6 };
    },
    // melts into a puddle, eyes half shut, and springs back up
    melt: (t, d) => {
      const down = step(t, 0.1, 0.8) * (1 - pop(clamp((t - (d - 0.65)) / 0.65, 0, 1)));
      return { sy: 1 - 0.42 * down, sx: 1 + 0.32 * down, anchor: 1, shut: 0.4 * down, pitch: 0.2 * down };
    },
    // a ring turns around it like a spinner, and the eyes follow its head
    loading: (t, d) => {
      const w = span(t, d, 0.2, 0.25);
      const head = TAU * t / 0.9 - Math.PI / 2;
      const len = 1.1 + 0.8 * Math.sin(TAU * t / 1.8);
      const trails = halves(arc3d(1.28, 0, 0.35, head - len, len, 0, 0), ramp(70, 60), 0.075, w);
      return { trails, yaw: 0.22 * Math.cos(head) * w, pitch: 0.16 * Math.sin(head) * w };
    },
    // done: turns into a check mark that pops in
    check: (t) => ({ fig: "check", figW: 1, eyeAlpha: 0, scale: lerp(0.7, 1, pop(t / 0.45)), rot: -0.08 * (1 - pop(t / 0.45)) }),
    // a "?" that tilts its head
    question: (t) => {
      const r = 0.14 * Math.sin(TAU * 0.6 * t);
      return { fig: "hook", figW: 1, eyeAlpha: 0, rot: r, ty: -0.1, parts: [{ x: 0.02 - 0.9 * Math.sin(r), y: -0.1 + 0.9 * Math.cos(r), r: 0.13, alpha: 1, color: null }] };
    },
    // a nap: eyes shut, slow deep breaths, bubbles rising from the top
    snooze: (t) => {
      const breath2 = Math.sin(TAU * t / 1.3);
      const parts = [0, 1, 2].map((i) => {
        const u = mod((t - 0.43 * i) / 1.3, 1);
        return { x: 0.62 + 0.38 * u, y: -0.72 - 0.62 * u, r: lerp(0.045, 0.12, u), alpha: smooth(u * 5) * (1 - smooth((u - 0.7) / 0.3)), color: null };
      });
      return { shut: 0.88, sy: 1 + 0.035 * breath2, sx: 1 - 0.02 * breath2, anchor: 1, pitch: 0.12, parts };
    },
    // a sad cloud, three drops falling from it
    rain: (t) => {
      const parts = [0, 1, 2].map((i) => {
        const u = mod((t - 0.27 * i) / 0.8, 1);
        return { x: [-0.42, 0.06, 0.5][i], y: lerp(0.8, 1.55, ease.in(u)), r: 0.075, alpha: smooth(u * 6) * (1 - smooth((u - 0.75) / 0.25)), color: "#5aaaf2" };
      });
      return { fig: "cloud", figW: 1, expr: "sad", exprW: 1, ty: -0.12 + 0.03 * Math.sin(TAU * t / 1.2), parts };
    },
    // a hop and a burst of streamers, very happy
    party: (t) => {
      const trails = Array.from({ length: TRAIL_SLOTS }, (_, k) => {
        const a = k * TAU / TRAIL_SLOTS + 0.2 * (k % 2);
        const u = clamp((t - 0.35 - 0.03 * (k % 3)) / 0.9, 0, 1);
        const r0 = lerp(1.05, 1.5, ease.out(u)), r1 = r0 + 0.32 * (1 - u * 0.6);
        const pts = Array.from({ length: TRAIL_POINTS }, (_2, i) => {
          const r = lerp(r0, r1, i / (TRAIL_POINTS - 1));
          const bend = 0.18 * (i / (TRAIL_POINTS - 1)) * (k % 2 ? 1 : -1);
          return [r * Math.sin(a + bend), -r * Math.cos(a + bend) + 0.05];
        });
        return { pts, colors: ramp(10 + 30 * k, 50), width: 0.06, alpha: u > 0 ? wave(u) : 0, front: k % 2 === 1 };
      });
      return { ...hop(clamp(t / 0.9, 0, 1)), expr: "excited", exprW: 1, trails };
    },
    // shivers with fear
    shiver: (t, d) => {
      const w = span(t, d, 0.15, 0.2);
      return { tx: 0.028 * Math.sin(TAU * 13 * t) * w, rot: 0.025 * Math.sin(TAU * 9 * t + 1) * w, sx: 1 - 0.03 * w, sy: 1 - 0.04 * w, anchor: 1, expr: "scared", exprW: 1 };
    }
  };
  function clipPose(anim, t, d, seed) {
    return { ...rest(), ...CLIPS[anim](clamp(t, 0, d), d, seed) };
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/color.ts
  var isHex = (s) => typeof s === "string" && /^#?[0-9a-f]{6}$/i.test(s);
  function toRgb(hex2) {
    const h = hex2.replace("#", "");
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  var lin = (v) => (v /= 255) <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  function toLab([r, g, b]) {
    const [R, G, B] = [lin(r), lin(g), lin(b)];
    const l = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
    const m = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
    const s = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
    return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s, 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s];
  }
  var lightness = (hex2) => toLab(toRgb(hex2))[0];
  var autoEyeColor = (body) => lightness(body) > 0.86 ? "#141416" : "#ffffff";

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/shapes.ts
  var BODY_POINTS = 56;
  var SHAPES = ["circle", "pebble", "squircle", "capsule", "triangle", "diamond", "hexagon", "star", "cloud", "droplet", "heart", "ghost", "cat", "bear", "bunny", "amoeba", "flower", "clover", "leaf", "gem", "bubble"];
  function polar(r, samples = 720) {
    return Array.from({ length: samples }, (_, i) => {
      const a = i / samples * TAU;
      const rr = r(a);
      return [rr * Math.sin(a), -rr * Math.cos(a)];
    });
  }
  var series = (c) => (a) => {
    let r = c[0];
    for (let k = 1; 2 * k <= c.length; k++) r += c[2 * k - 1] * Math.cos(k * a) + (c[2 * k] ?? 0) * Math.sin(k * a);
    return r;
  };
  function unionRay(circles, a) {
    const dx = Math.sin(a), dy = -Math.cos(a);
    let best = 0;
    for (const [cx, cy, r] of circles) {
      const b = dx * cx + dy * cy;
      const disc2 = b * b - (cx * cx + cy * cy - r * r);
      if (disc2 >= 0) best = Math.max(best, b + Math.sqrt(disc2));
    }
    return best;
  }
  var cosines = (c) => (a) => c.reduce((r, v, k) => r + v * Math.cos(k * a), 0);
  function roundedPolygon(verts, radius, perCorner = 24) {
    const pts = [];
    const n = verts.length;
    for (let i = 0; i < n; i++) {
      const [px, py] = verts[(i - 1 + n) % n];
      const [cx, cy] = verts[i];
      const [nx, ny] = verts[(i + 1) % n];
      const la = Math.hypot(px - cx, py - cy), lb = Math.hypot(nx - cx, ny - cy);
      const ux = (px - cx) / la, uy = (py - cy) / la, vx = (nx - cx) / lb, vy = (ny - cy) / lb;
      const half = Math.acos(Math.max(-1, Math.min(1, ux * vx + uy * vy))) / 2;
      const cut = Math.min(radius / Math.tan(half), la / 2, lb / 2);
      const r = cut * Math.tan(half);
      const bx = ux + vx, by = uy + vy;
      const bl = Math.hypot(bx, by) || 1;
      const dist = r / Math.sin(half);
      const ox = cx + bx / bl * dist, oy = cy + by / bl * dist;
      const a0 = Math.atan2(cy + uy * cut - oy, cx + ux * cut - ox);
      let da = Math.atan2(cy + vy * cut - oy, cx + vx * cut - ox) - a0;
      while (da > Math.PI) da -= TAU;
      while (da < -Math.PI) da += TAU;
      for (let k = 0; k <= perCorner; k++) pts.push([ox + r * Math.cos(a0 + da * k / perCorner), oy + r * Math.sin(a0 + da * k / perCorner)]);
    }
    return pts;
  }
  function taper(rt, rb, h, n = 360) {
    const yt = -h / 2 + rt, yb = h / 2 - rb;
    const a = Math.asin((rt - rb) / (yb - yt));
    const pts = [];
    for (let i = 0; i <= n / 2; i++) {
      const t = Math.PI - a + (Math.PI + 2 * a) * i / (n / 2);
      pts.push([rt * Math.cos(t), yt + rt * Math.sin(t)]);
    }
    for (let i = 0; i <= n / 2; i++) {
      const t = -a + (Math.PI + 2 * a) * i / (n / 2);
      pts.push([rb * Math.cos(t), yb + rb * Math.sin(t)]);
    }
    return pts;
  }
  var stadium = (w, h) => roundedPolygon([[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]], Math.min(w, h) / 2 * 0.999);
  var regular = (n, R, turn = 0) => Array.from({ length: n }, (_, i) => [R * Math.sin(turn + i * TAU / n), -R * Math.cos(turn + i * TAU / n)]);
  function heartCurve(p, s, d, m, samples = 1440) {
    return Array.from({ length: samples }, (_, i) => {
      const t = i / samples * TAU;
      const x = 16 * Math.sign(Math.sin(t)) * Math.abs(Math.sin(t)) ** p;
      const y = -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t) + d * Math.cos(t / 2) ** (2 * m));
      return [x * s, y * s];
    });
  }
  function ghostOutline(r, top, hem, amp) {
    const pts = [];
    for (let i = 0; i <= 180; i++) pts.push([-r * Math.cos(Math.PI * i / 180), top - r * Math.sin(Math.PI * i / 180)]);
    for (let i = 0; i <= 360; i++) pts.push([r - 2 * r * i / 360, hem + amp * Math.abs(Math.sin(3 * Math.PI * i / 360))]);
    return pts;
  }
  var ring = (cx, cy, r, n = 360) => Array.from({ length: n }, (_, i) => [cx + r * Math.sin(i / n * TAU), cy - r * Math.cos(i / n * TAU)]);
  var place = (pts, a, dx = 0, dy = 0) => pts.map(([x, y]) => [x * Math.cos(a) - y * Math.sin(a) + dx, x * Math.sin(a) + y * Math.cos(a) + dy]);
  function stroke(path, half, cap = 24) {
    const n = path.length;
    const side = (sign) => path.map((p, i) => {
      const a = path[Math.max(0, i - 1)], b = path[Math.min(n - 1, i + 1)];
      const n1 = norm(i > 0 ? [p[1] - a[1], a[0] - p[0]] : [b[1] - p[1], p[0] - b[0]]);
      const n2 = norm(i < n - 1 ? [b[1] - p[1], p[0] - b[0]] : n1);
      const m = norm([n1[0] + n2[0], n1[1] + n2[1]]);
      const k = half / Math.max(0.35, m[0] * n1[0] + m[1] * n1[1]);
      return [p[0] + sign * m[0] * k, p[1] + sign * m[1] * k];
    });
    const left = side(1), right = side(-1).reverse();
    const arc = (c, from) => {
      const a0 = Math.atan2(from[1] - c[1], from[0] - c[0]);
      return Array.from({ length: cap }, (_, i) => [c[0] + half * Math.cos(a0 + Math.PI * (i + 1) / (cap + 1)), c[1] + half * Math.sin(a0 + Math.PI * (i + 1) / (cap + 1))]);
    };
    return [...left, ...arc(path[n - 1], left[n - 1]), ...right, ...arc(path[0], right[n - 1])];
  }
  var norm = (v) => {
    const l = Math.hypot(v[0], v[1]) || 1;
    return [v[0] / l, v[1] / l];
  };
  var disk = (cx, cy, r) => (x, y) => Math.hypot(x - cx, y - cy) - r;
  var pill = (ax, ay, bx, by, r) => (x, y) => {
    const ex = bx - ax, ey = by - ay, wx = x - ax, wy = y - ay;
    const t = Math.max(0, Math.min(1, (wx * ex + wy * ey) / (ex * ex + ey * ey)));
    return Math.hypot(wx - ex * t, wy - ey * t) - r;
  };
  var grown = (v, r) => (x, y) => {
    let d = Infinity, inside = false;
    for (let i = 0, j = v.length - 1; i < v.length; j = i++) {
      const [ax, ay] = v[j], [bx, by] = v[i];
      const ex = bx - ax, ey = by - ay, wx = x - ax, wy = y - ay;
      const t = Math.max(0, Math.min(1, (wx * ex + wy * ey) / (ex * ex + ey * ey)));
      d = Math.min(d, Math.hypot(wx - ex * t, wy - ey * t));
      if (ay > y !== by > y && x < (bx - ax) * (y - ay) / (by - ay) + ax) inside = !inside;
    }
    return (inside ? -d : d) - r;
  };
  var joined = (k, ...parts) => (x, y) => parts.reduce((a, f) => {
    const b = f(x, y);
    const h = Math.max(k - Math.abs(a - b), 0) / k;
    return Math.min(a, b) - h * h * k / 4;
  }, Infinity);
  var traced = (f) => polar((a) => {
    const dx = Math.sin(a), dy = -Math.cos(a);
    let r = 1.8;
    while (r > 0 && f(r * dx, r * dy) > 0) r -= 0.01;
    let lo = r, hi = r + 0.01;
    for (let i = 0; i < 24; i++) {
      const mid = (lo + hi) / 2;
      if (f(mid * dx, mid * dy) > 0) hi = mid;
      else lo = mid;
    }
    return lo;
  }, 1440);
  var catHead = () => ring(0, 0.15, 0.95);
  var bunnyHead = () => ring(0, 0.32, 0.82);
  var OUTLINES = {
    circle: () => polar(() => 1),
    // a river stone: wider than tall, a little fuller on the right
    pebble: () => polar(series([0.9328, 0.0221, 0.01, -0.0585, 0.0325, -0.0297, 0.0163, -15e-4, -2e-4])),
    // a superellipse between a circle and a square
    squircle: () => polar((a) => ((Math.abs(Math.sin(a)) / 0.959) ** 4.179 + (Math.abs(Math.cos(a)) / 0.9552) ** 4.179) ** (-1 / 4.179)),
    capsule: () => stadium(2.0778, 1.2438),
    triangle: () => roundedPolygon([[0, -1.5296], [1.2656, 0.647], [-1.2656, 0.647]], 0.3402),
    // a rhombus, taller than wide
    diamond: () => roundedPolygon([[0, -1.2], [1, 0], [0, 1.2], [-1, 0]], 0.3),
    // flat on top and bottom, a corner on each side
    hexagon: () => roundedPolygon([[-0.5401, -0.9368], [0.5401, -0.9368], [1.0802, 0], [0.5401, 0.9368], [-0.5401, 0.9368], [-1.0802, 0]], 0.2598),
    // five plump points
    star: () => roundedPolygon(regular(10, 1).map(([x, y], i) => [x * (i % 2 ? 0.66 : 1.2), y * (i % 2 ? 0.66 : 1.2)]), 0.18),
    // a cloud: five round bumps
    cloud: () => polar((a) => unionRay([[0.4723, 0.1392, 0.4949], [0.03, 0.2334, 0.6002], [-0.4322, 0.139, 0.535], [-0.2296, -0.3544, 0.4792], [0.3097, -0.2956, 0.4386]], a), 1440),
    // a drop, its soft tip up
    droplet: () => polar(cosines([0.7341, -0.1584, 0.1602, 0.0675, 0.0383, 0.0278, 0.0236, 0.0189, 0.014, 0.0109, 95e-4, 83e-4, 67e-4, 55e-4, 5e-3, 44e-4, 38e-4, 32e-4, 3e-3, 27e-4, 24e-4]), 1440),
    // a heart: two lobes on top, a soft point at the bottom
    heart: () => heartCurve(2.5, 0.062, 4, 8),
    // a dome, straight sides and a hem with three scallops
    ghost: () => ghostOutline(0.86, -0.13, 0.77, 0.2),
    // a round head with two pointed ears
    cat: () => traced(joined(0.09, disk(0, 0.15, 0.95), grown([[-0.66, -0.36], [-0.76, -0.94], [-0.26, -0.68]], 0.09), grown([[0.66, -0.36], [0.76, -0.94], [0.26, -0.68]], 0.09))),
    // a round head with two round ears
    bear: () => traced(joined(0.14, disk(0, 0.15, 0.95), disk(-0.68, -0.6, 0.33), disk(0.68, -0.6, 0.33))),
    // a round head with two long ears, leaning out
    bunny: () => traced(joined(0.14, disk(0, 0.32, 0.82), pill(-0.27, -0.16, -0.4, -0.8, 0.18), pill(0.27, -0.16, 0.4, -0.8, 0.18))),
    // six round petals around a round middle
    flower: () => traced(joined(0.1, disk(0, 0, 0.74), ...Array.from({ length: 6 }, (_, i) => disk(0.66 * Math.sin(i * TAU / 6), -0.66 * Math.cos(i * TAU / 6), 0.4)))),
    // a speech bubble: a soft square with a tail at the bottom left
    bubble: () => traced(joined(0.14, grown([[-0.52, -0.34], [0.52, -0.34], [0.52, 0.24], [-0.52, 0.24]], 0.48), grown([[-0.7, 0.36], [-0.3, 0.6], [-0.76, 1.04]], 0.06))),
    // an amoeba: a blob with soft uneven lobes
    amoeba: () => polar((a) => 0.93 + 0.075 * Math.cos(2 * a + 0.7) + 0.065 * Math.sin(3 * a + 0.2) + 0.035 * Math.cos(5 * a + 1.3)),
    // a cut gem: flat top, slanted shoulders, a point at the bottom
    gem: () => roundedPolygon([[-0.56, -0.88], [0.56, -0.88], [1.06, -0.3], [0, 1.08], [-1.06, -0.3]], 0.16),
    // four round leaves
    clover: () => traced(joined(0.12, disk(-0.43, -0.43, 0.53), disk(0.43, -0.43, 0.53), disk(0.43, 0.43, 0.53), disk(-0.43, 0.43, 0.53))),
    // a leaf: two arcs meeting in points, leaning to the right
    leaf: () => place([...ring(0.36, 0, 1.11, 720).filter(([x]) => x <= 1e-3), ...ring(-0.36, 0, 1.11, 720).filter(([x]) => x >= -1e-3)].sort((p, q) => Math.atan2(p[0], -p[1]) - Math.atan2(q[0], -q[1])), 0.55),
    egg: () => polar(series([0.8993, -0.0294, -22e-4, 0.0888, -56e-4, 0.0221, -24e-4, 0.013, -16e-4])),
    // a hexagon standing on a corner
    hexa: () => roundedPolygon(regular(6, 1.0483, -0.0273), 0.3179),
    // the play triangle, pointing up and a little to the right
    play: () => roundedPolygon(regular(3, 1.3965, 0.104).map(([x, y]) => [x, y * 1.0083]), 0.277),
    // the stem of a "!": round, wider at the top
    stem: () => taper(0.131, 0.085, 0.84),
    // a check mark, thick and round at the ends
    check: () => stroke([[-0.7, -0.02], [-0.22, 0.46], [0.74, -0.52]], 0.21),
    // the hook of a "?": most of a circle, then a short drop
    hook: () => stroke([...Array.from({ length: 28 }, (_, i) => {
      const a = -2.5 + i / 27 * 3.6;
      return [0.4 * Math.cos(a), -0.3 + 0.4 * Math.sin(a)];
    }), [0.02, 0.28]], 0.17)
  };
  var START = { heart: "axis" };
  var DROP = { heart: 0.09 };
  var FACE = { cat: catHead, bear: catHead, bunny: bunnyHead };
  var FACE_SIZE = { cat: 0.95, bear: 0.95, bunny: 0.82 };
  var faceSize = (shape) => FACE_SIZE[shape] ?? 1;
  var cache2 = /* @__PURE__ */ new Map();
  var offsets = /* @__PURE__ */ new Map();
  function shapeContour(fig) {
    const hit = cache2.get(fig);
    if (hit) return hit;
    const c = resample(OUTLINES[fig](), BODY_POINTS, { start: START[fig] });
    const b = bounds(c);
    const cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2 - (DROP[fig] ?? 0);
    for (let i = 0; i < BODY_POINTS; i++) {
      c.x[i] -= cx;
      c.y[i] -= cy;
    }
    cache2.set(fig, c);
    offsets.set(fig, [cx, cy]);
    return c;
  }
  function faceContour(shape) {
    const head = FACE[shape];
    if (!head) return shapeContour(shape);
    shapeContour(shape);
    const [cx, cy] = offsets.get(shape);
    const c = resample(head(), BODY_POINTS);
    for (let i = 0; i < BODY_POINTS; i++) {
      c.x[i] -= cx;
      c.y[i] -= cy;
    }
    return c;
  }
  var RAYS = 128;
  var reach = /* @__PURE__ */ new Map();
  function edgeAt(shape, angle) {
    let table = reach.get(shape);
    if (!table) {
      const c = faceContour(shape);
      const n = c.x.length;
      table = new Float64Array(RAYS);
      for (let i2 = 0; i2 < RAYS; i2++) {
        const a = i2 / RAYS * TAU, dx = Math.sin(a), dy = -Math.cos(a);
        let best = 0;
        for (let k = 0; k < n; k++) {
          const x1 = c.x[k], y1 = c.y[k], x2 = c.x[(k + 1) % n], y2 = c.y[(k + 1) % n];
          const ex = x2 - x1, ey = y2 - y1, den = dx * ey - dy * ex;
          if (Math.abs(den) < 1e-12) continue;
          const t = (x1 * ey - y1 * ex) / den, u2 = (x1 * dy - y1 * dx) / den;
          if (t > 0 && u2 >= -1e-9 && u2 <= 1 + 1e-9) best = Math.max(best, t);
        }
        table[i2] = best;
      }
      reach.set(shape, table);
    }
    const f = angle / TAU * RAYS % RAYS;
    const i = Math.floor(f < 0 ? f + RAYS : f);
    const u = (f < 0 ? f + RAYS : f) - i;
    return table[i] * (1 - u) + table[(i + 1) % RAYS] * u;
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/state.ts
  var MAX_CLIPS = 24;
  var DEFAULT_CYCLE = CLASSIC_ANIMS.map((anim) => ({ anim, dur: DEFAULT_DUR[anim] }));
  var DEFAULT_STATE = {
    v: 2,
    shape: "circle",
    color: "#aefa0e",
    expression: "neutral",
    cycle: DEFAULT_CYCLE,
    seed: 1
  };
  var cloneState = (s) => ({ ...s, cycle: s.cycle.map((c) => ({ ...c })) });
  var loopLength = (s) => s.cycle.reduce((n, c) => n + c.dur, 0);

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/motion.ts
  var NUMERIC = ["tx", "ty", "sx", "sy", "scale", "rot", "anchor", "yaw", "pitch", "eyeAlpha", "shut", "holeX", "holeY", "holeR"];
  var XFADE = 0.3;
  var xfade = (u) => (1 - Math.exp(-u / 0.075)) / (1 - Math.exp(-XFADE / 0.075));
  var fit = (p, loop2) => loop2 > 0 ? loop2 / Math.max(1, Math.round(loop2 / p)) : p;
  var join = (a, b, k, w) => [...a, ...b].map((x, i) => ({ ...x, [k]: x[k] * (i < a.length ? 1 - w : w) }));
  function toMotion(p) {
    const { expr, exprW, fig, figW, eyes, eyesW, ...rest2 } = p;
    return {
      ...rest2,
      exprs: expr ? [{ expr, w: exprW }] : [],
      figs: fig ? [{ fig, w: figW }] : [],
      faces: eyes ? [{ face: eyes, w: eyesW }] : []
    };
  }
  function mixMotion(a, b, w) {
    const out = {
      ...b,
      exprs: join(a.exprs, b.exprs, "w", w),
      figs: join(a.figs, b.figs, "w", w),
      faces: join(a.faces, b.faces, "w", w),
      parts: join(a.parts, b.parts, "alpha", w),
      trails: join(a.trails, b.trails, "alpha", w)
    };
    for (const k of NUMERIC) out[k] = lerp(a[k], b[k], w);
    return out;
  }
  function sequenceAt(state, t) {
    const seq = state.cycle.length ? state.cycle : [{ anim: "idle", dur: 2.4 }];
    const L = loopLength({ ...state, cycle: seq });
    const local = mod(t, L);
    let start = 0;
    let i = 0;
    while (i < seq.length - 1 && local >= start + seq[i].dur) start += seq[i++].dur;
    const tau = local - start;
    const cur = clipPose(seq[i].anim, tau, seq[i].dur, state.seed + i * 101);
    if (seq.length < 2 || tau >= XFADE) return toMotion(cur);
    const j = (i - 1 + seq.length) % seq.length;
    const prev = clipPose(seq[j].anim, seq[j].dur, seq[j].dur, state.seed + j * 101);
    const out = mixMotion(toMotion(prev), toMotion(cur), xfade(tau));
    if (prev.eyes !== cur.eyes || prev.eyeAlpha !== cur.eyeAlpha) out.shut = Math.max(out.shut, 0.94 * Math.sqrt(Math.sin(Math.PI * Math.min(1, tau / 0.2))));
    return out;
  }
  function breath(t, loop2) {
    return 1 + 5e-3 * Math.sin(TAU * t / fit(3.4, loop2));
  }
  function wander(t, seed, loop2) {
    const ph = (k) => hash(seed, k) * TAU;
    const s = (p, k) => Math.sin(TAU * t / fit(p, loop2) + ph(k));
    return [0.055 * s(4.3, 1) + 0.03 * s(2.7, 2), 0.045 * s(3.7, 3) + 0.025 * s(5.9, 4)];
  }
  function blink(t, seed, loop2) {
    const win = fit(3.4, loop2);
    const k = Math.floor(t / win);
    const kk = Math.floor(mod(k, Math.max(1, Math.round(loop2 / win)) || 1e9));
    const offset = 0.3 + hash(seed, kk + 7) * (win - 0.75);
    const u = (t - k * win - offset) / 0.233;
    return u > 0 && u < 1 ? 1 - 0.57 * Math.sin(Math.PI * u) ** 1.2 : 1;
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/frame.ts
  var VIEW = 200;
  var RADIUS = 62;
  var envelope = (t, dur) => smooth(Math.min(t / 0.12, (dur - t) / 0.2));
  var POKE = { anim: "wink", dur: 0.8, hop: true };
  var wave2 = (v) => Math.sin(Math.PI * clamp(v, 0, 1));
  var dot = (x, y, r) => {
    const out = make(EYE_POINTS);
    for (let k = 0; k < EYE_POINTS; k++) [out.x[k], out.y[k]] = [(x + disc.x[k] * r) * RADIUS, (y + disc.y[k] * r) * RADIUS];
    return out;
  };
  var LOOK_X = 0.48;
  var LOOK_Y = 0.44;
  var OWN = 0.12;
  var EYE_GAP = 0.03;
  function clear(a, b, s) {
    const at = (e, i) => [e.x + (e.c.x[i] - e.x) * s, e.y + (e.c.y[i] - e.y) * s];
    for (const [p, q] of [[a, b], [b, a]]) {
      for (let i = 0; i < EYE_POINTS; i++) {
        const [x, y] = at(p, i);
        let out = -Infinity;
        for (let j = 0, k = EYE_POINTS - 1; j < EYE_POINTS; k = j++) {
          const [x1, y1] = at(q, k), [x2, y2] = at(q, j);
          const side = (u, v) => ((u - x1) * (y2 - y1) - (v - y1) * (x2 - x1)) / (Math.hypot(x2 - x1, y2 - y1) || 1);
          out = Math.max(out, side(x, y) * -Math.sign(side(q.x, q.y)));
        }
        if (out < EYE_GAP) return false;
      }
    }
    return true;
  }
  function apart(a, b) {
    const weight = Math.min(a.alpha, b.alpha);
    if (weight <= 0 || clear(a, b, 1)) return;
    let lo = 0.6, hi = 1;
    for (let i = 0; i < 7; i++) {
      const mid = (lo + hi) / 2;
      if (clear(a, b, mid)) lo = mid;
      else hi = mid;
    }
    const s = 1 - (1 - lo) * weight;
    for (const e of [a, b]) for (let i = 0; i < EYE_POINTS; i++) [e.c.x[i], e.c.y[i]] = [e.x + (e.c.x[i] - e.x) * s, e.y + (e.c.y[i] - e.y) * s];
  }
  function frame(state, t, input = {}) {
    const L = loopLength(state) || 2.4;
    const still = !!input.still;
    let m = sequenceAt(state, still ? 0 : t);
    if (still) {
      Object.assign(m, { tx: 0, ty: 0, sx: 1, sy: 1, scale: 1, rot: 0, yaw: 0, pitch: 0, eyeAlpha: 1, shut: 0, holeR: 0 });
      m.exprs = [];
      m.figs = [];
      m.faces = [];
      m.parts = [];
      m.trails = [];
    }
    const r = input.react;
    if (r) {
      const w = envelope(r.t, r.dur);
      m = mixMotion(m, toMotion(clipPose(r.anim, r.t, r.dur, state.seed)), w);
      m.shut = Math.max(m.shut, 0.94 * Math.sqrt(Math.sin(Math.PI * w)));
    }
    const u = input.poke ?? (r?.hop && !still ? r.t / r.dur : 0);
    let hy = 0;
    if (u > 0 && u < 1) {
      const a = clamp((u - 0.2) / 0.45, 0, 1);
      const e = 0.08 * wave2(a) - 0.16 * wave2(u / 0.22) - 0.09 * wave2((u - 0.65) / 0.35);
      hy = a * (a - 1);
      m.sx *= 1 - 0.7 * e;
      m.sy *= 1 + e;
      m.ty += hy;
      m.anchor = 1;
    }
    const body = clone(shapeContour(state.shape));
    let figured = 0;
    for (const { fig, w } of m.figs) {
      if (w <= 1e-3) continue;
      blend(body, shapeContour(fig), Math.min(1, w), body);
      figured = Math.min(1, figured + w);
    }
    let bottom = 0;
    for (let i = 0; i < size(body); i++) bottom = Math.max(bottom, body.y[i]);
    const ay = bottom * m.anchor;
    const sx = m.sx * m.scale;
    const sy = m.sy * m.scale * (still ? 1 : breath(t, L));
    const cos = Math.cos(m.rot), sin = Math.sin(m.rot);
    const place2 = (x, y) => {
      const qx = x * sx;
      const qy = ay * m.scale + (y - ay) * sy;
      return [(qx * cos - qy * sin + m.tx) * RADIUS, (qx * sin + qy * cos + m.ty) * RADIUS];
    };
    for (let i = 0; i < size(body); i++) [body.x[i], body.y[i]] = place2(body.x[i], body.y[i]);
    let face = FACES[state.expression];
    for (const { expr, w } of m.exprs) if (w > 1e-3) face = blendFace(face, FACES[expr], w);
    const own = faceCenter(face);
    for (const { face: f, w } of m.faces) if (w > 1e-3) face = blendFace(face, f, Math.min(1, w));
    let [wy, wp] = still ? [0, 0] : input.gaze ? [input.gaze[0] * 0.32, input.gaze[1] * 0.26] : wander(t, state.seed, L);
    const look = still ? null : input.look;
    if (look && look.w > 0) {
      const [ly, lp] = turnTo(own[0], own[1], lerp(LOOK_X * look.x, own[0], OWN), lerp(LOOK_Y * look.y, own[1], OWN));
      const w = clamp(look.w, 0, 1);
      [wy, wp] = [lerp(wy, ly, w), lerp(wp, lp, w)];
    }
    const yaw = wy + m.yaw, pitch = wp + m.pitch;
    const open = (still ? 1 : blink(t, state.seed, L)) * (1 - clamp(m.shut, 0, 1)) * clamp(input.open ?? 1, 0, 1);
    const eyeFill = autoEyeColor(state.color);
    const eyeSize = lerp(faceSize(state.shape), 1, figured);
    const fitted = (p) => {
      const turned = turnEye(p, yaw, pitch);
      const z = turned.z;
      const pose = eyeSize === 1 ? turned.pose : { ...turned.pose, w: turned.pose.w * eyeSize, h: turned.pose.h * eyeSize };
      const r2 = Math.hypot(pose.x, pose.y);
      let k = r2 > 1e-6 ? lerp(edgeAt(state.shape, Math.atan2(pose.x, -pose.y)), 1, figured) : 1;
      let c = eyeOutline(pose, open, pose.x * k, pose.y * k);
      if (state.shape !== "circle" && figured < 0.5) {
        for (let pass = 0; pass < 4; pass++) {
          let over = 0;
          for (let i = 0; i < EYE_POINTS; i++) over = Math.max(over, Math.hypot(c.x[i], c.y[i]) / (0.9 * edgeAt(state.shape, Math.atan2(c.x[i], -c.y[i]))));
          if (over <= 1) break;
          k *= 1 - Math.min(0.5, (over - 1) * 1.1);
          c = eyeOutline(pose, open, pose.x * k, pose.y * k);
        }
      }
      return { c, x: pose.x * k, y: pose.y * k, alpha: clamp(m.eyeAlpha, 0, 1) * smooth(z / 0.12) };
    };
    const pair = [fitted(face.left), fitted(face.right)];
    if (state.shape !== "circle" && figured < 0.5) apart(pair[0], pair[1]);
    const eyes = pair.map(({ c, alpha }) => {
      for (let i = 0; i < EYE_POINTS; i++) [c.x[i], c.y[i]] = place2(c.x[i], c.y[i]);
      return { c, fill: eyeFill, alpha };
    });
    const parts = [];
    for (let i = 0; i < PART_SLOTS; i++) {
      const p = m.parts[i];
      const live2 = p && p.alpha > 2e-3 && p.r > 1e-3;
      parts.push({ c: dot(p?.x ?? 0, (p?.y ?? 0) + hy, live2 ? p.r : 0), fill: p?.color ?? state.color, alpha: live2 ? Math.min(1, p.alpha) : 0 });
    }
    const hole = dot(m.holeX, m.holeY + hy, Math.max(0, m.holeR));
    const back = [], front = [];
    for (let i = 0; i < TRAIL_SLOTS; i++) {
      const tr = m.trails[i];
      const x = new Float64Array(TRAIL_POINTS), y = new Float64Array(TRAIL_POINTS);
      if (tr && tr.alpha > 2e-3) for (let k = 0; k < TRAIL_POINTS; k++) [x[k], y[k]] = [tr.pts[k][0] * RADIUS, (tr.pts[k][1] + hy) * RADIUS];
      (i % 2 ? front : back).push({ x, y, colors: tr?.colors ?? [state.color, state.color, state.color], width: (tr?.width ?? 0.05) * RADIUS, alpha: tr ? Math.min(1, tr.alpha) : 0 });
    }
    return {
      back,
      body: { c: body, fill: state.color, alpha: 1 },
      hole,
      parts,
      eyes,
      front
    };
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/codec.ts
  var oneOf = (list, v, fallback) => v && list.includes(v) ? v : fallback;
  var hex = (v, fallback) => v && isHex(v) ? `#${v.replace("#", "").toLowerCase()}` : fallback;
  var clampDur = (v) => Math.min(10, Math.max(0.4, Math.round(v * 10) / 10));
  var OLD_SHAPES = { orb: "circle", bean: "pebble", block: "squircle", pill: "capsule", tri: "triangle", hex: "hexagon", puff: "cloud", drop: "droplet" };
  var OLD_EXPRESSIONS = { joy: "laughing", love: "happy", starry: "excited", dizzy: "confused" };
  var renamed = (old, v) => v && Object.prototype.hasOwnProperty.call(old, v) ? old[v] : v;
  function parseCycle(v) {
    if (!v) return null;
    const clips = [];
    for (const part of v.split(",").slice(0, MAX_CLIPS)) {
      const m = part.match(/^([a-z]+)(?:\.(\d+(?:\.\d)?))?$/);
      if (!m || !ANIMS.includes(m[1])) continue;
      const anim = m[1];
      clips.push({ anim, dur: m[2] ? clampDur(Number(m[2])) : DEFAULT_DUR[anim] });
    }
    return clips.length ? clips : null;
  }
  var seedOf = (v, fallback) => v && /^[0-9a-z]{1,6}$/.test(v) ? parseInt(v, 36) : fallback;
  function fromParams(get, base = DEFAULT_STATE) {
    const s = cloneState(base);
    s.shape = oneOf(SHAPES, renamed(OLD_SHAPES, get("shape")), s.shape);
    s.color = hex(get("color"), s.color);
    s.expression = oneOf(EXPRESSIONS, renamed(OLD_EXPRESSIONS, get("expr") ?? get("expression")), s.expression);
    s.cycle = parseCycle(get("anim") ?? get("animation")) ?? s.cycle;
    s.seed = seedOf(get("seed"), s.seed);
    return s;
  }
  function fromHash(hash2, base = DEFAULT_STATE) {
    const p = new URLSearchParams(hash2.replace(/^#/, ""));
    return fromParams((k) => p.get(k), base);
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/render/svg.ts
  var NS = "http://www.w3.org/2000/svg";
  var bodyPath = (m) => toPath(m.body.c);
  var gapClip = (m) => `M${-VIEW} ${-VIEW}h${2 * VIEW}v${2 * VIEW}h${-2 * VIEW}Z${toPath(m.hole)}`;
  var gradientEnds = (t) => [t.x[0], t.y[0], t.x[t.x.length - 1], t.y[t.y.length - 1]].map(num);
  var LiveSvg = class {
    el;
    back = [];
    front = [];
    body;
    gap;
    fills = [];
    constructor(doc = document, slots = { trails: 6, parts: 3 }, prefix = `l${Math.random().toString(36).slice(2, 7)}`) {
      const half = VIEW / 2;
      const el = doc.createElementNS(NS, "svg");
      el.setAttribute("viewBox", `${-half} ${-half} ${VIEW} ${VIEW}`);
      el.setAttribute("aria-hidden", "true");
      el.style.overflow = "visible";
      const defs = el.appendChild(doc.createElementNS(NS, "defs"));
      const trail = (name) => {
        const grad = defs.appendChild(doc.createElementNS(NS, "linearGradient"));
        grad.id = `${prefix}${name}`;
        grad.setAttribute("gradientUnits", "userSpaceOnUse");
        const stops = [0, 0.5, 1].map((o) => {
          const s = grad.appendChild(doc.createElementNS(NS, "stop"));
          s.setAttribute("offset", String(o));
          return s;
        });
        const path = el.appendChild(doc.createElementNS(NS, "path"));
        path.setAttribute("fill", "none");
        path.setAttribute("stroke", `url(#${grad.id})`);
        path.setAttribute("stroke-linecap", "round");
        path.setAttribute("stroke-linejoin", "round");
        return { path, grad, stops };
      };
      for (let i = 0; i < slots.trails; i++) this.back.push(trail(`b${i}`));
      const clip = defs.appendChild(doc.createElementNS(NS, "clipPath"));
      clip.id = `${prefix}gap`;
      this.gap = clip.appendChild(doc.createElementNS(NS, "path"));
      this.gap.setAttribute("clip-rule", "evenodd");
      this.body = el.appendChild(doc.createElementNS(NS, "path"));
      this.body.setAttribute("clip-path", `url(#${clip.id})`);
      for (let i = 0; i < slots.parts + 2; i++) this.fills.push(el.appendChild(doc.createElementNS(NS, "path")));
      for (let i = 0; i < slots.trails; i++) this.front.push(trail(`f${i}`));
      this.el = el;
    }
    update(m) {
      const trails = (list, els) => list.forEach((t, i) => {
        const e = els[i];
        if (!e) return;
        if (t.alpha <= 2e-3) return e.path.setAttribute("d", "");
        const [x1, y1, x2, y2] = gradientEnds(t);
        e.grad.setAttribute("x1", x1);
        e.grad.setAttribute("y1", y1);
        e.grad.setAttribute("x2", x2);
        e.grad.setAttribute("y2", y2);
        t.colors.forEach((c, k) => e.stops[k].setAttribute("stop-color", c));
        e.path.setAttribute("d", toOpenPath(t.x, t.y));
        e.path.setAttribute("stroke-width", num(t.width));
        e.path.setAttribute("stroke-opacity", String(Math.round(t.alpha * 1e3) / 1e3));
      });
      trails(m.back, this.back);
      this.body.setAttribute("d", bodyPath(m));
      this.gap.setAttribute("d", gapClip(m));
      this.body.setAttribute("fill", m.body.fill);
      [...m.parts, ...m.eyes].forEach((l, i) => {
        const p = this.fills[i];
        if (!p) return;
        if (l.alpha <= 2e-3) return p.setAttribute("d", "");
        p.setAttribute("d", toPath(l.c));
        p.setAttribute("fill", l.fill);
        p.setAttribute("fill-opacity", String(Math.round(l.alpha * 1e3) / 1e3));
      });
      trails(m.front, this.front);
    }
  };

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/engine/gaze.ts
  function lookTarget(px, py, box) {
    const dx = px - box.left - box.width / 2, dy = py - box.top - box.height / 2;
    const d = Math.hypot(dx, dy);
    if (d < 1e-6) return [0, 0];
    const body = Math.min(box.width, box.height) * RADIUS / VIEW;
    const k = Math.tanh(d / Math.max(2.4 * body, 110)) / d;
    return [dx * k, dy * k];
  }
  var EYES = { k: 15 ** 2, c: 2 * 0.72 * 15 };
  var HAND_IN = { k: 10 ** 2, c: 2 * 10 };
  var HAND_OUT = { k: 5 ** 2, c: 2 * 5 };
  var BLINK_TURN = 0.75;
  var BLINK_GAP = 1.4;
  var BLINK_DUR = 0.22;
  var Gaze = class {
    x = 0;
    y = 0;
    vx = 0;
    vy = 0;
    w = 0;
    vw = 0;
    /** how open the eyes are, 0..1 */
    open = 1;
    /** the dart off the spot while the point rests, and the seconds until the next one */
    dart = [0, 0];
    next = 1.2;
    darts = 0;
    /** the spot last frame, to tell a resting point from a moving one, and how long it has rested */
    last = null;
    rested = 0;
    /** seconds since the last turn's blink began */
    blinked = BLINK_GAP;
    seed;
    constructor(seed = 1) {
      this.seed = seed;
    }
    step(target, dt) {
      if (dt <= 0) return this.look();
      this.blinked += dt;
      let tx = 0, ty = 0;
      if (target) {
        const moved = !this.last || Math.hypot(target[0] - this.last[0], target[1] - this.last[1]) > 4e-3;
        if (moved && this.w > 0.5 && this.blinked >= BLINK_GAP && Math.hypot(target[0] - this.x, target[1] - this.y) > BLINK_TURN) this.blinked = 0;
        this.rested = moved ? 0 : this.rested + dt;
        this.last = [target[0], target[1]];
        this.darting(dt, moved);
        [tx, ty] = [target[0] + this.dart[0], target[1] + this.dart[1]];
        const r = Math.hypot(tx, ty);
        if (r > 0.98) [tx, ty] = [tx / r * 0.98, ty / r * 0.98];
      } else {
        this.last = null;
        this.dart = [0, 0];
        this.rested = 0;
      }
      const n = Math.ceil(dt / (1 / 120));
      const h = dt / n;
      const hand = target ? HAND_IN : HAND_OUT;
      for (let i = 0; i < n; i++) {
        this.vx += ((tx - this.x) * EYES.k - EYES.c * this.vx) * h;
        this.vy += ((ty - this.y) * EYES.k - EYES.c * this.vy) * h;
        this.x += this.vx * h;
        this.y += this.vy * h;
        this.vw += (((target ? 1 : 0) - this.w) * hand.k - hand.c * this.vw) * h;
        this.w = Math.min(1, Math.max(0, this.w + this.vw * h));
      }
      const u = this.blinked / BLINK_DUR;
      this.open = u < 1 ? 1 - 0.6 * Math.sin(Math.PI * u) ** 1.2 : 1;
      if (!target && this.w < 1e-3) {
        [this.x, this.y, this.vx, this.vy, this.w, this.vw] = [0, 0, 0, 0, 0, 0];
        return null;
      }
      return this.look();
    }
    look() {
      return this.w > 0 ? { x: this.x, y: this.y, w: this.w } : null;
    }
    /** while the point rests, the eyes dart a little about it and back, every second or two; a moving point has their full attention */
    darting(dt, moved) {
      if (moved || this.rested < 0.4) {
        this.dart = [0, 0];
        this.next = 0.5 + hash(this.seed, this.darts * 3) * 1.2;
        return;
      }
      if ((this.next -= dt) > 0) return;
      this.darts++;
      const away = this.dart[0] === 0 && this.dart[1] === 0;
      const a = hash(this.seed, this.darts * 3 + 1) * Math.PI * 2;
      const r = 0.05 + hash(this.seed, this.darts * 3 + 2) * 0.06;
      this.dart = away ? [Math.cos(a) * r, Math.sin(a) * r * 0.7] : [0, 0];
      this.next = (away ? 0.35 : 0.9) + hash(this.seed, this.darts * 3) * 1.4;
    }
  };

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/pointer.ts
  var REST = 3;
  var LIFTED = 0.9;
  function watchPointer(win = window, moved = () => {
  }) {
    let spot = null;
    const clock = () => performance.now();
    const touchy = (e) => e.pointerType === "touch";
    const move = (e) => {
      if (touchy(e) && e.type === "pointermove" && !spot?.down) return;
      spot = { x: e.clientX, y: e.clientY, at: clock(), touch: touchy(e), down: e.type === "pointerdown" || touchy(e) && !!spot?.down };
      moved();
    };
    const lift = (e) => {
      if (spot && touchy(e)) spot = { ...spot, at: clock(), down: false };
    };
    const out = (e) => {
      if (!e.relatedTarget && !touchy(e)) spot = null;
    };
    const leave = (e) => {
      if (e.target === win) spot = null;
    };
    const on = [
      ["pointermove", move],
      ["pointerdown", move],
      ["pointerup", lift],
      ["pointercancel", lift],
      ["pointerout", out],
      ["blur", leave]
    ];
    for (const [type, f] of on) win.addEventListener(type, f, { passive: true, capture: true });
    return {
      at(now = clock()) {
        if (!spot) return null;
        if (spot.touch ? !spot.down && now - spot.at > LIFTED * 1e3 : now - spot.at > REST * 1e3) return null;
        return [spot.x, spot.y];
      },
      stop() {
        for (const [type, f] of on) win.removeEventListener(type, f, { capture: true });
        spot = null;
      }
    };
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/driver.ts
  var reactionOf = (v) => parseCycle(v)?.[0] ?? POKE;
  var reduced = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  var live = /* @__PURE__ */ new Map();
  var running = false;
  var last = 0;
  var pointer = null;
  function loop(now) {
    const dt = Math.min(0.05, (now - last) / 1e3);
    last = now;
    let any = false;
    for (const a of live.values()) any = a.step(dt) || any;
    if (any) requestAnimationFrame(loop);
    else running = false;
  }
  function wake() {
    if (running || typeof requestAnimationFrame !== "function") return;
    running = true;
    last = performance.now();
    requestAnimationFrame(loop);
  }
  var watcher = typeof IntersectionObserver === "function" ? new IntersectionObserver((entries) => {
    for (const e of entries) {
      const a = live.get(e.target);
      if (a) a.seen = e.isIntersecting;
    }
    wake();
  }) : null;
  if (typeof document !== "undefined") document.addEventListener("visibilitychange", wake);
  function drive(host, svg) {
    let o = { state: DEFAULT_STATE, gaze: false, paused: false, reaction: null };
    let t = 0;
    const eyes = new Gaze();
    let look = null;
    let now = null;
    const still = () => o.paused || reduced();
    const draw = () => {
      const s = still();
      const input = s ? { still: s } : look ? { look, open: eyes.open } : {};
      if (now) input.react = { ...now.re, t: s ? now.re.dur / 2 : now.r };
      svg.update(frame(o.state, t, input));
    };
    const me = {
      // only the avatars on screen are drawn
      seen: !watcher,
      step(dt) {
        if (still() || !me.seen || document.hidden) return false;
        t = (t + dt) % (loopLength(o.state) || 2.4);
        const at = o.gaze ? pointer?.at() : null;
        look = eyes.step(at ? lookTarget(at[0], at[1], host.getBoundingClientRect()) : null, dt);
        if (now && (now.r += dt) >= now.re.dur) now = null;
        draw();
        return true;
      }
    };
    const react = () => {
      if (now) return;
      now = { re: o.reaction ?? POKE, r: 0 };
      if (still()) {
        draw();
        setTimeout(() => {
          now = null;
          draw();
        }, 800);
      } else wake();
    };
    const click = () => o.reaction && react();
    const key = (e) => {
      if (!o.reaction || e.target !== host || e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      react();
    };
    return {
      set(p) {
        o = { ...o, ...p };
        if (o.gaze && !pointer) pointer = watchPointer(window, wake);
        if (o.reaction) {
          host.addEventListener("click", click);
          host.addEventListener("keydown", key);
        }
        draw();
        wake();
      },
      start() {
        live.set(host, me);
        watcher?.observe(host);
        wake();
      },
      stop() {
        live.delete(host);
        watcher?.unobserve(host);
      },
      react
    };
  }

  // macos/build/agent-refs/blob-avatar/packages/blob-avatar/src/element.ts
  var ATTRS = ["shape", "color", "expression", "expr", "animation", "anim", "seed", "size", "gaze", "paused", "state", "reaction"];
  var CSS = ":host{display:inline-block;width:160px;height:160px;line-height:0;vertical-align:middle}:host([hidden]){display:none}svg{width:100%;height:100%;overflow:visible}:host([reaction]){cursor:pointer;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none}:host(:focus-visible){outline:2px solid;outline-offset:2px}";
  var sheet = null;
  function styles(root) {
    try {
      if (!sheet) {
        sheet = new CSSStyleSheet();
        sheet.replaceSync(CSS);
      }
      root.adoptedStyleSheets = [sheet];
    } catch {
      const s = document.createElement("style");
      s.textContent = CSS;
      root.appendChild(s);
    }
  }
  var BlobAvatarElement = class extends HTMLElement {
    static observedAttributes = ATTRS;
    constructor() {
      super();
      const root = this.attachShadow({ mode: "open" });
      styles(root);
      const svg = new LiveSvg(document);
      root.appendChild(svg.el);
      this.driver = drive(this, svg);
    }
    connectedCallback() {
      if (!this.hasAttribute("role")) this.setAttribute("role", "img");
      if (!this.hasAttribute("aria-label") && !this.hasAttribute("aria-labelledby")) this.setAttribute("aria-label", "Blob avatar");
      this.read();
      this.driver.start();
    }
    disconnectedCallback() {
      this.driver.stop();
    }
    attributeChangedCallback() {
      if (this.isConnected) this.read();
    }
    read() {
      const base = this.getAttribute("state") ? fromHash(this.getAttribute("state")) : DEFAULT_STATE;
      const size2 = Number(this.getAttribute("size"));
      if (size2 > 0 && size2 <= 4096) this.style.width = this.style.height = `${size2}px`;
      const reaction = this.getAttribute("reaction");
      this.driver.set({ state: fromParams((k) => this.getAttribute(k), base), gaze: this.hasAttribute("gaze"), paused: this.hasAttribute("paused"), reaction: reaction === null ? null : reactionOf(reaction) });
    }
  };
  if (typeof customElements !== "undefined" && !customElements.get("blob-avatar")) customElements.define("blob-avatar", BlobAvatarElement);
})();
