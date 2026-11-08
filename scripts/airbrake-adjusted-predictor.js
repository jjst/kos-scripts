#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const { parseCsv } = require("./telemetry-csv.js");

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function canonicalProfileKey(value) {
  if (!value) return null;
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return null;
  }
}

function profileAdaptationForContext(predictor, context = {}) {
  const requestedProfileKey = canonicalProfileKey(context.profile_key);
  return (predictor.profile_adaptations ?? []).find((adaptation) =>
    (!requestedProfileKey || canonicalProfileKey(adaptation.profile_key) === requestedProfileKey)
    && (!context.profile_id || adaptation.profile_id === context.profile_id)
    && (!context.corridor_id || adaptation.entry_corridor_id === context.corridor_id)) ?? null;
}

function predictorForContext(predictor, context = {}) {
  const adaptation = profileAdaptationForContext(predictor, context);
  if (!adaptation?.trajectories_along_rate_model) return predictor;
  return {
    ...predictor,
    domain: adaptation.domain ?? predictor.domain,
    trajectories_domain: adaptation.trajectories_domain ?? adaptation.domain ?? predictor.trajectories_domain ?? predictor.domain,
    trajectories_along_rate_model: adaptation.trajectories_along_rate_model,
    active_profile_adaptation: {
      profile_id: adaptation.profile_id,
      profile_key: adaptation.profile_key,
      entry_corridor_id: adaptation.entry_corridor_id,
      angle_anchors_deg: adaptation.angle_anchors_deg,
      warning: adaptation.warning,
    },
  };
}

function inRange(value, limits) {
  if (!Array.isArray(limits) || limits.length !== 2 || !limits.every(finite)) return true;
  if (!finite(value)) return false;
  // A single run can produce a zero-width mass/count domain. Allow only a tiny
  // floating-point/paired-run tolerance, not meaningful physical extrapolation.
  const center = (limits[0] + limits[1]) / 2;
  const tolerance = Math.max(Math.abs(center) * 1e-4, Math.abs(limits[1] - limits[0]) * 1e-6, 1e-9);
  return value >= limits[0] - tolerance && value <= limits[1] + tolerance;
}

function stateInCalibrationDomain(predictor, state) {
  const domain = predictor.trajectories_domain ?? predictor.domain ?? {};
  return inRange(state.altitude_m, domain.altitude_m)
    && inRange(state.mach, domain.mach)
    && inRange(state.dynamic_pressure_kpa, domain.dynamic_pressure_kpa)
    && inRange(state.mass_t, domain.mass_t)
    && inRange(state.airbrake_count, domain.airbrake_count);
}

function extraDragDeceleration(predictor, state, angleDeg) {
  const model = predictor.extra_drag_model;
  if (!model) throw new Error("predictor has no extra-drag model");
  const angleFactor = Math.sin(angleDeg * Math.PI / 180) ** model.angle_sine_exponent;
  const cdaPerBrake = model.cda_at_mach_center_m2
    + model.cda_mach_slope_m2_per_mach * (state.mach - model.mach_center);
  return state.dynamic_pressure_kpa * state.airbrake_count / state.mass_t * angleFactor * cdaPerBrake;
}

function extraTrajectoriesAlongRate(predictor, state, angleDeg) {
  const model = predictor.trajectories_along_rate_model;
  if (!model) throw new Error("predictor has no Trajectories along-rate model");
  const angleFactor = Math.sin(angleDeg * Math.PI / 180) ** model.angle_sine_exponent;
  const altitudeFactor = Math.exp(model.altitude_log_slope_per_km
    * (state.altitude_m / 1000 - model.altitude_center_km));
  return model.scale * state.dynamic_pressure_kpa * state.airbrake_count / state.mass_t
    * angleFactor * altitudeFactor;
}

function validateState(state, index) {
  for (const field of ["time_s", "altitude_m", "mach", "dynamic_pressure_kpa", "mass_t", "airbrake_count"]) {
    if (!finite(state[field])) throw new Error(`future state ${index} has no finite ${field}`);
  }
  if (!(state.mass_t > 0) || !(state.airbrake_count > 0) || state.dynamic_pressure_kpa < 0) {
    throw new Error(`future state ${index} has invalid mass, airbrake count, or dynamic pressure`);
  }
}

function integrateRemainingCorrection(predictor, futureStates, angle, options = {}) {
  const domainPolicy = options.domainPolicy ?? "strict";
  if (!["strict", "clip", "extrapolate"].includes(domainPolicy)) throw new Error(`unknown domain policy: ${domainPolicy}`);
  if (!Array.isArray(futureStates) || futureStates.length < 2) throw new Error("at least two future states are required");
  const states = [...futureStates].sort((a, b) => a.time_s - b.time_s);
  states.forEach(validateState);
  const angleAt = typeof angle === "function" ? angle : () => angle;
  let correctionM = 0;
  let coveredDurationS = 0;
  let totalDurationS = 0;
  let skippedSegments = 0;
  let extrapolatedSegments = 0;

  for (let index = 1; index < states.length; index += 1) {
    const previous = states[index - 1];
    const current = states[index];
    const dt = current.time_s - previous.time_s;
    if (!(dt > 0)) continue;
    totalDurationS += dt;
    const inside = stateInCalibrationDomain(predictor, previous) && stateInCalibrationDomain(predictor, current);
    if (!inside && domainPolicy === "strict") {
      throw new Error(`future segment ${index - 1}-${index} leaves the predictor calibration domain`);
    }
    if (!inside && domainPolicy === "clip") {
      skippedSegments += 1;
      continue;
    }
    if (!inside) extrapolatedSegments += 1;
    const previousRate = extraTrajectoriesAlongRate(predictor, previous, angleAt(previous));
    const currentRate = extraTrajectoriesAlongRate(predictor, current, angleAt(current));
    correctionM += (previousRate + currentRate) / 2 * dt;
    coveredDurationS += dt;
  }

  return {
    remaining_correction_m: correctionM,
    covered_duration_s: coveredDurationS,
    total_duration_s: totalDurationS,
    coverage_fraction: totalDurationS > 0 ? coveredDurationS / totalDurationS : 0,
    skipped_segments: skippedSegments,
    extrapolated_segments: extrapolatedSegments,
    domain_policy: domainPolicy,
    complete: skippedSegments === 0,
    interpretation: skippedSegments > 0 ? "calibrated-domain lower bound" : extrapolatedSegments > 0 ? "explicit extrapolation" : "within calibrated domain",
  };
}

function adjustedTrajectoriesAlongMiss(currentAlongMissM, integration) {
  if (!finite(currentAlongMissM)) throw new Error("current Trajectories along miss must be finite");
  return currentAlongMissM + integration.remaining_correction_m;
}

function solveFixedAngleForCorrection(predictor, futureStates, targetCorrectionM, options = {}) {
  if (!(targetCorrectionM >= 0)) throw new Error("target correction must be non-negative");
  const minimumAngleDeg = options.minimumAngleDeg ?? 0;
  const maximumAngleDeg = options.maximumAngleDeg ?? 90;
  const integrationOptions = { domainPolicy: options.domainPolicy ?? "strict" };
  const atMinimum = integrateRemainingCorrection(predictor, futureStates, minimumAngleDeg, integrationOptions);
  const atMaximum = integrateRemainingCorrection(predictor, futureStates, maximumAngleDeg, integrationOptions);
  if (targetCorrectionM <= atMinimum.remaining_correction_m) return { angle_deg: minimumAngleDeg, saturated: targetCorrectionM < atMinimum.remaining_correction_m, integration: atMinimum };
  if (targetCorrectionM >= atMaximum.remaining_correction_m) return { angle_deg: maximumAngleDeg, saturated: targetCorrectionM > atMaximum.remaining_correction_m, integration: atMaximum };
  let low = minimumAngleDeg;
  let high = maximumAngleDeg;
  let result = atMaximum;
  for (let iteration = 0; iteration < 50; iteration += 1) {
    const candidate = (low + high) / 2;
    result = integrateRemainingCorrection(predictor, futureStates, candidate, integrationOptions);
    if (result.remaining_correction_m < targetCorrectionM) low = candidate;
    else high = candidate;
  }
  return { angle_deg: (low + high) / 2, saturated: false, integration: result };
}

function statePathFromSamples(samples, runId, startAltitudeKm, endAltitudeKm) {
  return samples.filter((row) => String(row.run_id) === String(runId)
    && row.phase === "entry"
    && row.altitude_asl_m <= startAltitudeKm * 1000
    && row.altitude_asl_m >= endAltitudeKm * 1000)
    .sort((a, b) => a.time_s - b.time_s)
    .map((row) => ({
      time_s: row.time_s,
      altitude_m: row.altitude_asl_m,
      mach: row.mach_model,
      dynamic_pressure_kpa: row.dynamic_pressure_kpa,
      mass_t: row.mass_t,
      airbrake_count: row.airbrake_part_count,
      trajectories_along_miss_m: row.impact_along_miss_m,
      profile_id: row.trajectories_profile_id,
      corridor_id: row.entry_corridor_id,
    }));
}

function parseArgs(argv) {
  const options = {
    model: "telemetry/airbrake_predictor.json",
    samples: "telemetry/reentry_samples.csv",
    run: null,
    startAltitudeKm: 60,
    endAltitudeKm: 20,
    angleDeg: 60,
    currentMissM: null,
    targetCorrectionM: null,
    domainPolicy: "clip",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key === "--model") options.model = argv[++index];
    else if (key === "--samples") options.samples = argv[++index];
    else if (key === "--run") options.run = argv[++index];
    else if (key === "--start-alt") options.startAltitudeKm = Number(argv[++index]);
    else if (key === "--end-alt") options.endAltitudeKm = Number(argv[++index]);
    else if (key === "--angle") options.angleDeg = Number(argv[++index]);
    else if (key === "--current-miss") options.currentMissM = Number(argv[++index]);
    else if (key === "--target-correction") options.targetCorrectionM = Number(argv[++index]);
    else if (key === "--domain-policy") options.domainPolicy = argv[++index];
    else throw new Error(`unknown option: ${key}`);
  }
  return options;
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const predictor = JSON.parse(fs.readFileSync(options.model, "utf8"));
  const samples = parseCsv(fs.readFileSync(options.samples, "utf8"));
  const defaultRun = predictor.selected_runs?.find((run) => run.mode === "off")?.run_id;
  const runId = options.run ?? defaultRun;
  if (!runId) throw new Error("no reference run supplied and predictor has no selected off run");
  const states = statePathFromSamples(samples, runId, options.startAltitudeKm, options.endAltitudeKm);
  if (states.length < 2) throw new Error(`run ${runId} has no usable future state path in the requested altitude range`);
  const activePredictor = predictorForContext(predictor, {
    profile_id: states[0].profile_id,
    corridor_id: states[0].corridor_id,
  });
  const currentMissM = options.currentMissM ?? states[0].trajectories_along_miss_m ?? 0;
  if (finite(options.targetCorrectionM)) {
    const solution = solveFixedAngleForCorrection(activePredictor, states, options.targetCorrectionM, { domainPolicy: options.domainPolicy });
    console.log(`Reference run: ${runId} | ${options.startAltitudeKm}-${options.endAltitudeKm} km`);
    if (activePredictor.active_profile_adaptation) console.log(`Profile adaptation: ${activePredictor.active_profile_adaptation.profile_id}/${activePredictor.active_profile_adaptation.entry_corridor_id} anchored at ${activePredictor.active_profile_adaptation.angle_anchors_deg.join(", ")} deg`);
    console.log(`Angle for ${(options.targetCorrectionM / 1000).toFixed(1)} km remaining correction: ${solution.angle_deg.toFixed(2)} deg${solution.saturated ? " (saturated)" : ""}`);
    console.log(`Coverage: ${(solution.integration.coverage_fraction * 100).toFixed(1)}% | ${solution.integration.interpretation}`);
    return 0;
  }
  const integration = integrateRemainingCorrection(activePredictor, states, options.angleDeg, { domainPolicy: options.domainPolicy });
  const adjusted = adjustedTrajectoriesAlongMiss(currentMissM, integration);
  console.log(`Reference run: ${runId} | ${options.startAltitudeKm}-${options.endAltitudeKm} km | fixed ${options.angleDeg} deg`);
  if (activePredictor.active_profile_adaptation) console.log(`Profile adaptation: ${activePredictor.active_profile_adaptation.profile_id}/${activePredictor.active_profile_adaptation.entry_corridor_id} anchored at ${activePredictor.active_profile_adaptation.angle_anchors_deg.join(", ")} deg`);
  console.log(`Current Trajectories along miss: ${(currentMissM / 1000).toFixed(2)} km`);
  console.log(`Remaining airbrake correction: +${(integration.remaining_correction_m / 1000).toFixed(2)} km (${integration.interpretation})`);
  console.log(`Adjusted along miss: ${(adjusted / 1000).toFixed(2)} km`);
  console.log(`Coverage: ${(integration.coverage_fraction * 100).toFixed(1)}% of reference duration | skipped ${integration.skipped_segments} segments`);
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  adjustedTrajectoriesAlongMiss,
  canonicalProfileKey,
  extraDragDeceleration,
  extraTrajectoriesAlongRate,
  integrateRemainingCorrection,
  main,
  predictorForContext,
  profileAdaptationForContext,
  solveFixedAngleForCorrection,
  stateInCalibrationDomain,
  statePathFromSamples,
};
