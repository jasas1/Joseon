import Foundation

// Metal shader source. SwiftPM does not compile `.metal` files, so the source lives here
// and `RenderContext` compiles it once with `device.makeLibrary(source:options:)`.
//
// All geometry is in view points with a top-left origin. `Globals.scale` turns points into pixels
// for anti-aliasing. Blending is premultiplied alpha ("over") or pure additive.

enum ShaderSource {
    static let metal = """
#include <metal_stdlib>
using namespace metal;

struct Globals {
    float2 viewSize;   // points
    float  scale;      // pixels per point
    float  time;
};

static inline float4 toClip(float2 p, constant Globals& g) {
    return float4(p.x / g.viewSize.x * 2.0 - 1.0, 1.0 - p.y / g.viewSize.y * 2.0, 0.0, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Shapes: instanced quads with a rounded-box signed distance field.
// mode 0: rect (x, y, w, h), vertical gradient color0 (top) -> color1 (bottom)
// mode 1: line (x0, y0, x1, y1), params.x = half width, gradient along the line
// mode 2: rect, horizontal gradient color0 (left) -> color1 (right)
// params: x = corner radius (or line half width), y = glow sigma (0 = crisp), z = mode, w = stroke width (0 = filled)
// ---------------------------------------------------------------------------------------------

struct ShapeInstance {
    float4 rect;
    float4 color0;
    float4 color1;
    float4 params;
};

struct ShapeVary {
    float4 position [[position]];
    float2 local;
    float2 hsize [[flat]];
    float4 color0 [[flat]];
    float4 color1 [[flat]];
    float4 params [[flat]];
};

vertex ShapeVary shape_vertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device ShapeInstance* inst [[buffer(0)]],
                              constant Globals& g [[buffer(1)]]) {
    ShapeInstance s = inst[iid];
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    int mode = int(s.params.z + 0.5);
    float pad = s.params.y * 3.0 + 1.5 / g.scale;
    float2 center; float2 hsize; float2 ax = float2(1, 0); float2 ay = float2(0, 1);
    if (mode == 1) {
        float2 d = s.rect.zw - s.rect.xy;
        float len = max(length(d), 1e-4);
        ax = d / len; ay = float2(-ax.y, ax.x);
        center = (s.rect.xy + s.rect.zw) * 0.5;
        hsize = float2(len * 0.5, s.params.x);
    } else {
        center = s.rect.xy + s.rect.zw * 0.5;
        hsize = s.rect.zw * 0.5;
    }
    float2 local = corner * (hsize + pad);
    float2 pos = center + ax * local.x + ay * local.y;
    ShapeVary o;
    o.position = toClip(pos, g);
    o.local = local;
    o.hsize = hsize;
    o.color0 = s.color0;
    o.color1 = s.color1;
    o.params = s.params;
    return o;
}

static inline float shapeAlpha(ShapeVary v, constant Globals& g) {
    int mode = int(v.params.z + 0.5);
    float radius = (mode == 1) ? 0.0 : min(v.params.x, min(v.hsize.x, v.hsize.y));
    float2 q = abs(v.local) - v.hsize + radius;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float stroke = v.params.w;
    if (stroke > 0.0) { d = abs(d + stroke * 0.5) - stroke * 0.5; }
    float soft = v.params.y;
    if (soft > 0.0) {
        float e = max(d, 0.0) / soft;
        return exp(-0.5 * e * e);
    }
    return clamp(0.5 - d * g.scale, 0.0, 1.0);
}

fragment float4 shape_fragment(ShapeVary v [[stage_in]], constant Globals& g [[buffer(1)]]) {
    int mode = int(v.params.z + 0.5);
    float t = (mode == 0) ? (v.local.y / max(2.0 * v.hsize.y, 1e-4) + 0.5)
                          : (v.local.x / max(2.0 * v.hsize.x, 1e-4) + 0.5);
    float4 c = mix(v.color0, v.color1, clamp(t, 0.0, 1.0));
    float a = shapeAlpha(v, g) * c.a;
    return float4(c.rgb * a, a);
}

// Vertical color-map bar (legend). Samples the LUT bottom (0) to top (1).
fragment float4 shape_lut_fragment(ShapeVary v [[stage_in]],
                                   constant Globals& g [[buffer(1)]],
                                   texture2d<float> lut [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float t = 1.0 - clamp(v.local.y / max(2.0 * v.hsize.y, 1e-4) + 0.5, 0.0, 1.0);
    // The bar runs floor (bottom) to top on a linear dB scale: color1.x = gamma of the map (the spectrogram's curve).
    t = pow(t, max(v.color1.x, 0.05));
    float3 c = lut.sample(s, float2(t, 0.5)).rgb;
    float a = shapeAlpha(v, g) * v.color0.a;
    return float4(c * a, a);
}

// ---------------------------------------------------------------------------------------------
// Curves: values are uniformly spaced in x across `rect`, 0 (bottom) ... 1 (top).
// The vertex shader expands the polyline with clamped miter joins. No CPU tessellation.
// ---------------------------------------------------------------------------------------------

struct CurveUniforms {
    float4 rect;        // x, y, w, h in points
    float4 color;
    float  halfWidth;   // points
    float  soft;        // glow sigma in points, 0 = crisp line
    float  count;       // number of values
    float  mode;        // 0 = uniform color, 1 = hue LUT by x
    float  dashPeriod;  // points along x, 0 = solid
    float  dashDuty;
    float  whiten;      // mix toward white (LUT mode)
    float  fillTop;     // fill alpha at the curve
    float  fillBottom;  // fill alpha at the base
    float  pad0;        // lines: segments to search on each side. fills: reference height at the left end
    float  fadeRight;   // points: alpha falls to 0 over this distance at the right end of the plot (0 = off)
    float  pad2;        // fills: reference height at the right end
};

static inline float edgeFade(float x, constant CurveUniforms& u) {
    if (u.fadeRight <= 0.0) { return 1.0; }
    return smoothstep(0.0, u.fadeRight, u.rect.x + u.rect.z - x);
}

struct CurveVary {
    float4 position [[position]];
    float  dist;        // signed distance from the center line, points
    float  u;           // 0...1 across the plot
    float  value;       // curve value at this x
    float  h;           // height in the plot 0 (bottom) ... 1 (top)
};

static inline float2 curvePoint(const device float* v, int i, constant CurveUniforms& u) {
    float x = u.rect.x + u.rect.z * (float(i) / max(u.count - 1.0, 1.0));
    float y = u.rect.y + u.rect.w * (1.0 - v[i]);
    return float2(x, y);
}

// Lines are drawn as a distance field: the strip only bounds the pixels near the curve, the fragment
// shader measures the true distance to the nearest segments. Width and glow stay even on sharp spikes.
vertex CurveVary curve_line_vertex(uint vid [[vertex_id]],
                                   const device float* values [[buffer(0)]],
                                   constant Globals& g [[buffer(1)]],
                                   constant CurveUniforms& u [[buffer(2)]]) {
    int n = int(u.count);
    int i = int(vid / 2u);
    bool top = (vid & 1u) == 0u;
    int K = int(u.pad0) + 1;
    float vmax = values[i], vmin = values[i];
    for (int j = max(i - K, 0); j <= min(i + K, n - 1); j++) {
        vmax = max(vmax, values[j]);
        vmin = min(vmin, values[j]);
    }
    float reach = u.halfWidth + u.soft * 3.0 + 1.5 / g.scale;
    float x = u.rect.x + u.rect.z * (float(i) / max(u.count - 1.0, 1.0));
    float y = top ? (u.rect.y + u.rect.w * (1.0 - vmax) - reach) : (u.rect.y + u.rect.w * (1.0 - vmin) + reach);
    CurveVary o;
    o.position = toClip(float2(x, y), g);
    o.dist = y;
    o.u = float(i) / max(u.count - 1.0, 1.0);
    o.value = float(i);
    o.h = x;
    return o;
}

fragment float4 curve_line_fragment(CurveVary v [[stage_in]],
                                    const device float* values [[buffer(0)]],
                                    constant Globals& g [[buffer(1)]],
                                    constant CurveUniforms& u [[buffer(2)]],
                                    texture2d<float> lut [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    int n = int(u.count);
    int K = int(u.pad0);
    int i0 = clamp(int(floor(v.value)), 0, n - 2);
    float2 p = float2(v.h, v.dist);
    float best = 1e9;
    int lo = max(i0 - K, 0), hi = min(i0 + K, n - 2);
    float2 a = curvePoint(values, lo, u);
    for (int j = lo; j <= hi; j++) {
        float2 b = curvePoint(values, j + 1, u);
        float2 ab = b - a, ap = p - a;
        float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
        float2 d2 = ap - ab * t;
        best = min(best, dot(d2, d2));
        a = b;
    }
    float d = sqrt(best) - u.halfWidth;
    float alpha;
    if (u.soft > 0.0) {
        float e = max(d, 0.0) / u.soft;
        alpha = exp(-0.5 * e * e);
    } else {
        alpha = clamp(0.5 - d * g.scale, 0.0, 1.0);
    }
    if (u.dashPeriod > 0.0) {
        float ph = fract(v.u * u.rect.z / u.dashPeriod);
        float edge = 0.75 / (u.dashPeriod * g.scale);
        alpha *= smoothstep(0.0, edge, ph) * (1.0 - smoothstep(u.dashDuty, u.dashDuty + edge, ph));
    }
    float4 c = u.color;
    if (u.mode > 0.5) {
        float3 hue = lut.sample(s, float2(v.u, 0.5)).rgb;
        c.rgb = mix(hue, float3(1.0), u.whiten);
    }
    alpha *= c.a * edgeFade(p.x, u);
    return float4(c.rgb * alpha, alpha);
}

// The fill is one polygon (the strip from the curve to the floor) with ONE gradient: alpha and brightness depend on the
// height of the pixel in the plot and on a straight reference line across x (`pad0` at the left end, `pad2` at the right
// end, both as plot heights 0...1). Nothing here reads the level of a column, so a narrow peak cannot draw a stripe
// down through the fill under it. Hue follows x through the LUT.
vertex CurveVary curve_fill_vertex(uint vid [[vertex_id]],
                                   const device float* values [[buffer(0)]],
                                   constant Globals& g [[buffer(1)]],
                                   constant CurveUniforms& u [[buffer(2)]]) {
    int i = int(vid / 2u);
    bool top = (vid & 1u) == 0u;
    float2 p = curvePoint(values, i, u);
    float2 pos = top ? p : float2(p.x, u.rect.y + u.rect.w);
    CurveVary o;
    o.position = toClip(pos, g);
    o.dist = 0.0;
    o.u = float(i) / max(u.count - 1.0, 1.0);
    o.value = 0.0;
    o.h = top ? values[i] : 0.0;     // linear in y inside every triangle: exactly the height of the pixel in the plot
    return o;
}

fragment float4 curve_fill_fragment(CurveVary v [[stage_in]],
                                    constant Globals& g [[buffer(1)]],
                                    constant CurveUniforms& u [[buffer(2)]],
                                    texture2d<float> lut [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 hue = (u.mode > 0.5) ? lut.sample(s, float2(v.u, 0.5)).rgb : u.color.rgb;
    float ref = max(mix(u.pad0, u.pad2, v.u), 0.05);
    float rel = clamp(v.h / ref, 0.0, 1.0);                   // 0 at the floor, 1 at the reference line and over it
    float shade = rel * rel;
    float a = mix(u.fillBottom, u.fillTop, shade) * u.color.a * edgeFade(u.rect.x + u.rect.z * v.u, u);
    float3 c = mix(hue * 0.80, mix(hue, float3(1.0), 0.16), shade);
    return float4(c * a, a);
}

// Area between two curves (`values` and `other`): the response-vs-target error of the headphone overlay.
vertex CurveVary curve_band_vertex(uint vid [[vertex_id]],
                                   const device float* values [[buffer(0)]],
                                   constant Globals& g [[buffer(1)]],
                                   constant CurveUniforms& u [[buffer(2)]],
                                   const device float* other [[buffer(3)]]) {
    int i = int(vid / 2u);
    bool top = (vid & 1u) == 0u;
    float2 p = curvePoint(top ? values : other, i, u);
    CurveVary o;
    o.position = toClip(p, g);
    o.dist = 0.0;
    o.u = float(i) / max(u.count - 1.0, 1.0);
    o.value = values[i] - other[i];
    o.h = 0.0;
    return o;
}

fragment float4 curve_band_fragment(CurveVary v [[stage_in]], constant CurveUniforms& u [[buffer(2)]]) {
    float a = u.color.a * edgeFade(u.rect.x + u.rect.z * v.u, u);
    return float4(u.color.rgb * a, a);
}

// ---------------------------------------------------------------------------------------------
// Spectrogram: ring texture, x = time column, y = log frequency row (row 0 = lowest frequency).
// ---------------------------------------------------------------------------------------------

struct SpectrogramUniforms {
    float4 rect;       // plot rect, points
    float  head;       // newest column index + 1 (next write position), in columns
    float  columns;    // texture width
    float  floorV;     // ring value (0...1 = -120...0 dB) that maps to the background
    float  gamma;      // exponent of the map position
    float  topV;       // ring value that maps to the top of the color map
    float  pad2;
    float  pad0; float pad1;
};

// dB to color map position: nothing at or under the floor, then a gamma curve up to the top. A gamma under 1 lifts the
// quiet end, so content 10 dB over the floor is a readable blue, not navy on black.
static inline float heatPosition(float v, float floorV, float topV, float gamma) {
    if (v <= floorV) { return 0.0; }
    return pow(clamp((v - floorV) / max(topV - floorV, 1e-5), 0.0, 1.0), gamma);
}

struct QuadVary {
    float4 position [[position]];
    float2 uv;
};

vertex QuadVary rect_vertex(uint vid [[vertex_id]],
                            constant Globals& g [[buffer(1)]],
                            constant float4& rect [[buffer(2)]]) {
    float2 c = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    QuadVary o;
    o.position = toClip(rect.xy + rect.zw * c, g);
    o.uv = c;
    return o;
}

fragment float4 spectrogram_fragment(QuadVary v [[stage_in]],
                                     constant SpectrogramUniforms& u [[buffer(3)]],
                                     texture2d<float> ring [[texture(0)]],
                                     texture2d<float> lut [[texture(1)]]) {
    constexpr sampler rs(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    constexpr sampler ls(filter::linear, address::clamp_to_edge);
    // uv.x = 1 is "now". Keep half a column away from the seam between newest and oldest.
    float col = u.head - 0.5 - (1.0 - v.uv.x) * (u.columns - 1.0);
    float x = col / u.columns;
    float level = ring.sample(rs, float2(x, 1.0 - v.uv.y)).r;
    float t = heatPosition(level, u.floorV, u.topV, u.gamma);
    float3 c = lut.sample(ls, float2(t, 0.5)).rgb;
    return float4(c, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Vectorscope: additive points into a float density texture that fades, then a log tone-mapped composite.
// ---------------------------------------------------------------------------------------------

struct ScopeUniforms {
    float2 center;     // accumulation texture space, pixels
    float  radius;     // pixels for |mid| = 1 (the diamond's top vertex)
    float  gain;
    float  pointSize;  // pixels (sigma)
    float  energy;     // per-point intensity
    float2 texSize;    // pixels
};

struct PointVary {
    float4 position [[position]];
    float2 local;      // pixels, x along the segment from its middle, y across
    float  halfLen;    // pixels
    float  energy;
};

// 45-degree goniometer: left = up-left, right = up-right, mid = up, side = horizontal.
// Contract: x = (R - L) / 2, positive = right, so x maps straight to screen x. y = (L + R) / 2 is up.
// |x| + |y| = max(|L|, |R|): full scale is the diamond |x| + |y| = 1, with its vertices on `radius`. Full-scale mono is the
// top vertex (0, 1), full-scale side the right vertex (1, 0), L alone at full scale (-0.5, 0.5): the middle of the upper
// left edge. A hard-clipped signal (|L| = 1 or |R| = 1) runs along the 45 degree edges. Nothing is clamped here.
static inline float2 scopeMap(float2 sm, constant ScopeUniforms& u) {
    return u.center + float2(sm.x, -sm.y) * (u.gain * u.radius);
}

// Light fades out between 92 % and 108 % of the full-scale diamond: loud peaks leave the field, they never pile up on the rim.
static inline float scopeEdge(float2 sm, constant ScopeUniforms& u) {
    float d = (abs(sm.x) + abs(sm.y)) * u.gain;
    return 1.0 - smoothstep(0.92, 1.08, d);
}

// One instance = the beam path from sample i to sample i + 1, like the trace of a CRT scope.
vertex PointVary scope_point_vertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    const device packed_float2* pts [[buffer(0)]],
                                    constant ScopeUniforms& u [[buffer(2)]]) {
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float2 s0 = float2(pts[iid]), s1 = float2(pts[iid + 1]);
    float2 p0 = scopeMap(s0, u);
    float2 p1 = scopeMap(s1, u);
    float2 d = p1 - p0;
    float len = length(d);
    // scopePoints are evenly decimated samples, not always consecutive ones. A long jump between two
    // points is a chord across the figure, not the beam path: draw the end point as a dot. The dot keeps
    // the low energy of the long segment (travel), so the change from line to dot does not flash.
    float travel = len;
    if (len > max(u.pointSize * 24.0, u.radius * 0.12)) { p0 = p1; d = float2(0.0); len = 0.0; }
    float2 ax = len > 1e-4 ? d / len : float2(1, 0);
    float2 ay = float2(-ax.y, ax.x);
    float ext = u.pointSize * 3.0;
    float2 local = corner * float2(len * 0.5 + ext, ext);
    float2 pos = (p0 + p1) * 0.5 + ax * local.x + ay * local.y;
    PointVary o;
    o.position = float4(pos.x / u.texSize.x * 2.0 - 1.0, 1.0 - pos.y / u.texSize.y * 2.0, 0.0, 1.0);
    o.local = local / u.pointSize;
    o.halfLen = len * 0.5 / u.pointSize;
    // A fast beam leaves less light per pixel.
    o.energy = u.energy / (1.0 + travel / (u.pointSize * 2.5)) * scopeEdge(s1, u);
    return o;
}

fragment float4 scope_point_fragment(PointVary v [[stage_in]]) {
    float dx = max(abs(v.local.x) - v.halfLen, 0.0);
    float d2 = dx * dx + v.local.y * v.local.y;
    float a = exp(-0.5 * d2) * v.energy;
    return float4(a, a, a, a);
}

vertex QuadVary fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 c = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    QuadVary o;
    o.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    o.uv = c;
    return o;
}

// The pipeline multiplies the destination by the blend color: dst = dst * fade.
fragment float4 scope_fade_fragment(QuadVary v [[stage_in]]) {
    return float4(0.0);
}

struct ScopeCompositeUniforms {
    float k;           // density scale inside the log
    float norm;        // 1 / log(1 + k * reference density)
    float pad1; float pad2;
};

// Density to color through log(1 + k d): the dense core compresses, thin filaments keep their place in the ramp.
fragment float4 scope_composite_fragment(QuadVary v [[stage_in]],
                                         constant ScopeCompositeUniforms& u [[buffer(3)]],
                                         texture2d<float> accum [[texture(0)]],
                                         texture2d<float> lut [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float d = max(accum.sample(s, v.uv).r, 0.0);
    float t = clamp(log(1.0 + u.k * d) * u.norm, 0.0, 1.0);
    float3 c = lut.sample(s, float2(t, 0.5)).rgb;
    // Additive: the LUT starts at black, so empty areas add nothing.
    return float4(c, 0.0);
}

// ---------------------------------------------------------------------------------------------
// Pan spectrum ("stereo placement by frequency"): one Gaussian splat per lit display bin. The CPU works out
// pan, height and light (`PanField`); the shader only places the splat. y = log frequency, x = pan,
// light = level, hue = the band hue of the frequency.
// ---------------------------------------------------------------------------------------------

struct PanUniforms {
    float2 texSize;    // pixels
    float  centerX;    // pan = 0, as a fraction of the texture width
    float  halfX;      // pan = 1 lies this far from the center, as a fraction of the texture width
    float  top;        // y of the top of the frequency axis, fraction of the texture height
    float  height;     // height of the frequency axis, fraction of the texture height
    float  sigmaX;     // pixels
    float  energy;
};

struct PanVary {
    float4 position [[position]];
    float2 local;
    float3 light;
};

// instance: x = pan -1...1, y = axis position 0 (bottom) ... 1 (top), z = light 0...1, w = vertical sigma in pixels
vertex PanVary pan_point_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device float4* splats [[buffer(0)]],
                                constant PanUniforms& u [[buffer(2)]],
                                texture2d<float> hue [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float4 d = splats[iid];
    float2 c = float2(u.texSize.x * (u.centerX + u.halfX * d.x), u.texSize.y * (u.top + (1.0 - d.y) * u.height));
    float2 pos = c + corner * float2(u.sigmaX, d.w) * 3.0;
    PanVary o;
    o.position = float4(pos.x / u.texSize.x * 2.0 - 1.0, 1.0 - pos.y / u.texSize.y * 2.0, 0.0, 1.0);
    o.local = corner * 3.0;
    o.light = hue.sample(s, float2(d.y, 0.5), level(0)).rgb * (u.energy * d.z);
    return o;
}

fragment float4 pan_point_fragment(PanVary v [[stage_in]]) {
    float a = exp(-0.5 * dot(v.local, v.local));
    return float4(v.light * a, a);
}

struct PanCompositeUniforms {
    float k;
    float norm;
    float pad0; float pad1;
};

// Keeps the hue of the accumulated light, compresses its amount with the same log curve as the scope.
fragment float4 pan_composite_fragment(QuadVary v [[stage_in]],
                                       constant PanCompositeUniforms& u [[buffer(3)]],
                                       texture2d<float> accum [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = max(accum.sample(s, v.uv).rgb, 0.0);
    float peak = max(max(c.r, c.g), max(c.b, 1e-6));
    float t = clamp(log(1.0 + u.k * peak) * u.norm, 0.0, 1.0);
    float3 hue = c / peak;
    // Dense cores drift toward a warm white, capped under full white.
    float3 rgb = mix(hue, float3(1.0, 0.96, 0.90), smoothstep(0.72, 1.0, t) * 0.7) * min(t * 1.08, 0.94);
    return float4(rgb, 0.0);
}

// ---------------------------------------------------------------------------------------------
// Text overlay: the Core Graphics text bitmap lives in a texture with the pixel size of the target.
// Only the rectangles that hold text are drawn.
// ---------------------------------------------------------------------------------------------

struct OverlayVary {
    float4 position [[position]];
};

vertex OverlayVary overlay_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device float4* rects [[buffer(0)]],
                                  constant Globals& g [[buffer(1)]]) {
    float2 c = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
    float4 r = rects[iid];
    OverlayVary o;
    o.position = toClip(r.xy + r.zw * c, g);
    return o;
}

fragment float4 overlay_fragment(OverlayVary v [[stage_in]], texture2d<float> text [[texture(0)]]) {
    uint2 p = uint2(v.position.xy);
    p = min(p, uint2(text.get_width() - 1, text.get_height() - 1));
    return text.read(p);   // premultiplied
}
"""
}
