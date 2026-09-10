import {RawImage, Tensor} from '@huggingface/transformers';

// TexTeller's input contract: grayscale, preserved aspect, top-left placement,
// normalized pixels followed by zero padding (not a stretched square).
// Numerical parity with the original Torch preprocessing is a separate gate.
export async function preprocess(image) {
  const img = image.clone().rgb();
  const corners = [0, img.width-1, (img.height-1)*img.width, img.width*img.height-1];
  const counts = new Map();
  for (const i of corners) {
    const color = Array.from(img.data.subarray(i*3, i*3+3)).join(',');
    counts.set(color, (counts.get(color) ?? 0)+1);
  }
  const background = [...counts].sort((a,b) => b[1]-a[1])[0][0].split(',').map(Number);
  let x0=img.width, y0=img.height, x1=-1, y1=-1;
  for (let y=0; y<img.height; y++) for (let x=0; x<img.width; x++) {
    const i=(y*img.width+x)*3;
    // Upstream trim_white_border uses OpenCV BGR2GRAY on RGB differences.
    const difference = 0.114*Math.abs(img.data[i]-background[0])
      + 0.587*Math.abs(img.data[i+1]-background[1]) + 0.299*Math.abs(img.data[i+2]-background[2]);
    if (difference > 15) { x0=Math.min(x0,x); y0=Math.min(y0,y); x1=Math.max(x1,x); y1=Math.max(y1,y); }
  }
  if (x1 < x0 || y1 < y0) throw new Error('No visible ink');
  let cropped = (await img.crop([x0,y0,x1,y1])).grayscale();
  const scale = Math.min(447/Math.min(cropped.width,cropped.height),448/Math.max(cropped.width,cropped.height));
  cropped = await cropped.resize(Math.max(1,Math.floor(cropped.width*scale)), Math.max(1,Math.floor(cropped.height*scale)), {resample:3});
  const pixels = new Float32Array(448*448);
  for (let y=0; y<cropped.height; y++) for (let x=0; x<cropped.width; x++) {
    pixels[y*448+x] = (cropped.data[y*cropped.width+x]/255-0.9545467)/0.15394445;
  }
  return {pixelValues: new Tensor('float32',pixels,[1,1,448,448]), crop:[x0,y0,x1,y1], resized:[cropped.width,cropped.height]};
}

export function normalizeLatex(source) {
  // Spacing and display wrappers only. Never repair signs, numbers or structure.
  return source.replace(/^\\\[/, '').replace(/\\\]$/, '').replace(/\s+/g, '');
}

export {RawImage};
