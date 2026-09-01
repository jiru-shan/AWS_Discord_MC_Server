/**
 * Behavioural tests for the idle/player-count state machine in servermanager.js.
 *
 * This is the logic the whole cost model rests on: if it misses a "left the
 * game" the instance bills forever, and if it miscounts a join it kicks people
 * off mid-session. Timers are injected so a fifteen minute countdown runs
 * instantly.
 *
 * Run with: node --test tests/test_session.js
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawnSync } = require('child_process');

const { createSession, createEventQueue, normalise, PATTERNS } = require(
  path.join(__dirname, '..', 'server', 'bin', 'servermanager.js')
);

/** Deterministic stand-in for setTimeout: nothing fires until advance(). */
function fakeTimers() {
  let now = 0;
  let seq = 0;
  const pending = new Map();

  return {
    timers: {
      setTimeout(fn, ms) {
        const id = ++seq;
        pending.set(id, { at: now + ms, fn });
        return id;
      },
      clearTimeout(id) {
        pending.delete(id);
      },
    },
    /** Move the clock forward, firing anything due. */
    advance(ms) {
      now += ms;
      for (const [id, entry] of [...pending.entries()].sort((a, b) => a[1].at - b[1].at)) {
        if (entry.at <= now) {
          pending.delete(id);
          entry.fn();
        }
      }
    },
    pendingCount: () => pending.size,
  };
}

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

/** Build a session plus a record of the callbacks it made. */
function build(options = {}) {
  const clock = fakeTimers();
  const events = [];
  const session = createSession({
    idleMinutes: 15,
    timers: clock.timers,
    onReady: () => events.push('ready'),
    onIdle: (message) => events.push(`idle:${message}`),
    ...options,
  });
  return { session, clock, events };
}

// Realistic log lines, matching vanilla/Fabric output exactly.
const line = (message) => `[12:34:56] [Server thread/INFO]: ${message}`;
const READY_LINE = line('Done (21.505s)! For help, type "help"');

// --------------------------------------------------------------------------

test('the ready line is recognised and starts the idle countdown', () => {
  const { session, clock, events } = build();

  assert.equal(session.isReady(), false);
  assert.equal(session.handleLine(READY_LINE), 'ready');
  assert.equal(session.isReady(), true);
  assert.deepEqual(events, ['ready']);
  assert.equal(session.idleArmed(), true, 'an empty server should be counting down');

  clock.advance(15 * MINUTE);
  assert.equal(events.length, 2);
  assert.match(events[1], /^idle:No players for 15 minutes/);
});

test('a server nobody ever joins still shuts down', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  clock.advance(14 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0, 'not yet');
  clock.advance(1 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 1);
});

test('ready fires only once even if the line repeats', () => {
  const { session, events } = build();
  session.handleLine(READY_LINE);
  session.handleLine(READY_LINE);
  assert.deepEqual(events.filter((e) => e === 'ready'), ['ready']);
});

// --------------------------------------------------------------------------

test('joining cancels the countdown, leaving restarts it', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  assert.equal(session.idleArmed(), true);

  session.handleLine(line('Notch joined the game'));
  assert.equal(session.playerCount(), 1);
  assert.equal(session.idleArmed(), false, 'someone is playing');

  clock.advance(60 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0, 'must not shut down mid-game');

  session.handleLine(line('Notch left the game'));
  assert.equal(session.playerCount(), 0);
  assert.equal(session.idleArmed(), true);

  clock.advance(15 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 1);
});

test('the countdown only starts when the last player leaves', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Bob joined the game'));
  assert.equal(session.playerCount(), 2);

  session.handleLine(line('Alice left the game'));
  assert.equal(session.playerCount(), 1);
  assert.equal(session.idleArmed(), false, 'Bob is still online');

  clock.advance(30 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);

  session.handleLine(line('Bob left the game'));
  assert.equal(session.idleArmed(), true);
});

test('a player rejoining before the timer fires cancels it', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Alice left the game'));

  clock.advance(14 * MINUTE);
  session.handleLine(line('Alice joined the game'));
  clock.advance(60 * MINUTE);

  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);
  assert.equal(session.playerCount(), 1);
});

test('duplicate joins and unknown leaves do not corrupt the count', () => {
  const { session } = build();
  session.handleLine(READY_LINE);

  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Alice joined the game'));
  assert.equal(session.playerCount(), 1, 'a Set, so no double counting');

  session.handleLine(line('Ghost left the game'));
  assert.equal(session.playerCount(), 1, 'leaving without joining must not go negative');

  session.handleLine(line('Alice left the game'));
  assert.equal(session.playerCount(), 0);
});

// --------------------------------------------------------------------------
// Spoofing: the reason the patterns are anchored at both ends.
// --------------------------------------------------------------------------

test('chat cannot forge a join or a leave', () => {
  const { session } = build();
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));

  const spoofs = [
    line('<Alice> Bob joined the game'),
    line('<Alice> Alice left the game'),
    line('<Alice> hey did you see that Bob joined the game'),
    line('[Alice] Bob joined the game'),
    line('Alice issued server command: /say Bob joined the game'),
  ];
  for (const spoof of spoofs) {
    assert.equal(session.handleLine(spoof), null, `should be ignored: ${spoof}`);
  }
  assert.deepEqual(session.playerNames(), ['Alice'], 'only the real join counted');
});

test('a 17 character name is not treated as a player', () => {
  const { session } = build();
  session.handleLine(READY_LINE);
  assert.equal(session.handleLine(line('A'.repeat(17) + ' joined the game')), null);
  assert.equal(session.playerCount(), 0);

  assert.equal(session.handleLine(line('A'.repeat(16) + ' joined the game')), 'join');
  assert.equal(session.playerCount(), 1);
});

test('names with digits and underscores are accepted', () => {
  const { session } = build();
  session.handleLine(READY_LINE);
  for (const name of ['Notch', 'x_2_x', 'Player_123', 'AAA']) {
    assert.equal(session.handleLine(line(`${name} joined the game`)), 'join', name);
  }
  assert.equal(session.playerCount(), 4);
});

// --------------------------------------------------------------------------
// Line shapes that would silently break the anchors.
// --------------------------------------------------------------------------

test('carriage returns and ANSI colour do not break matching', () => {
  assert.equal(normalise('abc\r'), 'abc');
  assert.equal(normalise('[32mabc[0m'), 'abc');

  const { session } = build();
  // A CRLF-terminated line, as a wrapper on a different platform might emit.
  session.handleLine(READY_LINE + '\r');
  assert.equal(session.isReady(), true, 'a trailing CR must not defeat the $ anchor');

  // A colourised join line, as some modded servers emit.
  session.handleLine('[0;32m' + line('Alice joined the game') + '[m');
  assert.equal(session.playerCount(), 1);
});

test('unrelated log noise is ignored', () => {
  const { session } = build();
  session.handleLine(READY_LINE);
  const noise = [
    line('Starting minecraft server version 1.21.4'),
    line('Preparing level "world"'),
    line('Alice lost connection: Disconnected'),
    line('UUID of player Alice is 069a79f4-44e9-4726-a5be-fca90e38aaf5'),
    '[12:34:56] [Server thread/WARN]: Can not keep up! Is the server overloaded?',
    '',
  ];
  for (const n of noise) assert.equal(session.handleLine(n), null, n);
  assert.equal(session.playerCount(), 0);
});

// --------------------------------------------------------------------------

test('the auto-pause line triggers an immediate shutdown', () => {
  const { session, events } = build();
  session.handleLine(READY_LINE);
  assert.equal(session.handleLine(line('Server empty for 60 seconds, pausing')), 'autopause');
  assert.deepEqual(events, ['ready', 'idle:Server reported itself empty.']);
});

test('idle fires at most once', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  clock.advance(15 * MINUTE);
  session.handleLine(line('Server empty for 60 seconds, pausing'));
  clock.advance(60 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 1);
});

test('idleMinutes = 0 disables the automatic shutdown', () => {
  const { session, clock, events } = build({ idleMinutes: 0 });
  session.handleLine(READY_LINE);
  assert.equal(session.idleArmed(), false);
  clock.advance(24 * 60 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);
});

test('a fractional idle timeout is honoured', () => {
  const { session, clock, events } = build({ idleMinutes: 0.5 });
  session.handleLine(READY_LINE);
  clock.advance(29 * 1000);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);
  clock.advance(2 * 1000);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 1);
});

test('stop() disarms the timer and prevents further shutdowns', () => {
  const { session, clock, events } = build();
  session.handleLine(READY_LINE);
  assert.equal(session.idleArmed(), true);

  session.stop();
  assert.equal(session.idleArmed(), false);
  assert.equal(clock.pendingCount(), 0, 'no timer should be left holding the event loop open');

  clock.advance(60 * MINUTE);
  session.handleLine(line('Server empty for 60 seconds, pausing'));
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);
});

test('no timer leaks across a join/leave churn', () => {
  const { session, clock } = build();
  session.handleLine(READY_LINE);
  for (let i = 0; i < 50; i++) {
    session.handleLine(line('Alice joined the game'));
    session.handleLine(line('Alice left the game'));
  }
  assert.equal(clock.pendingCount(), 1, 'exactly one countdown should ever be armed');
});

// --------------------------------------------------------------------------

test('events before the ready line still track players', () => {
  // Should not happen in practice, but must not throw or corrupt state.
  const { session } = build();
  session.handleLine(line('Alice joined the game'));
  assert.equal(session.playerCount(), 1);
  session.handleLine(READY_LINE);
  assert.equal(session.idleArmed(), false, 'someone is already on, so do not arm');
});

test('the exported patterns are anchored on both sides', () => {
  for (const [name, pattern] of Object.entries(PATTERNS)) {
    assert.ok(pattern.source.endsWith('$'), `${name} must be anchored at end of line`);
    assert.ok(pattern.source.startsWith('\\]: '), `${name} must be anchored to the log prefix`);
  }
});

// --------------------------------------------------------------------------
// Startup watchdog
//
// The ready line is the only thing that arms the idle countdown, so a server
// that never prints it -- a mod hanging in init, a world that will not load, a
// JVM thrashing on a small instance -- leaves a box with nobody on it, no
// countdown running and nothing that will ever stop it.
// --------------------------------------------------------------------------

test('a server that never becomes ready still shuts the instance down', () => {
  const { session, clock, events } = build({ startupMinutes: 30 });

  session.handleLine(line('Preparing spawn area: 40%'));
  clock.advance(29 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0, 'still within the budget');
  assert.equal(session.isReady(), false);

  clock.advance(2 * MINUTE);
  assert.equal(
    events.filter((e) => e.startsWith('idle')).length,
    1,
    'a server stuck before the ready line must not bill forever'
  );
});

test('the ready line disarms the startup watchdog', () => {
  const { session, clock, events } = build({ startupMinutes: 30 });
  assert.equal(session.startupArmed(), true, 'armed from the moment the session exists');

  session.handleLine(READY_LINE);
  assert.equal(session.startupArmed(), false);
  assert.equal(session.idleArmed(), true, 'the ordinary idle countdown takes over');

  // Well past the startup budget: whatever fires here has to be the idle
  // timeout, not a watchdog that was never disarmed.
  clock.advance(31 * MINUTE);
  const idle = events.filter((e) => e.startsWith('idle'));
  assert.equal(idle.length, 1);
  assert.match(idle[0], /No players for 15 minutes/);
});

test('a slow start followed by a join is not cut short', () => {
  const { session, clock, events } = build({ startupMinutes: 30 });

  clock.advance(20 * MINUTE);
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));

  clock.advance(48 * 60 * MINUTE);
  assert.equal(
    events.filter((e) => e.startsWith('idle')).length,
    0,
    'somebody is playing; the watchdog must be long gone'
  );
});

test('idleMinutes = 0 disables the startup watchdog too', () => {
  // "Never power this box off by itself" has to hold however the boot goes.
  const { session, clock, events } = build({ idleMinutes: 0, startupMinutes: 30 });
  assert.equal(session.startupArmed(), false);

  clock.advance(24 * 60 * MINUTE);
  assert.equal(events.filter((e) => e.startsWith('idle')).length, 0);
});

test('stop() leaves no startup timer holding the event loop open', () => {
  const { session, clock } = build({ startupMinutes: 30 });
  assert.equal(clock.pendingCount(), 1);
  session.stop();
  assert.equal(session.startupArmed(), false);
  assert.equal(clock.pendingCount(), 0);
});

test('a non-numeric idle timeout does not become NaN', () => {
  // NaN <= 0 is false, so it slips past the "disabled" guard, and
  // setTimeout(fn, NaN) fires on the next tick -- the server would stop
  // seconds after coming up. main() coerces; this pins the arithmetic that
  // makes the coercion necessary.
  assert.equal(NaN <= 0, false);
  assert.equal(Number.isFinite(parseFloat('fifteen')), false);
});

// --------------------------------------------------------------------------
// Process supervision
// --------------------------------------------------------------------------

test('a server process that cannot be spawned still powers the instance off', () => {
  // Node emits 'error' and 'close' but never 'exit' when the binary is not
  // there, and every teardown hangs off 'exit'. Before this was handled the
  // manager sat holding the console FIFO open: no sentinel, no exit, a unit
  // stuck "active", ExecStopPost never reached, and an instance billing until
  // somebody noticed.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-spawn-'));
  const runDir = path.join(dir, 'run');
  fs.mkdirSync(runDir);
  fs.mkdirSync(path.join(dir, 'server'));

  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, '..', 'server', 'bin', 'servermanager.js')],
    {
      env: {
        ...process.env,
        RUN_DIR: runDir,
        SERVER_DIR: path.join(dir, 'server'),
        JAVA_BIN: path.join(dir, 'no-such-java'),
        NOTIFY_SCRIPT: path.join(dir, 'no-such-notify'),
        SHUTDOWN_ON_CRASH: 'true',
      },
      timeout: 30000,
      encoding: 'utf8',
    }
  );

  assert.notEqual(
    result.signal,
    'SIGTERM',
    'the manager must exit on its own rather than be killed by the timeout'
  );

  const sentinel = path.join(runDir, 'idle-shutdown');
  assert.equal(
    fs.existsSync(sentinel),
    true,
    'no sentinel means on-stop.sh leaves the instance up and billing'
  );
  assert.equal(fs.readFileSync(sentinel, 'utf8').trim(), 'crash');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('a server that starts and then exits non-zero powers the instance off', () => {
  // The crash branch, which is what shutdown_on_crash defaults to true for. A
  // JVM that dies an hour in leaves nobody watching, so the sentinel is the
  // only thing between a crash and an instance billing until somebody notices.
  // JAVA_BIN is node given java's arguments: it starts, rejects them, and exits
  // non-zero -- a real exit rather than a spawn failure, which is the branch
  // the spawn test above already covers.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-crash-'));
  const runDir = path.join(dir, 'run');
  fs.mkdirSync(runDir);
  fs.mkdirSync(path.join(dir, 'server'));

  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, '..', 'server', 'bin', 'servermanager.js')],
    {
      env: {
        ...process.env,
        RUN_DIR: runDir,
        SERVER_DIR: path.join(dir, 'server'),
        JAVA_BIN: process.execPath,
        NOTIFY_SCRIPT: path.join(dir, 'no-such-notify'),
        SHUTDOWN_ON_CRASH: 'true',
      },
      timeout: 30000,
      encoding: 'utf8',
    }
  );

  assert.notEqual(result.signal, 'SIGTERM', 'the manager must exit on its own');

  const sentinel = path.join(runDir, 'idle-shutdown');
  assert.equal(
    fs.existsSync(sentinel),
    true,
    'no sentinel means on-stop.sh leaves a crashed instance up and billing'
  );
  assert.equal(fs.readFileSync(sentinel, 'utf8').trim(), 'crash');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('the uptime cap says so in the journal when it is armed', () => {
  // A cost guard that only takes effect on the boot after the one that set it,
  // and that ends a session people may be in the middle of. Whether it is on
  // has to be readable from the journal rather than discovered an hour later.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-cap-'));
  const runDir = path.join(dir, 'run');
  fs.mkdirSync(runDir);
  fs.mkdirSync(path.join(dir, 'server'));

  const env = {
    ...process.env,
    RUN_DIR: runDir,
    SERVER_DIR: path.join(dir, 'server'),
    JAVA_BIN: process.execPath,
    NOTIFY_SCRIPT: path.join(dir, 'no-such-notify'),
  };
  const args = [path.join(__dirname, '..', 'server', 'bin', 'servermanager.js')];

  const on = spawnSync(process.execPath, args, {
    env: { ...env, MAX_UPTIME_HOURS: '1' },
    timeout: 30000,
    encoding: 'utf8',
  });
  assert.match(on.stdout, /uptime cap armed: stopping after 1 hour/);

  const off = spawnSync(process.execPath, args, {
    env: { ...env, MAX_UPTIME_HOURS: '0' },
    timeout: 30000,
    encoding: 'utf8',
  });
  assert.doesNotMatch(off.stdout, /uptime cap armed/, 'no cap means no claim of one');

  fs.rmSync(dir, { recursive: true, force: true });
});

test('shutdown_on_crash = false keeps the box up for debugging', () => {
  // The documented escape hatch: troubleshooting tells people to set this while
  // they are reading a crash, and it is worthless if the box powers off anyway.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-nocrash-'));
  const runDir = path.join(dir, 'run');
  fs.mkdirSync(runDir);
  fs.mkdirSync(path.join(dir, 'server'));

  spawnSync(process.execPath, [path.join(__dirname, '..', 'server', 'bin', 'servermanager.js')], {
    env: {
      ...process.env,
      RUN_DIR: runDir,
      SERVER_DIR: path.join(dir, 'server'),
      JAVA_BIN: process.execPath,
      NOTIFY_SCRIPT: path.join(dir, 'no-such-notify'),
      SHUTDOWN_ON_CRASH: 'false',
    },
    timeout: 30000,
    encoding: 'utf8',
  });

  assert.equal(
    fs.existsSync(path.join(runDir, 'idle-shutdown')),
    false,
    'a sentinel here would power off the box somebody is trying to debug'
  );

  fs.rmSync(dir, { recursive: true, force: true });
});

// --------------------------------------------------------------------------
// Long-session warnings
//
// The idle countdown only ever fires on an empty server, so a session with
// somebody still connected has nothing bounding it but max_uptime_hours, which
// is off by default and ends the session outright when it is on. This is the
// part that just says something.
// --------------------------------------------------------------------------

test('a long session is warned about, and warned about again', () => {
  const warnings = [];
  const { session, clock } = build({
    uptimeWarningHours: 6,
    onUptimeWarning: (hours, online) => warnings.push({ hours, online }),
  });
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));

  clock.advance(5 * HOUR);
  assert.deepEqual(warnings, [], 'nothing before the interval is up');

  clock.advance(1 * HOUR);
  assert.deepEqual(warnings, [{ hours: 6, online: 1 }]);

  clock.advance(6 * HOUR);
  assert.deepEqual(warnings.at(-1), { hours: 12, online: 1 }, 'and again at twice the interval');

  clock.advance(6 * HOUR);
  assert.equal(warnings.length, 3);
  assert.deepEqual(warnings.at(-1), { hours: 18, online: 1 });
});

test('a warning counts the players actually online', () => {
  const warnings = [];
  const { session, clock } = build({
    uptimeWarningHours: 3,
    onUptimeWarning: (hours, online) => warnings.push(online),
  });
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Bob joined the game'));
  clock.advance(3 * HOUR);
  session.handleLine(line('Bob left the game'));
  clock.advance(3 * HOUR);

  assert.deepEqual(warnings, [2, 1]);
});

test('a warning on an empty server reports nobody online', () => {
  // Reachable only when the idle shutdown is off or broken -- which is exactly
  // the case worth being told about, so it must not be suppressed.
  const warnings = [];
  const { session, clock } = build({
    idleMinutes: 0,
    uptimeWarningHours: 2,
    onUptimeWarning: (hours, online) => warnings.push({ hours, online }),
  });
  session.handleLine(READY_LINE);
  clock.advance(2 * HOUR);
  assert.deepEqual(warnings, [{ hours: 2, online: 0 }]);
});

test('long-session warnings are off unless asked for', () => {
  const { session } = build();
  assert.equal(session.uptimeWarningArmed(), false);
});

test('a non-numeric warning interval arms nothing', () => {
  const { session } = build({ uptimeWarningHours: parseFloat('six') });
  assert.equal(session.uptimeWarningArmed(), false, 'NaN must not arm a timer');
});

test('stopping cancels the next long-session warning', () => {
  const warnings = [];
  const { session, clock } = build({
    uptimeWarningHours: 6,
    onUptimeWarning: () => warnings.push(1),
  });
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  clock.advance(6 * HOUR);
  assert.equal(warnings.length, 1);

  session.stop();
  assert.equal(session.uptimeWarningArmed(), false);
  assert.equal(clock.pendingCount(), 0, 'nothing left holding the event loop open');

  clock.advance(48 * HOUR);
  assert.equal(warnings.length, 1, 'no warnings after the session has ended');
});

// --------------------------------------------------------------------------
// Join and leave notifications
//
// The same events the idle countdown runs on, handed out for posting. They
// have to fire on a real change and only on a real change: the state machine
// already tolerates a repeated join line and a leave for somebody who never
// joined, and neither should reach a channel.
// --------------------------------------------------------------------------

test('joins and leaves are reported with the name and the new count', () => {
  const seen = [];
  const { session } = build({
    onJoin: (name, online) => seen.push(`join ${name} ${online}`),
    onLeave: (name, online) => seen.push(`leave ${name} ${online}`),
  });
  session.handleLine(READY_LINE);

  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Bob joined the game'));
  session.handleLine(line('Alice left the game'));
  session.handleLine(line('Bob left the game'));

  assert.deepEqual(seen, [
    'join Alice 1',
    'join Bob 2',
    'leave Alice 1',
    'leave Bob 0',
  ]);
});

test('a repeated join line is reported once', () => {
  const seen = [];
  const { session } = build({ onJoin: (name) => seen.push(name) });
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Alice joined the game'));
  assert.deepEqual(seen, ['Alice'], 'the Set absorbs the duplicate; so must the notification');
});

test('a leave for somebody who never joined is not reported', () => {
  const seen = [];
  const { session } = build({ onLeave: (name) => seen.push(name) });
  session.handleLine(READY_LINE);
  session.handleLine(line('Ghost left the game'));
  assert.deepEqual(seen, []);
});

test('a rejoin after a leave is reported again', () => {
  const seen = [];
  const { session } = build({
    onJoin: (name) => seen.push(`in:${name}`),
    onLeave: (name) => seen.push(`out:${name}`),
  });
  session.handleLine(READY_LINE);
  session.handleLine(line('Alice joined the game'));
  session.handleLine(line('Alice left the game'));
  session.handleLine(line('Alice joined the game'));
  assert.deepEqual(seen, ['in:Alice', 'out:Alice', 'in:Alice']);
});

test('a chat line that looks like a join is not reported', () => {
  // Same anchoring that protects the shutdown decision protects this.
  const seen = [];
  const { session } = build({ onJoin: (name) => seen.push(name) });
  session.handleLine(READY_LINE);
  session.handleLine(line('<Mallory> Notch joined the game'));
  assert.deepEqual(seen, []);
  assert.equal(session.playerCount(), 0);
});

// --------------------------------------------------------------------------
// The send queue
//
// notify() is synchronous, so one request per join would block this process
// out of reading the server's stdout -- and a stdout pipe that fills stops the
// server itself.
// --------------------------------------------------------------------------

/** A send() that hands back its completion callback so a test can hold it open. */
function manualSender() {
  const sent = [];
  const waiting = [];
  return {
    sent,
    send: (message, done) => {
      sent.push(message);
      waiting.push(done);
    },
    finishOne: (err) => waiting.shift()(err || null),
    outstanding: () => waiting.length,
  };
}

test('only one request is in flight at a time', () => {
  const sender = manualSender();
  const queue = createEventQueue({ send: sender.send });

  queue.push('a');
  queue.push('b');
  queue.push('c');

  assert.deepEqual(sender.sent, ['a'], 'b and c must wait');
  assert.equal(sender.outstanding(), 1);
  assert.equal(queue.isSending(), true);
});

test('everything queued during a send is coalesced into the next one', () => {
  const sender = manualSender();
  const queue = createEventQueue({ send: sender.send });

  queue.push('Alice joined');
  queue.push('Bob joined');
  queue.push('Alice left');
  sender.finishOne();

  assert.deepEqual(sender.sent, ['Alice joined', 'Bob joined\nAlice left']);
  sender.finishOne();
  assert.equal(queue.isSending(), false, 'nothing left to send');
  assert.equal(queue.pendingCount(), 0);
});

test('a failed send does not stall the queue', () => {
  const logged = [];
  const sender = manualSender();
  const queue = createEventQueue({ send: sender.send, log: (m) => logged.push(m) });

  queue.push('first');
  queue.push('second');
  sender.finishOne(new Error('webhook unreachable'));

  assert.equal(logged.length, 1);
  assert.match(logged[0], /webhook unreachable/);
  assert.deepEqual(sender.sent, ['first', 'second'], 'the next batch still goes out');
});

test('the queue is bounded, and drops the oldest', () => {
  const sender = manualSender();
  const queue = createEventQueue({ send: sender.send, max: 3 });

  queue.push('1');                       // sent immediately
  for (const n of ['2', '3', '4', '5', '6']) queue.push(n);

  assert.equal(queue.pendingCount(), 3, 'an unreachable webhook must not grow this forever');
  sender.finishOne();
  assert.deepEqual(sender.sent, ['1', '4\n5\n6'], 'the newest events are the ones kept');
});
