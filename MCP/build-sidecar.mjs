import { build } from 'esbuild';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const output = resolve(process.argv[2]);
await mkdir(resolve(output, 'dist'), { recursive: true });
await build({ entryPoints: [resolve(root, 'src/index.ts')], bundle: true, platform: 'node', target: 'node22', format: 'esm',
  outfile: resolve(output, 'dist/index.mjs'), banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
const pkg = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
await writeFile(resolve(output, 'package.json'), JSON.stringify({name: pkg.name, version: pkg.version, type: 'module'}));
