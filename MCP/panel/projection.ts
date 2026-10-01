import type { PanelView } from './model.js';

const maximumViewport=2048,maximumPixels=16*1024*1024,maximumPixelScale=4;

/** Fit the transport coordinates to the screen without losing display pixels. */
export function panelProjection(width:number,height:number,displayScale:number,
  camera?:PanelView['camera'],reserveMotion=false):PanelView {
  width=Math.max(1,width);height=Math.max(1,height);
  const pixels=Math.max(1,Number.isFinite(displayScale)?displayScale:1);
  // Give visible pixels priority. Overscan only uses the remaining allocation.
  const pixelMargin=(Math.sqrt((width-height)**2+4*maximumPixels/pixels**2)-width-height)/4;
  const sideMargin=(maximumViewport*maximumPixelScale/pixels-Math.max(width,height))/2;
  const cameraMargin=camera?(maximumViewport*camera.scale/.0125-Math.max(width,height))/2:0;
  const margin=reserveMotion?Math.max(0,Math.min(256,Math.min(width,height)/4,pixelMargin,sideMargin,cameraMargin)):0;
  const renderWidth=width+2*margin,renderHeight=height+2*margin;
  const ratio=Math.min(1,maximumViewport/renderWidth,maximumViewport/renderHeight);
  const viewport={x:Math.max(1,Math.min(maximumViewport,renderWidth*ratio)),
    y:Math.max(1,Math.min(maximumViewport,renderHeight*ratio))};
  const pixelScale=Math.min(maximumPixelScale,pixels/ratio,
    Math.sqrt(maximumPixels/(viewport.x*viewport.y)));
  return {viewport,pixelScale,...(camera?{camera:{center:camera.center,
    scale:Math.max(.0125,Math.min(4,camera.scale*ratio))}}:{})};
}
