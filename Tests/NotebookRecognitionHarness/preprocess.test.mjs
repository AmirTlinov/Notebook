import test from 'node:test';
import assert from 'node:assert/strict';
import {preprocess, RawImage, normalizeLatex} from './preprocess.mjs';

test('blank input cannot fabricate an expression', async () => {
  await assert.rejects(preprocess(new RawImage(new Uint8Array(30*20).fill(255),30,20,1)), /No visible ink/);
});
test('visible crop retains proportions and zero padding', async () => {
  const data = new Uint8Array(100*50).fill(255);
  for(let y=20;y<30;y++) for(let x=10;x<90;x++) data[y*100+x]=0;
  const result = await preprocess(new RawImage(data,100,50,1));
  assert.deepEqual(result.crop,[10,20,89,29]);
  assert.deepEqual(result.resized,[448,56]);
  assert.deepEqual(result.pixelValues.dims,[1,1,448,448]);
  assert.ok(result.pixelValues.data[0] < -6);
  assert.equal(result.pixelValues.data[56*448],0);
  assert.equal(data[0],255);
});
test('normalization never equates a different digit or sign', () => {
  assert.equal(normalizeLatex('\\[ 9 \\times 9 \\]'), '9\\times9');
  assert.notEqual(normalizeLatex('13x'),normalizeLatex('14x'));
  assert.notEqual(normalizeLatex('x^{2}'),normalizeLatex('x_{2}'));
  assert.notEqual(normalizeLatex('-3'),normalizeLatex('3'));
});
