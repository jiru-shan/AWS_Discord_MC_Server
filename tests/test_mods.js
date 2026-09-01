/**
 * Behavioural tests for install-mods.js.
 *
 * The risk this covers is not "a mod failed to download" -- it is a jar built
 * for the wrong Minecraft version being left in the mods directory, which does
 * not degrade the server but stops it booting at all, on a box whose only
 * recovery path is SSM. Most of what follows pins down exactly when a jar is
 * kept and when it is deleted.
 *
 * The network and the mods directory are injected, so nothing here touches
 * either.
 *
 * Run with: node --test tests/test_mods.js
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');

const {
  parseSpec,
  parseSpecList,
  chooseVersion,
  chooseFile,
  syncMods,
  resolveMinecraftVersion,
  directoryStore,
  readManifest,
  readJarMetadata,
  unmetRequirements,
  projectSupplying,
  MANIFEST,
} = require(path.join(__dirname, '..', 'server', 'bin', 'install-mods.js'));

// --------------------------------------------------------------------------
// Fixtures
// --------------------------------------------------------------------------

/** The mods directory as an in-memory map of name -> contents. */
function fakeStore(initial = {}) {
  const files = new Map(Object.entries(initial));
  return {
    files,
    has: (name) => files.has(name),
    read: (name) => Buffer.from(files.get(name) || ''),
    readText: (name) => (files.has(name) ? files.get(name).toString() : null),
    writeText: (name, text) => files.set(name, text),
    write: (name, buffer) => files.set(name, buffer),
    remove: (name) => files.delete(name),
    names: () => [...files.keys()].sort(),
  };
}

/**
 * Modrinth and the CDN. `projects` maps slug -> version list; `binaries` maps
 * url -> body. Anything not listed 404s, which is how a mod with no build for
 * the current Minecraft version is simulated.
 */
function fakeHttp({ projects = {}, binaries = {}, game = [], projectMeta = {} } = {}) {
  const calls = [];
  return {
    calls,
    async getJson(url) {
      calls.push(url);
      if (url.includes('meta.fabricmc.net')) return game;
      // /project/<id> with no /version is the id -> slug lookup.
      const meta = url.match(/\/project\/([^/]+)$/);
      if (meta) {
        if (!(meta[1] in projectMeta)) throw new Error('HTTP 404');
        return projectMeta[meta[1]];
      }
      const slug = url.match(/\/project\/([^/]+)\/version/)[1];
      if (!(slug in projects)) throw new Error('HTTP 404');
      return projects[slug];
    },
    async getBinary(url) {
      calls.push(url);
      if (!(url in binaries)) throw new Error('HTTP 404');
      return Buffer.from(binaries[url]);
    },
  };
}

/** Stand-in for crypto: the "hash" of a body is the body itself. */
const identitySha1 = (buffer) => buffer.toString();

function modrinthVersion(overrides = {}) {
  return {
    id: 'aaaaaaaa',
    version_number: '1.0.0',
    version_type: 'release',
    date_published: '2026-01-01T00:00:00Z',
    files: [
      {
        filename: 'lithium-1.0.0.jar',
        url: 'https://cdn.modrinth.com/lithium-1.0.0.jar',
        primary: true,
        hashes: { sha1: 'jar-body' },
      },
    ],
    ...overrides,
  };
}

function manifest(store) {
  return JSON.parse(store.readText(MANIFEST));
}

// --------------------------------------------------------------------------
// Specs
// --------------------------------------------------------------------------

test('a bare slug is a Modrinth project', () => {
  assert.deepStrictEqual(parseSpec('lithium'), {
    spec: 'lithium',
    kind: 'project',
    slug: 'lithium',
    pin: null,
  });
});

test('slug@version pins one Modrinth build', () => {
  const parsed = parseSpec('lithium@0.15.0');
  assert.strictEqual(parsed.slug, 'lithium');
  assert.strictEqual(parsed.pin, '0.15.0');
});

test('an https URL is a direct download named after its last path segment', () => {
  const parsed = parseSpec('https://example.com/mods/custom-1.2.jar');
  assert.strictEqual(parsed.kind, 'url');
  assert.strictEqual(parsed.filename, 'custom-1.2.jar');
});

test('a plaintext mod URL is refused', () => {
  // These jars run inside the server process; over http the jar is whoever is
  // on the path's choice, not ours.
  assert.throws(() => parseSpec('http://example.com/custom.jar'), /non-https/);
});

test('a URL that is not a jar is refused', () => {
  assert.throws(() => parseSpec('https://example.com/mods/'), /does not end in \.jar/);
});

test('a slug with a path separator is refused rather than sent to the API', () => {
  assert.throws(() => parseSpec('../../etc/passwd'), /not a Modrinth project slug/);
});

test('the spec list tolerates spacing and empty entries', () => {
  assert.deepStrictEqual(parseSpecList(' lithium , , krypton '), ['lithium', 'krypton']);
  assert.deepStrictEqual(parseSpecList(''), []);
  assert.deepStrictEqual(parseSpecList(undefined), []);
});

// --------------------------------------------------------------------------
// Choosing a build
// --------------------------------------------------------------------------

test('a release is preferred over a newer beta', () => {
  const chosen = chooseVersion([
    modrinthVersion({ version_number: 'beta', version_type: 'beta', date_published: '2026-06-01T00:00:00Z' }),
    modrinthVersion({ version_number: 'release', date_published: '2026-01-01T00:00:00Z' }),
  ]);
  assert.strictEqual(chosen.version_number, 'release');
});

test('among releases the newest publish date wins, whatever order the API used', () => {
  const chosen = chooseVersion([
    modrinthVersion({ version_number: 'old', date_published: '2026-01-01T00:00:00Z' }),
    modrinthVersion({ version_number: 'new', date_published: '2026-08-01T00:00:00Z' }),
  ]);
  assert.strictEqual(chosen.version_number, 'new');
});

test('a pin selects that build even when it is neither newest nor a release', () => {
  const chosen = chooseVersion(
    [
      modrinthVersion({ version_number: 'new' }),
      modrinthVersion({ version_number: '0.9.0', version_type: 'alpha' }),
    ],
    '0.9.0'
  );
  assert.strictEqual(chosen.version_number, '0.9.0');
});

test('a pin that matches nothing chooses nothing rather than falling back', () => {
  assert.strictEqual(chooseVersion([modrinthVersion()], '9.9.9'), null);
});

test('no builds for this Minecraft version yields nothing', () => {
  assert.strictEqual(chooseVersion([]), null);
});

test('the primary jar is chosen over sources attachments', () => {
  const file = chooseFile({
    files: [
      { filename: 'x-sources.jar', primary: false, url: 'a' },
      { filename: 'x.jar', primary: true, url: 'b' },
      { filename: 'x.txt', primary: false, url: 'c' },
    ],
  });
  assert.strictEqual(file.filename, 'x.jar');
});

// --------------------------------------------------------------------------
// Syncing
// --------------------------------------------------------------------------

const LITHIUM = {
  projects: { lithium: [modrinthVersion()] },
  binaries: { 'https://cdn.modrinth.com/lithium-1.0.0.jar': 'jar-body' },
};

test('a configured mod is downloaded and recorded', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  assert.deepStrictEqual(result.failed, []);
  assert.ok(store.has('lithium-1.0.0.jar'));
  assert.strictEqual(manifest(store).minecraft, '26.2');
  assert.deepStrictEqual(manifest(store).mods, [
    { spec: 'lithium', file: 'lithium-1.0.0.jar', sha1: 'jar-body' },
  ]);
});

test('a second boot re-downloads nothing', async () => {
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  const args = { specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 };

  await syncMods(args);
  const afterFirst = http.calls.length;
  await syncMods(args);

  // One API call to re-resolve, but no second download of the same jar.
  assert.strictEqual(http.calls.length, afterFirst + 1);
  assert.strictEqual(
    http.calls.filter((u) => u.includes('cdn.modrinth.com')).length,
    1
  );
});

test('a mod dropped from the list is deleted', async () => {
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  await syncMods({ specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 });

  const result = await syncMods({ specs: [], minecraft: '26.2', store, http, sha1: identitySha1 });

  assert.deepStrictEqual(result.removed, ['lithium-1.0.0.jar']);
  assert.ok(!store.has('lithium-1.0.0.jar'));
  assert.deepStrictEqual(manifest(store).mods, []);
});

test('a hand-installed jar is never touched', async () => {
  // The documented way to install anything not on Modrinth is to drop the jar
  // in by hand. A sync that deleted those would be worse than no sync at all.
  const store = fakeStore({ 'my-private-mod.jar': 'hand-placed' });

  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });
  await syncMods({ specs: [], minecraft: '26.2', store, http: fakeHttp(), sha1: identitySha1 });

  assert.ok(store.has('my-private-mod.jar'));
});

test('an unreachable Modrinth leaves the working jar in place', async () => {
  const store = fakeStore();
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(),
    sha1: identitySha1,
  });

  assert.strictEqual(result.failed.length, 1);
  assert.ok(store.has('lithium-1.0.0.jar'), 'a transient outage must not strip the server');
  assert.deepStrictEqual(result.removed, []);
});

test('a jar with no build for a new Minecraft version is removed, not kept', async () => {
  // The one case where keeping the jar is the dangerous choice: Fabric refuses
  // to start with a mod built for a different game version.
  const store = fakeStore();
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.3',
    store,
    http: fakeHttp({ projects: { lithium: [] } }),
    sha1: identitySha1,
  });

  assert.strictEqual(result.failed.length, 1);
  assert.deepStrictEqual(result.removed, ['lithium-1.0.0.jar']);
  assert.ok(!store.has('lithium-1.0.0.jar'));
});

test('a version bump replaces the old jar rather than stacking a second copy', async () => {
  const store = fakeStore();
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  const next = modrinthVersion({
    version_number: '2.0.0',
    files: [
      {
        filename: 'lithium-2.0.0.jar',
        url: 'https://cdn.modrinth.com/lithium-2.0.0.jar',
        primary: true,
        hashes: { sha1: 'new-body' },
      },
    ],
  });
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.3',
    store,
    http: fakeHttp({
      projects: { lithium: [next] },
      binaries: { 'https://cdn.modrinth.com/lithium-2.0.0.jar': 'new-body' },
    }),
    sha1: identitySha1,
  });

  assert.deepStrictEqual(store.names().filter((n) => n.endsWith('.jar')), ['lithium-2.0.0.jar']);
});

test('a jar whose checksum does not match is not installed', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp({
      projects: LITHIUM.projects,
      binaries: { 'https://cdn.modrinth.com/lithium-1.0.0.jar': 'something-else' },
    }),
    sha1: identitySha1,
  });

  assert.match(result.failed[0].error, /checksum mismatch/);
  assert.ok(!store.has('lithium-1.0.0.jar'));
});

test('one broken spec does not stop the others installing', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['http://example.com/evil.jar', 'lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  assert.strictEqual(result.failed.length, 1);
  assert.strictEqual(result.installed.length, 1);
  assert.ok(store.has('lithium-1.0.0.jar'));
});

test('a direct URL is downloaded without a checksum to verify', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['https://example.com/custom-1.0.jar'],
    minecraft: '26.2',
    store,
    http: fakeHttp({ binaries: { 'https://example.com/custom-1.0.jar': 'body' } }),
    sha1: identitySha1,
  });

  assert.deepStrictEqual(result.failed, []);
  assert.ok(store.has('custom-1.0.jar'));
  assert.strictEqual(manifest(store).mods[0].sha1, null);
});

test('a corrupt manifest does not orphan the jars it described', async () => {
  const store = fakeStore({ [MANIFEST]: '{ truncated' });
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });

  assert.ok(store.has('lithium-1.0.0.jar'));
  assert.strictEqual(manifest(store).mods.length, 1);
});

// --------------------------------------------------------------------------
// Edge cases
// --------------------------------------------------------------------------

test('the same mod listed twice is installed once', async () => {
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  await syncMods({ specs: ['lithium', 'lithium'], minecraft: '26.2', store, http, sha1: identitySha1 });

  assert.strictEqual(http.calls.filter((u) => u.includes('cdn.modrinth.com')).length, 1);
  assert.strictEqual(manifest(store).mods.length, 1, 'one file, one manifest entry');
});

test('two specs naming the same build install once', async () => {
  // `lithium` and `lithium@1.0.0` resolve to the same jar. Downloading it
  // twice and recording it twice would both be wrong.
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  await syncMods({ specs: ['lithium', 'lithium@1.0.0'], minecraft: '26.2', store, http, sha1: identitySha1 });

  assert.strictEqual(http.calls.filter((u) => u.includes('cdn.modrinth.com')).length, 1);
  assert.deepStrictEqual(store.names().filter((n) => n.endsWith('.jar')), ['lithium-1.0.0.jar']);
});

test('a pin can name the Modrinth version id as well as its number', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['lithium@aaaaaaaa'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });
  assert.deepStrictEqual(result.failed, []);
  assert.ok(store.has('lithium-1.0.0.jar'));
});

test('a full disk is reported, not swallowed', async () => {
  const store = fakeStore();
  store.write = () => {
    throw new Error('ENOSPC: no space left on device');
  };
  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http: fakeHttp(LITHIUM),
    sha1: identitySha1,
  });
  assert.strictEqual(result.installed.length, 0);
  assert.match(result.failed[0].error, /ENOSPC/);
});

test('a version whose files hold no jar fails cleanly', async () => {
  const store = fakeStore();
  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    sha1: identitySha1,
    http: fakeHttp({
      projects: {
        lithium: [modrinthVersion({ files: [{ filename: 'changelog.txt', url: 'x', primary: true }] })],
      },
    }),
  });
  assert.match(result.failed[0].error, /no jar/);
});

test('an error object where a version list belongs is treated as no build', async () => {
  // Modrinth answering 200 with a body that is not an array -- rate limiting,
  // a maintenance page -- must not throw past the per-mod handler.
  const store = fakeStore();
  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    sha1: identitySha1,
    http: {
      calls: [],
      async getJson() {
        return { error: 'rate limited' };
      },
      async getBinary() {
        throw new Error('unreachable');
      },
    },
  });
  assert.strictEqual(result.failed.length, 1);
  assert.strictEqual(result.installed.length, 0);
});

test('a corrupted jar is detected by its checksum and replaced', async () => {
  // Bookkeeping alone would call this jar current forever. Fabric does not
  // skip a bad jar, it refuses to start -- so the bytes get hashed, not just
  // the manifest compared.
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  await syncMods({ specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 });

  store.write('lithium-1.0.0.jar', Buffer.from('truncated'));
  const messages = [];
  await syncMods({
    specs: ['lithium'],
    minecraft: '26.2',
    store,
    http,
    sha1: identitySha1,
    log: (m) => messages.push(m),
  });

  assert.strictEqual(store.read('lithium-1.0.0.jar').toString(), 'jar-body');
  assert.ok(messages.some((m) => /no longer matches its checksum/.test(m)));
});

test('an intact jar is not re-downloaded by the checksum check', async () => {
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  const args = { specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 };
  await syncMods(args);
  await syncMods(args);

  assert.strictEqual(http.calls.filter((u) => u.includes('cdn.modrinth.com')).length, 1);
});

test('a direct-URL jar has no hash to verify and is left alone', async () => {
  const store = fakeStore();
  const http = fakeHttp({ binaries: { 'https://example.com/custom-1.0.jar': 'body' } });
  const args = {
    specs: ['https://example.com/custom-1.0.jar'],
    minecraft: '26.2',
    store,
    http,
    sha1: identitySha1,
  };
  await syncMods(args);
  store.write('custom-1.0.jar', Buffer.from('locally edited'));
  await syncMods(args);

  assert.strictEqual(store.read('custom-1.0.jar').toString(), 'locally edited');
});

test('a managed jar deleted by hand is put back', async () => {
  const store = fakeStore();
  const http = fakeHttp(LITHIUM);
  await syncMods({ specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 });

  store.remove('lithium-1.0.0.jar');
  await syncMods({ specs: ['lithium'], minecraft: '26.2', store, http, sha1: identitySha1 });

  assert.ok(store.has('lithium-1.0.0.jar'));
});

test('a manifest entry whose file is already gone is dropped quietly', async () => {
  const store = fakeStore({
    [MANIFEST]: JSON.stringify({
      version: 1,
      minecraft: '26.2',
      mods: [{ spec: 'gone', file: 'gone.jar', sha1: 'x' }],
    }),
  });
  const result = await syncMods({
    specs: [],
    minecraft: '26.2',
    store,
    http: fakeHttp(),
    sha1: identitySha1,
  });

  assert.deepStrictEqual(result.removed, [], 'nothing to remove; the file was already gone');
  assert.deepStrictEqual(manifest(store).mods, []);
});

test('a query string is not part of the filename', async () => {
  assert.strictEqual(
    parseSpec('https://example.com/dl/custom-1.0.jar?token=abc').filename,
    'custom-1.0.jar'
  );
});

test('a spec of just "@" is refused', () => {
  assert.throws(() => parseSpec('@'), /not a Modrinth project slug/);
});

test('uppercase and dots are legal in a slug', () => {
  // Modrinth's slug charset is wider than lowercase-and-hyphens; rejecting
  // those would refuse valid projects.
  assert.strictEqual(parseSpec('Fabric.API_2').slug, 'Fabric.API_2');
});

// --------------------------------------------------------------------------
// Minecraft version
// --------------------------------------------------------------------------

test('the version recorded next to the jar wins over the configured one', async () => {
  // `minecraft_version = "latest"` moves; the jar on disk does not. Mods have
  // to match the jar.
  const version = await resolveMinecraftVersion({
    configured: 'latest',
    recorded: '26.1.2',
    http: fakeHttp({ game: [{ version: '26.2', stable: true }] }),
  });
  assert.strictEqual(version, '26.1.2');
});

test('a pinned version is used when nothing is recorded yet', async () => {
  const version = await resolveMinecraftVersion({ configured: '26.1', recorded: null, http: fakeHttp() });
  assert.strictEqual(version, '26.1');
});

test('"latest" with nothing recorded asks Fabric for the newest stable', async () => {
  const version = await resolveMinecraftVersion({
    configured: 'latest',
    recorded: null,
    http: fakeHttp({ game: [{ version: '26.3-snapshot', stable: false }, { version: '26.2', stable: true }] }),
  });
  assert.strictEqual(version, '26.2');
});

// --------------------------------------------------------------------------
// The filesystem boundary
//
// Filenames arrive from Modrinth's file listing and from the last segment of a
// direct mod URL. Neither is ours, and this runs as root on every boot.
// --------------------------------------------------------------------------

test('a mod filename cannot escape the mods directory', () => {
  const path = require('path');
  const MODS = '/srv/minecraft/server/mods';
  const touched = [];
  const fakeFs = {
    existsSync: (target) => { touched.push(target); return false; },
    readFileSync: (target) => { touched.push(target); return Buffer.alloc(0); },
    writeFileSync: (target) => touched.push(target),
    renameSync: (from, to) => touched.push(from, to),
    rmSync: (target) => touched.push(target),
  };
  const store = directoryStore(fakeFs, path, MODS);

  // The property that matters is not "these inputs throw" -- a backslash is an
  // ordinary character in a POSIX filename -- but that no input reaches a path
  // outside the mods directory. Refusing and containing are both fine.
  for (const hostile of [
    '../../../../etc/cron.d/pwn.jar',
    '../../../../root/.ssh/authorized_keys',
    '/etc/cron.d/pwn.jar',
    'sub/dir/nested.jar',
    '..',
    '.',
    '',
  ]) {
    for (const call of [
      () => store.write(hostile, Buffer.from('x')),
      () => store.has(hostile),
      () => store.remove(hostile),
    ]) {
      try {
        call();
      } catch (err) {
        assert.match(err.message, /unsafe mod filename/, `unexpected error for ${JSON.stringify(hostile)}`);
      }
    }
  }

  for (const target of touched) {
    assert.ok(
      path.resolve(target).startsWith(path.resolve(MODS) + path.sep),
      `escaped the mods directory: ${target}`
    );
  }
});

test('an ordinary mod filename still resolves inside the directory', () => {
  const path = require('path');
  const written = [];
  const fakeFs = {
    existsSync: () => true,
    readFileSync: () => Buffer.alloc(0),
    writeFileSync: (target) => written.push(target),
    renameSync: () => {},
    rmSync: () => {},
  };
  const store = directoryStore(fakeFs, path, '/mods');
  store.write('lithium-fabric-0.15.0.jar', Buffer.from('x'));
  assert.equal(written[0], path.join('/mods', 'lithium-fabric-0.15.0.jar.part'));
  assert.equal(store.has('.managed.json'), true, 'the manifest is a normal name');
});

// --------------------------------------------------------------------------
// Requirements
//
// A mod whose hard dependency is missing does not run slower, it stops the
// server booting -- the same failure a version-mismatched jar causes. Adding
// spark without Fabric API is the real case: Modrinth resolves it happily and
// Fabric then refuses to start.
// --------------------------------------------------------------------------

/** A version fixture with its own file name and declared dependencies. */
function modVersion(name, { requires = [], sha1 = 'body' } = {}) {
  return modrinthVersion({
    project_id: `${name}-id`,
    version_number: '1.0.0',
    dependencies: requires.map((id) => ({ project_id: id, dependency_type: 'required' })),
    files: [
      {
        filename: `${name}-1.0.0.jar`,
        url: `https://cdn.modrinth.com/${name}-1.0.0.jar`,
        primary: true,
        hashes: { sha1 },
      },
    ],
  });
}

test('a required dependency is installed alongside the mod that needs it', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      spark: [modVersion('spark', { requires: ['fabric-api-id'] })],
      'fabric-api-id': [modVersion('fabric-api')],
    },
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'spark',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'fabric-api',
    },
  });

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });

  assert.deepEqual(store.names(), ['.managed.json', 'fabric-api-1.0.0.jar', 'spark-1.0.0.jar']);
  assert.equal(result.failed.length, 0);
  assert.deepEqual(
    result.dependencies.map((d) => [d.spec, d.requiredBy]),
    [['fabric-api-id', 'spark']],
    'the summary has to say whose requirement it was'
  );
});

test('a dependency of a dependency is followed', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      top: [modVersion('top', { requires: ['mid-id'] })],
      'mid-id': [modVersion('mid', { requires: ['base-id'] })],
      'base-id': [modVersion('base')],
    },
    binaries: {
      'https://cdn.modrinth.com/top-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/mid-1.0.0.jar': 'b',
      'https://cdn.modrinth.com/base-1.0.0.jar': 'c',
    },
  });

  await syncMods({ specs: ['top'], minecraft: '1.21.4', store, http, sha1: () => 'body' });
  assert.deepEqual(store.names(), [
    '.managed.json',
    'base-1.0.0.jar',
    'mid-1.0.0.jar',
    'top-1.0.0.jar',
  ]);
});

test('an auto-installed requirement is reported by slug, not by project id', async () => {
  // Modrinth records dependencies as project ids, so without a lookup the one
  // message that asks the operator to act says "P7dR8mSH was installed", which
  // names nothing they can put in server_mods.
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      spark: [modVersion('spark', { requires: ['P7dR8mSH'] })],
      'fabric-api': [modVersion('fabric-api')],
    },
    projectMeta: { P7dR8mSH: { slug: 'fabric-api' } },
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'b',
    },
  });

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });

  assert.equal(result.dependencies.length, 1);
  assert.equal(result.dependencies[0].spec, 'fabric-api', 'the summary must name the slug');
  assert.equal(result.dependencies[0].requiredBy, 'spark');
});

test('an unresolvable slug lookup falls back to the id rather than failing', async () => {
  // A display name is never worth failing a boot over, so a 404 on the lookup
  // leaves the id in place: uglier, still correct, still installed.
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      spark: [modVersion('spark', { requires: ['P7dR8mSH'] })],
      P7dR8mSH: [modVersion('fabric-api')],
    },
    // no projectMeta, so the lookup 404s
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'b',
    },
  });

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });

  assert.equal(result.dependencies.length, 1, 'it must still be installed');
  assert.equal(result.dependencies[0].spec, 'P7dR8mSH');
  assert.equal(result.failed.length, 0, 'a naming failure is not a sync failure');
});

test('a requirement shared by two mods is fetched once', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      one: [modVersion('one', { requires: ['shared-id'] })],
      two: [modVersion('two', { requires: ['shared-id'] })],
      'shared-id': [modVersion('shared')],
    },
    binaries: {
      'https://cdn.modrinth.com/one-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/two-1.0.0.jar': 'b',
      'https://cdn.modrinth.com/shared-1.0.0.jar': 'c',
    },
  });

  const result = await syncMods({
    specs: ['one', 'two'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });
  assert.equal(result.dependencies.length, 1, 'resolved once, not once per dependent');
  const versionFetches = http.calls.filter(
    (u) => u.includes('shared-id') && u.includes('/version')
  ).length;
  assert.equal(versionFetches, 1, 'the version list is fetched once, not once per dependent');
  const slugLookups = http.calls.filter((u) => u.endsWith('/project/shared-id')).length;
  assert.equal(slugLookups, 1, 'and the id -> slug lookup is cached across dependents');
});

test('a requirement the operator already listed is not fetched twice', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      spark: [modVersion('spark', { requires: ['fabric-api-id'] })],
      'fabric-api': [modVersion('fabric-api')],
      'fabric-api-id': [modVersion('fabric-api')],
    },
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'b',
    },
  });

  const result = await syncMods({
    specs: ['spark', 'fabric-api'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });
  assert.equal(result.dependencies.length, 0, 'it was already asked for by name');
  assert.deepEqual(store.names(), ['.managed.json', 'fabric-api-1.0.0.jar', 'spark-1.0.0.jar']);
});

test('optional and embedded dependencies are left alone', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      lithium: [
        modrinthVersion({
          project_id: 'lithium-id',
          dependencies: [
            { project_id: 'suggested-id', dependency_type: 'optional' },
            { project_id: 'bundled-id', dependency_type: 'embedded' },
            { project_id: 'clashes-id', dependency_type: 'incompatible' },
          ],
        }),
      ],
    },
    binaries: { 'https://cdn.modrinth.com/lithium-1.0.0.jar': 'body' },
  });

  const result = await syncMods({
    specs: ['lithium'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'jar-body',
  });
  assert.equal(result.dependencies.length, 0);
  assert.deepEqual(store.names(), ['.managed.json', 'lithium-1.0.0.jar']);
});

test('a requirement with no build for this version is reported, not silently skipped', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: { spark: [modVersion('spark', { requires: ['missing-id'] })] },
    binaries: { 'https://cdn.modrinth.com/spark-1.0.0.jar': 'a' },
  });

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });
  assert.equal(result.failed.length, 1);
  assert.match(result.failed[0].error, /required by spark/);
});

test('a dependency no longer needed is removed with its dependent', async () => {
  const store = fakeStore({
    'spark-1.0.0.jar': 'a',
    'fabric-api-1.0.0.jar': 'b',
    '.managed.json': JSON.stringify({
      version: 1,
      minecraft: '1.21.4',
      mods: [
        { spec: 'spark', file: 'spark-1.0.0.jar', sha1: 'body' },
        { spec: 'fabric-api-id', file: 'fabric-api-1.0.0.jar', sha1: 'body', requiredBy: 'spark' },
      ],
    }),
  });
  const http = fakeHttp({ projects: {}, binaries: {} });

  const result = await syncMods({
    specs: [],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
  });
  assert.deepEqual(result.removed.sort(), ['fabric-api-1.0.0.jar', 'spark-1.0.0.jar']);
  assert.deepEqual(store.names(), ['.managed.json']);
});

test('the file actually does something when run as a script', () => {
  // Every other test here imports the module, so `require.main === module` is
  // false and main() never runs. That makes losing the entry point invisible:
  // the suite stays green while the boot-time sync silently does nothing at
  // all. This is the only test that runs it the way systemd does.
  const fs = require('fs');
  const os = require('os');
  const { spawnSync } = require('child_process');

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-mods-cli-'));
  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, '..', 'server', 'bin', 'install-mods.js'), '--list'],
    { env: { ...process.env, SERVER_DIR: dir, SERVER_MODS: '' }, encoding: 'utf8', timeout: 30000 }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.stdout,
    /configured \(server_mods\)/,
    'running it as a script must produce its listing'
  );

  fs.rmSync(dir, { recursive: true, force: true });
});

// --------------------------------------------------------------------------
// Reading requirements out of the jars
//
// Modrinth said spark had no dependencies. Fabric then refused to start
// because spark needs Fabric API. The jar knew all along.
// --------------------------------------------------------------------------

/** A readJarEntry over a plain {file: fabricModJson} map. */
function fakeJars(map) {
  return (file, entry) => {
    if (entry !== 'fabric.mod.json') return null;
    if (!(file in map)) return null;
    return Buffer.from(JSON.stringify(map[file]));
  };
}

test('a dependency the installed set does not provide is reported', () => {
  const read = fakeJars({
    'spark.jar': { id: 'spark', depends: { fabricloader: '*', 'fabric-api-base': '*' } },
    'lithium.jar': { id: 'lithium', depends: { minecraft: '*' } },
  });

  const unmet = unmetRequirements(read, ['spark.jar', 'lithium.jar']);
  assert.deepEqual(unmet, [{ file: 'spark.jar', id: 'fabric-api-base' }]);
});

test('the loader and the game are not requirements', () => {
  const read = fakeJars({
    'a.jar': { id: 'a', depends: { minecraft: '*', java: '*', fabricloader: '*' } },
  });
  assert.deepEqual(unmetRequirements(read, ['a.jar']), []);
});

test('a jar that provides an id satisfies the mod that wants it', () => {
  const read = fakeJars({
    'needs.jar': { id: 'needs', depends: { 'fabric-command-api-v2': '*' } },
    'fabric-api.jar': { id: 'fabric-api', provides: ['fabric-command-api-v2', 'fabric-api-base'] },
  });
  assert.deepEqual(unmetRequirements(read, ['needs.jar', 'fabric-api.jar']), []);
});

test('an unreadable or non-Fabric jar is ignored rather than guessed at', () => {
  const read = () => null;
  assert.deepEqual(unmetRequirements(read, ['mystery.jar']), []);
  assert.equal(readJarMetadata(() => Buffer.from('not json'), 'x.jar'), null);
});

test('every fabric-* id points at the Fabric API project', () => {
  assert.equal(projectSupplying('fabric-api-base'), 'fabric-api');
  assert.equal(projectSupplying('fabric-command-api-v2'), 'fabric-api');
  assert.equal(projectSupplying('fabric'), 'fabric-api');
  assert.equal(projectSupplying('some-other-mod'), null, 'guessing would install a stranger');
});

test('syncMods fetches what a jar says it needs, even when Modrinth does not', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      // No declared dependencies at all -- exactly what Modrinth returns.
      spark: [modVersion('spark')],
      'fabric-api': [modVersion('fabric-api')],
    },
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'spark',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'fabric-api',
    },
  });

  const jars = {
    'spark-1.0.0.jar': { id: 'spark', depends: { 'fabric-api-base': '*' } },
    'fabric-api-1.0.0.jar': { id: 'fabric-api', provides: ['fabric-api-base'] },
  };

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars(jars),
  });

  assert.deepEqual(store.names(), ['.managed.json', 'fabric-api-1.0.0.jar', 'spark-1.0.0.jar']);
  assert.deepEqual(
    result.dependencies.map((d) => d.spec),
    ['fabric-api'],
    'the jar asked for it even though the index did not'
  );
  assert.equal(result.failed.length, 0);
});

test('a mod whose dependency cannot be supplied is removed, not left to break the boot', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: { lonely: [modVersion('lonely')] },
    binaries: { 'https://cdn.modrinth.com/lonely-1.0.0.jar': 'a' },
  });

  const result = await syncMods({
    specs: ['lonely'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars({ 'lonely-1.0.0.jar': { id: 'lonely', depends: { 'some-lib': '*' } } }),
  });

  // Fabric will not start with it, so it must not be left on disk.
  assert.equal(store.has('lonely-1.0.0.jar'), false);
  assert.ok(result.removed.includes('lonely-1.0.0.jar'));
  assert.equal(result.installed.find((m) => m.file === 'lonely-1.0.0.jar'), undefined);

  // And it says which requirement did it, so the message can name a fix.
  assert.equal(result.evicted.length, 1);
  assert.equal(result.evicted[0].spec, 'lonely');
  assert.deepEqual(result.evicted[0].missing, ['some-lib']);
});

test('an evicted mod is kept out of the manifest, so it is not counted as installed', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: { lonely: [modVersion('lonely')] },
    binaries: { 'https://cdn.modrinth.com/lonely-1.0.0.jar': 'a' },
  });

  await syncMods({
    specs: ['lonely'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars({ 'lonely-1.0.0.jar': { id: 'lonely', depends: { 'some-lib': '*' } } }),
  });

  assert.deepEqual(readManifest(store).mods, []);
});

test('a satisfiable dependency is still installed rather than evicted', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: {
      spark: [modVersion('spark')],
      'fabric-api': [modVersion('fabric-api')],
    },
    binaries: {
      'https://cdn.modrinth.com/spark-1.0.0.jar': 'a',
      'https://cdn.modrinth.com/fabric-api-1.0.0.jar': 'b',
    },
  });

  const result = await syncMods({
    specs: ['spark'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars({
      'spark-1.0.0.jar': { id: 'spark', depends: { 'fabric-api-base': '*' } },
      'fabric-api-1.0.0.jar': { id: 'fabric-api', provides: ['fabric-api-base'] },
    }),
  });

  assert.equal(result.evicted.length, 0);
  assert.equal(store.has('spark-1.0.0.jar'), true);
  assert.equal(store.has('fabric-api-1.0.0.jar'), true);
});

test('a hand-placed jar with an unmet dependency is left alone', async () => {
  const store = fakeStore({ 'mine.jar': 'x' });
  const http = fakeHttp({ projects: {}, binaries: {} });

  const result = await syncMods({
    specs: [],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars({ 'mine.jar': { id: 'mine', depends: { 'some-lib': '*' } } }),
  });

  assert.equal(store.has('mine.jar'), true);
  assert.equal(result.evicted.length, 0);
});

test('a requirement nothing can supply is named rather than left to crash the server', async () => {
  const store = fakeStore();
  const http = fakeHttp({
    projects: { lonely: [modVersion('lonely')] },
    binaries: { 'https://cdn.modrinth.com/lonely-1.0.0.jar': 'a' },
  });

  const result = await syncMods({
    specs: ['lonely'],
    minecraft: '1.21.4',
    store,
    http,
    sha1: () => 'body',
    readJarEntry: fakeJars({ 'lonely-1.0.0.jar': { id: 'lonely', depends: { 'some-lib': '*' } } }),
  });

  assert.equal(result.failed.length, 1);
  assert.match(result.failed[0].error, /some-lib/);
});
