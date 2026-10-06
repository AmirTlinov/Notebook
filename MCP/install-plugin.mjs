import assert from 'node:assert/strict';
import { access, lstat, readFile, readdir, realpath } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { defaultPluginRoot, inspectRuntimeBundle } from './package-plugin-runtime.mjs';

const codex = process.env.CODEX_BIN || 'codex';
const action = process.argv[2] || 'check';
assert(['check', 'install', 'uninstall'].includes(action) && process.argv.length <= 3,
  'Usage: node MCP/install-plugin.mjs [check|install|uninstall]');
const stableSource = dirname(defaultPluginRoot());
const source = action === 'check' ? join(dirname(fileURLToPath(import.meta.url)), 'plugin') : stableSource;
const packageRoot = join(source, 'notebook');

const json = async path => JSON.parse(await readFile(path, 'utf8'));
function run(args, { optional = false } = {}) {
  const result = spawnSync(codex, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  if (!optional && result.status !== 0) throw new Error(result.error?.message || result.stderr || `${codex} ${args.join(' ')} failed`);
  return result;
}
async function inspect(path) {
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const child = join(path, entry.name), status = await lstat(child);
    assert(!status.isSymbolicLink() && (status.isFile() || status.isDirectory()), `Plugin contains an unsupported entry: ${child}`);
    // The signed runtime seals its own nested resources and internal aliases.
    if (child === join(packageRoot, 'runtime')) continue;
    if (status.isDirectory()) await inspect(child);
  }
}
async function bundledRuntime() {
  const app = join(packageRoot, 'runtime/NotebookRuntime.app');
  try { await access(app, constants.F_OK); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  return inspectRuntimeBundle(app);
}

await inspect(packageRoot);
const [manifest, mcp, marketplace] = await Promise.all([
  json(join(packageRoot, 'plugin.json')),
  json(join(packageRoot, 'mcp.json')), json(join(source, '.agents/plugins/marketplace.json')),
]);
assert.equal(manifest.name, 'notebook');
assert.equal(manifest.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
const presentation = manifest.extensions['com.openai'].interface;
assert(presentation.shortDescription.length <= 30);
// Portable packages discover mcp.json and skills/ at their fixed locations.
assert(!['mcpServers', 'skills', 'interface'].some(key => key in manifest));
assert.equal(marketplace.name, 'notebook-local');
assert.equal(marketplace.plugins.length, 1);
assert.equal(marketplace.plugins[0].source.path, './notebook');
const startup = mcp.mcpServers.notebook;
const resources = '${PLUGIN_ROOT}/runtime/NotebookRuntime.app/Contents/Resources';
assert.equal(startup.type, 'stdio');
assert.equal(startup.command, './runtime/NotebookRuntime.app/Contents/Resources/CodexRuntime/node');
assert.deepEqual(startup.args, [resources + '/NotebookTools/dist/launch-runtime.mjs']);
await access(join(packageRoot, presentation.logo));
const skill = await readFile(join(packageRoot, 'skills/notebook/SKILL.md'), 'utf8');
assert(skill.startsWith('---\nname: notebook\n') && skill.includes('notebook_open'));

const selector = `${manifest.name}@${marketplace.name}`;
if (action === 'check') {
  console.log(JSON.stringify({ package: packageRoot, selector, version: manifest.version,
    runtime: await bundledRuntime(), commands: [
      ['codex', 'plugin', 'marketplace', 'add', stableSource], ['codex', 'plugin', 'add', selector],
    ] }, null, 2));
} else if (action === 'install') {
  assert.equal(process.platform, 'darwin', 'The Notebook plugin includes a macOS runtime.');
  assert(await bundledRuntime(), 'Package the signed NotebookRuntime.app into the stable plugin source before installation.');
  // The merged MCP view also contains this installed plugin. Inspect global
  // configuration with plugins disabled for this read-only CLI invocation.
  const existing = run(['--disable', 'plugins', 'mcp', 'get', 'notebook', '--json'], { optional: true });
  if (existing.status === 0) assert(JSON.parse(existing.stdout).enabled === false,
    'An enabled global notebook MCP already provides these tools. Migrate that entry before installing the plugin.');
  else assert(existing.stderr.includes("No MCP server named 'notebook' found"), existing.stderr);
  const configured = JSON.parse(run(['plugin', 'marketplace', 'list', '--json']).stdout).marketplaces;
  const sameName = configured.find(item => item.name === marketplace.name);
  if (sameName) assert.equal(await realpath(sameName.root), await realpath(source), 'This marketplace name already belongs to another source.');
  console.log(run(['plugin', 'marketplace', 'add', source, '--json']).stdout.trim());
  console.log(run(['plugin', 'add', selector, '--json']).stdout.trim());
  console.error('Notebook installed. Existing Codex chats can retain their previous MCP connection. '
    + 'If notebook_open or resources/read is missing, restart Codex to reconnect the existing chat, or open Notebook in a new chat.');
} else {
  console.log(run(['plugin', 'remove', selector, '--json']).stdout.trim());
  const configured = JSON.parse(run(['plugin', 'marketplace', 'list', '--json']).stdout).marketplaces;
  const local = configured.find(item => item.name === marketplace.name);
  if (local && resolve(local.root) === resolve(source)) {
    console.log(run(['plugin', 'marketplace', 'remove', marketplace.name, '--json']).stdout.trim());
  }
}
