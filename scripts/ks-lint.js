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

function braceDeltaOutsideStrings(code) {
  let delta = 0;
  let inString = false;
  for (let index = 0; index < code.length; index += 1) {
    const character = code[index];
    if (character === '"') inString = !inString;
    if (inString) continue;
    if (character === '{') delta += 1;
    else if (character === '}') delta -= 1;
  }
  return delta;
}

function scanGlobalSymbols(file) {
  const functions = [];
  const parameters = [];
  let braceDepth = 0;
  const lines = readFileSync(file, 'utf8').split(/\r?\n/);

  for (let index = 0; index < lines.length; index += 1) {
    const code = lines[index].replace(/\/\/.*$/, '');
    if (braceDepth === 0) {
      const functionMatch = code.match(/^\s*FUNCTION\s+([A-Za-z_][A-Za-z0-9_]*)\b/i);
      const parameterMatch = code.match(/^\s*PARAMETER\s+([A-Za-z_][A-Za-z0-9_]*)\b/i);
      if (functionMatch) functions.push({ name: functionMatch[1], file, line: index + 1 });
      if (parameterMatch) parameters.push({ name: parameterMatch[1], file, line: index + 1 });
    }
    braceDepth += braceDeltaOutsideStrings(code);
  }

  return { functions, parameters };
}

function findGlobalFunctionParameterCollisions(files) {
  const functionsByName = new Map();
  const parametersByName = new Map();

  for (const file of files) {
    const symbols = scanGlobalSymbols(file);
    for (const symbol of symbols.functions) {
      const key = symbol.name.toLowerCase();
      if (!functionsByName.has(key)) functionsByName.set(key, []);
      functionsByName.get(key).push(symbol);
    }
    for (const symbol of symbols.parameters) {
      const key = symbol.name.toLowerCase();
      if (!parametersByName.has(key)) parametersByName.set(key, []);
      parametersByName.get(key).push(symbol);
    }
  }

  const collisions = [];
  for (const [name, functions] of functionsByName) {
    const parameters = parametersByName.get(name);
    if (parameters) collisions.push({ name, functions, parameters });
  }
  return collisions;
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

  const symbolCollisions = findGlobalFunctionParameterCollisions(files);
  if (symbolCollisions.length > 0) {
    for (const collision of symbolCollisions) {
      for (const fn of collision.functions) {
        for (const parameter of collision.parameters) {
          console.log(`${fn.file}:${fn.line}:1: error: Global function ${fn.name} collides with top-level parameter at ${parameter.file}:${parameter.line}; kOS RUNPATH shares the caller's global scope.`);
        }
      }
    }
    process.exit(1);
  }

  const klsBin = process.platform === 'win32'
    ? process.execPath
    : resolve(__dirname, '../node_modules/.bin/kls');
  const klsArgs = process.platform === 'win32'
    ? [resolve(__dirname, '../node_modules/kos-language-server/bin/kos'), '--stdio']
    : ['--stdio'];
  const server = spawn(klsBin, klsArgs, { stdio: ['pipe', 'pipe', 'inherit'] });

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
    settleTimer = setTimeout(finish, 500);
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

if (require.main === module) main();

module.exports = {
  findGlobalFunctionParameterCollisions,
  scanGlobalSymbols,
};
