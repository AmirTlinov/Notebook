#include <metal_stdlib>

using namespace metal;

struct PaperInkVertex {
  float2 position;
  float4 premultipliedColor;
};

struct PaperInkVertexOut {
  float4 position [[position]];
  float4 premultipliedColor;
};

vertex PaperInkVertexOut paperInkVertex(
  const device PaperInkVertex *vertices [[buffer(0)]],
  constant float2 &viewportSize [[buffer(1)]],
  uint vertexID [[vertex_id]]
) {
  const PaperInkVertex input = vertices[vertexID];
  const float2 unit = input.position / max(viewportSize, float2(1.0));

  PaperInkVertexOut output;
  output.position = float4(
    (unit.x * 2.0) - 1.0,
    1.0 - (unit.y * 2.0),
    0.0,
    1.0
  );
  output.premultipliedColor = input.premultipliedColor;
  return output;
}

fragment half4 paperInkFragment(PaperInkVertexOut input [[stage_in]]) {
  return half4(input.premultipliedColor);
}
