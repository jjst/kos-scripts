#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {
  analyzeSegments,
  discoverFiles,
  readSegment,
} = require("./analyze-reentry-telemetry.js");

const MIN_FIT_DYNAMIC_PRESSURE_KPA = 0.1;
const MACH_CENTER = 6.75;
const ALTITUDE_CENTER_KM = 45;

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function range(values) {
  const clean = values.filter(finite);
  return clean.length ? [Math.min(...clean), Math.max(...clean)] : [null, null];
}

function median(values) {
  const clean = values.filter(finite).sort((a, b) => a - b);
  if (!clean.length) return null;
  const middle = Math.floor(clean.length / 2);
  return clean.length % 2 ? clean[middle] : (clean[middle - 1] + clean[middle]) / 2;
}

function domainFromRows(rows) {
  return {
    altitude_m: range(rows.map((row) => row.altitude_m)),
    mach: range(rows.map((row) => row.mach)),
    dynamic_pressure_kpa: range(rows.map((row) => row.dynamic_pressure_kpa)),
    mass_t: range(rows.map((row) => row.mass_t)),
    airbrake_count: range(rows.map((row) => row.fixed_airbrake_part_count)),
  };
}

function solveTwoParameterLeastSquares(rows) {
  let x00 = 0;
  let x01 = 0;
  let x11 = 0;
  let y0 = 0;
  let y1 = 0;
  for (const { x0, x1, y } of rows) {
    x00 += x0 * x0;
    x01 += x0 * x1;
    x11 += x1 * x1;
    y0 += x0 * y;
    y1 += x1 * y;
  }
  const determinant = x00 * x11 - x01 * x01;
  if (Math.abs(determinant) < 1e-12) throw new Error("Predictor fit is singular; gather a wider state envelope");
  return [
    (y0 * x11 - y1 * x01) / determinant,
    (x00 * y1 - x01 * y0) / determinant,
  ];
}

function metrics(rows, observed, predicted) {
  if (!rows.length) return { count: 0, rmse: null, mae: null, r2: null };
  const values = rows.map(observed);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  let squaredError = 0;
  let absoluteError = 0;
  let totalVariation = 0;
  for (const row of rows) {
    const error = observed(row) - predicted(row);
    squaredError += error * error;
    absoluteError += Math.abs(error);
    totalVariation += (observed(row) - mean) ** 2;
  }
  return {
    count: rows.length,
    rmse: Math.sqrt(squaredError / rows.length),
    mae: absoluteError / rows.length,
    r2: totalVariation > 0 ? 1 - squaredError / totalVariation : null,
  };
}

function readbackIsClean(row) {
  const fields = row.fixed_airbrake_deploy_angle_fields_deg;
  if (!Array.isArray(fields) || !fields.length) return true;
  if ((row.fixed_airbrake_angle_reassertion_count ?? 0) > 0) return false;
  return fields.every((angle) => finite(angle) && Math.abs(angle - row.fixed_airbrake_estimated_angle_deg) <= 0.5);
}

function plannedAlignmentIsClean(row) {
  const errors = [row.off_trajectories_planned_facing_error_deg, row.fixed_trajectories_planned_facing_error_deg].filter(finite);
  return errors.length === 0 || (errors.length === 2 && errors.every((error) => error <= 2));
}

function authorityReadbackIsClean(row) {
  const fieldSets = [row.off_airbrake_authority_limiter_fields_percent, row.fixed_airbrake_authority_limiter_fields_percent];
  const instrumented = fieldSets.filter(Array.isArray);
  if (!instrumented.length) return true;
  return instrumented.length === 2 && instrumented.every((fields) => fields.length > 0
    && fields.every((authority) => finite(authority) && Math.abs(authority) <= 0.5));
}

function vesselPartCountIsClean(row) {
  const pairs = [
    [row.off_vessel_part_count, row.off_initial_vessel_part_count],
    [row.fixed_vessel_part_count, row.fixed_initial_vessel_part_count],
  ];
  return pairs.every(([current, initial]) => !finite(initial) || (finite(current) && current === initial));
}

function selectFitRows(report, options = {}) {
  const { profileKey = null } = options;
  const intact = report.matched_rows.filter((row) =>
    (!profileKey || row.trajectories_profile_key === profileKey)
    && row.fixed_airbrake_part_count > 0
    && row.fixed_airbrake_survival_fraction >= 0.999
    && row.dynamic_pressure_kpa >= MIN_FIT_DYNAMIC_PRESSURE_KPA
    && finite(row.mass_t)
    && row.mass_t > 0
    && finite(row.mach)
    && finite(row.altitude_m)
    && finite(row.fixed_airbrake_estimated_angle_deg)
    && row.fixed_airbrake_estimated_angle_deg > 0
    && readbackIsClean(row)
    && authorityReadbackIsClean(row)
    && vesselPartCountIsClean(row)
    && plannedAlignmentIsClean(row));

  return {
    force: intact.filter((row) => finite(row.extra_deceleration_mps2) && row.extra_deceleration_mps2 > 0),
    impact: intact.filter((row) => finite(row.impact_along_rate_delta_mps) && row.impact_along_rate_delta_mps > 0),
  };
}

function calibrationCandidates(report) {
  return (report.profile_sets ?? []).map((profile) => {
    const rows = selectFitRows(report, { profileKey: profile.profile_key });
    const angles = [...new Set(rows.force.map((row) => Math.round(row.fixed_airbrake_estimated_angle_deg * 100) / 100))].sort((a, b) => a - b);
    const uniqueRows = new Map([...rows.force, ...rows.impact].map((row) => [`${row.fixed_run_id}:${row.fixed_time_s}`, row]));
    const instrumentedRows = [...uniqueRows.values()].filter((row) => Array.isArray(row.fixed_airbrake_deploy_angle_fields_deg)).length;
    const authorityLockedRows = [...uniqueRows.values()].filter((row) => Array.isArray(row.fixed_airbrake_authority_limiter_fields_percent)
      && row.fixed_airbrake_authority_limiter_fields_percent.length > 0
      && row.fixed_airbrake_authority_limiter_fields_percent.every((value) => finite(value) && Math.abs(value) <= 0.5)).length;
    const angleSpan = angles.length ? angles.at(-1) - angles[0] : 0;
    const eligible = rows.force.length >= 20 && rows.impact.length >= 20 && angles.length >= 2;
    const isCurrentMatchedProfile = profile.profile_key === report.matched10_validation?.profile_key;
    const score = Number(isCurrentMatchedProfile) * 1e9
      + Number(profile.profile_id === "matched10") * 1e8
      + instrumentedRows * 1e5
      + authorityLockedRows * 1e4
      + angles.length * 1e3
      + angleSpan * 10
      + rows.force.length + rows.impact.length;
    return { profile, rows, angles, instrumentedRows, authorityLockedRows, angleSpan, eligible, score };
  }).sort((a, b) => Number(b.eligible) - Number(a.eligible) || b.score - a.score);
}

function chooseCalibrationProfile(report, requestedProfile = null) {
  const candidates = calibrationCandidates(report);
  const matching = requestedProfile
    ? candidates.filter((candidate) => candidate.profile.profile_key === requestedProfile || candidate.profile.profile_id === requestedProfile)
    : candidates;
  const selected = matching.find((candidate) => candidate.eligible) ?? null;
  if (selected) return selected;
  if (requestedProfile) throw new Error(`No fit-ready telemetry profile matches ${requestedProfile}`);
  throw new Error("No telemetry profile has at least two fixed angles and 20 intact, AoA-aligned rows for both models");
}

function evaluationMetrics(rows, observed, predicted) {
  const result = metrics(rows, observed, predicted);
  if (!rows.length) {
    return {
      ...result,
      mean_error: null,
      median_prediction_to_observation_ratio: null,
      normalized_rmse_by_median_observation: null,
    };
  }
  const observedMedian = median(rows.map(observed));
  return {
    ...result,
    mean_error: rows.reduce((sum, row) => sum + predicted(row) - observed(row), 0) / rows.length,
    median_prediction_to_observation_ratio: median(rows.map((row) => predicted(row) / observed(row))),
    normalized_rmse_by_median_observation: observedMedian > 0 ? result.rmse / observedMedian : null,
  };
}

function evaluateTransfer(rows, model, observed, predicted) {
  return {
    ...evaluationMetrics(rows, observed, (row) => predicted(model, row)),
    metrics_by_mode: Object.fromEntries([...new Set(rows.map((row) => row.fixed_mode))].map((mode) => {
      const subset = rows.filter((row) => row.fixed_mode === mode);
      return [mode, evaluationMetrics(subset, observed, (row) => predicted(model, row))];
    })),
  };
}

function dragPrediction(model, row) {
  const angleRadians = row.fixed_airbrake_estimated_angle_deg * Math.PI / 180;
  const cdaPerAirbrake = Math.sin(angleRadians) ** model.angle_sine_exponent
    * (model.cda_at_mach_center_m2 + model.cda_mach_slope_m2_per_mach * (row.mach - model.mach_center));
  return row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t * cdaPerAirbrake;
}

function fitDragModel(rows) {
  if (rows.length < 20) throw new Error("At least 20 intact force rows are required");
  let best = null;
  for (let exponent = 0.2; exponent <= 2.5 + 1e-9; exponent += 0.005) {
    const regression = rows.map((row) => {
      const angleRadians = row.fixed_airbrake_estimated_angle_deg * Math.PI / 180;
      const base = row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t
        * Math.sin(angleRadians) ** exponent;
      return {
        x0: base,
        x1: base * (row.mach - MACH_CENTER),
        y: row.extra_deceleration_mps2,
      };
    });
    const [cda, machSlope] = solveTwoParameterLeastSquares(regression);
    const model = {
      angle_sine_exponent: exponent,
      mach_center: MACH_CENTER,
      cda_at_mach_center_m2: cda,
      cda_mach_slope_m2_per_mach: machSlope,
    };
    const squaredError = rows.reduce((sum, row) => sum + (row.extra_deceleration_mps2 - dragPrediction(model, row)) ** 2, 0);
    if (!best || squaredError < best.squaredError) best = { ...model, squaredError };
  }
  const model = { ...best };
  delete model.squaredError;
  model.formula = "extra_deceleration_mps2 = dynamic_pressure_kpa * airbrake_count / mass_t * sin(angle_deg*pi/180)^p * (cda0 + cdaMachSlope * (mach - machCenter))";
  model.metrics = metrics(rows, (row) => row.extra_deceleration_mps2, (row) => dragPrediction(model, row));
  model.metrics_by_mode = Object.fromEntries([...new Set(rows.map((row) => row.fixed_mode))].map((mode) => {
    const subset = rows.filter((row) => row.fixed_mode === mode);
    return [mode, metrics(subset, (row) => row.extra_deceleration_mps2, (row) => dragPrediction(model, row))];
  }));
  return model;
}

function impactRatePrediction(model, row) {
  const angleRadians = row.fixed_airbrake_estimated_angle_deg * Math.PI / 180;
  return model.scale
    * row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t
    * Math.sin(angleRadians) ** model.angle_sine_exponent
    * Math.exp(model.altitude_log_slope_per_km * (row.altitude_m / 1000 - model.altitude_center_km));
}

function cumulativeImpactValidation(rows, model) {
  const grouped = new Map();
  for (const row of rows) {
    if (![row.off_time_s, row.impact_along_miss_delta_m].every(finite)) continue;
    const key = `${row.off_run_id ?? "off"}|${row.fixed_run_id ?? row.fixed_mode ?? "fixed"}`;
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(row);
  }
  const groups = [];
  for (const [pairKey, unsorted] of grouped) {
    const ordered = [...unsorted].sort((a, b) => a.off_time_s - b.off_time_s);
    if (ordered.length < 2) continue;
    let predictedChangeM = 0;
    for (let index = 1; index < ordered.length; index += 1) {
      const previous = ordered[index - 1];
      const current = ordered[index];
      const dt = current.off_time_s - previous.off_time_s;
      if (!(dt > 0)) continue;
      predictedChangeM += (impactRatePrediction(model, previous) + impactRatePrediction(model, current)) / 2 * dt;
    }
    const first = ordered[0];
    const last = ordered.at(-1);
    const observedChangeM = last.impact_along_miss_delta_m - first.impact_along_miss_delta_m;
    groups.push({
      pair_key: pairKey,
      off_run_id: first.off_run_id ?? null,
      fixed_run_id: first.fixed_run_id ?? null,
      fixed_mode: first.fixed_mode ?? null,
      fixed_angle_deg: first.fixed_airbrake_estimated_angle_deg ?? null,
      rows: ordered.length,
      start_altitude_m: first.altitude_m,
      end_altitude_m: last.altitude_m,
      duration_s: last.off_time_s - first.off_time_s,
      observed_change_m: observedChangeM,
      predicted_change_m: predictedChangeM,
      error_m: predictedChangeM - observedChangeM,
      prediction_to_observation_ratio: observedChangeM !== 0 ? predictedChangeM / observedChangeM : null,
    });
  }
  const squaredErrors = groups.map((group) => group.error_m ** 2);
  return {
    kind: "in_sample_integrated_response",
    count: groups.length,
    rmse_m: groups.length ? Math.sqrt(squaredErrors.reduce((sum, value) => sum + value, 0) / groups.length) : null,
    mean_error_m: groups.length ? groups.reduce((sum, group) => sum + group.error_m, 0) / groups.length : null,
    median_prediction_to_observation_ratio: median(groups.map((group) => group.prediction_to_observation_ratio)),
    groups,
  };
}

function fitImpactRateModel(rows) {
  if (rows.length < 20) throw new Error("At least 20 intact Trajectories-response rows are required");
  let best = null;
  for (let exponent = 0.1; exponent <= 2 + 1e-9; exponent += 0.01) {
    for (let altitudeSlope = -0.05; altitudeSlope <= 0.15 + 1e-9; altitudeSlope += 0.001) {
      let crossProduct = 0;
      let squareProduct = 0;
      const bases = rows.map((row) => {
        const angleRadians = row.fixed_airbrake_estimated_angle_deg * Math.PI / 180;
        const base = row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t
          * Math.sin(angleRadians) ** exponent
          * Math.exp(altitudeSlope * (row.altitude_m / 1000 - ALTITUDE_CENTER_KM));
        crossProduct += base * row.impact_along_rate_delta_mps;
        squareProduct += base * base;
        return base;
      });
      const scale = crossProduct / squareProduct;
      const squaredError = rows.reduce((sum, row, index) => sum + (row.impact_along_rate_delta_mps - scale * bases[index]) ** 2, 0);
      if (!best || squaredError < best.squaredError) {
        best = { angle_sine_exponent: exponent, altitude_log_slope_per_km: altitudeSlope, scale, squaredError };
      }
    }
  }
  const model = {
    angle_sine_exponent: best.angle_sine_exponent,
    altitude_center_km: ALTITUDE_CENTER_KM,
    altitude_log_slope_per_km: best.altitude_log_slope_per_km,
    scale: best.scale,
    formula: "extra_trajectories_along_rate_mps = scale * dynamic_pressure_kpa * airbrake_count / mass_t * sin(angle_deg*pi/180)^p * exp(altitudeSlope * (altitude_km - altitudeCenterKm))",
  };
  model.metrics = metrics(rows, (row) => row.impact_along_rate_delta_mps, (row) => impactRatePrediction(model, row));
  model.metrics_by_mode = Object.fromEntries([...new Set(rows.map((row) => row.fixed_mode))].map((mode) => {
    const subset = rows.filter((row) => row.fixed_mode === mode);
    return [mode, metrics(subset, (row) => row.impact_along_rate_delta_mps, (row) => impactRatePrediction(model, row))];
  }));
  model.cumulative_validation = cumulativeImpactValidation(rows, model);
  return model;
}

function fitAnchoredImpactRateModel(rows, baseModel) {
  if (rows.length < 20) throw new Error("At least 20 intact Trajectories-response rows are required for a corridor anchor");
  if (!baseModel || !finite(baseModel.angle_sine_exponent)) throw new Error("A fitted base angle exponent is required for a corridor anchor");
  const exponent = baseModel.angle_sine_exponent;
  let best = null;
  for (let altitudeSlope = -0.05; altitudeSlope <= 0.15 + 1e-9; altitudeSlope += 0.001) {
    let crossProduct = 0;
    let squareProduct = 0;
    const bases = rows.map((row) => {
      const angleRadians = row.fixed_airbrake_estimated_angle_deg * Math.PI / 180;
      const base = row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t
        * Math.sin(angleRadians) ** exponent
        * Math.exp(altitudeSlope * (row.altitude_m / 1000 - ALTITUDE_CENTER_KM));
      crossProduct += base * row.impact_along_rate_delta_mps;
      squareProduct += base * base;
      return base;
    });
    const scale = crossProduct / squareProduct;
    const squaredError = rows.reduce((sum, row, index) => sum + (row.impact_along_rate_delta_mps - scale * bases[index]) ** 2, 0);
    if (!best || squaredError < best.squaredError) best = { altitudeSlope, scale, squaredError };
  }
  const model = {
    angle_sine_exponent: exponent,
    angle_sine_exponent_source: "inherited_from_multi_angle_calibration",
    anchor_angles_deg: [...new Set(rows.map((row) => Math.round(row.fixed_airbrake_estimated_angle_deg * 100) / 100))].sort((a, b) => a - b),
    altitude_center_km: ALTITUDE_CENTER_KM,
    altitude_log_slope_per_km: best.altitudeSlope,
    scale: best.scale,
    formula: "extra_trajectories_along_rate_mps = scale * dynamic_pressure_kpa * airbrake_count / mass_t * sin(angle_deg*pi/180)^inheritedP * exp(altitudeSlope * (altitude_km - altitudeCenterKm))",
  };
  model.metrics = metrics(rows, (row) => row.impact_along_rate_delta_mps, (row) => impactRatePrediction(model, row));
  model.metrics_by_mode = Object.fromEntries([...new Set(rows.map((row) => row.fixed_mode))].map((mode) => {
    const subset = rows.filter((row) => row.fixed_mode === mode);
    return [mode, metrics(subset, (row) => row.impact_along_rate_delta_mps, (row) => impactRatePrediction(model, row))];
  }));
  model.cumulative_validation = cumulativeImpactValidation(rows, model);
  return model;
}

function fitPredictor(report, options = {}) {
  const calibration = chooseCalibrationProfile(report, options.profile ?? null);
  const calibrationProfileKey = calibration.profile.profile_key;
  const fitRows = calibration.rows;
  const drag = fitDragModel(fitRows.force);
  const trajectories = fitImpactRateModel(fitRows.impact);
  const calibrationMatchedRows = report.matched_rows.filter((row) => row.trajectories_profile_key === calibrationProfileKey);
  const selectedRunIds = new Set(calibrationMatchedRows.flatMap((row) => [row.off_run_id, row.fixed_run_id]).filter(Boolean).map(String));
  const selectedRuns = report.merged_runs.filter((run) => selectedRunIds.has(String(run.run_id)));
  const selectedSummaries = report.runs.filter((run) => selectedRunIds.has(String(run.run_id)));
  const allFitRows = [...fitRows.force, ...fitRows.impact];
  const uniqueRows = new Set(allFitRows.map((row) => `${row.fixed_mode}:${row.fixed_time_s}`)).size;
  const instrumentedRows = new Set(allFitRows.filter((row) => Array.isArray(row.fixed_airbrake_deploy_angle_fields_deg)).map((row) => `${row.fixed_mode}:${row.fixed_time_s}`)).size;
  const angles = [...new Set(fitRows.force.map((row) => row.fixed_airbrake_estimated_angle_deg))].sort((a, b) => a - b);
  const warnings = [];
  if (instrumentedRows === 0) warnings.push("Selected calibration runs predate per-part deploy-angle readback; repeat at least one fixed-angle run with the instrumented build.");
  if (Math.min(...angles) > 60) warnings.push("The operational 60 degree minimum is extrapolated; no fixed60 calibration run is present.");
  if (Math.max(...angles) < 90) warnings.push(`The high-angle response is not yet bounded; maximum calibrated angle is ${Math.max(...angles).toFixed(1)} degrees.`);
  if (drag.angle_sine_exponent >= 2.495) warnings.push("The drag angle exponent reached its search ceiling; add higher-angle runs before expanding the search range or trusting extrapolation.");
  if (trajectories.angle_sine_exponent >= 1.995) warnings.push("The Trajectories-response angle exponent reached its search ceiling; add higher-angle runs before expanding the search range or trusting extrapolation.");
  for (const run of selectedSummaries) {
    if (run.first_airbrake_loss_altitude_m !== null) warnings.push(`${run.mode} run ${run.run_id} lost an airbrake at ${(run.first_airbrake_loss_altitude_m / 1000).toFixed(2)} km; only intact pre-failure matches were fitted.`);
  }
  const profiles = selectedRuns.map((run) => JSON.stringify(run.run.trajectories_descent_angles_deg ?? null));
  if (new Set(profiles).size > 1) warnings.push("Selected runs used different Trajectories descent-angle profiles.");
  const profileDiffersFromCommand = selectedRuns.some((run) => {
    const anglesForTrajectories = run.run.trajectories_descent_angles_deg;
    const modes = run.run.trajectories_descent_modes;
    if (!Array.isArray(anglesForTrajectories) || !finite(run.run.entry_aoa_deg)) return false;
    return anglesForTrajectories.some((angle, index) => {
      const normalized = Array.isArray(modes) && modes[index] && angle > 90 ? 180 - angle : angle;
      return Math.abs(normalized - run.run.entry_aoa_deg) > 1;
    });
  });
  if (profileDiffersFromCommand && calibration.profile.profile_id !== "matched10") warnings.push("Trajectories' descent profile does not match the flown AoA command in every phase; validate the coefficients with a matched-AoA profile.");

  const transferProfile = calibrationCandidates(report).find((candidate) => candidate.eligible && candidate.profile.profile_key !== calibrationProfileKey) ?? null;
  const transferRows = transferProfile?.rows ?? { force: [], impact: [] };
  const transferValidation = {
    profile_id: transferProfile?.profile.profile_id ?? null,
    profile_key: transferProfile?.profile.profile_key ?? null,
    ready: Boolean(transferProfile),
    force_rows: transferRows.force.length,
    trajectories_response_rows: transferRows.impact.length,
    extra_drag_model: evaluateTransfer(transferRows.force, drag, (row) => row.extra_deceleration_mps2, dragPrediction),
    trajectories_along_rate_model: evaluateTransfer(transferRows.impact, trajectories, (row) => row.impact_along_rate_delta_mps, impactRatePrediction),
  };
  const profileAdaptations = calibrationCandidates(report)
    .filter((candidate) => candidate.profile.profile_key !== calibrationProfileKey
      && (candidate.rows.force.length >= 20 || candidate.rows.impact.length >= 20))
    .map((candidate) => {
      let metadata = {};
      try { metadata = JSON.parse(candidate.profile.profile_key); } catch { metadata = {}; }
      const candidateMatchedRows = report.matched_rows.filter((row) => row.trajectories_profile_key === candidate.profile.profile_key);
      const anchoredTrajectories = candidate.rows.impact.length >= 20
        ? fitAnchoredImpactRateModel(candidate.rows.impact, trajectories)
        : null;
      return {
        profile_id: candidate.profile.profile_id,
        profile_key: candidate.profile.profile_key,
        entry_corridor_id: metadata.entry_corridor_id ?? "trajectories_miss",
        source_run_ids: candidate.profile.run_ids ?? [],
        off_run_ids: [...new Set(candidateMatchedRows.map((row) => String(row.off_run_id)).filter(Boolean))],
        fixed_run_ids: [...new Set(candidateMatchedRows.map((row) => String(row.fixed_run_id)).filter(Boolean))],
        angle_anchors_deg: candidate.angles,
        force_rows: candidate.rows.force.length,
        trajectories_response_rows: candidate.rows.impact.length,
        domain: domainFromRows(candidate.rows.force),
        trajectories_domain: domainFromRows(candidate.rows.impact),
        base_model_transfer: {
          extra_drag_model: evaluateTransfer(candidate.rows.force, drag, (row) => row.extra_deceleration_mps2, dragPrediction),
          trajectories_along_rate_model: evaluateTransfer(candidate.rows.impact, trajectories, (row) => row.impact_along_rate_delta_mps, impactRatePrediction),
        },
        trajectories_along_rate_model: anchoredTrajectories,
        warning: anchoredTrajectories
          ? `Trajectories response is anchored at ${candidate.angles.join(", ")} degrees; the multi-angle exponent is inherited from ${calibration.profile.profile_id}.`
          : "No corridor-specific Trajectories-response anchor is available.",
      };
    });
  if (calibration.profile.profile_id !== "matched10") warnings.push("Matched-AoA calibration is not yet fit-ready; coefficients still come from a proxy attitude profile.");
  if (!transferValidation.ready) warnings.push("No independent fit-ready profile is available for cross-profile validation.");
  warnings.push("Coefficients are calibrated only for this vessel, atmosphere, attitude law, and the observed state envelope.");

  return {
    schema: "empirical_airbrake_trajectories_predictor",
    schema_version: 2,
    generated_at: new Date().toISOString(),
    calibration_profile: {
      profile_key: calibrationProfileKey,
      profile_id: calibration.profile.profile_id,
    },
    selected_runs: selectedRuns.map((run) => ({
      run_id: run.run_id,
      mode: run.mode,
      status: run.status,
      trajectories_descent_angles_deg: run.run.trajectories_descent_angles_deg ?? null,
      trajectories_descent_modes: run.run.trajectories_descent_modes ?? null,
      entry_aoa_deg: run.run.entry_aoa_deg ?? null,
    })),
    fit_rows: {
      unique: uniqueRows,
      force: fitRows.force.length,
      trajectories_response: fitRows.impact.length,
      instrumented: instrumentedRows,
    },
    domain: {
      calibrated_airbrake_angles_deg: angles,
      ...domainFromRows(fitRows.force),
    },
    trajectories_domain: domainFromRows(fitRows.impact),
    descriptive: Object.fromEntries([...new Set(fitRows.force.map((row) => row.fixed_mode))].map((mode) => {
      const subset = fitRows.force.filter((row) => row.fixed_mode === mode);
      return [mode, {
        count: subset.length,
        median_extra_cda_per_airbrake_m2: median(subset.map((row) => row.extra_cd_area_per_airbrake_m2)),
        median_extra_deceleration_mps2: median(subset.map((row) => row.extra_deceleration_mps2)),
      }];
    })),
    extra_drag_model: drag,
    trajectories_along_rate_model: trajectories,
    transfer_validation: transferValidation,
    profile_adaptations: profileAdaptations,
    warnings,
  };
}

function parseArgs(argv) {
  const options = { inputs: [], out: null, profile: null, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--out") options.out = argv[++i];
    else if (arg === "--profile") options.profile = argv[++i];
    else if (arg === "--help" || arg === "-h") options.help = true;
    else options.inputs.push(arg);
  }
  return options;
}

function usage() {
  console.log(`Usage: node scripts/fit-airbrake-predictor.js [files/directories...] [--out FILE] [--profile ID_OR_KEY]

Fits an empirical extra-drag model and a one-step Trajectories along-rate model
from intact, instrumented, AoA-aligned portions of comparable fixed-angle runs.
By default it prefers the current matched-AoA authority-locked profile. With no
input, reads KSP's adjacent Ships/Script archive.`);
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    usage();
    return 0;
  }
  const files = discoverFiles(options.inputs);
  if (!files.length) throw new Error("No reentry telemetry segments found");
  const report = analyzeSegments(files.map(readSegment));
  const model = fitPredictor(report, { profile: options.profile });
  if (options.out) {
    fs.mkdirSync(path.dirname(path.resolve(options.out)), { recursive: true });
    fs.writeFileSync(options.out, `${JSON.stringify(model, null, 2)}\n`, "utf8");
  }
  console.log(`Fit rows: force=${model.fit_rows.force}, Trajectories response=${model.fit_rows.trajectories_response}`);
  console.log(`Drag: sin(angle)^${model.extra_drag_model.angle_sine_exponent.toFixed(3)}, CdA/brake=${model.extra_drag_model.cda_at_mach_center_m2.toFixed(3)} ${model.extra_drag_model.cda_mach_slope_m2_per_mach < 0 ? "-" : "+"} ${Math.abs(model.extra_drag_model.cda_mach_slope_m2_per_mach).toFixed(3)}*(Mach-${model.extra_drag_model.mach_center.toFixed(2)}) m^2, R2=${model.extra_drag_model.metrics.r2.toFixed(3)}`);
  console.log(`Trajectories along-rate: sin(angle)^${model.trajectories_along_rate_model.angle_sine_exponent.toFixed(3)}, altitude slope=${model.trajectories_along_rate_model.altitude_log_slope_per_km.toFixed(3)}/km, R2=${model.trajectories_along_rate_model.metrics.r2.toFixed(3)}`);
  if (model.transfer_validation.ready) {
    console.log(`Transfer[${model.transfer_validation.profile_id}]: drag RMSE=${model.transfer_validation.extra_drag_model.rmse.toFixed(3)} m/s^2, Trajectories-rate RMSE=${model.transfer_validation.trajectories_along_rate_model.rmse.toFixed(1)} m/s`);
  } else {
    console.log(`Transfer: WAIT (${model.transfer_validation.force_rows} force rows, ${model.transfer_validation.trajectories_response_rows} Trajectories-response rows)`);
  }
  for (const warning of model.warnings) console.log(`WARN: ${warning}`);
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
  calibrationCandidates,
  chooseCalibrationProfile,
  cumulativeImpactValidation,
  dragPrediction,
  fitDragModel,
  fitImpactRateModel,
  fitAnchoredImpactRateModel,
  fitPredictor,
  evaluationMetrics,
  evaluateTransfer,
  impactRatePrediction,
  main,
  plannedAlignmentIsClean,
  readbackIsClean,
  selectFitRows,
};
