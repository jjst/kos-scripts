"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  interfaceState,
  solveCircularRetrogradeBurn,
  KERBIN_ROTATION_PERIOD_S,
} = require("./entry-corridor.js");

const MU = 3.5316e12;
const RADIUS = 600000;

test("a circular 100 km orbit does not yet cross the 70 km interface", () => {
  const burnRadius = RADIUS + 100000;
  const state = interfaceState(MU, burnRadius, Math.sqrt(MU / burnRadius), RADIUS + 70000);
  assert.equal(state.crosses, false);
  assert.equal(state.flightPathAngleDownDeg, 0);
});

test("solves the 2.9 degree surface-relative Kerbin entry corridor used by deorbit.ks", () => {
  const result = solveCircularRetrogradeBurn({
    mu: MU,
    burnRadiusM: RADIUS + 100000,
    interfaceRadiusM: RADIUS + 70000,
    targetFlightPathAngleDownDeg: 2.9,
    rotationPeriodS: KERBIN_ROTATION_PERIOD_S,
  });
  assert.ok(Math.abs(result.retrogradeBurnMps - 52.6296) < 0.01);
  assert.ok(Math.abs(result.interface.flightPathAngleDownDeg - 2.9) < 1e-9);
  assert.ok(result.interface.orbitalFlightPathAngleDownDeg < 2.9);
  assert.ok(Math.abs((result.periapsisRadiusM - RADIUS) - 38031) < 1);
});

test("surface-relative FPA accounts for Kerbin rotation", () => {
  const burnRadius = RADIUS + 100000;
  const interfaceRadius = RADIUS + 70000;
  const postBurnSpeed = Math.sqrt(MU / burnRadius) - 52.6296;
  const inertial = interfaceState(MU, burnRadius, postBurnSpeed, interfaceRadius);
  const surface = interfaceState(
    MU,
    burnRadius,
    postBurnSpeed,
    interfaceRadius,
    KERBIN_ROTATION_PERIOD_S,
  );
  assert.equal(inertial.flightPathAngleDownDeg, inertial.orbitalFlightPathAngleDownDeg);
  assert.ok(surface.flightPathAngleDownDeg > surface.orbitalFlightPathAngleDownDeg);
  assert.ok(Math.abs(surface.flightPathAngleDownDeg - 2.9) < 0.001);
});
