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
function fakeHttp({ projects = {}, binaries = {}, game = [] } = {}) {
  const calls = [];
  return {
    calls,
    async getJson(url) {
      calls.push(url);
      if (url.includes('meta.fabricmc.net')) return game;
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
