#!/usr/bin/env node

"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { predictorForContext } = require("./airbrake-adjusted-predictor.js");
const {
  cumulativeImpactValidation,
  dragPrediction,
  evaluateTransfer,
  impactRatePrediction,
  selectFitRows,
} = require("./fit-airbrake-predictor.js");
const { parseCsv } = require("./telemetry-csv.js");

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function median(values) {
  const clean = values.filter(finite).sort((a, b) => a - b);
  if (!clean.length) return null;
  const middle = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[middle] : (clean[middle - 1] + clean[middle]) / 2;
}

function inRange(value, limits) {
  if (!Array.isArray(limits) || limits.length !== 2 || !limits.every(finite)) return true;
  if (!finite(value)) return false;
  const center = (limits[0] + limits[1]) / 2;
  const tolerance = Math.max(Math.abs(center) * 1e-4, Math.abs(limits[1] - limits[0]) * 1e-6, 1e-9);
  return value >= limits[0] - tolerance && value <= limits[1] + tolerance;
}

function rowInDomain(row, domain = {}) {
  return inRange(row.altitude_m, domain.altitude_m)
    && inRange(row.mach, domain.mach)
    && inRange(row.dynamic_pressure_kpa, domain.dynamic_pressure_kpa)
    && inRange(row.mass_t, domain.mass_t)
    && inRange(row.fixed_airbrake_part_count, domain.airbrake_count);
}

function pairSummaries(report) {
  const result = [];
  for (const profile of report.profile_sets ?? []) {
    for (const key of ["fixed30_pair", "fixed45_pair", "fixed50_pair", "fixed60_pair", "fixed90_pair"]) {
      if (profile[key]) result.push(profile[key]);
    }
    result.push(...(profile.custom_fixed_pairs ?? []));
  }
  return result;
}

function criterion(pass, observed, expected) {
  return { pass: Boolean(pass), observed, expected };
}

function evaluateHoldout(model, pairs, report, options = {}) {
  const runId = String(options.runId ?? "");
  if (!runId) throw new Error("A fixed-run ID is required");
  const runRows = pairs.filter((row) => String(row.fixed_run_id) === runId);
  if (!runRows.length) throw new Error(`No matched rows exist for fixed run ${runId}`);
  const first = runRows[0];
  const active = predictorForContext(model, {
    profile_id: first.trajectories_profile_id,
    profile_key: first.trajectories_profile_key,
    corridor_id: first.entry_corridor_id,
  });
  if (!active.extra_drag_model || !active.trajectories_along_rate_model) {
    throw new Error("The frozen predictor has no applicable drag or Trajectories-response model");
  }
  const selected = selectFitRows({ matched_rows: runRows });
  const forceRows = selected.force.filter((row) => rowInDomain(row, active.domain));
  const impactRows = selected.impact.filter((row) => rowInDomain(row, active.trajectories_domain ?? active.domain));
  const drag = evaluateTransfer(forceRows, active.extra_drag_model, (row) => row.extra_deceleration_mps2, dragPrediction);
  const response = evaluateTransfer(impactRows, active.trajectories_along_rate_model, (row) => row.impact_along_rate_delta_mps, impactRatePrediction);
  const cumulative = cumulativeImpactValidation(impactRows, active.trajectories_along_rate_model);
  const cumulativeGroup = cumulative.groups[0] ?? null;
  const run = (report.runs ?? []).find((candidate) => String(candidate.run_id) === runId) ?? null;
  const pair = pairSummaries(report).find((candidate) => String(candidate.fixed_run_id) === runId) ?? null;
  const angleDeg = median(runRows.map((row) => row.fixed_airbrake_estimated_angle_deg));
  const expectedAngleDeg = options.expectedAngleDeg ?? 45;
  const minRows = options.minRows ?? 40;
  const expectedCumulativeKm = options.expectedCumulativeKm ?? null;
  const cumulativeToleranceKm = options.cumulativeToleranceKm ?? 10;
  const dragRatio = drag.median_prediction_to_observation_ratio;
  const responseRatio = response.median_prediction_to_observation_ratio;
  const cumulativeErrorKm = cumulativeGroup && finite(expectedCumulativeKm)
    ? cumulativeGroup.observed_change_m / 1000 - expectedCumulativeKm
    : null;
  const qualification = {
    profile: criterion(first.trajectories_profile_id === (options.expectedProfile ?? "matched10"), first.trajectories_profile_id, options.expectedProfile ?? "matched10"),
    corridor: criterion(first.entry_corridor_id === (options.expectedCorridor ?? "entry_fpa29"), first.entry_corridor_id, options.expectedCorridor ?? "entry_fpa29"),
    angle: criterion(finite(angleDeg) && Math.abs(angleDeg - expectedAngleDeg) <= 0.5, angleDeg, `${expectedAngleDeg} +/- 0.5 deg`),
    entry_fpa: criterion(run && finite(run.predicted_entry_fpa_down_deg) && Math.abs(run.predicted_entry_fpa_down_deg - 2.9) <= 0.1, run?.predicted_entry_fpa_down_deg ?? null, "2.9 +/- 0.1 deg down"),
    airbrake_readback: criterion(run?.checks?.airbrake_angle_readback === true, run?.checks?.airbrake_angle_readback ?? null, true),
    authority_zero: criterion(run?.checks?.airbrake_authority_limiter_zero === true, run?.checks?.airbrake_authority_limiter_zero ?? null, true),
    no_reassertions: criterion(run?.checks?.no_airbrake_angle_reassertions === true, run?.airbrake_angle_reassertion_count ?? null, 0),
    initial_airspeed: criterion(pair && pair.initial?.airspeed_delta_mps <= 5, pair?.initial?.airspeed_delta_mps ?? null, "<= 5 m/s"),
    initial_position: criterion(pair && pair.initial?.position_delta_m <= 2000, pair?.initial?.position_delta_m ?? null, "<= 2000 m"),
    clean_force_rows: criterion(forceRows.length >= minRows, forceRows.length, `>= ${minRows}`),
    clean_response_rows: criterion(impactRows.length >= minRows, impactRows.length, `>= ${minRows}`),
  };
  const predictorCriteria = {
    drag_ratio: criterion(finite(dragRatio) && dragRatio >= 0.85 && dragRatio <= 1.15, dragRatio, "0.85-1.15"),
    drag_normalized_rmse: criterion(finite(drag.normalized_rmse_by_median_observation) && drag.normalized_rmse_by_median_observation <= 0.25, drag.normalized_rmse_by_median_observation, "<= 0.25"),
    response_ratio: criterion(finite(responseRatio) && responseRatio >= 0.8 && responseRatio <= 1.2, responseRatio, "0.80-1.20"),
    response_normalized_rmse: criterion(finite(response.normalized_rmse_by_median_observation) && response.normalized_rmse_by_median_observation <= 0.3, response.normalized_rmse_by_median_observation, "<= 0.30"),
    cumulative_response: criterion(!finite(expectedCumulativeKm) || (finite(cumulativeErrorKm) && Math.abs(cumulativeErrorKm) <= cumulativeToleranceKm), cumulativeGroup?.observed_change_m / 1000 ?? null, finite(expectedCumulativeKm) ? `${expectedCumulativeKm} +/- ${cumulativeToleranceKm} km` : "not preregistered"),
  };
  const qualificationPass = Object.values(qualification).every((item) => item.pass);
  const predictorPass = qualificationPass && Object.values(predictorCriteria).every((item) => item.pass);
  return {
    schema: "airbrake_holdout_evaluation",
    schema_version: 1,
    generated_at: new Date().toISOString(),
    frozen_model_sha256: options.modelSha256 ?? null,
    fixed_run_id: runId,
    off_run_id: first.off_run_id,
    context: {
      profile_id: first.trajectories_profile_id,
      profile_key: first.trajectories_profile_key,
      corridor_id: first.entry_corridor_id,
      angle_deg: angleDeg,
      adaptation: active.active_profile_adaptation ?? null,
    },
    qualification,
    qualification_pass: qualificationPass,
    metrics: { drag, trajectories_response: response, cumulative_response: cumulative },
    predictor_criteria: predictorCriteria,
    predictor_pass: predictorPass,
    survivability: {
      full_integrity: run ? run.first_vessel_part_loss_altitude_m === null && run.minimum_vessel_part_count === run.expected_vessel_part_count : null,
      initial_parts: run?.expected_vessel_part_count ?? null,
      final_minimum_parts: run?.minimum_vessel_part_count ?? null,
      initial_airbrakes: run?.expected_airbrake_count ?? null,
      final_minimum_airbrakes: run?.minimum_airbrake_count ?? null,
      first_loss_altitude_m: run?.first_vessel_part_loss_altitude_m ?? null,
    },
  };
}

function parseArgs(argv) {
  const options = {
    model: "telemetry/airbrake_predictor.json",
    pairs: "telemetry/airbrake_pairs.csv",
    report: "telemetry/report.json",
    runId: null,
    out: null,
    expectedModelSha256: null,
    expectedProfile: "matched10",
    expectedCorridor: "entry_fpa29",
    expectedAngleDeg: 45,
    expectedCumulativeKm: null,
    cumulativeToleranceKm: 10,
    minRows: 40,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key === "--model") options.model = argv[++index];
    else if (key === "--pairs") options.pairs = argv[++index];
    else if (key === "--report") options.report = argv[++index];
    else if (key === "--run") options.runId = argv[++index];
    else if (key === "--out") options.out = argv[++index];
    else if (key === "--expected-model-sha256") options.expectedModelSha256 = argv[++index].toUpperCase();
    else if (key === "--expected-profile") options.expectedProfile = argv[++index];
    else if (key === "--expected-corridor") options.expectedCorridor = argv[++index];
    else if (key === "--expected-angle") options.expectedAngleDeg = Number(argv[++index]);
    else if (key === "--expected-cumulative-km") options.expectedCumulativeKm = Number(argv[++index]);
    else if (key === "--cumulative-tolerance-km") options.cumulativeToleranceKm = Number(argv[++index]);
    else if (key === "--min-rows") options.minRows = Number(argv[++index]);
    else throw new Error(`Unknown option: ${key}`);
  }
  return options;
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (!options.runId) throw new Error("Use --run RUN_ID for the new fixed-angle holdout");
  const modelText = fs.readFileSync(options.model, "utf8");
  const modelSha256 = crypto.createHash("sha256").update(modelText).digest("hex").toUpperCase();
  if (options.expectedModelSha256 && modelSha256 !== options.expectedModelSha256) {
    throw new Error(`Frozen model hash changed: expected ${options.expectedModelSha256}, found ${modelSha256}. Evaluate against the preregistered model before refitting.`);
  }
  const result = evaluateHoldout(
    JSON.parse(modelText),
    parseCsv(fs.readFileSync(options.pairs, "utf8")),
    JSON.parse(fs.readFileSync(options.report, "utf8")),
    { ...options, modelSha256 },
  );
  if (options.out) {
    const output = path.resolve(options.out);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  }
  console.log(`Holdout run ${result.fixed_run_id}: qualification ${result.qualification_pass ? "PASS" : "FAIL"}; predictor ${result.predictor_pass ? "PASS" : "FAIL"}`);
  console.log(`Drag: n=${result.metrics.drag.count}, median predicted/observed=${result.metrics.drag.median_prediction_to_observation_ratio?.toFixed(3) ?? "n/a"}, normalized RMSE=${result.metrics.drag.normalized_rmse_by_median_observation?.toFixed(3) ?? "n/a"}`);
  console.log(`Trajectories response: n=${result.metrics.trajectories_response.count}, median predicted/observed=${result.metrics.trajectories_response.median_prediction_to_observation_ratio?.toFixed(3) ?? "n/a"}, normalized RMSE=${result.metrics.trajectories_response.normalized_rmse_by_median_observation?.toFixed(3) ?? "n/a"}`);
  const cumulative = result.metrics.cumulative_response.groups[0];
  if (cumulative) console.log(`Integrated observed/model: ${(cumulative.observed_change_m / 1000).toFixed(2)} / ${(cumulative.predicted_change_m / 1000).toFixed(2)} km`);
  console.log(`Survivability: ${result.survivability.full_integrity === null ? "unknown" : result.survivability.full_integrity ? "full integrity" : "part loss"}`);
  return result.predictor_pass ? 0 : 2;
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { evaluateHoldout, main, pairSummaries, parseArgs, rowInDomain };
