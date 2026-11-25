'use strict';

// A stand-in for the kOS telnet server, for testing scripts/kos-drive.js
// without KSP. It mirrors the parts of kOS's behaviour the runner relies on
// (see kOS src/kOS/UserIO/Telnet*.cs and src/kOS/Screen/TermWindow.cs):
// option negotiation and the terminal-type keepalive, the CPU menu format,
// server-side echo, input typed while a program runs being queued until it
// ends, Ctrl-C (IAC IP) aborting the program and wiping type-ahead, Ctrl-D
// detaching, and a load detaching the telnet back to the menu.
// It only understands the commands kos-drive.js sends.

const fs = require('fs');
const net = require('net');
const path = require('path');

const IAC = 255; const DONT = 254; const DO = 253; const WONT = 252; const WILL = 251;
const SB = 250; const SE = 240; const IP = 244;
const ECHO = 1; const SGA = 3; const TERMTYPE = 24; const NAWS = 31;

const CLEAR = '\x1b?47h\x1b[2J\x1b[H'; // what kOS's xterm mapper sends for CLEARSCREEN

function menuRow(fields) {
  const pad = (value, width) => String(value).padStart(width);
  return `${pad(fields[0], 4)} ${pad(fields[1], 4)} ${pad(fields[2], 4)} ${fields[3]} ${fields[4]} ${fields[5]}`;
}

class FakeKos {
  constructor({ scriptDir, cpus, saves = [], values = {}, programs = {} }) {
    this.scriptDir = scriptDir;
    this.cpus = cpus.map((cpu) => ({ part: 'CX-4181', telnets: 0, busy: false, ...cpu }));
    this.saves = new Set(saves);
    this.values = { ...values };
    this.programs = programs; // script path -> { outcome: 'pass' | 'fail' | 'crash' | 'hang', delayMs }
    this.typed = []; // every complete line received while attached to a CPU, for assertions
    this.negotiation = { naws: null, termtype: null };
    this.interrupts = 0;
    this.loads = [];
    this.savedTo = [];
    this.loadDelayMs = 100;
    this.sessions = new Set();
  }

  listen() {
    this.server = net.createServer((socket) => this.accept(socket));
    return new Promise((resolve) => this.server.listen(0, '127.0.0.1', () => resolve(this.server.address().port)));
  }

  close() {
    for (const session of this.sessions) session.socket.destroy();
    return new Promise((resolve) => this.server.close(() => resolve()));
  }

  accept(socket) {
    const session = { socket, cpu: null, line: '', mode: 'data', sub: [], command: 0, timers: [] };
    this.sessions.add(session);
    socket.on('data', (chunk) => this.receive(session, chunk));
    socket.on('close', () => {
      for (const timer of session.timers) clearTimeout(timer);
      if (session.cpu) session.cpu.telnets -= 1;
      this.sessions.delete(session);
    });
    socket.on('error', () => {});
    socket.write(Buffer.from([IAC, WILL, ECHO, IAC, DONT, ECHO, IAC, WILL, SGA, IAC, DO, NAWS, IAC, DO, TERMTYPE]));
    socket.write('Connected to the kOS Terminal Server.\r\n');
    this.showMenu(session, true);
  }

  write(session, text) {
    if (!session.socket.destroyed) session.socket.write(text);
  }

  later(session, ms, fn) {
    session.timers.push(setTimeout(fn, ms));
  }

  showMenu(session, clear) {
    const lines = [];
    if (clear) lines.push(CLEAR);
    lines.push(`Terminal: type = ${this.negotiation.termtype || 'INITIAL_UNSET'}, size = 120x40`);
    lines.push('_'.repeat(60));
    const rows = [
      menuRow(['Menu', 'GUI ', ' Other ', '', '', '']),
      menuRow(['Pick', 'Open', 'Telnets', '', 'Vessel Name', '(CPU tagname)']),
      menuRow(['----', '----', '-------', '', '--------------------------------', '']),
    ];
    const visible = this.cpus.filter((cpu) => !cpu.unloaded);
    visible.forEach((cpu, index) => {
      rows.push(menuRow([`[${index + 1}]`, 'no', cpu.telnets, '   ', cpu.vessel, `(${cpu.part}(${cpu.tag}))`]));
    });
    for (const row of rows) lines.push(`          ${row}`);
    if (visible.length > 0) {
      lines.push('-'.repeat(60));
      lines.push('Choose a CPU to attach to by typing a selection number and pressing return/enter. Or enter [Q] to quit terminal server.');
      lines.push('');
      lines.push('(After attaching, you can (D)etach and return to this menu by pressing Control-D as the first character on a new command line.)');
      lines.push('-'.repeat(60));
      this.write(session, `${lines.join('\r\n')}\r\n> `);
    } else {
      lines.push('                                <NONE>');
      this.write(session, `${lines.join('\r\n')}\r\n`);
    }
  }

  receive(session, chunk) {
    for (const byte of chunk) {
      switch (session.mode) {
        case 'data':
          if (byte === IAC) session.mode = 'iac';
          else this.inputChar(session, String.fromCharCode(byte));
          break;
        case 'iac':
          if (byte === SB) { session.sub = []; session.mode = 'sub'; }
          else if (byte === IP) { this.interrupt(session); session.mode = 'data'; }
          else if ([DO, DONT, WILL, WONT].includes(byte)) { session.command = byte; session.mode = 'option'; }
          else session.mode = 'data';
          break;
        case 'option':
          if (session.command === WILL && byte === TERMTYPE) {
            session.socket.write(Buffer.from([IAC, SB, TERMTYPE, 1, IAC, SE]));
          }
          session.mode = 'data';
          break;
        case 'sub':
          if (byte === IAC) session.mode = 'sub-iac'; else session.sub.push(byte);
          break;
        case 'sub-iac':
          if (byte === SE) {
            const [option, ...rest] = session.sub;
            if (option === NAWS) this.negotiation.naws = { columns: (rest[0] << 8) + rest[1], rows: (rest[2] << 8) + rest[3] };
            if (option === TERMTYPE && rest[0] === 0) this.negotiation.termtype = Buffer.from(rest.slice(1)).toString();
            session.mode = 'data';
          } else { session.sub.push(byte); session.mode = 'sub'; }
          break;
        default:
          session.mode = 'data';
      }
    }
  }

  // Server-side keepalive: ask for the terminal type again.
  keepalive(session) {
    this.negotiation.termtype = null;
    session.socket.write(Buffer.from([IAC, SB, TERMTYPE, 1, IAC, SE]));
  }

  inputChar(session, ch) {
    if (ch === '\x04') {
      if (session.cpu && session.line === '') {
        session.cpu.telnets -= 1;
        session.cpu = null;
        this.showMenu(session, true);
      }
      return;
    }
    if (ch === '\r' || ch === '\n') {
      const line = session.line;
      session.line = '';
      this.write(session, '\r\n');
      this.lineEntered(session, line);
      return;
    }
    session.line += ch;
    this.write(session, ch); // the server echoes typed characters
  }

  lineEntered(session, line) {
    if (!session.cpu) {
      const visible = this.cpus.filter((cpu) => !cpu.unloaded);
      const pick = Number(line);
      if (Number.isInteger(pick) && pick >= 1 && pick <= visible.length) {
        session.cpu = visible[pick - 1];
        session.cpu.telnets += 1;
        this.write(session, `${CLEAR}kOS Operating System\r\n`);
      } else if (line !== '') {
        this.write(session, 'Garbled selection. Try again.\r\n');
        this.showMenu(session, true);
      }
      return;
    }
    this.typed.push(line);
    const cpu = session.cpu;
    if (cpu.busy) {
      cpu.queue = cpu.queue || [];
      cpu.queue.push(line); // queued until the running program ends
      return;
    }
    this.execute(session, line);
  }

  print(session, text) {
    // Write each printed line through a cursor move, as kOS screen diffs do.
    this.write(session, `\x1b[40;1H${text}\r\n\x1b[S`);
  }

  evaluate(expression) {
    let match = /^"(\w+)=" \+ (.*)$/.exec(expression);
    if (match) return `${match[1]}=${this.evaluate(match[2])}`;
    const inner = /^\((.*)\)$/.exec(expression);
    const key = expression in this.values || !inner ? expression : inner[1];
    return key in this.values ? String(this.values[key]) : `<unknown ${key}>`;
  }

  execute(session, line) {
    let match = /^PRINT "KD-" \+ "(\w+)-(\w+) "(?: \+ \((.*)\))?\.$/.exec(line);
    if (match) {
      const value = match[3] === undefined ? '' : this.evaluate(match[3]);
      this.print(session, `KD-${match[1]}-${match[2]} ${value}`.trimEnd());
      return;
    }
    match = /^FOR kd_save IN KUNIVERSE:QUICKSAVELIST \{ PRINT "KD-" \+ "SAVE-(\w+) " \+ \(kd_save\)\. \}$/.exec(line);
    if (match) {
      for (const save of this.saves) this.print(session, `KD-SAVE-${match[1]} ${save}`);
      return;
    }
    match = /^KUNIVERSE:QUICKSAVETO\("([^"]+)"\)\.$/.exec(line);
    if (match) {
      this.saves.add(match[1]);
      this.savedTo.push(match[1]);
      return;
    }
    match = /^KUNIVERSE:QUICKLOADFROM\("([^"]+)"\)\.$/.exec(line);
    if (match) {
      if (!this.saves.has(match[1])) {
        this.print(session, 'Error loading the quicksave file, the save file does not exist.');
        return;
      }
      this.loads.push(match[1]);
      this.saves.add('kos-backup-quicksave');
      this.reload(session);
      return;
    }
    match = /^RUNPATH\("0:\/([^"]+)", "([^"]+)", "([^"]+)"\)\.$/.exec(line);
    if (match) {
      this.runProgram(session, match[1], match[2], match[3]);
      return;
    }
    this.print(session, `Unknown command: ${line}`);
  }

  reload(session) {
    const cpu = session.cpu;
    cpu.telnets -= 1;
    session.cpu = null;
    for (const each of this.cpus) each.unloaded = true;
    this.showMenu(session, true); // the vessel is gone: back to the menu
    this.later(session, this.loadDelayMs, () => {
      for (const each of this.cpus) { each.unloaded = false; each.busy = false; each.queue = []; }
      this.write(session, "--(List of CPU's has Changed)--\r\n");
      this.showMenu(session, false);
    });
  }

  runProgram(session, script, testId, token) {
    const cpu = session.cpu;
    const program = this.programs[script];
    if (!program) {
      this.print(session, `File '0:/${script}' not found`);
      return;
    }
    cpu.busy = true;
    this.print(session, `TEST-START ${token}`);
    const finish = () => {
      if (!cpu.busy) return;
      if (program.outcome !== 'crash') {
        const name = `test-${testId}-1234.log`;
        const lines = program.log || [
          `1.00 [i] Test - ${testId}`,
          program.outcome === 'fail'
            ? '2.00 [FAIL] Periapsis - 61000.0 m, minimum 75000 m'
            : '2.00 [PASS] Periapsis - 80100.0 m, minimum 75000 m',
          '3.00 [!] Apoapsis - 84000.0 m, target 80000 m, tolerance 3000 m',
        ];
        const failures = lines.filter((entry) => entry.includes('[FAIL]')).length;
        if (program.copied !== false) fs.writeFileSync(path.join(this.scriptDir, name), `${lines.join('\n')}\n`);
        this.print(session, `TEST-DONE ${token} 0:/${name} failures=${failures} copied=${program.copied === false ? 'False' : 'True'}`);
      } else {
        this.print(session, 'Undefined Variable Name \'oops\'.');
      }
      this.endProgram(session, cpu);
    };
    if (program.outcome !== 'hang') this.later(session, program.delayMs || 50, finish);
  }

  endProgram(session, cpu) {
    cpu.busy = false;
    const queued = cpu.queue || [];
    cpu.queue = [];
    for (const line of queued) this.execute(session, line);
  }

  interrupt(session) {
    this.interrupts += 1;
    const cpu = session.cpu;
    if (cpu && cpu.busy) {
      cpu.queue = []; // kOS wipes type-ahead on BREAK
      cpu.busy = false;
      this.print(session, 'Program aborted.');
    }
  }
}

module.exports = { FakeKos, menuRow, CLEAR };
