#!/usr/bin/env node
'use strict';

const { spawn } = require('child_process');
const { readFileSync, readdirSync, statSync } = require('fs');
const { resolve, join, extname } = require('path');
const { pathToFileURL, fileURLToPath } = require('url');

function findKsFiles(dir) {
  const results = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry.startsWith('.')) continue;
    const full = join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      results.push(...findKsFiles(full));
    } else if (extname(entry) === '.ks') {
      results.push(resolve(full));
    }
  }
  return results;
}

function encode(msg) {
  const body = JSON.stringify(msg);
  return `Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`;
}

function main() {
  const strict = process.argv.includes('--strict');
  const root = process.cwd();
  const files = findKsFiles(root);

  if (files.length === 0) {
    console.log('No .ks files found.');
    process.exit(0);
  }

  console.log(`Checking ${files.length} file(s)...`);

  const klsBin = resolve(__dirname, `../node_modules/.bin/${process.platform === 'win32' ? 'kls.cmd' : 'kls'}`);
  const server = spawn(klsBin, ['--stdio'], { stdio: ['pipe', 'pipe', 'inherit'] });

  const fileUris = new Set(files.map(f => pathToFileURL(f).href));
  const seen = new Set();
  const allDiagnostics = new Map();
  let settleTimer = null;
  let initializeId = null;
  let msgId = 0;
  let finished = false;

  function send(msg) {
    server.stdin.write(encode(msg));
  }

  function finish() {
    if (finished) return;
    finished = true;
    clearTimeout(settleTimer);
    server.kill();

    let hasErrors = false;
    let hasDiagnostics = false;
    for (const [uri, diags] of allDiagnostics) {
      const errors = diags.filter(d => d.severity === 1);
      const warnings = diags.filter(d => d.severity === 2);
      if (errors.length === 0 && warnings.length === 0) continue;

      hasDiagnostics = true;
      const filePath = fileURLToPath(uri);
      for (const d of [...errors, ...warnings]) {
        const level = d.severity === 1 ? 'error' : 'warning';
        const line = d.range.start.line + 1;
        const col = d.range.start.character + 1;
        console.log(`${filePath}:${line}:${col}: ${level}: ${d.message}`);
      }
      if (errors.length > 0) hasErrors = true;
      if (strict && warnings.length > 0) hasErrors = true;
    }

    if (!hasDiagnostics) {
      console.log('No errors or warnings found.');
    }

    process.exit(hasErrors ? 1 : 0);
  }

  function scheduleSettle() {
    clearTimeout(settleTimer);
    // Wait for any follow-up diagnostics before declaring done
    settleTimer = setTimeout(finish, 1500);
  }

  let buf = Buffer.alloc(0);
  server.stdout.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);

    while (true) {
      const headerEnd = buf.indexOf('\r\n\r\n');
      if (headerEnd === -1) break;

      const header = buf.slice(0, headerEnd).toString('utf8');
      const match = header.match(/Content-Length: (\d+)/i);
      if (!match) { buf = buf.slice(headerEnd + 4); continue; }

      const len = parseInt(match[1], 10);
      const msgStart = headerEnd + 4;
      if (buf.length < msgStart + len) break;

      const body = buf.slice(msgStart, msgStart + len).toString('utf8');
      buf = buf.slice(msgStart + len);

      let msg;
      try { msg = JSON.parse(body); } catch { continue; }

      if (msg.id === initializeId && msg.result) {
        send({ jsonrpc: '2.0', method: 'initialized', params: {} });
        // Open ksconfig.json first so the LSP applies linting rules before
        // diagnosing .ks files, avoiding a stale-config race condition.
        const ksconfigPath = resolve(root, 'ksconfig.json');
        const { existsSync } = require('fs');
        if (existsSync(ksconfigPath)) {
          send({
            jsonrpc: '2.0',
            method: 'textDocument/didOpen',
            params: {
              textDocument: {
                uri: pathToFileURL(ksconfigPath).href,
                languageId: 'json',
                version: 1,
                text: readFileSync(ksconfigPath, 'utf8'),
              },
            },
          });
        }
        for (const f of files) {
          send({
            jsonrpc: '2.0',
            method: 'textDocument/didOpen',
            params: {
              textDocument: {
                uri: pathToFileURL(f).href,
                languageId: 'kos',
                version: 1,
                text: readFileSync(f, 'utf8'),
              },
            },
          });
        }
      }

      if (msg.method === 'textDocument/publishDiagnostics') {
        const { uri, diagnostics } = msg.params;
        if (fileUris.has(uri)) {
          allDiagnostics.set(uri, diagnostics);
          seen.add(uri);
          if (seen.size === fileUris.size) {
            scheduleSettle();
          }
        }
      }
    }
  });

  server.on('error', (err) => {
    console.error('Failed to start kls:', err.message);
    process.exit(2);
  });

  server.on('close', (code) => {
    if (!finished) {
      console.error(`kls exited unexpectedly with code ${code}`);
      process.exit(2);
    }
  });

  setTimeout(() => {
    console.error('Timeout: diagnostics not received within 30s');
    server.kill();
    process.exit(2);
  }, 30000);

  initializeId = ++msgId;
  send({
    jsonrpc: '2.0',
    id: initializeId,
    method: 'initialize',
    params: {
      processId: process.pid,
      rootUri: pathToFileURL(root).href,
      capabilities: {
        textDocument: {
          publishDiagnostics: { relatedInformation: false },
        },
      },
    },
  });
}

main();
