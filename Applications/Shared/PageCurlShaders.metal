// Page-curl mesh projection adapted from Ransel's NotebookMaterialShaders.
// Ransel is licensed under Apache-2.0; see docs/licenses/Ransel-Apache-2.0.txt.

#include <metal_stdlib>
using namespace metal;

struct PageCurlVertex {
  float2 position;
  float2 uv;
};

struct PageCurlUniforms {
  float progress;
  float direction;
  float gripY;
  float aspect;
  uint kind;
};

struct PageCurlRaster {
  float4 position [[position]];
  float2 uv;
  float shade;
  float alpha;
};

vertex PageCurlRaster notebookPageCurlVertex(
  uint vertexID [[vertex_id]],
  const device PageCurlVertex *vertices [[buffer(0)]],
  constant PageCurlUniforms &uniforms [[buffer(1)]])
{
  PageCurlVertex input = vertices[vertexID];
  float2 point = input.position;
  float shade = 1.0;
  float alpha = 1.0;

  if (uniforms.kind != 0) {
    float fold = uniforms.direction < 0.0
      ? 1.0 - uniforms.progress
      : uniforms.progress;
    float delta = max(0.0, point.x - fold);
    if (delta > 0.0) {
      float gripDistance = abs(point.y - uniforms.gripY);
      float radius = mix(0.115, 0.19, min(gripDistance, 1.0));
      float angle = min(delta / radius, M_PI_F);
      float side = uniforms.direction < 0.0 ? 1.0 : -1.0;
      point.x = fold + side * sin(angle) * radius;
      float lift = (1.0 - cos(angle)) * radius;
      point.y += (point.y - uniforms.gripY) * lift * 0.12;
      shade = 0.66 + 0.34 * abs(cos(angle));
      if (uniforms.kind == 2) {
        point.x += side * 0.025;
        point.y += 0.018;
        alpha = 0.18 * sin(angle);
        shade = 0.0;
      }
    } else if (uniforms.kind == 2) {
      alpha = 0.0;
      shade = 0.0;
    }
  }

  PageCurlRaster output;
  output.position = float4(
    point.x * 2.0 - 1.0,
    1.0 - point.y * 2.0,
    0,
    1
  );
  output.uv = input.uv;
  output.shade = shade;
  output.alpha = alpha;
  return output;
}

fragment float4 notebookPageCurlFragment(
  PageCurlRaster input [[stage_in]],
  texture2d<float> paperTexture [[texture(0)]],
  sampler textureSampler [[sampler(0)]],
  constant PageCurlUniforms &uniforms [[buffer(1)]])
{
  if (uniforms.kind == 2) {
    return float4(0.02, 0.018, 0.015, input.alpha);
  }
  float4 paper = paperTexture.sample(textureSampler, input.uv);
  return float4(paper.rgb * input.shade, paper.a);
}
