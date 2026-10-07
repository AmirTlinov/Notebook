import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { access, cp, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { inspectRuntimeBundle } from './package-plugin-runtime.mjs';

export const marketplaceName = 'notebook-local', pluginID = 'notebook@notebook-local';
export const marketplaceFile = '.agents/plugins/marketplace.json';
const migrationFile = 'source-migration.json';
const runtimePath = 'runtime/NotebookRuntime.app', versionPattern = /^\d+\.\d+\.\d+$/;
export const readJSON = async path => JSON.parse(await readFile(path, 'utf8'));
export const publicationRoot = () => join(homedir(), 'Library/Application Support/NotebookPlugin/marketplace');
export async function pendingSourceMigration(root) {
  try { return await readJSON(join(root, migrationFile)); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

export async function inspectPluginMetadata(root) {
  const manifest = await readJSON(join(root, 'plugin.json'));
  assert.equal(manifest.name, 'notebook');
  assert.equal(manifest.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
  assert.match(manifest.version, versionPattern);
  assert(!['mcpServers', 'skills', 'interface'].some(key => key in manifest));
  const presentation = manifest.extensions['com.openai'].interface;
  assert(presentation.shortDescription.length <= 30);
  const startup = (await readJSON(join(root, 'mcp.json'))).mcpServers.notebook;
  assert.equal(startup.type, 'stdio');
  assert.equal(startup.command, './runtime/NotebookRuntime.app/Contents/Resources/CodexRuntime/node');
  assert.deepEqual(startup.args, ['${PLUGIN_ROOT}/runtime/NotebookRuntime.app/Contents/Resources/NotebookTools/dist/launch-runtime.mjs']);
  await access(join(root, presentation.logo));
  const skill = await readFile(join(root, 'skills/notebook/SKILL.md'), 'utf8');
  assert(skill.startsWith('---\nname: notebook\n') && skill.includes('notebook_open'));
  return manifest;
}

export function inspectMarketplace(value) {
  assert.equal(value.name, marketplaceName);
  assert.equal(value.plugins.length, 1);
  assert.equal(value.plugins[0].name, 'notebook');
  assert.equal(value.plugins[0].source.source, 'local');
  return value;
}

/** Includes metadata and every signed resource; filenames alone cannot seal a release. */
export async function pluginInventory(root) {
  const files = [];
  async function visit(path, relative = '') {
    const info = await lstat(path);
    assert(!info.isSymbolicLink(), `Plugin contains a symbolic link: ${path}`);
    if (info.isDirectory()) {
      for (const name of (await readdir(path)).sort()) await visit(join(path, name), relative ? `${relative}/${name}` : name);
    } else {
      assert(info.isFile(), `Plugin contains an unsupported entry: ${path}`);
      files.push({ path: relative, bytes: info.size, executable: Boolean(info.mode & 0o111),
        sha256: createHash('sha256').update(await readFile(path)).digest('hex') });
    }
  }
  await visit(root);
  return { sha256: createHash('sha256').update(JSON.stringify(files)).digest('hex'), files };
}

async function atomicJSON(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const directory = await mkdtemp(join(dirname(path), '.publication-'));
  const temporary = join(directory, 'value.json');
  try {
    const file = await open(temporary, 'wx', 0o600);
    try { await file.writeFile(JSON.stringify(value, null, 2) + '\n'); await file.sync(); }
    finally { await file.close(); }
    await rename(temporary, path);
    const parent = await open(dirname(path), 'r');
    try { await parent.sync(); } finally { await parent.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
}

function compareVersions(left, right) {
  const a = left.split('.').map(Number), b = right.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

export async function publishedPlugin(root) {
  const marketplace = inspectMarketplace(await readJSON(join(root, marketplaceFile)));
  const relative = marketplace.plugins[0].source.path;
  const match = /^\.\/releases\/(\d+\.\d+\.\d+)\/notebook$/.exec(relative);
  assert(match, 'The published marketplace must address an immutable release.');
  const plugin = join(root, relative);
  assert.equal(await realpath(plugin), resolve(plugin), 'Publication contains an indirect package path.');
  const manifest = await inspectPluginMetadata(plugin);
  assert.equal(manifest.version, match[1]);
  const sealed = await readJSON(join(dirname(plugin), 'publication.json'));
  assert.deepEqual(await pluginInventory(plugin), sealed.inventory, 'Published plugin changed after admission.');
  assert.equal(sealed.version, manifest.version);
  return { marketplace, manifest, plugin, inventory: sealed.inventory };
}

async function optionalPublication(root) {
  try { return await publishedPlugin(root); }
  catch (error) { if (error.code === 'ENOENT' && !(await exists(join(root, marketplaceFile)))) return null; throw error; }
}
async function exists(path) {
  try { await lstat(path); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

async function discardInterruptedStages(root) {
  // The Python owner holds its OS lease across this helper. These directories
  // were never catalog addresses, so an interrupted copy can be discarded.
  for (const directory of [root, join(root, '.agents/plugins')]) {
    if (!(await exists(directory))) continue;
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (!/^\.publication-(?:stage-)?[A-Za-z0-9]{6}$/.test(entry.name)) continue;
      assert(entry.isDirectory() && !entry.isSymbolicLink(), 'Invalid interrupted publication stage.');
      await rm(join(directory, entry.name), { recursive: true });
    }
  }
}

/** Called by the leased release owner; exposes one ready package atomically. */
export async function publishPlugin(source, root, marketplace, { inspect = inspectRuntimeBundle, copy = cp } = {}) {
  source = await realpath(source); root = resolve(root);
  assert(source !== root && !source.startsWith(root + sep), 'Publish a verified build or the installed cache.');
  inspectMarketplace(marketplace);
  await mkdir(root, { recursive: true });
  assert.equal(await realpath(root), root, 'Publication root must be an ordinary directory.');
  await discardInterruptedStages(root);
  let stage;
  try {
    const manifest = await inspectPluginMetadata(source);
    await inspect(join(source, runtimePath));
    const inventory = await pluginInventory(source), previous = await optionalPublication(root);
    const migration = await pendingSourceMigration(root);
    assert(!migration || migration.sha256 === inventory.sha256,
      'Finish the pending source migration before publishing another payload.');
    assert(!previous || compareVersions(manifest.version, previous.manifest.version) >= 0, 'Plugin downgrade is forbidden.');
    const release = join(root, 'releases', manifest.version), target = join(release, 'notebook');
    await mkdir(dirname(release), { recursive: true });
    if (await exists(release)) {
      const sealed = await readJSON(join(release, 'publication.json'));
      assert.equal(sealed.version, manifest.version);
      assert.deepEqual(sealed.inventory, inventory, 'A plugin version cannot be reused for changed metadata or runtime.');
      assert.deepEqual(await pluginInventory(target), inventory, 'The admitted release changed.');
      await inspect(join(target, runtimePath));
    } else {
      stage = await mkdtemp(join(root, '.publication-stage-'));
      const stagedPlugin = join(stage, 'notebook');
      await copy(source, stagedPlugin, { recursive: true, verbatimSymlinks: true, preserveTimestamps: true });
      await inspect(join(stagedPlugin, runtimePath));
      assert.deepEqual(await pluginInventory(stagedPlugin), inventory, 'Plugin changed during publication copy.');
      assert.deepEqual(await pluginInventory(source), inventory, 'Source changed during publication copy.');
      await atomicJSON(join(stage, 'publication.json'), { format: 1, version: manifest.version, inventory });
      await rename(stage, release); stage = null;
    }
    const ready = { ...marketplace, plugins: marketplace.plugins.map(entry => ({ ...entry,
      source: { source: 'local', path: `./releases/${manifest.version}/notebook` } })) };
    await atomicJSON(join(root, marketplaceFile), ready);
    return { root, plugin: target, version: manifest.version, sha256: inventory.sha256,
      previousVersion: previous?.manifest.version ?? null };
  } finally {
    if (stage) await rm(stage, { recursive: true, force: true });
  }
}

/** Called after the complete pair has been installed and read back. */
export async function prunePublications(root) {
  await discardInterruptedStages(root);
  const current = await publishedPlugin(root), releases = join(root, 'releases');
  const names = (await readdir(releases)).filter(name => versionPattern.test(name)).sort(compareVersions).reverse();
  assert(names[0] === current.manifest.version, 'Only the newest complete publication can retire old packages.');
  for (const version of names.slice(1)) {
    const release = join(releases, version), info = await lstat(release);
    assert(info.isDirectory() && !info.isSymbolicLink());
    const record = await readJSON(join(release, 'publication.json'));
    assert.equal(record.format, 1); assert.equal(record.version, version);
    assert.deepEqual((await readdir(release)).sort(), ['notebook', 'publication.json']);
    const retired = await mkdtemp(join(root, '.publication-stage-'));
    await rename(release, join(retired, 'release'));
    await rm(retired, { recursive: true });
  }
}

function installedIdentity(value) {
  const rows = value.installed.filter(item => item.pluginId === pluginID);
  assert.equal(rows.length, 1, 'Migration requires one installed Notebook plugin.');
  const { pluginId, version, enabled } = rows[0];
  assert.match(version, versionPattern); assert.equal(typeof enabled, 'boolean');
  return { pluginId, version, enabled };
}

/** Official marketplace commands preserve the installed plugin and its cache. */
export async function migrateMarketplace(previousRoot, root, { run, checkCache, cacheRoot }) {
  const ready = await publishedPlugin(root);
  const configured = (await run(['plugin', 'marketplace', 'list', '--json'])).marketplaces;
  const entry = configured.find(item => item.name === marketplaceName);
  let intent = await pendingSourceMigration(root);
  if (intent) {
    assert.equal(intent.format, 1); assert.equal(intent.root, root); assert.equal(intent.previousRoot, previousRoot);
    assert.equal(intent.cacheRoot, cacheRoot); assert.equal(intent.sha256, ready.inventory.sha256);
    assert.equal(intent.plugin.pluginId, pluginID); assert.equal(intent.plugin.version, ready.manifest.version);
    assert.equal(typeof intent.plugin.enabled, 'boolean');
  } else {
    assert(entry && entry.marketplaceSource?.sourceType === 'local', 'Migration requires the existing local marketplace.');
    assert.equal(await realpath(entry.root), await realpath(previousRoot), 'The marketplace belongs to another source.');
    const identity = installedIdentity(await run(['plugin', 'list', '--json']));
    assert.equal(ready.manifest.version, identity.version, 'Migration cannot change the installed version.');
    assert(typeof cacheRoot === 'string' && resolve(cacheRoot) === cacheRoot);
    await checkCache();
    intent = { format: 1, previousRoot, root, cacheRoot, plugin: identity, sha256: ready.inventory.sha256 };
    await atomicJSON(join(root, migrationFile), intent);
  }
  const identity = intent.plugin;
  await checkCache();
  let attempted = false;
  try {
    if (entry) {
      assert.equal(entry.marketplaceSource?.sourceType, 'local');
      if (await realpath(entry.root) === await realpath(previousRoot)) {
        attempted = true;
        await run(['plugin', 'marketplace', 'remove', marketplaceName, '--json']);
        await run(['plugin', 'marketplace', 'add', root, '--json']);
      } else {
        assert.equal(await realpath(entry.root), await realpath(root), 'Marketplace changed concurrently; do not overwrite it.');
        attempted = true; // The previous attempt already published this source.
      }
    } else {
      attempted = true;
      await run(['plugin', 'marketplace', 'add', root, '--json']);
    }
    const after = (await run(['plugin', 'marketplace', 'list', '--json'])).marketplaces.find(item => item.name === marketplaceName);
    assert(after && await realpath(after.root) === await realpath(root), 'Codex did not confirm the new marketplace source.');
    assert.deepEqual(installedIdentity(await run(['plugin', 'list', '--json'])), identity, 'Migration changed plugin identity or enabled state.');
    await checkCache();
    await rm(join(root, migrationFile));
    return { plugin: identity, previousRoot, root, cachePreserved: true };
  } catch (error) {
    if (!attempted) throw error;
    try {
      const observed = (await run(['plugin', 'marketplace', 'list', '--json'])).marketplaces.find(item => item.name === marketplaceName);
      const unchanged = observed && await realpath(observed.root) === await realpath(previousRoot);
      if (!unchanged) {
        if (observed) {
          assert.equal(await realpath(observed.root), await realpath(root), 'Marketplace changed concurrently; do not overwrite it.');
          await run(['plugin', 'marketplace', 'remove', marketplaceName, '--json']);
        }
        await run(['plugin', 'marketplace', 'add', previousRoot, '--json']);
      }
      assert.deepEqual(installedIdentity(await run(['plugin', 'list', '--json'])), identity);
      await checkCache();
      await rm(join(root, migrationFile));
    } catch (restoration) { throw new AggregateError([error, restoration], 'Marketplace migration is incomplete; existing plugin cache was not removed.'); }
    throw error;
  }
}
