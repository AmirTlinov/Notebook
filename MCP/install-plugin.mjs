import assert from 'node:assert/strict';
import { access, realpath } from 'node:fs/promises';
import { fstatSync, lstatSync } from 'node:fs';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { inspectRuntimeBundle } from './package-plugin-runtime.mjs';
import { inspectPluginMetadata, inspectMarketplace, marketplaceFile, marketplaceName, pluginID, readJSON,
  publicationRoot, publishedPlugin, publishPlugin, pluginInventory, migrateMarketplace, pendingSourceMigration, prunePublications } from './plugin-publication.mjs';

const codex = process.env.CODEX_BIN || 'codex', root = publicationRoot();
const directory = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2), leaseIndex = args.indexOf('--publication-fd');
let lease;
if (leaseIndex >= 0) {
  assert.equal(leaseIndex, args.length - 2);
  lease = Number(args[leaseIndex + 1]); args.splice(leaseIndex);
}
const action = args[0] || 'check';
assert(['check', 'location', 'preflight', 'migrate-source', 'install', 'uninstall', 'publish', 'prune'].includes(action)
  && args.length <= (action === 'publish' ? 2 : 1), 'Use notebook_release.py for publication, migration and pair installation.');
if (['publish', 'prune', 'migrate-source', 'install'].includes(action)) {
  assert(Number.isSafeInteger(lease) && lease > 2, 'The Python release owner must hold the publication lease.');
  const inherited = fstatSync(lease), owner = lstatSync(join(root, '.publication.owner'));
  assert(inherited.isFile() && !owner.isSymbolicLink() && inherited.nlink === 1
    && inherited.uid === process.getuid() && (inherited.mode & 0o777) === 0o600
    && inherited.dev === owner.dev && inherited.ino === owner.ino, 'Invalid inherited publication lease.');
}

function command(args, { optional = false } = {}) {
  // The CLI may outlive this adapter after a timeout or process exit. Its FD
  // must keep the same OS lease until the registry/cache operation finishes.
  const result = spawnSync(codex, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
    stdio: lease === undefined ? 'pipe' : ['pipe', 'pipe', 'pipe', lease] });
  if (!optional && result.status !== 0) throw new Error(result.error?.message || result.stderr || `${codex} ${args.join(' ')} failed`);
  return result;
}
const run = async args => JSON.parse(command(args).stdout);
const marketplaces = async () => (await run(['plugin', 'marketplace', 'list', '--json'])).marketplaces;
const installed = async () => (await run(['plugin', 'list', '--json'])).installed.filter(row => row.pluginId === pluginID);

async function cachedPlugin() {
  const rows = await installed(); assert.equal(rows.length, 1);
  const transport = (await run(['mcp', 'get', 'notebook', '--json'])).transport;
  assert.equal(transport.type, 'stdio');
  const app = resolve(dirname(transport.command), '../../..'), plugin = resolve(app, '../..');
  assert.equal(transport.command, join(app, 'Contents/Resources/CodexRuntime/node'));
  assert.deepEqual(transport.args, [join(app, 'Contents/Resources/NotebookTools/dist/launch-runtime.mjs')]);
  return inspectCachedPlugin(plugin, rows[0].version);
}

async function inspectCachedPlugin(plugin, version) {
  assert.equal(basename(plugin), version);
  assert.equal(basename(dirname(plugin)), 'notebook');
  assert.equal(basename(resolve(plugin, '../..')), marketplaceName);
  assert.equal(basename(resolve(plugin, '../../..')), 'cache');
  const manifest = await inspectPluginMetadata(plugin);
  assert.equal(manifest.version, version);
  const runtime = await inspectRuntimeBundle(join(plugin, 'runtime/NotebookRuntime.app'));
  return { plugin, version: manifest.version, build: runtime.version, inventory: await pluginInventory(plugin) };
}

if (action === 'location') {
  console.log(JSON.stringify({ root }));
} else if (action === 'check') {
  const source = join(directory, 'plugin'), plugin = join(source, 'notebook');
  const manifest = await inspectPluginMetadata(plugin);
  const marketplace = inspectMarketplace(await readJSON(join(source, marketplaceFile)));
  assert.equal(marketplace.plugins[0].source.path, './notebook');
  let runtime = null;
  try { await access(join(plugin, 'runtime/NotebookRuntime.app')); runtime = await inspectRuntimeBundle(join(plugin, 'runtime/NotebookRuntime.app')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  console.log(JSON.stringify({ source: plugin, selector: pluginID, version: manifest.version, runtime,
    publication: root, install: 'Applications/notebook_release.py install-pair' }, null, 2));
} else if (action === 'preflight') {
  const current = (await marketplaces()).find(item => item.name === marketplaceName);
  if (current) assert.equal(await realpath(current.root), await realpath(root),
    'Run notebook_release.py migrate-plugin-source before changing the authored plugin version.');
  let catalogExists = true;
  try { await access(join(root, marketplaceFile)); }
  catch (error) { if (error.code !== 'ENOENT') throw error; catalogExists = false; }
  const ready = catalogExists ? await publishedPlugin(root) : null;
  console.log(JSON.stringify({ root, plugin: ready?.plugin ?? null }));
} else if (action === 'publish') {
  assert.equal(args.length, 2, 'Publication requires the complete verified build package.');
  const source = resolve(args[1]);
  const marketplace = await readJSON(join(source, marketplaceFile));
  assert.equal(marketplace.plugins[0].source.path, './notebook');
  console.log(JSON.stringify(await publishPlugin(join(source, 'notebook'), root, marketplace), null, 2));
} else if (action === 'migrate-source') {
  const current = (await marketplaces()).find(item => item.name === marketplaceName);
  const pending = await pendingSourceMigration(root);
  assert(current || pending, 'Migration requires the existing Notebook marketplace.');
  const cache = pending ? await inspectCachedPlugin(pending.cacheRoot, pending.plugin.version) : await cachedPlugin();
  if (!pending && await realpath(current.root) === await realpath(root).catch(error => { if (error.code === 'ENOENT') return root; throw error; })) {
    const ready = await publishedPlugin(root);
    assert.equal(ready.manifest.version, cache.version);
    assert.deepEqual(ready.inventory, cache.inventory);
    console.log(JSON.stringify({ root, version: cache.version, build: cache.build, alreadyMigrated: true, cachePreserved: true }));
  } else {
    const git = spawnSync('git', ['-C', directory, 'worktree', 'list', '--porcelain', '-z'], { encoding: 'utf8' });
    assert.equal(git.status, 0, git.stderr);
    const first = git.stdout.split('\0')[0]; assert(first.startsWith('worktree '));
    const previous = join(first.slice('worktree '.length), 'MCP/plugin');
    if (!pending) assert.equal(await realpath(current.root), await realpath(previous), 'Migration only adopts the former authored Notebook marketplace.');
    const publication = await publishPlugin(cache.plugin, root, await readJSON(join(previous, marketplaceFile)));
    const migration = await migrateMarketplace(previous, root, { run, cacheRoot: cache.plugin, checkCache: async () => {
      assert.deepEqual(await pluginInventory(cache.plugin), cache.inventory, 'Installed cache changed during migration.');
    } });
    console.log(JSON.stringify({ ...migration, build: cache.build, publication }, null, 2));
  }
} else if (action === 'prune') {
  const ready = await publishedPlugin(root), cache = await cachedPlugin();
  assert.equal(cache.version, ready.manifest.version);
  assert.deepEqual(cache.inventory, ready.inventory);
  await prunePublications(root);
  console.log(JSON.stringify({ root, retainedPackages: 1 }));
} else if (action === 'install') {
  assert.equal(process.platform, 'darwin');
  const ready = await publishedPlugin(root);
  await inspectRuntimeBundle(join(ready.plugin, 'runtime/NotebookRuntime.app'));
  const global = command(['--disable', 'plugins', 'mcp', 'get', 'notebook', '--json'], { optional: true });
  if (global.status === 0) assert(JSON.parse(global.stdout).enabled === false,
    'An enabled global notebook MCP already provides these tools. Migrate that entry first.');
  else assert(global.stderr.includes("No MCP server named 'notebook' found"), global.stderr);
  const sameName = (await marketplaces()).find(item => item.name === marketplaceName);
  if (sameName) assert.equal(await realpath(sameName.root), await realpath(root),
    'Run notebook_release.py migrate-plugin-source before changing the authored plugin version.');
  else await run(['plugin', 'marketplace', 'add', root, '--json']);
  const rows = await installed(); assert(rows.length <= 1);
  if (rows[0]?.version === ready.manifest.version) {
    const cache = await cachedPlugin();
    assert.deepEqual(cache.inventory, ready.inventory, 'Installed version has another payload; release a new version.');
    console.log(JSON.stringify({ pluginId: pluginID, version: cache.version, alreadyInstalled: true }));
  } else console.log(JSON.stringify(await run(['plugin', 'add', pluginID, '--json']), null, 2));
  console.error('Notebook installed. Existing Codex chats keep their current MCP connection until the host reconnects them.');
} else {
  console.log(JSON.stringify(await run(['plugin', 'remove', pluginID, '--json'])));
  const current = (await marketplaces()).find(item => item.name === marketplaceName);
  if (current && resolve(current.root) === resolve(root)) {
    console.log(JSON.stringify(await run(['plugin', 'marketplace', 'remove', marketplaceName, '--json'])));
  }
}
