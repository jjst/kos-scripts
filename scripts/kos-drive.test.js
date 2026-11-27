'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Writable } = require('stream');

const { Screen, parseCpuMenu, KosTelnet, findMarkers, markerPrint } = require('./kos-telnet');
const { main, summarizeLog, logVerdict, encodeKos } = require('./kos-drive');
const { FakeKos, menuRow, CLEAR } = require('./fake-kos-server');

const FAST = { probeTimeoutMs: 400, attachDelayMs: 30, loadTimeoutMs: 3000, loadSettleMs: 50, menuTimeoutMs: 2000, connectTimeoutMs: 2000 };

const VALUES = {
  'KUNIVERSE:CANQUICKSAVE': 'True',
  'KUNIVERSE:TIMEWARP:RATE': '1',
  'KUNIVERSE:TIMEWARP:ISSETTLED': 'True',
  'SHIP = KUNIVERSE:ACTIVEVESSEL': 'True',
  'SHIP:NAME': 'Test Rocket',
  'SHIP:STATUS': 'PRELAUNCH',
  'SHIP:BODY:NAME': 'Kerbin',
  'ROUND(TIME:SECONDS, 1)': '12345.6',
  'ROUND(SHIP:APOAPSIS)': '75',
  'ROUND(SHIP:PERIAPSIS)': '-598000',
};

async function until(check, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('condition not met in time');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function capture() {
  const chunks = [];
  const stream = new Writable({ write(chunk, _encoding, done) { chunks.push(chunk.toString()); done(); } });
  stream.text = () => chunks.join('');
  return stream;
}

function setup(t, { saves = ['__test_pad'], cpus = [{ vessel: 'Test Rocket', tag: 'test' }], programs, values = {}, tests } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kos-drive-'));
  const kspDir = path.join(root, 'KSP');
  const scriptDir = path.join(kspDir, 'Ships', 'Script');
  fs.mkdirSync(scriptDir, { recursive: true });
  const runsDir = path.join(root, 'runs');
  const testList = path.join(root, 'tests.json');
  fs.writeFileSync(testList, JSON.stringify({
    tests: tests || {
      smoke: { script: 'tests/smoke.ks', save: 'pad', cpu: { tag: 'test' }, timeout_s: 5, options: {} },
      'pad-launch': {
        script: 'tests/pad_launch.ks', save: 'pad', cpu: { tag: 'test' }, timeout_s: 5,
        options: { heading: 90, target_altitude: 80000, half_dv_timing: true },
      },
      orbit: { script: 'tests/smoke.ks', save: 'rdv-parking', cpu: { tag: 'test' }, timeout_s: 5, options: {} },
    },
  }));
  const fake = new FakeKos({
    scriptDir,
    cpus,
    saves,
    values: { ...VALUES, ...values },
    programs: programs || { 'tests/smoke.ks': { outcome: 'pass' }, 'tests/pad_launch.ks': { outcome: 'pass' } },
  });
  t.after(async () => {
    await fake.close();
    fs.rmSync(root, { recursive: true, force: true });
  });
  return { root, kspDir, scriptDir, runsDir, testList, fake };
}

async function drive(env, args, { stdin } = {}) {
  const port = env.port || (env.port = await env.fake.listen());
  const stdout = capture();
  const stderr = capture();
  const code = await main([...args, '--ksp-dir', env.kspDir, '--tests', env.testList, '--runs-dir', env.runsDir, '--port', String(port)],
    { stdout, stderr, stdin: stdin || { isTTY: false } }, FAST);
  return { code, out: stdout.text(), err: stderr.text() };
}

test('screen emulator follows kOS cursor moves, clears and scrolls', () => {
  const screen = new Screen(20, 3);
  screen.write('hello\r\nworld');
  screen.write('\x1b[1;1HJ');
  assert.deepEqual(screen.visibleLines(), ['Jello', 'world']);
  screen.write('\x1b?47h\x1b[2J\x1b[H'); // kOS xterm CLEARSCREEN
  assert.deepEqual(screen.visibleLines(), []);
  assert.deepEqual(screen.history, ['Jello', 'world']);
  screen.write('a\r\nb\r\nc\r\nd');
  assert.deepEqual(screen.visibleLines(), ['b', 'c', 'd']);
  assert.equal(screen.history.at(-1), 'a');
  screen.write('\x1b[2;3Hxy\x1b[2;2H\x1b[K');
  assert.equal(screen.visibleLines()[1], 'c');
});

test('screen emulator keeps escape sequences split across chunks', () => {
  const screen = new Screen(20, 3);
  screen.write('ab\x1b[');
  screen.write('1;1Hz');
  assert.deepEqual(screen.visibleLines(), ['zb']);
  screen.write('\x1b]2;kOS title');
  screen.write('\x07!');
  assert.deepEqual(screen.visibleLines(), ['z!']);
});

test('parses the kOS CPU menu and the latest copy of it', () => {
  const row = (fields) => `          ${menuRow(fields)}`;
  const lines = [
    row(['Pick', 'Open', 'Telnets', '', 'Vessel Name', '(CPU tagname)']),
    row(['[1]', 'no', 0, '   ', 'Old Ship', '(CX-4181(old))']),
    'Choose a CPU to attach to by typing a selection number',
    row(['Pick', 'Open', 'Telnets', '', 'Vessel Name', '(CPU tagname)']),
    row(['----', '----', '-------', '', '-----', '']),
    row(['[1]', 'yes', 1, '   ', 'Station (Alpha)', '(KR-2042(station))']),
    row(['[2]', 'no', 0, '   ', 'Test Rocket', '(CX-4181(test))']),
    'Choose a CPU to attach to by typing a selection number',
  ];
  const menu = parseCpuMenu(lines);
  assert.equal(menu.complete, true);
  assert.deepEqual(menu.cpus, [
    { pick: 1, guiOpen: true, telnets: 1, vessel: 'Station (Alpha)', part: 'KR-2042', tag: 'station' },
    { pick: 2, guiOpen: false, telnets: 0, vessel: 'Test Rocket', part: 'CX-4181', tag: 'test' },
  ]);
  assert.equal(parseCpuMenu(['no menu here']), null);
});

test('markers only match what kOS printed, not the echoed command', () => {
  const command = markerPrint('READY', 'abc123');
  assert.equal(command, 'PRINT "KD-" + "READY-abc123 ".');
  assert.deepEqual(findMarkers([command, 'KD-READY-abc123'], 'READY', 'abc123'), ['']);
  assert.deepEqual(findMarkers(['KD-Q-abc123 warp=1'], 'Q', 'abc123'), ['warp=1']);
});

test('summarises check lines and result lines from a log', () => {
  const summary = summarizeLog([
    '10.00 [PASS] Periapsis - 80100.0 m, minimum 75000 m',
    '10.10 [!] Apoapsis - 84000.0 m, target 80000 m, tolerance 3000 m',
    '10.20 [i] Gravity turn - 90 deg at 100 m',
    '10.30 Launch result: success=True, circularisation stopped at minimum eccentricity.',
  ].join('\n'));
  assert.equal(summary.passes.length, 1);
  assert.equal(summary.warnings[0].label, 'Apoapsis');
  assert.equal(summary.infos.length, 1);
  assert.deepEqual(summary.results, [{ label: 'Launch result', success: true, detail: 'circularisation stopped at minimum eccentricity.' }]);
  assert.equal(logVerdict(summary), true);
  assert.equal(logVerdict(summarizeLog('1 Launch result: success=False, ascent exceeded 600 s.')), false);
  assert.equal(logVerdict(summarizeLog('1 [FAIL] Periapsis - 61000 m, minimum 75000 m')), false);
});

test('encodes options in the typed JSON format READJSON expects', () => {
  assert.deepEqual(encodeKos({ heading: 90, half_dv_timing: true, list: [1, 'a'] }), {
    entries: ['heading', 90, 'half_dv_timing', true, 'list', { items: [1, 'a'], $type: 'kOS.Safe.Encapsulation.ListValue' }],
    $type: 'kOS.Safe.Encapsulation.Lexicon',
  });
});

test('client answers negotiation and the terminal-type keepalive', async (t) => {
  const env = setup(t);
  const port = await env.fake.listen();
  const client = new KosTelnet({ port });
  await client.connect();
  t.after(() => client.close());
  await client.waitForMenu(2000);
  await until(() => env.fake.negotiation.naws && env.fake.negotiation.termtype);
  assert.deepEqual(env.fake.negotiation.naws, { columns: 120, rows: 40 });
  assert.equal(env.fake.negotiation.termtype, 'XTERM');
  const [session] = env.fake.sessions;
  env.fake.keepalive(session);
  await until(() => env.fake.negotiation.termtype === 'XTERM');
});

test('run: syncs scripts, loads the save, runs the test and reports PASS', async (t) => {
  const env = setup(t);
  const result = await drive(env, ['run', 'pad-launch']);
  assert.equal(result.code, 0, result.out + result.err);
  assert.match(result.out, /PASS {2}pad-launch \(save "__test_pad"\)/);
  assert.match(result.out, /\[PASS\] Periapsis - 80100\.0 m/);
  assert.match(result.out, /\[!\] Apoapsis/);
  assert.deepEqual(env.fake.loads, ['__test_pad']);
  assert.ok(fs.existsSync(path.join(env.scriptDir, 'tests', 'pad_launch.ks')), 'tests synced');
  assert.ok(fs.existsSync(path.join(env.scriptDir, 'lib', 'telemetry.ks')), 'libs synced');
  const options = JSON.parse(fs.readFileSync(path.join(env.scriptDir, 'tests', 'options', 'pad-launch.json'), 'utf8'));
  assert.equal(options.$type, 'kOS.Safe.Encapsulation.Lexicon');
  assert.deepEqual(options.entries, ['heading', 90, 'target_altitude', 80000, 'half_dv_timing', true]);
  const kept = fs.readdirSync(env.runsDir);
  assert.ok(kept.some((name) => name.endsWith('-pad-launch.log')), 'log copied into the runs folder');
  assert.ok(kept.some((name) => name.endsWith('-pad-launch.screen.txt')), 'screen transcript written');
  const runLine = env.fake.typed.find((line) => line.startsWith('RUNPATH('));
  assert.match(runLine, /^RUNPATH\("0:\/tests\/pad_launch\.ks", "pad-launch", "[0-9a-f]{8}"\)\.$/);
  assert.equal(env.fake.typed.at(-1), runLine, 'no commands are queued behind RUNPATH');
});

test('run: a failed check fails the test', async (t) => {
  const env = setup(t, { programs: { 'tests/smoke.ks': { outcome: 'fail' } } });
  const result = await drive(env, ['run', 'smoke']);
  assert.equal(result.code, 1);
  assert.match(result.out, /FAIL {2}smoke/);
  assert.match(result.out, /\[FAIL\] Periapsis - 61000\.0 m, minimum 75000 m/);
});

test('run: a script that stops on a kOS error is reported straight away', async (t) => {
  const env = setup(t, { programs: { 'tests/smoke.ks': { outcome: 'crash' } } });
  const started = Date.now();
  const result = await drive(env, ['run', 'smoke']);
  assert.equal(result.code, 1);
  assert.match(result.out, /ended without TEST-DONE/);
  assert.ok(Date.now() - started < 4000, 'did not wait for the time limit');
});

test('run: a script that never finishes is stopped with Ctrl-C at the time limit', async (t) => {
  const env = setup(t, { programs: { 'tests/smoke.ks': { outcome: 'hang' } } });
  const result = await drive(env, ['run', 'smoke', '--timeout', '1']);
  assert.equal(result.code, 1);
  assert.match(result.out, /Timed out after 1 s; sent Ctrl-C to stop the script\. The CPU is back at the kOS prompt\./);
  assert.equal(env.fake.interrupts, 1);
});

test('run: a log that could not be copied to the archive fails', async (t) => {
  const env = setup(t, { programs: { 'tests/smoke.ks': { outcome: 'pass', copied: false } } });
  const result = await drive(env, ['run', 'smoke']);
  assert.equal(result.code, 1);
  assert.match(result.out, /not copied to the archive/);
});

test('run: refuses when only the unprefixed save exists', async (t) => {
  const env = setup(t, { saves: ['rdv-parking'] });
  const result = await drive(env, ['run', 'orbit']);
  assert.equal(result.code, 2);
  assert.match(result.out, /save "__test_rdv-parking" is not in this game's saves/);
  assert.deepEqual(env.fake.loads, []);
});

test('run: refuses when a script is already running on the CPU', async (t) => {
  const env = setup(t, { cpus: [{ vessel: 'Test Rocket', tag: 'test', busy: true }] });
  const result = await drive(env, ['run', 'smoke']);
  assert.equal(result.code, 2);
  assert.match(result.out, /a script is probably running/);
  assert.ok(!env.fake.typed.some((line) => line.includes('QUICKLOADFROM')), 'never typed a load');
});

test('run: refuses a CPU that already has a telnet connection or is ambiguous', async (t) => {
  const busy = setup(t, { cpus: [{ vessel: 'Test Rocket', tag: 'test', telnets: 1 }] });
  let result = await drive(busy, ['run', 'smoke']);
  assert.equal(result.code, 2);
  assert.match(result.out, /already has 1 telnet connection/);

  const twice = setup(t, { cpus: [{ vessel: 'A', tag: 'test' }, { vessel: 'B', tag: 'test' }] });
  result = await drive(twice, ['run', 'smoke']);
  assert.equal(result.code, 2);
  assert.match(result.out, /2 CPUs match processor tag "test"/);
});

test('run: unknown test ids are a usage error', async (t) => {
  const env = setup(t);
  const result = await drive(env, ['run', 'nope']);
  assert.equal(result.code, 2);
  assert.match(result.err, /unknown test "nope"/);
});

test('run and save can use the only listed untagged CPU', async (t) => {
  const env = setup(t, {
    cpus: [{ vessel: 'Test Rocket', tag: '' }],
    saves: [],
    tests: { smoke: { script: 'tests/smoke.ks', save: 'pad', timeout_s: 5 } },
  });
  const saved = await drive(env, ['save', 'pad', '--yes']);
  assert.equal(saved.code, 0, saved.out + saved.err);
  const run = await drive(env, ['run', 'smoke']);
  assert.equal(run.code, 0, run.out + run.err);
});

test('run requires a selector for multiple CPUs and accepts a tag override', async (t) => {
  const smoke = { script: 'tests/smoke.ks', save: 'pad', timeout_s: 5 };
  const env = setup(t, {
    cpus: [{ vessel: 'Wrong CPU', tag: 'test', busy: true }, { vessel: 'Test Rocket', tag: 'chaser' }],
    tests: { smoke, configured: { ...smoke, cpu: { tag: 'test' } } },
  });
  const refused = await drive(env, ['run', 'smoke']);
  assert.equal(refused.code, 2, refused.out);
  assert.match(refused.out, /2 CPUs are listed/);
  assert.deepEqual(env.fake.loads, []);
  const run = await drive(env, ['run', 'configured', '--cpu-tag', 'chaser']);
  assert.equal(run.code, 0, run.out + run.err);
});

test('save: makes the prefixed save even if the unprefixed save exists', async (t) => {
  const env = setup(t, { saves: ['pad'] });
  const result = await drive(env, ['save', 'pad', '--yes']);
  assert.equal(result.code, 0, result.out + result.err);
  assert.deepEqual(env.fake.savedTo, ['__test_pad']);
  assert.match(result.out, /Saved "__test_pad": Test Rocket, PRELAUNCH at Kerbin, UT 12345\.6 s/);
  assert.match(result.out, /Used by: smoke, pad-launch/);
});

test('save: refuses to overwrite without --force, and replaces with it', async (t) => {
  const env = setup(t);
  let result = await drive(env, ['save', 'pad', '--yes']);
  assert.equal(result.code, 2);
  assert.match(result.out, /already exists\. Pass --force/);
  assert.deepEqual(env.fake.savedTo, []);
  result = await drive(env, ['save', 'pad', '--yes', '--force']);
  assert.equal(result.code, 0, result.out);
  assert.match(result.out, /replaced the old save/);
});

test('save: refuses names no test uses, reserved names and unconfirmed runs', async (t) => {
  const env = setup(t, { saves: [] });
  let result = await drive(env, ['save', 'random', '--yes']);
  assert.equal(result.code, 2);
  assert.match(result.err, /no test in the test list uses save "random"/);
  result = await drive(env, ['save', 'quicksave', '--yes']);
  assert.equal(result.code, 2);
  assert.match(result.err, /reserved/);
  result = await drive(env, ['save', 'pad']);
  assert.equal(result.code, 2);
  assert.match(result.err, /not confirmed/);
  assert.deepEqual(env.fake.savedTo, []);
});

test('save: refuses while KSP does not allow saving or time warp is on', async (t) => {
  const env = setup(t, { saves: [], values: { 'KUNIVERSE:CANQUICKSAVE': 'False', 'KUNIVERSE:TIMEWARP:RATE': '50' } });
  const result = await drive(env, ['save', 'pad', '--yes']);
  assert.equal(result.code, 2);
  assert.match(result.out, /doesn't allow saving right now/);
  assert.match(result.out, /time warp is 50x/);
  assert.deepEqual(env.fake.savedTo, []);
});

test('report-only summarises an existing log', async (t) => {
  const env = setup(t);
  const log = path.join(env.root, 'x.log');
  fs.writeFileSync(log, '1 [PASS] A - fine\n2 [FAIL] B - 3 m, limit 2 m\n');
  const result = await drive(env, ['run', '--report-only', log]);
  assert.equal(result.code, 1);
  assert.match(result.out, /^FAIL/);
  assert.match(result.out, /\[FAIL\] B - 3 m, limit 2 m/);
});

test('fake server sends the kOS clear-screen sequence the emulator understands', () => {
  const screen = new Screen(40, 5);
  screen.write(`old\r\n${CLEAR}new`);
  assert.deepEqual(screen.visibleLines(), ['new']);
});
