#!/usr/bin/env node
/**
 * Keep the Fabric mods directory in step with the `server_mods` list Terraform
 * publishes.
 *
 * Runs from minecraft.service as an ExecStartPre, so every boot reconciles the
 * directory before the server starts: mods added to the list are downloaded,
 * mods removed from it are deleted, and a Minecraft version change re-resolves
 * all of them.
 *
 * Two rules drive everything here:
 *
 *   1. A mod jar built for the wrong Minecraft version does not degrade the
 *      server, it stops it booting. So when the game version has changed and a
 *      mod has no build for the new one, its jar is DELETED rather than left in
 *      place. Losing an optimisation is recoverable; a crash loop on a box
 *      nobody can SSH into is much less so.
 *
 *   2. Only jars this script installed are ever touched. They are recorded in
 *      .managed.json, so a jar dropped into the directory by hand -- which is
 *      how you install anything not on Modrinth -- survives every sync.
 *
 * Nothing in here is allowed to fail the boot. main() catches everything and
 * exits 0, and the unit invokes it with a "-" prefix as a second line of
 * defence.
 *
 * The logic is exported and its I/O injected so tests/test_mods.js can drive it
 * without a network or a filesystem; main() wires up the real ones.
 */

'use strict';

const MODRINTH_API = 'https://api.modrinth.com/v2';
const FABRIC_META = 'https://meta.fabricmc.net/v2';

const MANIFEST = '.managed.json';
const MANIFEST_VERSION = 1;

/** Modrinth asks every API client to identify itself. */
const USER_AGENT = 'aws-discord-mc-server (mods installer)';

// --------------------------------------------------------------------------
// Specs
// --------------------------------------------------------------------------

/**
 * A spec is one entry of `server_mods`. Two forms:
 *
 *   lithium            a Modrinth project slug; latest build for this version
 *   lithium@0.15.0     the same, pinned to one Modrinth version
 *   https://.../x.jar  a direct download, for anything not on Modrinth
 *
 * Direct URLs must be https: these jars run inside the server process, and a
 * plaintext download is a jar chosen by whoever is between us and the host.
 */
function parseSpec(raw) {
  const spec = String(raw).trim();
  if (!spec) return null;

  if (/^[a-z][a-z0-9+.-]*:/i.test(spec)) {
    if (!spec.startsWith('https://')) {
      throw new Error(`refusing a non-https mod URL: ${spec}`);
    }
    const filename = decodeURIComponent(spec.split('?')[0].split('/').pop() || '');
    if (!filename.endsWith('.jar')) {
      throw new Error(`mod URL does not end in .jar: ${spec}`);
    }
    return { spec, kind: 'url', url: spec, filename };
  }

  // slug@version. The slug charset is Modrinth's; anything else is a typo we
  // would rather name now than send to the API and get a 404 for.
  const at = spec.lastIndexOf('@');
  const slug = at === -1 ? spec : spec.slice(0, at);
  const pin = at === -1 ? null : spec.slice(at + 1);
  if (!/^[a-zA-Z0-9!@$()`.+,_"-]{1,64}$/.test(slug)) {
    throw new Error(`not a Modrinth project slug or an https URL: ${spec}`);
  }
  if (at !== -1 && !pin) {
    throw new Error(`missing version after @: ${spec}`);
  }
  return { spec, kind: 'project', slug, pin };
}

function parseSpecList(raw) {
  return String(raw || '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

// --------------------------------------------------------------------------
// Resolution
// --------------------------------------------------------------------------

/**
 * Pick the build to install from everything Modrinth returned.
 *
 * The query already filters to fabric + this game version, so this is only
 * ordering: a real release beats a beta or alpha of the same mod, and within
 * that the newest publish date wins. Modrinth returns newest-first today, but
 * sorting explicitly means a change there cannot quietly install a year-old
 * jar.
 */
function chooseVersion(versions, pin) {
  const candidates = Array.isArray(versions) ? versions.slice() : [];
  if (candidates.length === 0) return null;

  if (pin) {
    return candidates.find((v) => v.version_number === pin || v.id === pin) || null;
  }

  const rank = (v) => (v.version_type === 'release' ? 0 : v.version_type === 'beta' ? 1 : 2);
  candidates.sort((a, b) => {
    const byType = rank(a) - rank(b);
    if (byType !== 0) return byType;
    return String(b.date_published || '').localeCompare(String(a.date_published || ''));
  });
  return candidates[0];
}

/** The jar itself, as opposed to a sources or javadoc attachment. */
function chooseFile(version) {
  const files = Array.isArray(version.files) ? version.files : [];
  const jars = files.filter((f) => typeof f.filename === 'string' && f.filename.endsWith('.jar'));
  return jars.find((f) => f.primary) || jars[0] || null;
}

async function resolveSpec(parsed, { minecraft, http }) {
  if (parsed.kind === 'url') {
    return {
      spec: parsed.spec,
      file: parsed.filename,
      url: parsed.url,
      sha1: null,
      title: parsed.filename,
    };
  }

  const query =
    `?loaders=${encodeURIComponent('["fabric"]')}` +
    `&game_versions=${encodeURIComponent(JSON.stringify([minecraft]))}`;
  const versions = await http.getJson(`${MODRINTH_API}/project/${parsed.slug}/version${query}`);

  const version = chooseVersion(versions, parsed.pin);
  if (!version) {
    throw new Error(
      parsed.pin
        ? `no version ${parsed.pin} for Minecraft ${minecraft}`
        : `no Fabric build for Minecraft ${minecraft}`
    );
  }

  const file = chooseFile(version);
  if (!file || !file.url) throw new Error(`version ${version.version_number} has no jar`);

  return {
    spec: parsed.spec,
    file: file.filename,
    url: file.url,
    sha1: (file.hashes && file.hashes.sha1) || null,
    title: `${parsed.slug} ${version.version_number}`,
  };
}

// --------------------------------------------------------------------------
// Sync
// --------------------------------------------------------------------------

function readManifest(store) {
  const text = store.readText(MANIFEST);
  if (!text) return { version: MANIFEST_VERSION, minecraft: null, mods: [] };
  try {
    const parsed = JSON.parse(text);
    return {
      version: MANIFEST_VERSION,
      minecraft: parsed.minecraft || null,
      mods: Array.isArray(parsed.mods) ? parsed.mods : [],
    };
  } catch {
    // A truncated manifest would otherwise make every managed jar look
    // hand-placed and leak forever. Starting empty re-adopts them instead:
    // the desired mods are re-downloaded over the top and anything stale is
    // left for the operator, which is the safe direction to be wrong in.
    return { version: MANIFEST_VERSION, minecraft: null, mods: [] };
  }
}

/**
 * Reconcile the mods directory with `specs`.
 *
 * Returns a summary rather than logging directly, so the caller decides what
 * reaches the journal and the tests can assert on the decisions.
 */
async function syncMods({ specs, minecraft, store, http, sha1, log = () => {} }) {
  const previous = readManifest(store);
  const versionChanged = previous.minecraft !== null && previous.minecraft !== minecraft;
  if (versionChanged) {
    log(`Minecraft version changed ${previous.minecraft} -> ${minecraft}; re-resolving every mod`);
  }

  const installed = [];
  const failed = [];
  const removed = [];

  for (const raw of specs) {
    let parsed;
    try {
      parsed = parseSpec(raw);
    } catch (err) {
      failed.push({ spec: raw, error: err.message });
      continue;
    }
    if (!parsed) continue;

    let resolved;
    try {
      resolved = await resolveSpec(parsed, { minecraft, http });
    } catch (err) {
      failed.push({ spec: parsed.spec, error: err.message });

      // Modrinth being unreachable is not a reason to strip a working server
      // of its mods -- but only while the jar on disk is still one built for
      // the version about to be launched.
      const kept = previous.mods.find((m) => m.spec === parsed.spec);
      if (!versionChanged && kept && store.has(kept.file)) {
        installed.push(kept);
        log(`${parsed.spec}: ${err.message}; keeping the installed ${kept.file}`);
      } else {
        log(`${parsed.spec}: ${err.message}; not installed`);
      }
      continue;
    }

    // Two entries can land on the same build -- the same slug listed twice, or
    // a slug and a pin that name the same version. Resolve both, install once.
    if (installed.some((m) => m.file === resolved.file)) {
      log(`${resolved.spec}: already installed this run as ${resolved.file}`);
      continue;
    }

    // A jar is only current if the manifest agrees it is the one we resolved
    // AND the bytes on disk still hash to that. Checking the bookkeeping alone
    // would leave a truncated or corrupted jar in place forever, and Fabric
    // does not skip a bad jar -- it refuses to start. Hashing a few megabytes
    // per boot is a rounding error against that.
    const existing = previous.mods.find((m) => m.file === resolved.file);
    if (existing && store.has(resolved.file) && existing.sha1 === resolved.sha1) {
      // A direct URL has no published hash, so there is nothing to check
      // against; the file is taken on trust.
      if (!resolved.sha1 || sha1(store.read(resolved.file)) === resolved.sha1) {
        installed.push({ spec: resolved.spec, file: resolved.file, sha1: resolved.sha1 });
        continue;
      }
      log(`${resolved.file} no longer matches its checksum; downloading it again`);
    }

    try {
      const body = await http.getBinary(resolved.url);
      if (resolved.sha1) {
        const actual = sha1(body);
        if (actual !== resolved.sha1) {
          throw new Error(`checksum mismatch (expected ${resolved.sha1}, got ${actual})`);
        }
      }
      store.write(resolved.file, body);
      installed.push({ spec: resolved.spec, file: resolved.file, sha1: resolved.sha1 });
      log(`installed ${resolved.title} as ${resolved.file}`);
    } catch (err) {
      failed.push({ spec: resolved.spec, error: `download failed: ${err.message}` });
      log(`${resolved.spec}: download failed: ${err.message}`);
    }
  }

  // Anything this script put there before and no longer wants. Files it never
  // recorded are left alone: those are hand-installed mods.
  const wanted = new Set(installed.map((m) => m.file));
  for (const stale of previous.mods) {
    if (wanted.has(stale.file)) continue;
    if (!store.has(stale.file)) continue;
    store.remove(stale.file);
    removed.push(stale.file);
    log(`removed ${stale.file}`);
  }

  store.writeText(
    MANIFEST,
    `${JSON.stringify({ version: MANIFEST_VERSION, minecraft, mods: installed }, null, 2)}\n`
  );

  return { installed, failed, removed, minecraft };
}

// --------------------------------------------------------------------------
// Minecraft version
// --------------------------------------------------------------------------

/**
 * Which Minecraft version the mods have to match.
 *
 * bootstrap.sh writes .minecraft-version next to the jar when it installs one,
 * which is authoritative: it is the version the jar in $SERVER_DIR actually is,
 * even if `minecraft_version = "latest"` has since moved on. Only when that
 * file is missing does this fall back to asking Fabric what "latest" means.
 */
async function resolveMinecraftVersion({ configured, recorded, http }) {
  if (recorded) return recorded;
  if (configured && configured !== 'latest') return configured;

  const games = await http.getJson(`${FABRIC_META}/versions/game`);
  const stable = (Array.isArray(games) ? games : []).find((g) => g.stable);
  if (!stable || !stable.version) throw new Error('Fabric meta returned no stable game version');
  return stable.version;
}

// --------------------------------------------------------------------------
// Real I/O
// --------------------------------------------------------------------------

function httpsClient(https, { timeoutMs = 30000, maxRedirects = 3 } = {}) {
  const get = (url, redirectsLeft) =>
    new Promise((resolve, reject) => {
      const request = https.get(
        url,
        { headers: { 'User-Agent': USER_AGENT, Accept: '*/*' }, timeout: timeoutMs },
        (response) => {
          const status = response.statusCode;

          if (status >= 300 && status < 400 && response.headers.location) {
            response.resume();
            if (redirectsLeft <= 0) return reject(new Error('too many redirects'));
            const next = new URL(response.headers.location, url).toString();
            if (!next.startsWith('https://')) return reject(new Error('redirect left https'));
            return resolve(get(next, redirectsLeft - 1));
          }

          if (status !== 200) {
            response.resume();
            return reject(new Error(`HTTP ${status}`));
          }

          const chunks = [];
          response.on('data', (chunk) => chunks.push(chunk));
          response.on('end', () => resolve(Buffer.concat(chunks)));
          response.on('error', reject);
        }
      );

      request.on('timeout', () => request.destroy(new Error(`timed out after ${timeoutMs}ms`)));
      request.on('error', reject);
    });

  return {
    async getJson(url) {
      return JSON.parse((await get(url, maxRedirects)).toString('utf8'));
    },
    async getBinary(url) {
      return get(url, maxRedirects);
    },
  };
}

/**
 * The mods directory as a flat key-value store.
 *
 * Writes land on a .part file and are renamed into place, so an interrupted
 * download cannot leave a half-jar for Fabric to choke on at the next start.
 */
function directoryStore(fs, path, dir) {
  // Names reaching here come from Modrinth's file listing and from the last
  // segment of a direct mod URL, so they are not ours to trust. path.join
  // walks out of the directory happily on a "..", and this runs as root on
  // every boot. basename() is the whole guard: a mod jar has no business
  // naming a path.
  const full = (name) => {
    const safe = path.basename(String(name));
    if (!safe || safe === '.' || safe === '..') {
      throw new Error(`unsafe mod filename: ${name}`);
    }
    return path.join(dir, safe);
  };
  return {
    has: (name) => fs.existsSync(full(name)),
    read(name) {
      return fs.readFileSync(full(name));
    },
    readText(name) {
      try {
        return fs.readFileSync(full(name), 'utf8');
      } catch {
        return null;
      }
    },
    writeText(name, text) {
      fs.writeFileSync(full(name), text);
    },
    write(name, buffer) {
      const tmp = `${full(name)}.part`;
      fs.writeFileSync(tmp, buffer);
      fs.renameSync(tmp, full(name));
    },
    remove(name) {
      fs.rmSync(full(name), { force: true });
    },
  };
}

// --------------------------------------------------------------------------
// Entry point
// --------------------------------------------------------------------------

async function main() {
  const fs = require('fs');
  const path = require('path');
  const https = require('https');
  const crypto = require('crypto');
  const { execFileSync } = require('child_process');

  const log = (message) => console.log(`[mods] ${message}`);

  const serverDir = process.env.SERVER_DIR || '/srv/minecraft/server';
  const modsDir = path.join(serverDir, 'mods');
  const specs = parseSpecList(process.env.SERVER_MODS);
  const listOnly = process.argv.includes('--list');

  const http = httpsClient(https);
  const store = directoryStore(fs, path, modsDir);
  const sha1 = (buffer) => crypto.createHash('sha1').update(buffer).digest('hex');

  if (listOnly) {
    const jars = fs.existsSync(modsDir)
      ? fs.readdirSync(modsDir).filter((f) => f.endsWith('.jar')).sort()
      : [];
    const managed = new Set(readManifest(store).mods.map((m) => m.file));
    if (jars.length === 0) {
      console.log('no mods installed');
    } else {
      for (const jar of jars) console.log(`${managed.has(jar) ? 'managed' : 'manual '}  ${jar}`);
    }
    console.log(`\nconfigured (server_mods): ${specs.join(', ') || '(none)'}`);
    return;
  }

  // No mods configured and none ever installed: do not create the directory,
  // do not call out to the network. This is the common case and it should cost
  // nothing at boot.
  if (specs.length === 0 && !fs.existsSync(path.join(modsDir, MANIFEST))) return;

  fs.mkdirSync(modsDir, { recursive: true });

  const recorded = (() => {
    try {
      return fs.readFileSync(path.join(serverDir, '.minecraft-version'), 'utf8').trim() || null;
    } catch {
      return null;
    }
  })();

  const minecraft = await resolveMinecraftVersion({
    configured: process.env.MINECRAFT_VERSION,
    recorded,
    http,
  });

  const result = await syncMods({ specs, minecraft, store, http, sha1, log });

  // The server runs as MC_USER and Fabric only reads these, but a root-owned
  // jar in a directory the operator edits by hand is a trap.
  try {
    const user = process.env.MC_USER || 'minecraft';
    if (typeof process.getuid === 'function' && process.getuid() === 0) {
      const uid = parseInt(execFileSync('id', ['-u', user], { encoding: 'utf8' }), 10);
      const gid = parseInt(execFileSync('id', ['-g', user], { encoding: 'utf8' }), 10);
      fs.chownSync(modsDir, uid, gid);
      for (const name of fs.readdirSync(modsDir)) fs.chownSync(path.join(modsDir, name), uid, gid);
    }
  } catch (err) {
    log(`could not set ownership of ${modsDir}: ${err.message}`);
  }

  log(
    `${result.installed.length} installed, ${result.removed.length} removed, ` +
      `${result.failed.length} failed (Minecraft ${minecraft})`
  );
  for (const failure of result.failed) log(`WARNING: ${failure.spec}: ${failure.error}`);
}

if (require.main === module) {
  main().catch((err) => {
    // Deliberately exit 0. Mods are an optimisation; the server starting is
    // not. Whatever went wrong is in the journal next to this line.
    console.log(`[mods] WARNING: ${err && err.message ? err.message : err}`);
    console.log('[mods] continuing without a mod sync');
  });
}

module.exports = {
  parseSpec,
  parseSpecList,
  chooseVersion,
  chooseFile,
  resolveSpec,
  syncMods,
  resolveMinecraftVersion,
  readManifest,
  directoryStore,
  MANIFEST,
};
