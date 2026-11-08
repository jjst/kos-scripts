"use strict";

const assert = require("node:assert/strict");
const { mkdtempSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const test = require("node:test");

const { findGlobalFunctionParameterCollisions, scanGlobalSymbols } = require("./ks-lint");

test("detects a global function colliding with a RUNPATH script parameter", () => {
  const directory = mkdtempSync(join(tmpdir(), "kos-lint-"));
  const caller = join(directory, "caller.ks");
  const callee = join(directory, "callee.ks");
  writeFileSync(caller, "FUNCTION predicted_value {\n  PARAMETER altitude.\n  RETURN altitude.\n}\n");
  writeFileSync(callee, "PARAMETER predicted_value IS -1.\n");

  const collisions = findGlobalFunctionParameterCollisions([caller, callee]);
  assert.equal(collisions.length, 1);
  assert.equal(collisions[0].name, "predicted_value");
});

test("ignores function-local parameters", () => {
  const directory = mkdtempSync(join(tmpdir(), "kos-lint-"));
  const script = join(directory, "script.ks");
  writeFileSync(script, "FUNCTION convert_value {\n  PARAMETER convert_value.\n  RETURN convert_value.\n}\n");

  const symbols = scanGlobalSymbols(script);
  assert.deepEqual(symbols.parameters, []);
  assert.deepEqual(findGlobalFunctionParameterCollisions([script]), []);
});
