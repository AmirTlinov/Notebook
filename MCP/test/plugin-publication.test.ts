import assert from 'node:assert/strict';
import { test, type TestContext } from 'node:test';
import { cp, mkdir, mkdtemp, readFile, realpath, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const { publishPlugin, publishedPlugin, pluginInventory, migrateMarketplace, prunePublications } =
  await import(new URL('../plugin-publication.mjs', import.meta.url).href);

const marketplace = { name: 'notebook-local', plugins: [{ name: 'notebook',
  source: { source: 'local', path: './notebook' }, policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
  category: 'Productivity' }] };

async function fixture(t: TestContext) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'notebook-publication-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, 'authored/notebook'), output = join(root, 'published');
  await cp(new URL('../plugin/notebook', import.meta.url), source, { recursive: true,
    filter: path => !String(path).includes('/runtime/') && !String(path).endsWith('/runtime') });
  const app = join(source, 'runtime/NotebookRuntime.app'); await mkdir(app, { recursive: true });
  const setVersion = async (version: string, body = `sealed-runtime-${version}`) => {
    const path = join(source, 'plugin.json'), value = JSON.parse(await readFile(path, 'utf8'));
    await writeFile(path, JSON.stringify({ ...value, version }));
    await writeFile(join(app, 'sealed'), body);
  };
  const inspect = async (path: string) => {
    assert.match(await readFile(join(path, 'sealed'), 'utf8'), /^sealed-runtime-/); return { app: path };
  };
  await setVersion('0.2.5');
  return { root, source, output, app, setVersion, inspect };
}

test('authored metadata is invisible until the entire signed payload is admitted', async t => {
  const f = await fixture(t);
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  const first = await publishedPlugin(f.output);
  await f.setVersion('0.2.6');
  assert.equal((await publishedPlugin(f.output)).manifest.version, '0.2.5');
  await assert.rejects(publishPlugin(f.source, f.output, marketplace, { inspect: async (app: string) => {
    if (app !== f.app) throw new Error('copied signature rejected'); return f.inspect(app);
  } }), /copied signature/);
  assert.deepEqual((await publishedPlugin(f.output)).inventory, first.inventory);
  const publication = await publishPlugin(f.source, f.output, marketplace, {
    inspect: f.inspect, copy: async (source: string, target: string) => {
      assert.equal((await publishedPlugin(f.output)).manifest.version, '0.2.5');
      await cp(source, target, { recursive: true });
      assert.equal((await publishedPlugin(f.output)).manifest.version, '0.2.5');
    },
  });
  assert.equal(publication.version, '0.2.6');
  const ready = await publishedPlugin(f.output);
  assert.equal(ready.manifest.version, '0.2.6');
  assert.equal(await readFile(join(ready.plugin, 'runtime/NotebookRuntime.app/sealed'), 'utf8'), 'sealed-runtime-0.2.6');
  assert(!(await readdir(f.output)).some((name: string) => name.startsWith('.publication-')));
});

test('changed copy, same-version payload replacement and downgrade preserve the admitted publication', async t => {
  const f = await fixture(t);
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  const admitted = await publishedPlugin(f.output);
  await f.setVersion('0.2.5', 'sealed-runtime-another-build');
  await assert.rejects(publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect }), /cannot be reused/);
  await f.setVersion('0.2.4');
  await assert.rejects(publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect }), /downgrade/);
  await f.setVersion('0.2.6');
  await assert.rejects(publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect,
    copy: async (source: string, target: string) => {
      await cp(source, target, { recursive: true });
      await writeFile(join(target, 'runtime/NotebookRuntime.app/sealed'), 'sealed-runtime-truncated');
    } }), /changed during publication copy/);
  assert.deepEqual((await publishedPlugin(f.output)).inventory, admitted.inventory);
});

test('completed pair cleanup retains the current package and same bytes can be retried', async t => {
  const f = await fixture(t);
  for (const version of ['0.2.5', '0.2.6', '0.2.7']) {
    await f.setVersion(version); await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  }
  const ready = await publishedPlugin(f.output);
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  assert.deepEqual((await publishedPlugin(f.output)).inventory, ready.inventory);
  await prunePublications(f.output);
  assert.deepEqual(await readdir(join(f.output, 'releases')), ['0.2.7']);
  assert.deepEqual((await publishedPlugin(f.output)).inventory, ready.inventory);
});

test('official source migration preserves disabled state and exact cache without plugin installation', async t => {
  const f = await fixture(t), previous = join(f.root, 'authored');
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  const cache = await pluginInventory(f.source), calls: string[][] = [];
  let source: string | null = previous;
  const identity = { pluginId: 'notebook@notebook-local', version: '0.2.5', enabled: false };
  const run = async (args: string[]) => {
    calls.push(args);
    if (args[1] === 'list') return { installed: source ? [identity] : [] };
    assert.equal(args[1], 'marketplace');
    if (args[2] === 'list') return { marketplaces: source ? [{ name: 'notebook-local', root: source,
      marketplaceSource: { sourceType: 'local', source } }] : [] };
    if (args[2] === 'remove') source = null;
    else if (args[2] === 'add') { assert(args[3]); source = args[3]; }
    else assert.fail('Unexpected host mutation');
    return {};
  };
  const result = await migrateMarketplace(previous, f.output, { run, cacheRoot: f.source,
    checkCache: async () => assert.deepEqual(await pluginInventory(f.source), cache) });
  assert.equal(source, f.output); assert.equal(result.cachePreserved, true);
  assert.deepEqual(result.plugin, identity);
  assert(!calls.some(args => ['add', 'remove'].includes(args[1] ?? '')));
});

test('migration restores the old source after failed add or unknown remove outcome', async t => {
  for (const failure of ['add', 'remove']) {
    const f = await fixture(t), previous = join(f.root, 'authored');
    await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
    const cache = await pluginInventory(f.source);
    let source: string | null = previous, injected = false;
    const run = async (args: string[]) => {
      if (args[1] === 'list') return { installed: source ? [{ pluginId: 'notebook@notebook-local', version: '0.2.5', enabled: true }] : [] };
      assert.equal(args[1], 'marketplace');
      if (args[2] === 'list') return { marketplaces: source ? [{ name: 'notebook-local', root: source,
        marketplaceSource: { sourceType: 'local', source } }] : [] };
      if (args[2] === 'remove') source = null;
      else if (args[2] === 'add') { assert(args[3]); source = args[3]; }
      else assert.fail('Unexpected host mutation');
      if (!injected && args[2] === failure) { injected = true; throw new Error('lost CLI completion'); }
      return {};
    };
    await assert.rejects(migrateMarketplace(previous, f.output, { run, cacheRoot: f.source,
      checkCache: async () => assert.deepEqual(await pluginInventory(f.source), cache) }), /lost CLI completion/);
    assert.equal(source, previous);
    assert.deepEqual(await pluginInventory(f.source), cache);
  }
});

test('an interrupted registry rollback resumes from its pinned receipt without reinstalling', async t => {
  const f = await fixture(t), previous = join(f.root, 'authored');
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  const cache = await pluginInventory(f.source);
  const identity = { pluginId: 'notebook@notebook-local', version: '0.2.5', enabled: false };
  let source: string | null = previous, failing = true;
  const run = async (args: string[]) => {
    if (args[1] === 'list') return { installed: source ? [identity] : [] };
    assert.equal(args[1], 'marketplace', 'Migration never installs or removes a plugin');
    if (args[2] === 'list') return { marketplaces: source ? [{ name: 'notebook-local', root: source,
      marketplaceSource: { sourceType: 'local', source } }] : [] };
    if (args[2] === 'remove') {
      source = null;
      if (failing) throw new Error('remove result lost');
    } else if (args[2] === 'add') {
      if (failing) throw new Error('rollback unavailable');
      assert(args[3]); source = args[3];
    } else assert.fail('Unexpected host mutation');
    return {};
  };
  const options = { run, cacheRoot: f.source,
    checkCache: async () => assert.deepEqual(await pluginInventory(f.source), cache) };
  await assert.rejects(migrateMarketplace(previous, f.output, options), /migration is incomplete/);
  assert.equal(source, null);
  const intent = JSON.parse(await readFile(join(f.output, 'source-migration.json'), 'utf8'));
  assert.deepEqual(intent.plugin, identity); assert.equal(intent.sha256, cache.sha256);
  failing = false;
  const result = await migrateMarketplace(previous, f.output, options);
  assert.equal(source, f.output); assert.deepEqual(result.plugin, identity);
  assert.deepEqual(await pluginInventory(f.source), cache);
  await assert.rejects(readFile(join(f.output, 'source-migration.json')), { code: 'ENOENT' });
});

test('the next leased attempt discards an interrupted copy while keeping the current publication', async t => {
  const f = await fixture(t);
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  const stage = join(f.output, '.publication-stage-orphan');
  await mkdir(stage); await writeFile(join(stage, 'partial-runtime'), 'incomplete');
  await f.setVersion('0.2.6');
  await publishPlugin(f.source, f.output, marketplace, { inspect: f.inspect });
  assert.equal((await publishedPlugin(f.output)).manifest.version, '0.2.6');
  await assert.rejects(readdir(stage), { code: 'ENOENT' });
});
