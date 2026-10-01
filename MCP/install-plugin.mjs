import assert from 'node:assert/strict';
import { access, lstat, readFile, readdir, realpath } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const source = join(dirname(fileURLToPath(import.meta.url)), 'plugin');
const packageRoot = join(source, 'notebook');
const codex = process.env.CODEX_BIN || 'codex';
const action = process.argv[2] || 'check';
assert(['check', 'install', 'uninstall'].includes(action) && process.argv.length <= 3,
  'Usage: node MCP/install-plugin.mjs [check|install|uninstall]');

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
    if (status.isDirectory()) await inspect(child);
  }
}
async function installedApp() {
  const candidates = process.env.NOTEBOOK_APP ? [process.env.NOTEBOOK_APP]
    : [join(process.env.HOME, 'Applications/Notebook.app'), '/Applications/Notebook.app'];
  for (const app of candidates) {
    try {
      const node = join(app, 'Contents/Resources/CodexRuntime/node');
      const server = join(app, 'Contents/Resources/NotebookTools/dist/index.mjs');
      await access(node, constants.X_OK);
      const body = await readFile(server, 'utf8');
      return { app, panelReady: body.includes('notebook_open') && body.includes('notebook_panel_presentation')
        && body.includes('ui://notebook/workspace.html') };
    } catch (error) {
      if (!['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) throw error;
    }
  }
  return null;
}

await inspect(packageRoot);
const [manifest, mcp, marketplace] = await Promise.all([
  json(join(packageRoot, '.codex-plugin/plugin.json')),
  json(join(packageRoot, 'mcp.json')), json(join(source, '.agents/plugins/marketplace.json')),
]);
assert.equal(manifest.name, 'notebook');
assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
const presentation = manifest.interface;
assert(presentation.shortDescription.length <= 30);
assert.equal(manifest.mcpServers, './mcp.json');
assert.equal(manifest.skills, './skills/');
assert.equal(marketplace.name, 'notebook-local');
assert.equal(marketplace.plugins.length, 1);
assert.equal(marketplace.plugins[0].source.path, './notebook');
const startup = mcp.mcpServers.notebook;
assert.equal(startup.type, 'stdio'); assert.equal(startup.command, '/bin/sh');
assert.equal(startup.args[0], '-c'); assert.equal(startup.args.length, 2);
assert(!startup.args[1].includes('${PLUGIN_ROOT}'));
const syntax = spawnSync('/bin/sh', ['-n'], { input: startup.args[1], encoding: 'utf8' });
assert.equal(syntax.status, 0, syntax.stderr);
await access(join(packageRoot, presentation.logo));
const skill = await readFile(join(packageRoot, 'skills/notebook/SKILL.md'), 'utf8');
assert(skill.startsWith('---\nname: notebook\n') && skill.includes('notebook_open'));

const selector = `${manifest.name}@${marketplace.name}`;
if (action === 'check') {
  console.log(JSON.stringify({ package: packageRoot, selector, version: manifest.version,
    runtime: await installedApp(), commands: [
      ['codex', 'plugin', 'marketplace', 'add', source], ['codex', 'plugin', 'add', selector],
    ] }, null, 2));
} else if (action === 'install') {
  assert.equal(process.platform, 'darwin', 'The Notebook plugin uses the installed macOS runtime.');
  const runtime = await installedApp();
  assert(runtime?.panelReady, 'Install the signed Notebook update with native panel presentation before installing this plugin.');
  const signature = spawnSync('/usr/bin/codesign', ['--verify', '--strict', '--deep', runtime.app], { encoding: 'utf8' });
  assert.equal(signature.status, 0, signature.stderr);
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
} else {
  console.log(run(['plugin', 'remove', selector, '--json']).stdout.trim());
  const configured = JSON.parse(run(['plugin', 'marketplace', 'list', '--json']).stdout).marketplaces;
  const local = configured.find(item => item.name === marketplace.name);
  if (local && resolve(local.root) === resolve(source)) {
    console.log(run(['plugin', 'marketplace', 'remove', marketplace.name, '--json']).stdout.trim());
  }
}
