'use strict';

// Minimal client for the kOS telnet server (kOS src/kOS/UserIO/Telnet*.cs).
//
// The server works one character at a time, echoes what it receives, sends
// screen updates as diffs with cursor moves (xterm/VT100 codes), and asks for
// the terminal type every 10 s as a keepalive. A client that doesn't answer is
// dropped. This module answers the negotiation, keeps a small screen emulator
// so output can be read reliably, and parses the CPU selection menu.

const net = require('net');
const { StringDecoder } = require('string_decoder');

const IAC = 255;
const DONT = 254;
const DO = 253;
const WONT = 252;
const WILL = 251;
const SB = 250;
const SE = 240;
const IP = 244;
const OPT_ECHO = 1;
const OPT_SGA = 3;
const OPT_TERMTYPE = 24;
const OPT_NAWS = 31;
const TERMTYPE_IS = 0;
const TERMTYPE_SEND = 1;

const DEFAULT_COLUMNS = 120;
const DEFAULT_ROWS = 40;
const HISTORY_LIMIT = 20000;

// A small terminal emulator for what kOS sends: printable text, CR/LF/BS,
// CSI cursor moves (H, A-D), erase (J, K), scroll (S, T), xterm resize (t)
// and title (OSC ... BEL). Rows that scroll off the top or are cleared are
// kept in `history`, so output that is immediately redrawn is not lost.
class Screen {
  constructor(columns = DEFAULT_COLUMNS, rows = DEFAULT_ROWS) {
    this.columns = columns;
    this.rows = rows;
    this.history = [];
    this.reset();
    this.pending = '';
  }

  reset() {
    this.grid = Array.from({ length: this.rows }, () => []);
    this.row = 0;
    this.col = 0;
  }

  pushHistory(line) {
    this.history.push(line);
    if (this.history.length > HISTORY_LIMIT) this.history.splice(0, this.history.length - HISTORY_LIMIT);
  }

  rowText(index) {
    return this.grid[index].map((ch) => ch || ' ').join('').replace(/\s+$/, '');
  }

  visibleLines() {
    const lines = [];
    for (let index = 0; index < this.rows; index += 1) lines.push(this.rowText(index));
    while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
    return lines;
  }

  // Everything seen so far: rows that left the screen, then the visible rows.
  allLines() {
    return this.history.concat(this.visibleLines());
  }

  text() {
    return this.allLines().join('\n');
  }

  clearScreen() {
    for (const line of this.visibleLines()) if (line !== '') this.pushHistory(line);
    this.reset();
  }

  scrollUp(count = 1) {
    for (let step = 0; step < count; step += 1) {
      const line = this.rowText(0);
      if (line !== '') this.pushHistory(line);
      this.grid.shift();
      this.grid.push([]);
    }
  }

  scrollDown(count = 1) {
    for (let step = 0; step < count; step += 1) {
      this.grid.pop();
      this.grid.unshift([]);
    }
  }

  lineFeed() {
    if (this.row >= this.rows - 1) this.scrollUp(1);
    else this.row += 1;
  }

  putChar(ch) {
    if (this.col >= this.columns) {
      this.col = 0;
      this.lineFeed();
    }
    this.grid[this.row][this.col] = ch;
    this.col += 1;
  }

  resize(rows, columns) {
    if (rows > 0 && rows !== this.rows) {
      while (this.grid.length < rows) this.grid.push([]);
      while (this.grid.length > rows) {
        const line = this.grid.shift().map((ch) => ch || ' ').join('').replace(/\s+$/, '');
        if (line !== '') this.pushHistory(line);
      }
      this.rows = rows;
    }
    if (columns > 0) this.columns = columns;
    this.row = Math.min(this.row, this.rows - 1);
    this.col = Math.min(this.col, this.columns);
  }

  csi(params, final) {
    const numbers = params.replace(/^\?/, '').split(';').map((value) => (value === '' ? NaN : Number(value)));
    const first = Number.isFinite(numbers[0]) ? numbers[0] : null;
    switch (final) {
      case 'H':
      case 'f':
        this.row = Math.max(0, Math.min(this.rows - 1, (first || 1) - 1));
        this.col = Math.max(0, Math.min(this.columns - 1, (Number.isFinite(numbers[1]) ? numbers[1] : 1) - 1));
        break;
      case 'A': this.row = Math.max(0, this.row - (first || 1)); break;
      case 'B': this.row = Math.min(this.rows - 1, this.row + (first || 1)); break;
      case 'C': this.col = Math.min(this.columns - 1, this.col + (first || 1)); break;
      case 'D': this.col = Math.max(0, this.col - (first || 1)); break;
      case 'J':
        if (first === 2 || first === 3) {
          this.clearScreen();
        } else if (first === 1) {
          for (let row = 0; row < this.row; row += 1) this.grid[row] = [];
          this.grid[this.row].fill(undefined, 0, this.col + 1);
        } else {
          this.grid[this.row].length = Math.min(this.grid[this.row].length, this.col);
          for (let row = this.row + 1; row < this.rows; row += 1) this.grid[row] = [];
        }
        break;
      case 'K':
        if (first === 1) this.grid[this.row].fill(undefined, 0, this.col + 1);
        else if (first === 2) this.grid[this.row] = [];
        else this.grid[this.row].length = Math.min(this.grid[this.row].length, this.col);
        break;
      case 'S': this.scrollUp(first || 1); break;
      case 'T': this.scrollDown(first || 1); break;
      case 't':
        if (first === 8) this.resize(numbers[1], numbers[2]);
        break;
      default:
        break; // modes (h/l), colours (m) and anything else are ignored.
    }
  }

  write(text) {
    let data = this.pending + text;
    this.pending = '';
    let index = 0;
    while (index < data.length) {
      const ch = data[index];
      if (ch === '\x1b') {
        const rest = data.slice(index);
        let match = /^\x1b\[([0-9;?]*)([@-~])/.exec(rest);
        if (match) {
          this.csi(match[1], match[2]);
          index += match[0].length;
          continue;
        }
        match = /^\x1b\][^\x07\x1b]*(\x07|\x1b\\)/.exec(rest);
        if (match) { index += match[0].length; continue; }
        // kOS sends "ESC ? 47 h" without the '[' before CLEARSCREEN on xterm.
        match = /^\x1b\?[0-9;]*[A-Za-z]/.exec(rest);
        if (match) { index += match[0].length; continue; }
        if (/^\x1b(\[[0-9;?]*|\][^\x07\x1b]*|\?[0-9;]*)?$/.test(rest)) {
          this.pending = rest; // incomplete sequence: wait for more data.
          return;
        }
        index += 2; // unknown two-character escape.
        continue;
      }
      if (ch === '\r') this.col = 0;
      else if (ch === '\n') this.lineFeed();
      else if (ch === '\b') this.col = Math.max(0, this.col - 1);
      else if (ch === '\t') this.col = Math.min(this.columns - 1, (Math.floor(this.col / 8) + 1) * 8);
      else if (ch >= ' ' && ch !== '\x7f') this.putChar(ch);
      index += 1;
    }
  }
}

// Parse the most recent kOS CPU menu (TelnetWelcomeMenu.PrintCPUMenu) out of
// screen lines. Rows look like:
//   [1]   no    0     Vessel Name (CX-4181(tagname))
function parseCpuMenu(lines) {
  let header = -1;
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (/Pick\s+Open\s+Telnets\s+Vessel Name/.test(lines[index])) { header = index; break; }
  }
  if (header < 0) return null;
  const cpus = [];
  for (let index = header + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const match = /^\s*\[(\d+)\]\s+(yes|no)\s+(\d+)\s+(.*?)\s*\(([^()]*)\((.*)\)\)\s*$/.exec(line);
    if (match) {
      cpus.push({
        pick: Number(match[1]),
        guiOpen: match[2] === 'yes',
        telnets: Number(match[3]),
        vessel: match[4].trim(),
        part: match[5],
        tag: match[6],
      });
    } else if (/Choose a CPU|<NONE>/.test(line)) {
      break;
    }
  }
  const complete = lines.slice(header + 1).some((line) => /Choose a CPU|<NONE>/.test(line));
  return { cpus, complete };
}

class KosTelnet {
  constructor({ host = '127.0.0.1', port = 5410, columns = DEFAULT_COLUMNS, rows = DEFAULT_ROWS, log = null } = {}) {
    this.host = host;
    this.port = port;
    this.columns = columns;
    this.rows = rows;
    this.screen = new Screen(columns, rows);
    this.decoder = new StringDecoder('utf8');
    this.log = log; // optional (text) => void for a raw transcript
    this.socket = null;
    this.closed = false;
    this.waiters = new Set();
    this.agreed = new Set(); // options we already answered, to avoid negotiation loops.
    this.parseState = { mode: 'data', command: 0, sub: [] };
  }

  connect(timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: this.host, port: this.port });
      this.socket = socket;
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`timed out connecting to kOS telnet at ${this.host}:${this.port}`));
      }, timeoutMs);
      socket.once('connect', () => { clearTimeout(timer); resolve(); });
      socket.once('error', (error) => {
        clearTimeout(timer);
        reject(new Error(`could not connect to kOS telnet at ${this.host}:${this.port}: ${error.message}`));
      });
      socket.on('data', (chunk) => this.onData(chunk));
      socket.on('close', () => {
        this.closed = true;
        this.notify();
      });
    });
  }

  sendRaw(bytes) {
    if (this.socket && !this.closed) this.socket.write(Buffer.from(bytes));
  }

  answerOption(verb, option) {
    const key = `${verb}:${option}`;
    if (this.agreed.has(key)) return;
    this.agreed.add(key);
    if (verb === DO) {
      if (option === OPT_NAWS) {
        this.sendRaw([IAC, WILL, OPT_NAWS]);
        this.sendWindowSize();
      } else if (option === OPT_TERMTYPE) {
        this.sendRaw([IAC, WILL, OPT_TERMTYPE]);
      } else {
        this.sendRaw([IAC, WONT, option]); // includes ECHO: the server echoes, we don't.
      }
    } else if (verb === WILL) {
      if (option === OPT_ECHO || option === OPT_SGA) this.sendRaw([IAC, DO, option]);
      else this.sendRaw([IAC, DONT, option]);
    } else if (verb === WONT) {
      this.sendRaw([IAC, DONT, option]);
    } else if (verb === DONT) {
      this.sendRaw([IAC, WONT, option]);
    }
  }

  sendWindowSize() {
    const escape = (value) => (value === IAC ? [IAC, IAC] : [value]);
    this.sendRaw([IAC, SB, OPT_NAWS,
      ...escape((this.columns >> 8) & 0xff), ...escape(this.columns & 0xff),
      ...escape((this.rows >> 8) & 0xff), ...escape(this.rows & 0xff),
      IAC, SE]);
  }

  handleSubnegotiation(bytes) {
    if (bytes[0] === OPT_TERMTYPE && bytes[1] === TERMTYPE_SEND) {
      // Also the server's keepalive: it drops clients that stop answering.
      this.sendRaw([IAC, SB, OPT_TERMTYPE, TERMTYPE_IS, ...Buffer.from('XTERM'), IAC, SE]);
    }
  }

  onData(chunk) {
    const text = [];
    const state = this.parseState;
    for (const byte of chunk) {
      switch (state.mode) {
        case 'data':
          if (byte === IAC) state.mode = 'iac';
          else text.push(byte);
          break;
        case 'iac':
          if (byte === IAC) { text.push(IAC); state.mode = 'data'; }
          else if (byte === DO || byte === DONT || byte === WILL || byte === WONT) { state.command = byte; state.mode = 'option'; }
          else if (byte === SB) { state.sub = []; state.mode = 'sub'; }
          else state.mode = 'data';
          break;
        case 'option':
          this.answerOption(state.command, byte);
          state.mode = 'data';
          break;
        case 'sub':
          if (byte === IAC) state.mode = 'sub-iac';
          else state.sub.push(byte);
          break;
        case 'sub-iac':
          if (byte === SE) { this.handleSubnegotiation(state.sub); state.mode = 'data'; }
          else { state.sub.push(byte); state.mode = 'sub'; }
          break;
        default:
          state.mode = 'data';
      }
    }
    if (text.length > 0) {
      const decoded = this.decoder.write(Buffer.from(text));
      if (this.log) this.log(decoded);
      this.screen.write(decoded);
      this.notify();
    }
  }

  notify() {
    for (const waiter of [...this.waiters]) waiter();
  }

  // Wait until check(lines) returns a truthy value, the connection closes, or the time runs out.
  waitFor(check, timeoutMs, description) {
    return new Promise((resolve, reject) => {
      let timer = null;
      const finish = (error, value) => {
        clearTimeout(timer);
        this.waiters.delete(evaluate);
        if (error) reject(error); else resolve(value);
      };
      const evaluate = () => {
        let value;
        try { value = check(this.screen.allLines()); } catch (error) { finish(error); return; }
        if (value) finish(null, value);
        else if (this.closed) finish(new Error(`kOS telnet connection closed while waiting for ${description}`));
      };
      timer = setTimeout(() => finish(new Error(`timed out after ${Math.round(timeoutMs / 1000)} s waiting for ${description}`)), timeoutMs);
      this.waiters.add(evaluate);
      evaluate();
    });
  }

  // Type a line into whatever is attached: the menu, or the CPU's terminal.
  typeLine(line) {
    const bytes = [];
    for (const byte of Buffer.from(line + '\r', 'utf8')) {
      bytes.push(byte);
      if (byte === IAC) bytes.push(IAC);
    }
    this.sendRaw(bytes);
  }

  interrupt() {
    this.sendRaw([IAC, IP]); // kOS maps this to Ctrl-C (BREAK) and clears type-ahead.
  }

  detach() {
    this.sendRaw([0x04]); // Ctrl-D at the start of a command line returns to the menu.
  }

  close() {
    if (this.socket && !this.closed) this.socket.end();
    this.closed = true;
  }

  async waitForMenu(timeoutMs, description = 'the kOS CPU menu') {
    return this.waitFor((lines) => {
      const menu = parseCpuMenu(lines);
      return menu && menu.complete ? menu : null;
    }, timeoutMs, description);
  }
}

// kOS echoes what is typed, so a marker built by string concatenation only
// appears on screen when kOS actually runs the command.
function markerPrint(kind, nonce, expression = null) {
  const prefix = `"KD-" + "${kind}-${nonce} "`;
  return expression ? `PRINT ${prefix} + (${expression}).` : `PRINT ${prefix}.`;
}

function findMarkers(lines, kind, nonce) {
  const pattern = new RegExp(`KD-${kind}-${nonce}(?: (.*))?$`);
  const found = [];
  for (const line of lines) {
    const match = pattern.exec(line);
    if (match) found.push(match[1] === undefined ? '' : match[1].replace(/\s+$/, ''));
  }
  return found;
}

module.exports = {
  KosTelnet,
  Screen,
  parseCpuMenu,
  markerPrint,
  findMarkers,
  constants: { IAC, DO, DONT, WILL, WONT, SB, SE, IP, OPT_ECHO, OPT_SGA, OPT_TERMTYPE, OPT_NAWS, TERMTYPE_IS, TERMTYPE_SEND },
};
