# Offline recognition candidate measurement

This harness measures **TexTeller 3 / ONNX q8**. It is not Notebook's integrated
recognizer. Model images and expected transcriptions do not establish binding
to real Pencil stroke IDs or points. No cloud recognition service, paid API,
SDK certificate, or substituted recognition output is used.

## Reproduce

From the repository root, prepare dependencies with network access:

```sh
python3 Tests/NotebookRecognitionHarness/prepare.py
npm ci --ignore-scripts --prefix Tests/NotebookRecognitionHarness
```

Check image preprocessing, then run the actual model with networking denied:

```sh
npm test --prefix Tests/NotebookRecognitionHarness
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  node Tests/NotebookRecognitionHarness/evaluate.mjs
```

The report is `.build/recognition-result.json`. Its `status:not_accepted`
remains unaccepted even if five examples match. This does not establish iPad
execution, memory bounds, stroke binding, ambiguity calibration, or independent
accuracy; upstream examples may have appeared in training. Do not register this
as a passing integrated-recognition acceptance test.

## Sources and boundaries

- [TexTeller](https://github.com/OleehyO/TexTeller) is the source model.
  The [ONNX conversion](https://huggingface.co/onnx-community/TexTeller3-ONNX)
  publishes Apache-2.0 licensing. `model-lock.json` pins revision and hashes.
  Model files go only into `.build`, never a user archive.
- `preprocess.mjs` preserves aspect ratio, crops background, and prepares
  single-channel 448 × 448 input, based on
  [upstream preprocessing](https://github.com/OleehyO/TexTeller/blob/9b88cec77bda735aa16f9fc7e4ccb4eb1500a8b2/texteller/utils/image.py).
  Numerical equivalence with Torch remains unproven. Decoding starts with the
  tokenizer BOS rather than inherited EOS; upstream-model validation is pending.
- `evaluate.mjs` checks SHA-256 before loading models and images. It does not
  repair recognized numbers, signs, or structure. Comparison removes only
  whitespace and outer math delimiters.
- Five images come from the
  [UniMERNet demonstration](https://github.com/opendatalab/UniMERNet/tree/5a2c80d96b1d2dba447ff18d873e5fb73ba03c35/asset/streamlit_demo/DirectRecognition).
  The [dataset](https://huggingface.co/datasets/wanderkid/UniMER_Dataset) publishes
  Apache-2.0 licensing; the notice is retained. `fixtures.json` records origins,
  hashes, and explicitly identified visually transcribed expected strings.
  Chemistry is a diagnostic control, not supported product functionality.
- Node/Transformers.js belongs only to this measurement process. It is not the
  proposed iPad runtime. Dependencies pin Transformers.js 3.8.1 and Sharp 0.35.4;
  install scripts are disabled. The historical installation's `npm audit`
  reported no known vulnerabilities, not a permanent security guarantee.

The harness does not read NotebookStore, `NOTEBOOK_HOME`, installed apps, or MCP
delivery, and does not modify user ink.
