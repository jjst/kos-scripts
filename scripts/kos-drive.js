#!/usr/bin/env node
'use strict';

// In-game test runner and test-save maker for kOS, driven over kOS telnet.
// See README "In-game tests" and tests/tests.json.
//
//   node scripts/kos-drive.js run <test-id> [options]     (npm run test:ingame -- <test-id>)
//   node scripts/kos-drive.js save <save-name> [options]  (npm run test:save -- <save-name>)
//   node scripts/kos-drive.js report <log-file>           (npm run test:ingame -- --report-only <log>)
//   node scripts/kos-drive.js list

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');
const { KosTelnet, parseCpuMenu, markerPrint, findMarkers } = require('./kos-telnet');

const REPO_ROOT = path.resolve(__dirname, '..');
const DEFAULT_TEST_LIST = path.join(REPO_ROOT, 'tests', 'tests.json');
const DEFAULT_RUNS_DIR = path.join(REPO_ROOT, 'test-runs');
const RESERVED_SAVES = new Set(['persistent', 'quicksave', 'kos-backup-quicksave']);
const SAVE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const TEST_SAVE_PREFIX = '__test_';

const DEFAULTS = {
  host: '127.0.0.1',
  port: 5410,
  connectTimeoutMs: 5000,
  menuTimeoutMs: 15000,
  probeTimeoutMs: 5000,
  probeAttempts: 6,
  loadTimeoutMs: 180000,
  attachDelayMs: 1000,
  loadSettleMs: 5000,
};

class UsageError extends Error {}
class Refusal extends Error {}

function kspCandidates(env = process.env) {
  const home = os.homedir();
  const candidates = [
    path.join(home, '.local/share/Steam/steamapps/common/Kerbal Space Program'),
    path.join(home, 'snap/steam/common/.local/share/Steam/steamapps/common/Kerbal Space Program'),
    path.join(home, '.steam/steam/steamapps/common/Kerbal Space Program'),
    path.join(home, 'Library/Application Support/Steam/steamapps/common/Kerbal Space Program'),
  ];
  for (const variable of ['ProgramFiles(x86)', 'ProgramFiles']) {
    if (env[variable]) candidates.push(path.join(env[variable], 'Steam', 'steamapps', 'common', 'Kerbal Space Program'));
  }
  if (env.LOCALAPPDATA) candidates.push(path.join(env.LOCALAPPDATA, 'Programs', 'Kerbal Space Program'));
  return candidates;
}

function resolveScriptDir(options, env = process.env) {
  const explicit = options.kspDir || env.KSP_DIR;
  const candidates = explicit ? [explicit] : kspCandidates(env);
  for (const dir of candidates) {
    const scriptDir = path.join(dir, 'Ships', 'Script');
    if (fs.existsSync(scriptDir) && fs.statSync(scriptDir).isDirectory()) return scriptDir;
  }
  if (explicit) throw new UsageError(`Ships/Script not found in ${explicit}. Pass --ksp-dir "<KSP folder>" or set KSP_DIR.`);
  throw new UsageError('KSP install not found. Pass --ksp-dir "<KSP folder>" or set KSP_DIR.');
}

// Same files as install.sh / install.bat, plus tests/*.ks.
function syncScripts(scriptDir, repoRoot = REPO_ROOT) {
  const copied = [];
  for (const sub of ['', 'boot', 'lib', 'tests']) {
    const from = path.join(repoRoot, sub);
    if (!fs.existsSync(from)) continue;
    const to = path.join(scriptDir, sub);
    fs.mkdirSync(to, { recursive: true });
    for (const entry of fs.readdirSync(from)) {
      if (path.extname(entry) !== '.ks') continue;
      fs.copyFileSync(path.join(from, entry), path.join(to, entry));
      copied.push(path.posix.join(sub, entry));
    }
  }
  return copied;
}

function loadTestList(file = DEFAULT_TEST_LIST) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new UsageError(`could not read the test list ${file}: ${error.message}`);
  }
  const tests = parsed && parsed.tests;
  if (!tests || typeof tests !== 'object') throw new UsageError(`${file} has no "tests" object`);
  for (const [id, test] of Object.entries(tests)) {
    for (const field of ['script', 'save', 'timeout_s']) {
      if (test[field] === undefined) throw new UsageError(`test "${id}" in ${file} is missing "${field}"`);
    }
    if (test.cpu !== undefined && (!test.cpu || typeof test.cpu !== 'object'
        || (test.cpu.tag !== undefined && typeof test.cpu.tag !== 'string')
        || (test.cpu.vessel !== undefined && typeof test.cpu.vessel !== 'string'))) {
      throw new UsageError(`test "${id}" in ${file} has an invalid "cpu" selector`);
    }
    if (!SAVE_NAME.test(test.save)) throw new UsageError(`test "${id}" has an invalid save name "${test.save}"`);
  }
  return { file, tests };
}

// kOS READJSON needs its typed format (kOS SafeSerializationMgr). Lexicon entries
// may be plain JSON primitives, so only objects need the wrapper.
function encodeKos(value) {
  if (Array.isArray(value)) return { items: value.map(encodeKos), $type: 'kOS.Safe.Encapsulation.ListValue' };
  if (value && typeof value === 'object') {
    const entries = [];
    for (const [key, child] of Object.entries(value)) entries.push(key, encodeKos(child));
    return { entries, $type: 'kOS.Safe.Encapsulation.Lexicon' };
  }
  return value;
}

function summarizeLog(text) {
  const summary = { fails: [], warnings: [], passes: [], infos: [], results: [] };
  for (const line of text.split(/\r?\n/)) {
    let match = /\[(PASS|FAIL)\]\s+(.*?)\s+-\s+(.*)$/.exec(line);
    if (match) {
      (match[1] === 'PASS' ? summary.passes : summary.fails).push({ label: match[2], detail: match[3] });
      continue;
    }
    match = /\[(!|i)\]\s+(.*?)\s+-\s+(.*)$/.exec(line);
    if (match) {
      (match[1] === '!' ? summary.warnings : summary.infos).push({ label: match[2], detail: match[3] });
      continue;
    }
    match = /^(?:[\d.]+\s+)?(.*\bresult): success=(True|False)\b(.*)$/i.exec(line);
    if (match) summary.results.push({ label: match[1], success: match[2].toLowerCase() === 'true', detail: match[3].replace(/^,\s*/, '') });
  }
  return summary;
}

function formatSummary(title, summary, extra = []) {
  const out = [title];
  const section = (heading, items, mark) => {
    if (items.length === 0) return;
    out.push(`  ${heading}:`);
    for (const item of items) out.push(`    ${mark} ${item.label} - ${item.detail}`);
  };
  section('Failures', summary.fails, '[FAIL]');
  section('Warnings', summary.warnings, '[!]');
  section('Passed', summary.passes, '[PASS]');
  for (const result of summary.results) {
    out.push(`  ${result.label}: success=${result.success}${result.detail ? `, ${result.detail}` : ''}`);
  }
  for (const line of extra) out.push(`  ${line}`);
  return out.join('\n');
}

function logVerdict(summary) {
  return summary.fails.length === 0 && summary.results.every((result) => result.success);
}

function parseArgs(argv) {
  const options = { positional: [] };
  const flags = {
    '--ksp-dir': 'kspDir', '--host': 'host', '--port': 'port', '--tests': 'testList',
    '--cpu-tag': 'cpuTag', '--vessel': 'vessel', '--timeout': 'timeoutS', '--report-only': 'reportOnly',
    '--runs-dir': 'runsDir',
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--force') options.force = true;
    else if (arg === '--yes') options.yes = true;
    else if (arg === '--no-sync') options.noSync = true;
    else if (arg === '--help' || arg === '-h') options.help = true;
    else if (flags[arg]) {
      if (index + 1 >= argv.length) throw new UsageError(`${arg} needs a value`);
      options[flags[arg]] = argv[++index];
    } else if (arg.startsWith('--')) throw new UsageError(`unknown option ${arg}`);
    else options.positional.push(arg);
  }
  if (options.port !== undefined) options.port = Number(options.port);
  if (options.timeoutS !== undefined) options.timeoutS = Number(options.timeoutS);
  return options;
}

const HELP = `Usage:
  npm run test:ingame -- <test-id> [--ksp-dir DIR] [--no-sync] [--timeout S] [--cpu-tag TAG] [--vessel NAME]
  npm run test:ingame -- --report-only <log-file>
  npm run test:save -- <save-name> [--force] [--yes] [--cpu-tag TAG] [--vessel NAME]
  node scripts/kos-drive.js list

Use the unprefixed name from tests/tests.json for test:save. In KSP, the save
appears with the ${TEST_SAVE_PREFIX} prefix.

Needs KSP running with kOS telnet on (SET CONFIG:TELNET TO TRUE.) and
"Simulate in Background" enabled. See README "In-game tests".`;

function nonce() {
  return crypto.randomBytes(4).toString('hex');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function matchCpus(cpus, selector) {
  return cpus.filter((cpu) => (!selector.tag || cpu.tag.toLowerCase() === selector.tag.toLowerCase())
    && (!selector.vessel || cpu.vessel === selector.vessel));
}

function describeSelector(selector = {}) {
  return [selector.vessel && `vessel "${selector.vessel}"`, selector.tag && `processor tag "${selector.tag}"`].filter(Boolean).join(' and ');
}

function cpuOverride(options) {
  if (!options.cpuTag && !options.vessel) return undefined;
  return { tag: options.cpuTag, vessel: options.vessel };
}

class Session {
  constructor(settings) {
    this.settings = settings;
    this.client = new KosTelnet({ host: settings.host, port: settings.port });
  }

  async open() {
    await this.client.connect(this.settings.connectTimeoutMs);
  }

  mark() {
    return this.client.screen.history.length;
  }

  waitSince(mark, check, timeoutMs, description) {
    return this.client.waitFor((lines) => check(lines.slice(mark)), timeoutMs, description);
  }

  // Attach to the single CPU that matches the selector, from the current menu.
  // With waitMs, keep watching the menu until the CPU appears (after a load).
  // With settleMs (after a load), wait that long once the CPU appears and use the
  // menu as it is then, so a CPU that is still being torn down isn't picked.
  async attach(selector, { mark = 0, waitMs = this.settings.menuTimeoutMs, settleMs = 0 } = {}) {
    const selection = describeSelector(selector);
    const description = selection ? `a kOS CPU with ${selection} in the telnet menu` : 'a kOS CPU in the telnet menu';
    const latestMatchingMenu = (lines) => {
      const parsed = parseCpuMenu(lines);
      return parsed && parsed.complete && matchCpus(parsed.cpus, selector).length > 0 ? parsed : null;
    };
    let menu = await this.waitSince(mark, latestMatchingMenu, waitMs, description).catch((error) => {
      const parsed = parseCpuMenu(this.client.screen.allLines());
      const seen = parsed ? parsed.cpus.map((cpu) => `"${cpu.vessel}" (tag "${cpu.tag}")`).join(', ') || 'none' : 'no menu';
      throw new Refusal(`${error.message}. CPUs listed: ${seen}.`);
    });
    if (settleMs > 0) {
      await sleep(settleMs);
      menu = latestMatchingMenu(this.client.screen.allLines().slice(mark));
      if (!menu) throw new Refusal(`the matching CPU left the telnet menu again after the load`);
    }
    const matches = matchCpus(menu.cpus, selector);
    if (matches.length > 1) {
      const detail = selection ? `match ${selection}` : 'are listed';
      throw new Refusal(`${matches.length} CPUs ${detail}. Pass --cpu-tag or --vessel to select one.`);
    }
    const cpu = matches[0];
    if (cpu.telnets > 0) {
      throw new Refusal(`CPU "${cpu.vessel}" (tag "${cpu.tag}") already has ${cpu.telnets} telnet connection(s). Close them first: two connections to one CPU act as copies of each other.`);
    }
    this.client.typeLine(String(cpu.pick));
    // Let kOS attach and repaint the CPU's screen before typing at its prompt.
    await sleep(this.settings.attachDelayMs);
    return cpu;
  }

  // Ask kOS to print a marker. It only appears once the interpreter runs the line.
  async probe(kind = 'READY', timeoutMs = this.settings.probeTimeoutMs, attempts = 1) {
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const id = nonce();
      const mark = this.mark();
      this.client.typeLine(markerPrint(kind, id));
      try {
        await this.waitSince(mark, (lines) => findMarkers(lines, kind, id).length > 0, timeoutMs, `the kOS prompt to answer`);
        return true;
      } catch (error) {
        if (this.client.closed) throw error;
      }
    }
    return false;
  }

  // Evaluate kOS expressions at the prompt; each value is printed on its own short line.
  async query(fields, timeoutMs = this.settings.probeTimeoutMs) {
    const id = nonce();
    const mark = this.mark();
    for (const [key, expression] of Object.entries(fields)) {
      this.client.typeLine(markerPrint('Q', id, `"${key}=" + ${expression}`));
    }
    this.client.typeLine(markerPrint('QEND', id));
    await this.waitSince(mark, (lines) => findMarkers(lines, 'QEND', id).length > 0, timeoutMs, 'kOS to answer a query');
    const values = {};
    for (const entry of findMarkers(this.client.screen.allLines().slice(mark), 'Q', id)) {
      const split = entry.indexOf('=');
      if (split > 0) values[entry.slice(0, split)] = entry.slice(split + 1);
    }
    return values;
  }

  async saveList(timeoutMs = this.settings.probeTimeoutMs) {
    const id = nonce();
    const mark = this.mark();
    this.client.typeLine(`FOR kd_save IN KUNIVERSE:QUICKSAVELIST { ${markerPrint('SAVE', id, 'kd_save')} }`);
    this.client.typeLine(markerPrint('SAVEEND', id));
    await this.waitSince(mark, (lines) => findMarkers(lines, 'SAVEEND', id).length > 0, timeoutMs, 'the kOS save list');
    return findMarkers(this.client.screen.allLines().slice(mark), 'SAVE', id);
  }

  close() {
    this.client.detach();
    this.client.close();
  }
}

async function confirm(question, io) {
  if (!io.stdin || !io.stdin.isTTY) return false;
  const rl = readline.createInterface({ input: io.stdin, output: io.stdout });
  const answer = await new Promise((resolve) => rl.question(`${question} [y/N] `, resolve));
  rl.close();
  return /^y(es)?$/i.test(answer.trim());
}

function writeRunFile(runsDir, name, content) {
  fs.mkdirSync(runsDir, { recursive: true });
  const file = path.join(runsDir, name);
  fs.writeFileSync(file, content);
  return file;
}

function displayPath(file) {
  const relative = path.relative(REPO_ROOT, file);
  return relative.startsWith('..') ? file : relative;
}

function archiveToDisk(scriptDir, archivePath) {
  const relative = archivePath.replace(/^0:\/?/, '');
  return path.join(scriptDir, ...relative.split('/'));
}

async function commandReport(options, io) {
  const file = options.reportOnly || options.positional[0];
  if (!file) throw new UsageError('give the log file to report on');
  const summary = summarizeLog(fs.readFileSync(file, 'utf8'));
  const pass = logVerdict(summary);
  io.stdout.write(`${formatSummary(`${pass ? 'PASS' : 'FAIL'}  ${file}`, summary)}\n`);
  return pass ? 0 : 1;
}

function commandList(options, io) {
  const { tests } = loadTestList(options.testList);
  for (const [id, test] of Object.entries(tests)) {
    io.stdout.write(`${id}: ${test.script} from save "${TEST_SAVE_PREFIX}${test.save}", CPU ${describeSelector(test.cpu) || 'only listed processor'}, limit ${test.timeout_s} s\n`);
  }
  return 0;
}

async function commandRun(options, io, settings) {
  if (options.reportOnly) return commandReport(options, io);
  const testId = options.positional[0];
  if (!testId) throw new UsageError('give a test id (see node scripts/kos-drive.js list)');
  const { tests } = loadTestList(options.testList);
  const test = tests[testId];
  if (!test) throw new UsageError(`unknown test "${testId}". Known tests: ${Object.keys(tests).join(', ')}`);
  const selector = cpuOverride(options) || test.cpu || {};
  const save = TEST_SAVE_PREFIX + test.save;
  const timeoutMs = (options.timeoutS || test.timeout_s) * 1000;
  const scriptDir = resolveScriptDir(options);
  const runsDir = options.runsDir || DEFAULT_RUNS_DIR;
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const token = nonce();
  const say = (line) => io.stdout.write(`${line}\n`);

  if (!options.noSync) say(`Copied ${syncScripts(scriptDir).length} scripts to ${scriptDir}.`);
  const optionsFile = path.join(scriptDir, 'tests', 'options', `${testId}.json`);
  fs.mkdirSync(path.dirname(optionsFile), { recursive: true });
  fs.writeFileSync(optionsFile, JSON.stringify(encodeKos(test.options || {}), null, 2));

  const session = new Session(settings);
  let outcome = { code: 1, lines: [] };
  try {
    await session.open();
    await session.attach(selector);
    if (!(await session.probe('READY', settings.probeTimeoutMs, 2))) {
      throw new Refusal('the CPU did not answer at the kOS prompt, so a script is probably running on it. Nothing was loaded. Stop the script and rerun.');
    }
    const saves = await session.saveList();
    if (!saves.includes(save)) {
      throw new Refusal(`save "${save}" is not in this game's saves (found: ${saves.join(', ') || 'none'}). Make it with npm run test:save -- ${test.save}. Nothing was loaded.`);
    }
    say(`Loading save "${save}". kOS writes kos-backup-quicksave first.`);
    const loadMark = session.mark();
    session.client.typeLine(`KUNIVERSE:QUICKLOADFROM("${save}").`);
    await session.attach(selector, { mark: loadMark, waitMs: settings.loadTimeoutMs, settleMs: settings.loadSettleMs });
    if (!(await session.probe('READY', settings.probeTimeoutMs, settings.probeAttempts))) {
      throw new Refusal(`the test CPU did not answer after loading "${save}". Check that its boot file doesn't keep a script running.`);
    }

    say(`Running ${test.script} (limit ${Math.round(timeoutMs / 1000)} s).`);
    const runMark = session.mark();
    const runCommand = `RUNPATH("0:/${test.script}", "${testId}", "${token}").`;
    session.client.typeLine(runCommand);
    const done = (lines) => lines.map((line) => new RegExp(`TEST-DONE ${token} (\\S+) failures=(\\d+) copied=(\\w+)`).exec(line)).find(Boolean);
    let doneMatch = null;
    try {
      const completion = await session.waitSince(runMark, (lines) => {
        const marker = done(lines);
        if (marker) return marker;
        // Ignore completion messages left over from earlier programs.
        const command = lines.findIndex((line) => line.trim() === runCommand);
        return command >= 0 && lines.slice(command + 1).some((line) => line.trim() === 'Program ended.')
          ? 'ended' : null;
      }, timeoutMs, `${testId} to finish`);
      if (completion !== 'ended') doneMatch = completion;
    } catch (error) {
      if (session.client.closed) throw error;
      session.client.interrupt();
      // Ctrl-C also wipes type-ahead, so ask again to confirm the script stopped.
      const stopped = await session.probe('READY', settings.probeTimeoutMs, 2);
      outcome.lines.push(`Timed out after ${Math.round(timeoutMs / 1000)} s; sent Ctrl-C to stop the script. `
        + (stopped ? 'The CPU is back at the kOS prompt.' : 'The CPU did not answer afterwards: check the vessel.'));
    }
    if (doneMatch) {
      const archivePath = doneMatch[1];
      const failures = Number(doneMatch[2]);
      const copied = doneMatch[3] === 'True';
      const diskLog = archiveToDisk(scriptDir, archivePath);
      if (!copied || !fs.existsSync(diskLog)) {
        outcome.lines.push(`The log was not copied to the archive (copied=${doneMatch[3]}, ${diskLog}). The vessel needs a home connection.`);
      } else {
        const text = fs.readFileSync(diskLog, 'utf8');
        const kept = writeRunFile(runsDir, `${stamp}-${testId}.log`, text);
        const summary = summarizeLog(text);
        const pass = logVerdict(summary) && failures === 0;
        outcome = {
          code: pass ? 0 : 1,
          lines: [formatSummary(`${pass ? 'PASS' : 'FAIL'}  ${testId} (save "${save}")`, summary,
            [`Failures counted by the script: ${failures}`, `Log: ${archivePath} (copy: ${displayPath(kept)})`])],
        };
      }
    } else if (outcome.lines.length === 0) {
      outcome.lines.push('The script ended without TEST-DONE, so it probably stopped on a kOS error. See the screen transcript.');
    }
  } catch (error) {
    if (error instanceof Refusal) outcome = { code: 2, lines: [`Refused: ${error.message}`] };
    else outcome = { code: 2, lines: [`Error: ${error.message}`] };
  } finally {
    const transcript = writeRunFile(runsDir, `${stamp}-${testId}.screen.txt`, session.client.screen.text());
    outcome.lines.push(`Screen transcript: ${displayPath(transcript)}`);
    session.close();
  }
  for (const line of outcome.lines) say(line);
  if (outcome.code === 1 && outcome.lines.every((line) => !/^(PASS|FAIL)/.test(line))) say(`FAIL  ${testId}`);
  return outcome.code;
}

async function commandSave(options, io, settings) {
  const name = options.positional[0];
  if (!name) throw new UsageError('give the save name (it must be used by a test in tests/tests.json)');
  if (!SAVE_NAME.test(name)) throw new UsageError(`invalid save name "${name}": use letters, digits, ".", "_" or "-"`);
  if (RESERVED_SAVES.has(name)) throw new UsageError(`"${name}" is reserved by KSP or kOS`);
  const { tests } = loadTestList(options.testList);
  const users = Object.entries(tests).filter(([, test]) => test.save === name);
  if (users.length === 0) {
    throw new Refusal(`no test in the test list uses save "${name}". Add the test entry first.`);
  }
  const save = TEST_SAVE_PREFIX + name;
  let selector = cpuOverride(options);
  if (!selector) {
    const configured = users.map(([, test]) => test.cpu).filter(cpu => describeSelector(cpu));
    const distinct = new Set(configured.map(describeSelector));
    if (distinct.size > 1) throw new Refusal(`tests using "${name}" name different CPUs. Pass --cpu-tag or --vessel.`);
    selector = configured[0] || {};
  }
  const say = (line) => io.stdout.write(`${line}\n`);

  if (!options.yes) {
    const selection = describeSelector(selector);
    const cpuDescription = selection ? `the CPU with ${selection}` : 'the only listed CPU';
    const ok = await confirm(`Is ${cpuDescription} idle at the kOS prompt, with no script running, and the game at 1x?`, io);
    if (!ok) throw new Refusal('not confirmed. Anything typed while a script runs goes to that script as key presses. Stop it, then rerun (pass --yes to skip this question).');
  }

  const session = new Session(settings);
  try {
    await session.open();
    const cpu = await session.attach(selector);
    if (!(await session.probe('READY', settings.probeTimeoutMs, 2))) {
      throw new Refusal('the CPU did not answer at the kOS prompt, so a script is probably running on it. Nothing was saved.');
    }
    const saves = await session.saveList();
    const alreadyExists = saves.includes(save);
    if (alreadyExists && !options.force) {
      throw new Refusal(`save "${save}" already exists. Pass --force to remake it deliberately. Nothing was saved.`);
    }
    const state = await session.query({
      canquicksave: 'KUNIVERSE:CANQUICKSAVE',
      warp: 'KUNIVERSE:TIMEWARP:RATE',
      settled: 'KUNIVERSE:TIMEWARP:ISSETTLED',
      active: '(SHIP = KUNIVERSE:ACTIVEVESSEL)',
      vessel: 'SHIP:NAME',
      status: 'SHIP:STATUS',
      body: 'SHIP:BODY:NAME',
      ut: 'ROUND(TIME:SECONDS, 1)',
      ap: 'ROUND(SHIP:APOAPSIS)',
      pe: 'ROUND(SHIP:PERIAPSIS)',
    });
    const problems = [];
    if (state.canquicksave !== 'True') problems.push(`KSP doesn't allow saving right now (KUNIVERSE:CANQUICKSAVE = ${state.canquicksave}); coast without thrust`);
    if (!(Number(state.warp) <= 1.01) || state.settled !== 'True') problems.push(`time warp is ${state.warp}x (settled ${state.settled}); return to 1x`);
    if (state.active !== 'True') problems.push(`"${cpu.vessel}" is not the active vessel`);
    if (problems.length > 0) throw new Refusal(`${problems.join('; ')}. Nothing was saved.`);

    session.client.typeLine(`KUNIVERSE:QUICKSAVETO("${save}").`);
    const after = await session.saveList(settings.probeTimeoutMs * 2);
    if (!after.includes(save)) throw new Error(`save "${save}" did not appear in KUNIVERSE:QUICKSAVELIST after saving`);
    say(`Saved "${save}"${alreadyExists ? ' (replaced the old save)' : ''}: ${state.vessel}, ${state.status} at ${state.body}, UT ${state.ut} s, Ap ${state.ap} m, Pe ${state.pe} m.`);
    say(`Used by: ${users.map(([id]) => id).join(', ')}.`);
    return 0;
  } catch (error) {
    if (error instanceof Refusal) say(`Refused: ${error.message}`);
    else say(`Error: ${error.message}`);
    return 2;
  } finally {
    session.close();
  }
}

async function main(argv = process.argv.slice(2), io = { stdout: process.stdout, stderr: process.stderr, stdin: process.stdin }, overrides = {}) {
  let options;
  try {
    const [command, ...rest] = argv;
    options = parseArgs(rest);
    if (!command || options.help || command === 'help') {
      io.stdout.write(`${HELP}\n`);
      return command ? 0 : 2;
    }
    const settings = { ...DEFAULTS, ...overrides };
    if (options.host) settings.host = options.host;
    if (options.port) settings.port = options.port;
    if (command === 'run') return await commandRun(options, io, settings);
    if (command === 'save') return await commandSave(options, io, settings);
    if (command === 'report') return await commandReport(options, io);
    if (command === 'list') return commandList(options, io);
    throw new UsageError(`unknown command "${command}"`);
  } catch (error) {
    if (error instanceof UsageError || error instanceof Refusal) {
      io.stderr.write(`${error instanceof Refusal ? 'Refused' : 'Error'}: ${error.message}\n`);
      return 2;
    }
    throw error;
  }
}

if (require.main === module) {
  main().then((code) => { process.exitCode = code; }, (error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 2;
  });
}

module.exports = { main, summarizeLog, logVerdict, encodeKos, syncScripts, loadTestList, parseArgs, resolveScriptDir, archiveToDisk };
