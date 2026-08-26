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

const { createSession, normalise, PATTERNS } = require(
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
