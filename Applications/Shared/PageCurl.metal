#include <metal_stdlib>
using namespace metal;

struct PageCurlVertex {
  float4 position [[position]];
  float2 uv;
};
struct PageCurlUniforms {
  float4 fold; // normal.xy, axis projection, radius
  float4 paper; // RGB, shadow amount
  float2 size; // height / width, one pixel / width
};
vertex PageCurlVertex pageCurlVertex(uint id [[vertex_id]]) {
  constexpr float2 uv[] = { {0,0}, {0,1}, {1,0}, {1,0}, {0,1}, {1,1} };
  return {float4(uv[id].x * 2 - 1, 1 - uv[id].y * 2, 0, 1), uv[id]};
}
static float pageCoverage(float2 source, float stretch, constant PageCurlUniforms &u) {
  float k = stretch - 1, nx = u.fold.x, ny = u.fold.y;
  float2 pixel = u.size.y * float2(abs(1 + nx*nx*k) + abs(nx*ny*k), abs(nx*ny*k) + abs(1 + ny*ny*k));
  float2 edge = min(source, float2(1, u.size.x) - source);
  return saturate(min(edge.x / max(pixel.x, 0.000001f), edge.y / max(pixel.y, 0.000001f)) + 0.5f);
}
static float3 pageColor(float4 sample, float3 paper) {
  return sample.rgb + paper*(1-sample.a);
}
fragment float4 pageCurlFragment(PageCurlVertex in [[stage_in]],
  constant PageCurlUniforms &u [[buffer(0)]],
  texture2d<float> leaf [[texture(0)]], texture2d<float> base [[texture(1)]]) {
  constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
  float radius = u.fold.w;
  // Endpoint 0 is the flat leaf; endpoint 1 is the exposed base. Both are
  // complete opaque images, independent of UIKit's underlay transaction.
  if (radius == 0) return float4(pageColor(u.fold.z == 0 ? leaf.sample(sample, in.uv) : base.sample(sample, in.uv), u.paper.rgb), 1);
  float2 normal = u.fold.xy, q = float2(in.uv.x, in.uv.y*u.size.x);
  float s = dot(q, normal) - u.fold.z, aa = u.size.y*(abs(normal.x) + abs(normal.y));
  float rim = 1 - smoothstep(radius-aa*0.5f, radius+aa*0.5f, s);
  float reach = radius*0.65f + 0.012f;
  float shade = exp(-pow((s-radius*0.65f)/reach, 2.0f))*u.paper.w;
  float3 color = pageColor(base.sample(sample, in.uv), u.paper.rgb)*(1-shade);
  if (rim > 0) {
    float3 under = color;
    float sine = clamp(s/radius, 0.0f, 1.0f), angle = asin(sine);
    float stretch = rsqrt(max(1-sine*sine, 0.0001f));
    float frontDistance = s > 0 ? radius*angle : s;
    float2 front = q + normal*(frontDistance-s);
    float frontCoverage = pageCoverage(front, s > 0 ? stretch : 1, u);
    if (frontCoverage > 0) {
      float3 face = pageColor(leaf.sample(sample, front/float2(1,u.size.x)), u.paper.rgb)*(1-0.19f*sine);
      float groove = exp(-abs(frontDistance)/(radius*0.28f+0.001f))*0.06f;
      color = mix(color, face*(1-groove), frontCoverage);
    }
    float backDistance = s > 0 ? radius*(M_PI_F-angle) : M_PI_F*radius-s;
    float2 back = q + normal*(backDistance-s);
    float backCoverage = pageCoverage(back, s > 0 ? -stretch : -1, u);
    if (backCoverage > 0) {
      float3 face = mix(u.paper.rgb, pageColor(leaf.sample(sample, back/float2(1,u.size.x)), u.paper.rgb), 0.105f)*(0.94f+0.09f*sine);
      float groove = exp(-backDistance/(radius*0.28f+0.001f))*0.06f;
      color = mix(color, face*(1-groove), backCoverage);
    }
    color = mix(under, color, rim);
  }
  return float4(color, 1);
}
