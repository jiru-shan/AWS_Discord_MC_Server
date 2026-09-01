#!/usr/bin/env node
/**
 * Supervises the Minecraft server process and shuts the box down when nobody is
 * playing -- the piece that makes an on-demand server actually cheap.
 *
 * Idle is decided by watching the server log for join/leave lines and counting
 * players, rather than by querying the server, so there is nothing to configure
 * and no extra port to open. When the player count has been zero for
 * IDLE_TIMEOUT_MINUTES the server is asked to stop cleanly.
 *
 * On an idle-triggered stop this writes /run/minecraft/idle-shutdown before
 * exiting. on-stop.sh powers the instance off only when it finds that file, so
 * `systemctl stop minecraft` during maintenance leaves the box up.
 *
 * The idle state machine is exported as createSession() so it can be tested
 * without spawning a JVM; running this file directly starts the server.
 *
 * Node standard library only -- there is no npm install on the instance.
 */

'use strict';

const { spawn, execFileSync, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const net = require('net');

// Overridable so the behavioural tests can run outside /run.
const RUN_DIR = process.env.RUN_DIR || '/run/minecraft';
const SHUTDOWN_SENTINEL = path.join(RUN_DIR, 'idle-shutdown');
const CONSOLE_FIFO = path.join(RUN_DIR, 'console');

// --------------------------------------------------------------------------
// Log line patterns
//
// Anchored to the "]: " that ends the log prefix and to end-of-line, so a
// player typing "someone joined the game" in chat cannot fake a join: chat
// lines read "]: <Name> message" and fail the anchor.
//
// Minecraft usernames are at most 16 characters of [A-Za-z0-9_], so \w{1,16}
// is exact at the long end: a 17-character string is never read as a player.
// --------------------------------------------------------------------------

const PATTERNS = {
  JOINED: /\]: (\w{1,16}) joined the game$/,
  LEFT: /\]: (\w{1,16}) left the game$/,
  READY: /\]: Done \([\d.]+s\)! For help, type "help"$/,
  // Vanilla's own empty-server auto-pause, enabled by pause-when-empty-seconds.
  // Treated as an immediate idle signal when it fires before our own timer.
  AUTO_PAUSED: /\]: Server empty for \d+ seconds, pausing$/,
};

/**
 * Strip anything that would break the end-of-line anchors.
 *
 * A stray carriage return or an ANSI colour sequence at the end of a line makes
 * every pattern above silently stop matching, which would mean the server never
 * notices it is empty and the instance bills forever. Vanilla on Linux emits
 * neither, but some wrappers and modded servers colourise their output.
 */
function normalise(line) {
  return line.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\s+$/, '');
}

/**
 * The idle/player-count state machine.
 *
 * Pure logic: it is handed lines and calls back. Timers are injectable so the
 * tests do not have to wait out a fifteen minute countdown.
 */
function createSession(options) {
  const {
    idleMinutes = 15,
    // A server that never finishes starting never prints the ready line, and
    // the ready line is the only thing that arms the idle timer below. Left to
    // itself such a box stays up with nobody on it and no countdown running:
    // a mod hanging in init, a world that will not load, a JVM thrashing
    // itself to death on a small instance. Generous, because a first boot
    // generates the spawn area and a large modpack takes a while to load --
    // anything past this is broken rather than slow.
    startupMinutes = 30,
    // Repeating reminder that a session is still running. 0 disables it.
    // max_uptime_hours ends a session; this only mentions it, which is the
    // right tool while people are still playing.
    uptimeWarningHours = 0,
    onReady = () => {},
    onIdle = () => {},
    onUptimeWarning = () => {},
    onJoin = () => {},
    onLeave = () => {},
    log = () => {},
    timers = { setTimeout, clearTimeout },
  } = options || {};

  const players = new Set();
  let ready = false;
  let stopped = false;
  let idleTimer = null;
  let idleFired = false;
  let startupTimer = null;
  let uptimeWarningTimer = null;

  function clearUptimeWarningTimer() {
    if (uptimeWarningTimer !== null) {
      timers.clearTimeout(uptimeWarningTimer);
      uptimeWarningTimer = null;
    }
  }

  // Re-armed rather than an interval, so the injected timers need only
  // setTimeout and so a stop between two warnings cancels the next one.
  // `> 0` rather than `<= 0`: a non-numeric value is NaN, and NaN fails every
  // comparison, so the negated form is the one that catches it.
  function armUptimeWarning(hoursSoFar) {
    if (stopped || !(uptimeWarningHours > 0)) return;
    uptimeWarningTimer = timers.setTimeout(() => {
      uptimeWarningTimer = null;
      const elapsed = hoursSoFar + uptimeWarningHours;
      onUptimeWarning(elapsed, players.size);
      armUptimeWarning(elapsed);
    }, uptimeWarningHours * 3600 * 1000);
  }

  function clearStartupTimer() {
    if (startupTimer !== null) {
      timers.clearTimeout(startupTimer);
      startupTimer = null;
    }
  }

  function clearIdleTimer() {
    if (idleTimer !== null) {
      timers.clearTimeout(idleTimer);
      idleTimer = null;
    }
  }

  function armIdleTimer(reason) {
    clearIdleTimer();
    // idleMinutes <= 0 disables the automatic shutdown, for anyone who wants
    // the Discord controls without the power-off.
    if (stopped || idleFired || idleMinutes <= 0) return;
    log(`no players (${reason}); shutting down in ${idleMinutes} minutes unless someone joins`);
    idleTimer = timers.setTimeout(() => {
      idleTimer = null;
      fireIdle(`No players for ${idleMinutes} minutes.`);
    }, idleMinutes * 60 * 1000);
  }

  function fireIdle(message) {
    if (stopped || idleFired) return;
    idleFired = true;
    clearIdleTimer();
    clearStartupTimer();
    onIdle(message);
  }

  // Armed at creation rather than on ready, because catching a server that
  // never reaches ready is the entire point. Disabled alongside the idle
  // shutdown: idleMinutes = 0 means "never power this box off by itself", and
  // that has to stay true however the boot goes.
  armUptimeWarning(0);

  if (idleMinutes > 0 && startupMinutes > 0) {
    startupTimer = timers.setTimeout(() => {
      startupTimer = null;
      fireIdle(`Server did not finish starting within ${startupMinutes} minutes.`);
    }, startupMinutes * 60 * 1000);
  }

  return {
    /** Feed one line of server output. Returns the event name, or null. */
    handleLine(rawLine) {
      const line = normalise(rawLine);

      if (!ready && PATTERNS.READY.test(line)) {
        ready = true;
        clearStartupTimer();
        onReady();
        // Nobody can have joined yet, but check rather than assume: this is the
        // path that shuts down a server nobody ever connected to.
        if (players.size === 0) armIdleTimer('server just started');
        return 'ready';
      }

      let match = line.match(PATTERNS.JOINED);
      if (match) {
        const name = match[1];
        // Fire the callback only on a real change. The server can repeat a
        // join line, and the Set quietly absorbs it -- so without this a
        // duplicate would announce somebody who was already here.
        const arrived = !players.has(name);
        players.add(name);
        log(`${name} joined (${players.size} online)`);
        clearIdleTimer();
        if (arrived) onJoin(name, players.size);
        return 'join';
      }

      match = line.match(PATTERNS.LEFT);
      if (match) {
        const name = match[1];
        // delete() reports whether the player was actually counted, which is
        // how a leave for somebody who never joined stays silent.
        const departed = players.delete(name);
        log(`${name} left (${players.size} online)`);
        if (players.size === 0) armIdleTimer('last player left');
        if (departed) onLeave(name, players.size);
        return 'leave';
      }

      if (PATTERNS.AUTO_PAUSED.test(line)) {
        // The server itself concluded it is empty, which is a stronger signal
        // than our line counting -- act on it immediately.
        fireIdle('Server reported itself empty.');
        return 'autopause';
      }

      return null;
    },

    /** Stop watching. Called once a shutdown is already under way. */
    stop() {
      stopped = true;
      clearIdleTimer();
      clearStartupTimer();
      clearUptimeWarningTimer();
    },

    isReady: () => ready,
    playerCount: () => players.size,
    playerNames: () => Array.from(players),
    idleArmed: () => idleTimer !== null,
    startupArmed: () => startupTimer !== null,
    uptimeWarningArmed: () => uptimeWarningTimer !== null,
  };
}

/**
 * Serialised, coalescing sender for messages that arrive faster than they can
 * be delivered.
 *
 * notify() is synchronous, which is right for the handful of lifecycle
 * messages and wrong for one per join: while curl runs, this process is not
 * reading the server's stdout, and a stdout pipe that fills stops the server
 * itself. So player events go through here instead -- one request at a time,
 * with everything that arrived during the last one folded into the next, which
 * also keeps a reconnect storm inside Discord's rate limit.
 *
 * `send` is injected, so the queue is testable without spawning anything.
 */
function createEventQueue({ send, max = 20, log = () => {} }) {
  const pending = [];
  let inFlight = false;

  function flush() {
    if (inFlight || pending.length === 0) return;
    inFlight = true;
    const message = pending.splice(0).join('\n');
    send(message, (err) => {
      inFlight = false;
      if (err) log(`notification failed: ${err.message}`);
      // Anything that queued up while that was away goes now, as one message.
      flush();
    });
  }

  return {
    push(message) {
      pending.push(message);
      // Bounded: an unreachable webhook must not let this grow without limit.
      // Dropping the oldest is the right end to lose -- the newest events are
      // the ones that describe who is actually on the server now.
      if (pending.length > max) pending.splice(0, pending.length - max);
      flush();
    },
    pendingCount: () => pending.length,
    isSending: () => inFlight,
  };
}

// --------------------------------------------------------------------------
// Process supervision
// --------------------------------------------------------------------------

function main() {
  // A value that does not parse must not become NaN. NaN fails every "<= 0"
  // guard -- NaN <= 0 is false -- and setTimeout(fn, NaN) fires on the next
  // tick, so a typo in idle_timeout_minutes would stop the server seconds
  // after it came up rather than falling back to the documented default.
  const number = (value, fallback) => {
    const parsed = parseFloat(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  };

  const config = {
    serverDir: process.env.SERVER_DIR || '/srv/minecraft/server',
    serverJar: process.env.SERVER_JAR || 'server.jar',
    javaBin: process.env.JAVA_BIN || 'java',
    heapMb: Math.round(number(process.env.JAVA_HEAP_MB, 2048)),
    idleMinutes: number(process.env.IDLE_TIMEOUT_MINUTES, 15),
    stopTimeoutSeconds: Math.round(number(process.env.STOP_TIMEOUT_SECONDS, 120)),
    maxUptimeHours: number(process.env.MAX_UPTIME_HOURS, 0),
    startupMinutes: number(process.env.STARTUP_TIMEOUT_MINUTES, 30),
    // Terraform writes 0 here when uptime_warning_enabled is false.
    uptimeWarningHours: number(process.env.UPTIME_WARNING_HOURS, 0),
    // Terraform writes false here when there is no webhook to post to.
    notifyPlayerEvents: (process.env.NOTIFY_PLAYER_EVENTS || 'false') === 'true',
    shutdownOnCrash: (process.env.SHUTDOWN_ON_CRASH || 'true') === 'true',
    notifyScript: process.env.NOTIFY_SCRIPT || '/opt/minecraft/bin/notify.sh',
    // The unit runs as root so that ExecStopPost can power the box off. The
    // Java process is the one exposed to the internet, so it runs unprivileged.
    runAsUser: process.env.MC_USER || 'minecraft',
  };

  let stopping = false;
  let idleShutdown = false;
  let killTimer = null;
  let uptimeTimer = null;
  const recentLog = [];

  const log = (message) => console.log(`[servermanager] ${message}`);

  /** Fire-and-forget Discord notification. Never allowed to break the server. */
  const notify = (message) => {
    try {
      execFileSync(config.notifyScript, [message], { timeout: 15000, stdio: 'ignore' });
    } catch (err) {
      log(`notification failed: ${err.message}`);
    }
  };

  // One request at a time, so a slow webhook can never stop this process
  // reading the server's stdout. See createEventQueue above.
  const playerEvents = createEventQueue({
    log,
    send: (message, done) =>
      execFile(config.notifyScript, [message], { timeout: 15000 }, done),
  });

  const notifyPlayerEvent = (message) => {
    if (config.notifyPlayerEvents) playerEvents.push(message);
  };

  const connectAddress = () => {
    try {
      return fs.readFileSync(path.join(RUN_DIR, 'address'), 'utf8').trim();
    } catch {
      return null;
    }
  };

  const remember = (line) => {
    recentLog.push(line);
    if (recentLog.length > 40) recentLog.shift();
  };

  // Aikar's G1 flags: they matter more than raw heap size for tick stability on
  // a small instance. Xms == Xmx so the heap is never resized mid-session.
  const javaArgs = [
    `-Xms${config.heapMb}M`,
    `-Xmx${config.heapMb}M`,
    '-XX:+UseG1GC',
    '-XX:+ParallelRefProcEnabled',
    '-XX:MaxGCPauseMillis=200',
    '-XX:+UnlockExperimentalVMOptions',
    '-XX:+DisableExplicitGC',
    '-XX:+AlwaysPreTouch',
    '-XX:G1NewSizePercent=30',
    '-XX:G1MaxNewSizePercent=40',
    '-XX:G1HeapRegionSize=8M',
    '-XX:G1ReservePercent=20',
    '-XX:G1HeapWastePercent=5',
    '-XX:G1MixedGCCountTarget=4',
    '-XX:InitiatingHeapOccupancyPercent=15',
    '-XX:G1MixedGCLiveThresholdPercent=90',
    '-XX:G1RSetUpdatingPauseTimePercent=5',
    '-XX:SurvivorRatio=32',
    '-XX:+PerfDisableSharedMem',
    '-XX:MaxTenuringThreshold=1',
    '-jar',
    config.serverJar,
    'nogui',
  ];

  /**
   * spawn() options that drop the Java process to an unprivileged account.
   * Skipped when we are not root (running the manager by hand) or the account
   * does not exist, in which case Java simply inherits our identity.
   */
  function privilegeDrop() {
    if (typeof process.getuid !== 'function' || process.getuid() !== 0) return {};
    if (!config.runAsUser || config.runAsUser === 'root') return {};
    try {
      const uid = parseInt(execFileSync('id', ['-u', config.runAsUser], { encoding: 'utf8' }), 10);
      const gid = parseInt(execFileSync('id', ['-g', config.runAsUser], { encoding: 'utf8' }), 10);
      log(`running the server as ${config.runAsUser} (uid ${uid}, gid ${gid})`);
      return { uid, gid };
    } catch (err) {
      log(`could not resolve user ${config.runAsUser}; running as root: ${err.message}`);
      return {};
    }
  }

  log(`starting ${config.javaBin} with ${config.heapMb}M heap in ${config.serverDir}`);

  const child = spawn(config.javaBin, javaArgs, {
    cwd: config.serverDir,
    stdio: ['pipe', 'pipe', 'pipe'],
    ...privilegeDrop(),
  });

  child.on('error', (err) => {
    log(`failed to start the server process: ${err.message}`);
    notify(`Minecraft server failed to start: ${err.message}`);
    process.exitCode = 1;
    // Node emits 'error' and 'close' -- but never 'exit' -- when the process
    // could not be spawned at all: a missing or unreadable JAVA_BIN, a failed
    // package install. Every teardown below hangs off 'exit', so without this
    // none of it runs: no sentinel, and no exit either, because the console
    // FIFO holds the event loop open. The unit would sit there "active",
    // systemd would never reach ExecStopPost, and the instance would bill
    // until somebody noticed. process.exitCode cannot save us on its own --
    // nothing is going to drain the loop and honour it.
    serverGone(null, null, { alreadyReported: true });
  });

  // The server can exit between the liveness check in beginStop and the write
  // that follows, and the console FIFO can deliver a command at the same
  // moment. A dead pipe there is an expected race, not a reason to take the
  // manager down with an unhandled error event.
  child.stdin.on('error', (err) => {
    log(`could not write to the server console: ${err.message}`);
  });

  /**
   * Ask the server to stop. `cause` decides whether the instance powers off
   * afterwards: only "idle" and "requested" stops write the sentinel that
   * on-stop.sh looks for.
   */
  function beginStop(cause, message) {
    if (stopping) return;
    stopping = true;
    session.stop();
    if (uptimeTimer) clearTimeout(uptimeTimer);

    idleShutdown = cause === 'idle' || cause === 'requested';
    log(`stopping the server (${cause}): ${message}`);

    if (idleShutdown) {
      try {
        fs.writeFileSync(SHUTDOWN_SENTINEL, `${cause}\n`);
      } catch (err) {
        log(`could not write the shutdown sentinel: ${err.message}`);
      }
    }

    if (child.exitCode === null && child.signalCode === null) {
      // The console strips a leading slash, but "stop" is the canonical form.
      child.stdin.write('stop\n');
      killTimer = setTimeout(() => {
        log(`server did not exit within ${config.stopTimeoutSeconds}s; killing it`);
        child.kill('SIGKILL');
      }, config.stopTimeoutSeconds * 1000);
    }
  }

  const session = createSession({
    idleMinutes: config.idleMinutes,
    startupMinutes: config.startupMinutes,
    log,
    onReady: () => {
      const address = connectAddress();
      log('server is accepting connections');
      notify(address ? `Server is up. Connect at \`${address}\`` : 'Server is up.');
    },
    onIdle: (message) => beginStop('idle', message),
    // Backticks rather than bold: a name may contain underscores, which Discord
    // would otherwise read as italics.
    onJoin: (name, online) => notifyPlayerEvent(`\`${name}\` joined (${online} online)`),
    onLeave: (name, online) => notifyPlayerEvent(`\`${name}\` left (${online} online)`),
    onUptimeWarning: (hours, online) => {
      const unit = hours === 1 ? 'hour' : 'hours';
      log(`uptime warning: ${hours} ${unit} with ${online} online`);
      if (online > 0) {
        const who = online === 1 ? 'somebody is' : `${online} people are`;
        notify(
          `The server has been up for ${hours} ${unit} and ${who} still online, ` +
            'so the idle shutdown has not run. It bills for every one of those ' +
            'hours -- `/stop` when you are done.'
        );
      } else {
        // Nobody on and still running means the countdown that should have
        // ended this session did not. That is the expensive failure, and it is
        // worth saying plainly rather than repeating the generic reminder.
        notify(
          `The server has been up for ${hours} ${unit} with nobody online. It ` +
            'should have shut itself down by now -- check `journalctl -u minecraft` ' +
            'before it bills for much longer.'
        );
      }
    },
  });

  // readline rather than testing raw chunks: stdout arrives in arbitrary
  // pieces, and a chunk boundary landing mid-line would silently drop an event.
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    process.stdout.write(`${line}\n`);
    remember(line);
    session.handleLine(line);
  });

  readline.createInterface({ input: child.stderr }).on('line', (line) => {
    process.stderr.write(`${line}\n`);
    remember(line);
  });

  // --------------------------------------------------------------------------
  // Admin console
  //
  // Anything written to /run/minecraft/console is forwarded to the server's
  // stdin, which is how `mc console <command>` works. The FIFO is opened
  // read-write so it never reports EOF when a writer disconnects.
  // --------------------------------------------------------------------------

  let consoleStream = null;
  try {
    fs.mkdirSync(RUN_DIR, { recursive: true });
    if (!fs.existsSync(CONSOLE_FIFO)) {
      execFileSync('mkfifo', ['-m', '600', CONSOLE_FIFO]);
    }

    // O_NONBLOCK and a net.Socket, rather than fs.createReadStream, because of
    // where the two do their reading. An fs stream reads on a libuv threadpool
    // worker, and a blocking read(2) on a FIFO that never receives data never
    // returns -- so that worker is stuck for the life of the process, and
    // Node's exit path, which waits for the pool to drain, hangs with it.
    //
    // The symptom is the worst one this project has: the server dies, the exit
    // handler runs to completion, and then process.exit() never returns. The
    // unit stays "active", systemd never runs ExecStopPost, on-stop.sh never
    // reads the sentinel, and the instance bills until somebody notices.
    //
    // A socket is polled through epoll and holds no worker. O_RDWR keeps the
    // FIFO from reporting EOF every time a writer disconnects.
    const fd = fs.openSync(CONSOLE_FIFO, fs.constants.O_RDWR | fs.constants.O_NONBLOCK);
    consoleStream = new net.Socket({ fd, readable: true, writable: false });
    consoleStream.on('error', (err) => log(`admin console error: ${err.message}`));

    readline.createInterface({ input: consoleStream }).on('line', (line) => {
      const command = line.trim();
      if (!command || stopping) return;
      log(`console: ${command}`);
      child.stdin.write(`${command}\n`);
    });
  } catch (err) {
    log(`admin console unavailable: ${err.message}`);
  }

  // systemctl stop, or a Ctrl-C in the foreground: stop cleanly but leave the
  // instance running, so maintenance is not interrupted by a power-off.
  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => beginStop('signal', `received ${signal}`));
  }

  if (config.maxUptimeHours > 0) {
    // Say so. This is a cost guard that only takes effect on a boot after the
    // one that configured it, and it ends a session people may be playing, so
    // "is it actually on?" has to be answerable from the journal rather than by
    // waiting to find out. The idle countdown announces itself for the same
    // reason.
    const capUnit = config.maxUptimeHours === 1 ? 'hour' : 'hours';
    log(
      `uptime cap armed: stopping after ${config.maxUptimeHours} ${capUnit}, ` +
        'even if people are still online'
    );
    uptimeTimer = setTimeout(() => {
      beginStop('requested', `Reached the ${config.maxUptimeHours} hour uptime cap.`);
    }, config.maxUptimeHours * 3600 * 1000);
  }

  // Everything that has to happen once the server process is gone, however it
  // went. Latched, and reachable from both 'exit' and 'error': those are two
  // disjoint paths -- a process that ran and stopped emits the first, a
  // process that never started emits the second -- and both have to end with
  // this one exiting.
  let finished = false;

  function serverGone(code, signal, { alreadyReported = false } = {}) {
    if (finished) return;
    finished = true;

    if (killTimer) clearTimeout(killTimer);
    session.stop();
    if (uptimeTimer) clearTimeout(uptimeTimer);

    const crashed = !stopping;
    log(`server process exited with code=${code} signal=${signal}`);

    if (crashed) {
      // Nothing asked for this exit. Report it, and by default still power the
      // box off so a crash loop cannot quietly run up a bill.
      if (!alreadyReported) {
        const tail = recentLog.slice(-15).join('\n');
        notify(
          `Minecraft server exited unexpectedly (code ${code}${signal ? `, ${signal}` : ''}).` +
            (tail ? `\n\`\`\`\n${tail.slice(-1500)}\n\`\`\`` : '')
        );
      }
      if (config.shutdownOnCrash) {
        try {
          fs.writeFileSync(SHUTDOWN_SENTINEL, 'crash\n');
        } catch (err) {
          log(`could not write the shutdown sentinel: ${err.message}`);
        }
      }
    } else if (idleShutdown) {
      notify('Server stopped due to inactivity.');
    } else {
      notify('Server stopped.');
    }

    // Nothing may keep this process alive once the server it supervises is
    // gone: an exit that hangs is billed by the hour.
    if (consoleStream) consoleStream.destroy();
    process.exit(crashed ? code || 1 : 0);
  }

  child.on('exit', (code, signal) => serverGone(code, signal));
}

module.exports = { createSession, createEventQueue, normalise, PATTERNS };

if (require.main === module) {
  main();
}
