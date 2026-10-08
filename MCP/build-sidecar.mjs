import { build } from 'esbuild';
import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { resolve, dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const output = resolve(process.argv[2]);
const temporary = resolve(process.argv[3] ?? dirname(output));
if (temporary === output || temporary.startsWith(output + sep)) throw new Error('NotebookTools staging must be outside its output.');
await mkdir(temporary, {recursive:true});
const stage = await mkdtemp(join(temporary, '.notebook-tools-'));
const prepared = join(stage, 'NotebookTools'), retired = join(stage, 'previous');
let replaced = false, preserveStage = false;
try {
  await mkdir(join(prepared, 'dist'), {recursive:true});
  await build({ entryPoints: {index:resolve(root, 'src/index.ts'),'launch-runtime':resolve(root,'src/runtime-launcher.ts')}, bundle: true, platform: 'node', target: 'node22', format: 'esm',
    outdir: join(prepared, 'dist'), outExtension:{'.js':'.mjs'}, banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
  const pkg = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
  await writeFile(join(prepared, 'package.json'), JSON.stringify({name: pkg.name, version: pkg.version, type: 'module'}));
  // Xcode grants literal output paths. Retire the whole old tree into its
  // permitted temporary directory before replacing this producer's payload.
  try { await rename(output, retired); replaced = true; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  try { await rename(prepared, output); }
  catch (error) {
    if (replaced) {
      try { await rename(retired, output); }
      catch (restoreError) {
        preserveStage = true;
        throw new AggregateError([error, restoreError], `Previous NotebookTools remains at ${retired}`);
      }
    }
    throw error;
  }
} finally { if (!preserveStage) await rm(stage, {recursive:true, force:true}); }
