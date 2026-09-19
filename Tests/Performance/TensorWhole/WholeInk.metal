#include "../TensorGPU/TensorInk.metal"

InkSpace composeSpace(InkSpace outer, InkSpace inner) {
  float2x2 a=float2x2(float2(outer.x.x,outer.y.x),float2(outer.x.y,outer.y.y));
  float2x2 b=float2x2(float2(inner.x.x,inner.y.x),float2(inner.x.y,inner.y.y));
  float2x2 c=a*b;
  float2 t=inSpace(float2(inner.x.z,inner.y.z),outer);
  return {float4(c[0][0],c[1][0],t.x,0),float4(c[0][1],c[1][1],t.y,0)};
}
kernel void initializeWorldShapes(device const uint *packed [[buffer(0)]],
  device float4 *world [[buffer(1)]], uint id [[thread_position_in_grid]]) {
  world[id]=unpackShape(packed[id]);
}
// Eager control: one invocation per addressed node, real position and Q writes.
kernel void materializeWholeEdit(device Node *nodes [[buffer(0)]],
  device float4 *shapes [[buffer(1)]], constant InkSpace &delta [[buffer(2)]],
  constant uint2 &range [[buffer(3)]], uint id [[thread_position_in_grid]]) {
  if (id >= range.y) return;
  uint node=range.x+id;
  nodes[node].position=inSpace(nodes[node].position,delta);
  shapes[node]=shapeInSpace(shapes[node],delta);
}
// Lazy path: one owner, one state. Left composition preserves action order.
kernel void updateWholeSpace(device InkSpace *space [[buffer(0)]],
  constant InkSpace &delta [[buffer(2)]], uint id [[thread_position_in_grid]]) {
  if (id == 0) space[0]=composeSpace(delta,space[0]);
}
vertex DirectOut wholeInkVertex(device const Node *nodes [[buffer(0)]],
  device const float *shapes [[buffer(1)]], device const uint2 *caps [[buffer(2)]],
  constant Uniforms &u [[buffer(3)]], constant InkSpace &space [[buffer(4)]],
  uint vertexID [[vertex_id]]) {
  Evaluated v=evaluate(vertexID,nodes,shapes,caps,u.nodeCount,space);
  float2 unit=v.position/u.viewport;
  return {float4(unit.x*2-1,1-unit.y*2,0,1),v.color};
}
kernel void inspectWholePositions(device const Node *nodes [[buffer(0)]],
  device const float *shapes [[buffer(1)]], device const uint2 *caps [[buffer(2)]],
  constant Uniforms &u [[buffer(3)]], constant InkSpace &space [[buffer(4)]],
  device const uint *indices [[buffer(5)]], device float2 *output [[buffer(6)]],
  uint id [[thread_position_in_grid]]) {
  if (id < u.indexCount) output[id]=evaluate(indices[id],nodes,shapes,caps,u.nodeCount,space).position;
}
