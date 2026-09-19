#include <metal_stdlib>

using namespace metal;

struct PaperInkVertexOut {
  float4 position [[position]];
  float4 premultipliedColor;
};

struct StableInkVertexOut {
  float4 position [[position]];
  float2 textureCoordinate;
};

vertex StableInkVertexOut stableInkVertex(uint vertexID [[vertex_id]]) {
  constexpr float2 positions[] = {
    float2(-1.0, 1.0),
    float2(-1.0, -1.0),
    float2(1.0, 1.0),
    float2(1.0, 1.0),
    float2(-1.0, -1.0),
    float2(1.0, -1.0),
  };
  constexpr float2 textureCoordinates[] = {
    float2(0.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 1.0),
  };

  StableInkVertexOut output;
  output.position = float4(positions[vertexID], 0.0, 1.0);
  output.textureCoordinate = textureCoordinates[vertexID];
  return output;
}

fragment half4 stableInkFragment(
  StableInkVertexOut input [[stage_in]],
  texture2d<half> stableInk [[texture(0)]]
) {
  constexpr sampler stableInkSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
  );
  return stableInk.sample(stableInkSampler, input.textureCoordinate);
}

fragment half4 paperInkFragment(PaperInkVertexOut input [[stage_in]]) {
  return half4(input.premultipliedColor);
}
