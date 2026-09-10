import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {pipeline, env} from '@huggingface/transformers';
import {preprocess, RawImage, normalizeLatex} from './preprocess.mjs';

const root = path.resolve(import.meta.dirname, '../..');
const modelPath = path.join(root,'.build/recognition-model');
const lock = JSON.parse(await fs.readFile(path.join(import.meta.dirname,'model-lock.json')));
for (const entry of lock.files) {
  const bytes = await fs.readFile(path.join(modelPath,entry.path));
  if (bytes.length !== entry.bytes || crypto.createHash('sha256').update(bytes).digest('hex') !== entry.sha256) {
    throw new Error('Invalid model resource: ' + entry.path);
  }
}
env.allowRemoteModels = false;
env.allowLocalModels = true;
const started = performance.now();
const recognizer = await pipeline('image-to-text', modelPath, {dtype:'q8', device:'cpu', local_files_only:true});
const loadMS = performance.now()-started;
const fixtures = JSON.parse(await fs.readFile(path.join(import.meta.dirname,'fixtures.json')));
const results = [];
try {
  for (const fixture of fixtures.samples) {
    const input = path.join(import.meta.dirname,'fixtures',fixture.file);
    const bytes = await fs.readFile(input);
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== fixture.sha256) throw new Error('Changed fixture');
    const began = performance.now();
    const {pixelValues} = await preprocess(await RawImage.read(input));
    const output = await recognizer.model.generate({
      pixel_values:pixelValues, max_new_tokens:192,
      // The converted decoder inherited EOS=2 as start. This profile explicitly
      // supplies the tokenizer BOS. Original Torch parity is not yet certified.
      decoder_start_token_id:recognizer.tokenizer.bos_token_id,
    });
    const latex = recognizer.tokenizer.batch_decode(output,{skip_special_tokens:true})[0];
    const row = {file:fixture.file, latex, expected:fixture.expected,
      matches:normalizeLatex(latex) === normalizeLatex(fixture.expected),
      milliseconds:performance.now()-began, rssBytes:process.memoryUsage().rss};
    results.push(row);
    console.log(JSON.stringify(row));
  }
} finally { await recognizer.dispose(); }
const report = {candidate:lock.repository, revision:lock.revision, loadMS, results,
  status:'not_accepted',
  limitations:['Author demo samples, not held-out accuracy', 'No physical iPad evidence',
    'No stroke/token alignment', 'No calibrated ambiguity scores', 'No native preprocessing parity'],
};
const output = path.join(root,'.build/recognition-result.json');
await fs.writeFile(output,JSON.stringify(report,null,2)+'\n');
console.log(`NOT ACCEPTED for Notebook: ${results.filter(r=>r.matches).length}/${results.length} exact sample transcriptions; ${output}`);
