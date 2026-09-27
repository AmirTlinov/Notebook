#include <metal_stdlib>
using namespace metal;
struct InkNode { float2 position; float2 edge; float radius; float alpha; };
struct InkPrimitive { uint count; uint flags; uint2 reserved; float4 color; };
struct InkAffine { float4 x; float4 y; };
struct CompactInkOut { float4 position [[position]]; float4 premultipliedColor; };
float2 inkDirection(float2 a,float2 b) {
  float2 d=b-a;
  if (!(dot(d,d)>0.0001f)) return float2(1,0);
  // Match the exact axis directions of InkStrokeGeometry.
  if (d.y==0) return float2(d.x>0 ? 1:-1,0);
  if (d.x==0) return float2(0,d.y>0 ? 1:-1);
  return normalize(d);
}
float2 inkArc(InkNode n,uint slot,uint segments,float start,float sweep) {
  if (slot == 0) return n.position;
  float angle=start+float(slot-1)/float(segments)*sweep;
  return n.position+float2(cos(angle),sin(angle))*n.radius;
}
vertex CompactInkOut compactInkVertex(device const InkNode *nodes [[buffer(0)]],
  constant float2 &viewport [[buffer(1)]], constant InkAffine &affine [[buffer(2)]],
  constant InkPrimitive &p [[buffer(3)]], uint id [[vertex_id]]) {
  uint node=0; float2 pos;
  if (p.flags&8) { node=id;pos=nodes[node].position; }
  else if (p.count == 1) { pos=inkArc(nodes[0],id,24,0,2*M_PI_F); }
  else if (p.flags&4) {
    if (id<25) { pos=inkArc(nodes[0],id,24,0,2*M_PI_F); }
    else {
      uint segment=(id-25)/29,slot=(id-25)%29;
      if (slot<4) {
        node=segment+(slot/2);
        float2 d=inkDirection(nodes[segment].position,nodes[segment+1].position);
        pos=nodes[node].position+float2(-d.y,d.x)*nodes[node].radius*(slot%2 == 0 ? 1.0f:-1.0f);
      } else { node=segment+1;pos=inkArc(nodes[node],slot-4,24,0,2*M_PI_F); }
    }
  } else if (id<514) {
    node=id/2;pos=nodes[node].position+nodes[node].edge*(id%2 == 0 ? 1.0f:-1.0f);
  } else {
    bool first=id<528;
    node=first ? 0:p.count-1;
    float2 outward=first ? -inkDirection(nodes[0].position,nodes[1].position):inkDirection(nodes[p.count-2].position,nodes[p.count-1].position);
    pos=inkArc(nodes[node],id-(first ? 514:528),12,atan2(outward.y,outward.x)-M_PI_F/2,M_PI_F);
  }
  float2 world=float2(dot(affine.x.xy,pos)+affine.x.z,dot(affine.y.xy,pos)+affine.y.z);
  float2 unit=world/max(viewport,float2(1));float alpha=nodes[node].alpha;
  return {float4(unit.x*2-1,1-unit.y*2,0,1),float4(p.color.rgb*alpha,alpha)};
}

// Reverse outer composition. Local body layers are rendered forward into their
// isolated attachment before the fold; historical raw cuts never touch it.
struct OrderedInkState { float4 value [[color(0),raster_order_group(0)]]; float weight [[color(1),raster_order_group(0)]]; };
struct OrderedInkBody { half4 color [[color(2),raster_order_group(0)]]; };
struct OrderedInkFinal { half4 color [[color(3),raster_order_group(0)]]; };
struct OrderedInkQuad { float4 position [[position]]; float2 textureCoordinate; };
fragment OrderedInkState orderedInkRawFragment(CompactInkOut input [[stage_in]],
  float4 value [[color(0),raster_order_group(0)]], float weight [[color(1),raster_order_group(0)]],
  constant uint &erases [[buffer(0)]], uint sample [[sample_id]]) {
  float4 c=input.premultipliedColor;
  if (!erases) {value.rgb += c.rgb*weight;value.a -= c.a*weight;}
  return {value,weight*(1-c.a)};
}
fragment OrderedInkBody orderedInkBodyFragment(CompactInkOut input [[stage_in]]) {return {half4(input.premultipliedColor)};}
fragment OrderedInkState orderedInkFoldFragment(OrderedInkQuad input [[stage_in]],
  float4 value [[color(0),raster_order_group(0)]], float weight [[color(1),raster_order_group(0)]],
  half4 body [[color(2),raster_order_group(0)]], uint sample [[sample_id]]) {
  value.rgb += float3(body.rgb)*value.a;value.a *= 1-float(body.a);
  return {value,weight*(1-float(body.a))};
}
fragment OrderedInkBody orderedInkClearFragment(OrderedInkQuad input [[stage_in]]) {return {half4(0)};}
fragment OrderedInkFinal orderedInkFinalFragment(OrderedInkQuad input [[stage_in]],
  float4 value [[color(0),raster_order_group(0)]], uint sample [[sample_id]]) {return {half4(float4(value.rgb,1-value.a))};}
fragment OrderedInkState orderedInkBaselineFragment(OrderedInkQuad input [[stage_in]],
  float4 value [[color(0),raster_order_group(0)]], float weight [[color(1),raster_order_group(0)]],
  texture2d<half> baseline [[texture(0)]], uint sample [[sample_id]]) {
  constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
  float4 c=float4(baseline.sample(s,input.textureCoordinate));
  value.rgb += c.rgb*weight;value.a -= c.a*weight;
  return {value,weight*(1-c.a)};
}
