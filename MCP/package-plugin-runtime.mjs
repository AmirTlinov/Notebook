import assert from 'node:assert/strict';
import { access, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** A worktree release updates the existing marketplace in the primary checkout. */
export function defaultPluginRoot() {
  const result = spawnSync('git', ['-C', repository, 'worktree', 'list', '--porcelain', '-z'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || 'Cannot locate the primary Notebook checkout.');
  const first = result.stdout.split('\0')[0];
  assert(first.startsWith('worktree '), 'Git did not identify the primary checkout.');
  return join(first.slice('worktree '.length), 'MCP/plugin/notebook');
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  assert.equal(result.status, 0, result.error?.message || result.stderr || `${command} failed`);
  return result.stdout;
}

export async function inspectRuntimeBundle(app) {
  assert.equal(process.platform, 'darwin', 'Notebook runtime packaging requires macOS.');
  const directory = await lstat(app);
  assert(directory.isDirectory() && !directory.isSymbolicLink(), 'Runtime must be a regular app bundle directory.');
  const info = JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(app, 'Contents/Info.plist')]));
  assert.equal(info.CFBundleIdentifier, 'com.amirtlinov.notebook.mac');
  assert.equal(info.CFBundleExecutable, 'NotebookRuntime');
  assert.equal(info.CFBundleName, 'NotebookRuntime');
  assert.equal(info.CFBundlePackageType, 'APPL');
  assert(typeof info.CFBundleVersion === 'string' && info.CFBundleVersion.trim(), 'Runtime must have a build identity.');
  assert.equal(info.LSUIElement, true, 'The plugin runtime must not create a Dock application.');
  assert.equal(info.NotebookPluginRuntime, true, 'The app must use the plugin runtime entrypoint.');
  const tools = join(app, 'Contents/Resources/NotebookTools/dist');
  await Promise.all([
    access(join(app, 'Contents/MacOS/NotebookRuntime'), constants.X_OK),
    access(join(app, 'Contents/Resources/CodexRuntime/node'), constants.X_OK),
    access(join(tools, 'launch-runtime.mjs'), constants.R_OK),
    access(join(tools, 'index.mjs'), constants.R_OK),
  ]);
  const entry = await readFile(join(tools, 'index.mjs'), 'utf8');
  assert(entry.includes('notebook_open') && entry.includes('notebook_panel_presentation')
    && entry.includes('ui://notebook/workspace.html'), 'Runtime does not contain the Notebook panel.');
  run('/usr/bin/codesign', ['--verify', '--strict', '--deep', app]);
  return { app, bundleID: info.CFBundleIdentifier, version: info.CFBundleVersion, panelReady: true };
}

/** Copies the already signed product; the package never re-signs or edits it. */
export async function packageRuntime(app, pluginRoot, { inspect = inspectRuntimeBundle, copy } = {}) {
  const manifest = JSON.parse(await readFile(join(pluginRoot, 'plugin.json'), 'utf8'));
  assert.equal(manifest.name, 'notebook');
  const root = await realpath(pluginRoot), source = await realpath(app);
  const output = join(root, 'runtime');
  assert(!source.startsWith(output + sep) && source !== output, 'Package from a build product, not the current plugin runtime.');
  await inspect(app);
  const stage = await mkdtemp(join(root, '.runtime-stage-'));
  const prepared = join(stage, 'runtime'), bundled = join(prepared, 'NotebookRuntime.app');
  const retired = join(stage, 'retired');
  let replaced = false, preserveStage = false;
  try {
    await mkdir(prepared);
    if (copy) await copy(source, bundled);
    else run('/usr/bin/ditto', [source, bundled]);
    const result = await inspect(bundled);
    try {
      const current = await lstat(output);
      assert(current.isDirectory() && !current.isSymbolicLink(), 'Plugin runtime output must be an ordinary directory.');
      await rename(output, retired); replaced = true;
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try { await rename(prepared, output); }
    catch (error) {
      if (replaced) {
        try { await rename(retired, output); }
        catch (restoreError) {
          preserveStage = true;
          throw new AggregateError([error, restoreError], `Previous runtime remains at ${retired}`);
        }
      }
      throw error;
    }
    return { ...result, app: join(output, 'NotebookRuntime.app') };
  } finally { if (!preserveStage) await rm(stage, { recursive: true, force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert(process.argv.length >= 3 && process.argv.length <= 4,
    'Usage: node MCP/package-plugin-runtime.mjs <signed NotebookRuntime.app> [plugin-root]');
  const result = await packageRuntime(resolve(process.argv[2]), resolve(process.argv[3] ?? defaultPluginRoot()));
  console.log(JSON.stringify(result, null, 2));
}
