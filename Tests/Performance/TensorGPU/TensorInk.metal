#include <metal_stdlib>
using namespace metal;

// The same indexed geometry evaluator owns rendering and verification readback.
// No generated triangle buffer, prefix scan, radius table, or node search.
constant bool tensorMode [[function_constant(0)]];
constant bool bitShapeMode [[function_constant(1)]];
struct Node {
  float2 position;
  uint previous;
  uint next;
  float4 color;
};
struct Uniforms { float2 viewport; uint nodeCount; uint indexCount; };
struct DirectOut { float4 position [[position]]; float4 premultipliedColor; };
struct Evaluated { float2 position; float4 color; };

float2 direction(float2 from, float2 to) {
  float2 d = to - from;
  return dot(d,d) > 0.0001f ? normalize(d) : float2(1,0);
}
// One authoritative 32-bit shape word: signed log2(min radius) in 12 bits,
// log2(axis ratio) in 10 bits, angle phase in 10 bits. No lookup table.
float4 unpackShape(uint word) {
  int base = int(word & 4095); if (base >= 2048) base -= 4096;
  float r = exp2(float(base)/256.0f);
  float major = r*exp2(float((word >> 12) & 1023)/128.0f);
  float angle = float(word >> 22)*(2.0f*M_PI_F/1024.0f);
  float c=cos(angle), s=sin(angle), a=major*major, b=r*r;
  return float4(a*c*c+b*s*s,(a-b)*c*s,a*s*s+b*c*c,0);
}
uint packShape(float4 q) {
  float mid=(q.x+q.z)*0.5f;
  float difference=length(float2((q.x-q.z)*0.5f,q.y));
  float low=max(mid-difference,1e-12f), high=max(mid+difference,low);
  int base=clamp(int(round(log2(low)*128.0f)),-2048,2047);
  uint ratio=uint(clamp(round(log2(high/low)*64.0f),0.0f,1023.0f));
  int phase=int(round(atan2(2*q.y,q.x-q.z)*(256.0f/M_PI_F)));
  return (uint(base)&4095) | (ratio<<12) | ((uint(phase)&1023)<<22);
}

float2 support(uint id, float2 normal, device const float *shapes) {
  if (!tensorMode) return normal * shapes[id];
  float4 q = bitShapeMode ? unpackShape(((device const uint *)shapes)[id])
    : ((device const float4 *)shapes)[id]; // Qxx, Qxy, Qyy, reserved
  float2 v = float2(q.x * normal.x + q.y * normal.y, q.y * normal.x + q.z * normal.y);
  return v / sqrt(max(dot(normal, v), 1e-12f));
}
float2 crossSection(uint id, device const Node *nodes, device const float *shapes) {
  Node n = nodes[id];
  float2 incoming = n.previous == id ? direction(n.position, nodes[n.next].position)
    : direction(nodes[n.previous].position, n.position);
  float2 outgoing = n.next == id ? incoming : direction(n.position, nodes[n.next].position);
  float2 sum = float2(-incoming.y-outgoing.y, incoming.x+outgoing.x);
  float2 outNormal = float2(-outgoing.y,outgoing.x);
  float2 normal = dot(sum,sum) > 0.0001f ? normalize(sum) : outNormal;
  float denominator = max(abs(dot(normal,outNormal)),0.55f);
  return support(id,normal,shapes) * min(1.0f/denominator,1.8f);
}
Evaluated evaluate(uint vertexID, device const Node *nodes, device const float *shapes,
  device const uint2 *caps, uint nodeCount) {
  uint node;
  float2 offset;
  if (vertexID < 2 * nodeCount) {
    node = vertexID / 2;
    offset = crossSection(node,nodes,shapes) * ((vertexID & 1) ? -1.0f : 1.0f);
  } else {
    uint capVertex = vertexID - 2 * nodeCount;
    uint2 cap = caps[capVertex / 32];
    uint local = capVertex % 32;
    node = cap.x;
    offset = float2(0);
    if (local > 0) {
      uint segments = cap.y == 2 ? 24 : 12;
      float start = 0;
      float sweep = 2.0f * M_PI_F;
      if (cap.y != 2) {
        Node n = nodes[node];
        float2 outward = cap.y == 0 ? -direction(n.position,nodes[n.next].position)
          : direction(nodes[n.previous].position,n.position);
        start = atan2(outward.y,outward.x) - M_PI_F / 2.0f;
        sweep = M_PI_F;
      }
      uint arc = local - 1;
      float angle = cap.y == 2 && arc == segments ? start : start + (float(arc)/float(segments))*sweep;
      offset = support(node,float2(cos(angle),sin(angle)),shapes);
    }
  }
  return {nodes[node].position + offset, nodes[node].color};
}
vertex DirectOut directInkVertex(device const Node *nodes [[buffer(0)]],
  device const float *shapes [[buffer(1)]], device const uint2 *caps [[buffer(2)]],
  constant Uniforms &u [[buffer(3)]], uint vertexID [[vertex_id]]) {
  Evaluated v = evaluate(vertexID,nodes,shapes,caps,u.nodeCount);
  float2 unit = v.position/u.viewport;
  return {float4(unit.x*2.0f-1.0f,1.0f-unit.y*2.0f,0,1),v.color};
}
struct TileUniforms { float2 viewport; float2 origin; uint2 counts; };
vertex DirectOut tileInkVertex(device const Node *nodes [[buffer(0)]],
  device const float *shapes [[buffer(1)]], device const uint2 *caps [[buffer(2)]],
  constant TileUniforms &u [[buffer(3)]], uint vertexID [[vertex_id]]) {
  Evaluated v = evaluate(vertexID,nodes,shapes,caps,u.counts.x);
  float2 unit = (v.position-u.origin)/u.viewport;
  return {float4(unit.x*2.0f-1.0f,1.0f-unit.y*2.0f,0,1),v.color};
}
kernel void inspectPositions(device const Node *nodes [[buffer(0)]],
  device const float *shapes [[buffer(1)]], device const uint2 *caps [[buffer(2)]],
  constant Uniforms &u [[buffer(3)]], device const uint *indices [[buffer(4)]],
  device float2 *output [[buffer(5)]], uint id [[thread_position_in_grid]]) {
  if (id < u.indexCount) output[id] = evaluate(indices[id],nodes,shapes,caps,u.nodeCount).position;
}

// One invocation per DISTINCT addressed node. Host rejects duplicates in a batch.
// kind 0 = uniform pressure, 1 = stretch across local stroke, 2 = rotate shape.
// sign bit 0/1 means inverse/forward relation. k=0 gives scales 1/2 and 2/1.
float4 transformShape(float4 value, uint4 edit, device const Node *nodes) {
  float step = exp2(-float(edit.w));
  float sign = edit.z == 0 ? -1.0f : 1.0f;
  float scale = exp2(sign*step);
  float2x2 a;
  if (edit.y == 0) a = float2x2(float2(scale,0),float2(0,scale));
  else if (edit.y == 1) {
    Node n = nodes[edit.x];
    float2 d = direction(nodes[n.previous].position,nodes[n.next].position);
    float2 axis = float2(-d.y,d.x);
    float k = scale-1;
    a = float2x2(float2(1+k*axis.x*axis.x,k*axis.x*axis.y),float2(k*axis.x*axis.y,1+k*axis.y*axis.y));
  } else {
    float angle = sign*step*M_PI_F/4;
    float c = cos(angle), s = sin(angle);
    a = float2x2(float2(c,s),float2(-s,c));
  }
  float2x2 q = float2x2(float2(value.x,value.y),float2(value.y,value.z));
  q = a*q*transpose(a);
  return float4(q[0][0],(q[0][1]+q[1][0])*0.5f,q[1][1],0);
}
kernel void editTensor(device float4 *shapes [[buffer(0)]],
  device const Node *nodes [[buffer(1)]], device const uint4 *edits [[buffer(2)]],
  constant uint &count [[buffer(3)]], uint id [[thread_position_in_grid]]) {
  if (id < count) {
    uint4 edit=edits[id];
    shapes[edit.x]=transformShape(shapes[edit.x],edit,nodes);
  }
}
kernel void editBitShape(device uint *shapes [[buffer(0)]],
  device const Node *nodes [[buffer(1)]], device const uint4 *edits [[buffer(2)]],
  constant uint &count [[buffer(3)]], uint id [[thread_position_in_grid]]) {
  if (id < count) {
    uint4 edit=edits[id];
    if (edit.y == 0) {
      // Uniform pressure is exact integer modification of the addressed bits.
      int base=int(shapes[edit.x]&4095); if (base >= 2048) base-=4096;
      int delta=int(round(exp2(8.0f-float(edit.w))));
      base=clamp(base+(edit.z == 0 ? -delta : delta),-2048,2047);
      shapes[edit.x]=(shapes[edit.x]&0xfffff000u)|(uint(base)&4095);
    } else {
      shapes[edit.x]=packShape(transformShape(unpackShape(shapes[edit.x]),edit,nodes));
    }
  }
}
kernel void editScalar(device float *radii [[buffer(0)]], device const uint4 *edits [[buffer(2)]],
  constant uint &count [[buffer(3)]], uint id [[thread_position_in_grid]]) {
  if (id < count) {
    uint4 edit = edits[id];
    float sign = edit.z == 0 ? -1.0f : 1.0f;
    radii[edit.x] *= exp2(sign*exp2(-float(edit.w)));
  }
}
