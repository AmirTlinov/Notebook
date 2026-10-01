import assert from 'node:assert/strict';
import test from 'node:test';
import { panelProjection } from '../panel/projection.js';
import { panelViewSchema } from '../src/panel-tools.js';

test('Retina projection preserves screen density through transport scaling and overscan',()=>{
  const center={tileX:0,tileY:0,localX:417,localY:597};
  for(const [width,height,dpr] of [[1064,750,2],[2200,1200,2],[3024,1600,1.5],[390,720,3]] as const){
    for(const scale of [.13,1,2])for(const reserve of [false,true]){
      const view=panelProjection(width,height,dpr,{center,scale},reserve);
      panelViewSchema.parse(view);
      assert.ok(Math.abs(view.camera!.scale*view.pixelScale-scale*dpr)<1e-9,
        `${width}×${height} @${dpr}: world pixels must match display pixels`);
      assert.deepEqual(view.camera!.center,center);
      assert.ok(view.viewport.x/view.camera!.scale>=width/scale-1e-9);
      assert.ok(view.viewport.y/view.camera!.scale>=height/scale-1e-9);
    }
  }
});

test('large displays and collapsed panels keep a finite admitted projection',()=>{
  for(const [width,height,dpr] of [[5120,2880,2],[0,0,2],[1,5000,2]] as const){
    const view=panelProjection(width,height,dpr);
    panelViewSchema.parse(view);
    assert.ok(view.viewport.x*view.viewport.y*view.pixelScale**2<=16_777_216.000001);
  }
});
