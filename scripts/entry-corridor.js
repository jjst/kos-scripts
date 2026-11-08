#!/usr/bin/env node

"use strict";

const KERBIN_MU = 3.5316e12;
const KERBIN_RADIUS_M = 600000;
const KERBIN_ROTATION_PERIOD_S = 21549.425;

function interfaceState(mu, burnRadiusM, tangentialSpeedMps, interfaceRadiusM, rotationPeriodS = Infinity) {
  const specificEnergy = tangentialSpeedMps ** 2 / 2 - mu / burnRadiusM;
  const specificAngularMomentum = burnRadiusM * tangentialSpeedMps;
  const speedSquared = 2 * (specificEnergy + mu / interfaceRadiusM);
  const tangentialSpeed = specificAngularMomentum / interfaceRadiusM;
  const radialSpeedSquared = speedSquared - tangentialSpeed ** 2;
  if (!(speedSquared > 0) || !(radialSpeedSquared > 0)) {
    return { crosses: false, flightPathAngleDownDeg: 0 };
  }
  const radialSpeedDown = Math.sqrt(radialSpeedSquared);
  const surfaceRotationSpeedMps = Number.isFinite(rotationPeriodS)
    ? 2 * Math.PI * interfaceRadiusM / rotationPeriodS
    : 0;
  const surfaceTangentialSpeedMps = tangentialSpeed - surfaceRotationSpeedMps;
  return {
    crosses: true,
    speedMps: Math.sqrt(speedSquared),
    tangentialSpeedMps: tangentialSpeed,
    surfaceTangentialSpeedMps,
    radialSpeedDownMps: radialSpeedDown,
    orbitalFlightPathAngleDownDeg: Math.atan2(radialSpeedDown, tangentialSpeed) * 180 / Math.PI,
    flightPathAngleDownDeg: Math.atan2(radialSpeedDown, Math.abs(surfaceTangentialSpeedMps)) * 180 / Math.PI,
  };
}

function periapsisRadius(mu, burnRadiusM, tangentialSpeedMps) {
  const specificEnergy = tangentialSpeedMps ** 2 / 2 - mu / burnRadiusM;
  const specificAngularMomentum = burnRadiusM * tangentialSpeedMps;
  if (!(specificEnergy < 0)) return null;
  const semiMajorAxis = -mu / (2 * specificEnergy);
  const eccentricity = Math.sqrt(1 + 2 * specificEnergy * specificAngularMomentum ** 2 / mu ** 2);
  return semiMajorAxis * (1 - eccentricity);
}

function solveCircularRetrogradeBurn({
  mu,
  burnRadiusM,
  interfaceRadiusM,
  targetFlightPathAngleDownDeg,
  rotationPeriodS = Infinity,
}) {
  const circularSpeedMps = Math.sqrt(mu / burnRadiusM);
  let lowSpeed = circularSpeedMps * 0.5;
  let highSpeed = circularSpeedMps;
  const lowState = interfaceState(mu, burnRadiusM, lowSpeed, interfaceRadiusM, rotationPeriodS);
  if (!lowState.crosses || lowState.flightPathAngleDownDeg < targetFlightPathAngleDownDeg) {
    throw new Error("target flight-path angle is outside the solver bracket");
  }
  for (let i = 0; i < 100; i += 1) {
    const candidateSpeed = (lowSpeed + highSpeed) / 2;
    const candidateState = interfaceState(mu, burnRadiusM, candidateSpeed, interfaceRadiusM, rotationPeriodS);
    if (candidateState.crosses && candidateState.flightPathAngleDownDeg > targetFlightPathAngleDownDeg) {
      lowSpeed = candidateSpeed;
    } else {
      highSpeed = candidateSpeed;
    }
  }
  const postBurnSpeedMps = (lowSpeed + highSpeed) / 2;
  return {
    circularSpeedMps,
    postBurnSpeedMps,
    retrogradeBurnMps: circularSpeedMps - postBurnSpeedMps,
    interface: interfaceState(mu, burnRadiusM, postBurnSpeedMps, interfaceRadiusM, rotationPeriodS),
    periapsisRadiusM: periapsisRadius(mu, burnRadiusM, postBurnSpeedMps),
  };
}

function parseArgs(argv) {
  const result = { parkingAltM: 100000, entryAltM: 70000, targetFpaDeg: 2.9 };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--parking-alt") result.parkingAltM = Number(argv[++i]);
    else if (argv[i] === "--entry-alt") result.entryAltM = Number(argv[++i]);
    else if (argv[i] === "--target-fpa") result.targetFpaDeg = Number(argv[++i]);
  }
  return result;
}

function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const solution = solveCircularRetrogradeBurn({
    mu: KERBIN_MU,
    burnRadiusM: KERBIN_RADIUS_M + args.parkingAltM,
    interfaceRadiusM: KERBIN_RADIUS_M + args.entryAltM,
    targetFlightPathAngleDownDeg: args.targetFpaDeg,
    rotationPeriodS: KERBIN_ROTATION_PERIOD_S,
  });
  console.log(`Kerbin circular orbit ${args.parkingAltM / 1000} km -> ${args.targetFpaDeg} deg surface-relative down at ${args.entryAltM / 1000} km`);
  console.log(`Retrograde burn: ${solution.retrogradeBurnMps.toFixed(2)} m/s`);
  console.log(`Post-burn periapsis: ${(solution.periapsisRadiusM - KERBIN_RADIUS_M).toFixed(0)} m`);
  console.log(`Interface orbital speed: ${solution.interface.speedMps.toFixed(2)} m/s (${solution.interface.radialSpeedDownMps.toFixed(2)} m/s down)`);
  console.log(`Interface FPA: ${solution.interface.flightPathAngleDownDeg.toFixed(3)} deg surface / ${solution.interface.orbitalFlightPathAngleDownDeg.toFixed(3)} deg orbital`);
}

if (require.main === module) main();

module.exports = {
  interfaceState,
  periapsisRadius,
  solveCircularRetrogradeBurn,
  KERBIN_ROTATION_PERIOD_S,
};
