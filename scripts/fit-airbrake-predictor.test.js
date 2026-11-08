"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  cumulativeImpactValidation,
  fitDragModel,
  fitAnchoredImpactRateModel,
  fitImpactRateModel,
  fitPredictor,
  plannedAlignmentIsClean,
  readbackIsClean,
  selectFitRows,
} = require("./fit-airbrake-predictor.js");

function syntheticRows() {
  const rows = [];
  const dragExponent = 1.2;
  const cda = 2.7;
  const cdaMachSlope = -0.12;
  const responseExponent = 0.65;
  const responseAltitudeSlope = 0.082;
  const responseScale = 3300;
  for (const angle of [45, 90]) {
    for (let i = 0; i < 26; i += 1) {
      const altitude = 35000 + i * 1000;
      const mach = 6.4 + i * 0.036;
      const dynamicPressure = 0.15 + i * 0.1;
      const mass = 20;
      const count = 4;
      const sine = Math.sin(angle * Math.PI / 180);
      const extraDeceleration = dynamicPressure * count / mass * sine ** dragExponent * (cda + cdaMachSlope * (mach - 6.75));
      const impactRate = responseScale * dynamicPressure * count / mass * sine ** responseExponent * Math.exp(responseAltitudeSlope * (altitude / 1000 - 45));
      rows.push({
        fixed_mode: angle === 45 ? "fixed45" : "fixed90",
        fixed_time_s: i * 2,
        fixed_airbrake_part_count: count,
        fixed_airbrake_survival_fraction: 1,
        fixed_airbrake_estimated_angle_deg: angle,
        fixed_airbrake_deploy_angle_fields_deg: [angle, angle, angle, angle],
        fixed_airbrake_deploy_angle_field_spread_deg: 0,
        fixed_airbrake_angle_reassertion_count: 0,
        dynamic_pressure_kpa: dynamicPressure,
        mass_t: mass,
        mach,
        altitude_m: altitude,
        extra_deceleration_mps2: extraDeceleration,
        impact_along_rate_delta_mps: impactRate,
      });
    }
  }
  return rows;
}

test("recovers the synthetic extra-drag relationship", () => {
  const rows = syntheticRows();
  const model = fitDragModel(rows);
  assert.ok(Math.abs(model.angle_sine_exponent - 1.2) <= 0.006);
  assert.ok(Math.abs(model.cda_at_mach_center_m2 - 2.7) < 1e-6);
  assert.ok(Math.abs(model.cda_mach_slope_m2_per_mach - -0.12) < 1e-6);
  assert.ok(model.metrics.r2 > 0.999999);
});

test("recovers the synthetic Trajectories along-rate relationship", () => {
  const rows = syntheticRows();
  const model = fitImpactRateModel(rows);
  assert.ok(Math.abs(model.angle_sine_exponent - 0.65) <= 0.011);
  assert.ok(Math.abs(model.altitude_log_slope_per_km - 0.082) <= 0.0011);
  assert.ok(Math.abs(model.scale - 3300) < 1e-6);
  assert.ok(model.metrics.r2 > 0.999999);
});

test("validates the integrated landing-point response over a matched pair", () => {
  const model = { angle_sine_exponent: 2, altitude_center_km: 50, altitude_log_slope_per_km: 0, scale: 100 };
  const rows = [0, 5, 10].map((time, index) => ({
    off_run_id: 1,
    fixed_run_id: 2,
    fixed_mode: "fixed90",
    fixed_airbrake_estimated_angle_deg: 90,
    off_time_s: time,
    altitude_m: 50000 - index * 1000,
    dynamic_pressure_kpa: 1,
    fixed_airbrake_part_count: 4,
    mass_t: 20,
    impact_along_miss_delta_m: 100 + index * 100,
  }));
  const validation = cumulativeImpactValidation(rows, model);
  assert.equal(validation.count, 1);
  assert.equal(validation.groups[0].observed_change_m, 200);
  assert.ok(Math.abs(validation.groups[0].predicted_change_m - 200) < 1e-9);
  assert.ok(Math.abs(validation.groups[0].prediction_to_observation_ratio - 1) < 1e-12);
});

test("anchors corridor response magnitude and altitude shape while inheriting the angle exponent", () => {
  const allRows = syntheticRows();
  const base = fitImpactRateModel(allRows);
  const anchoredRows = allRows.filter((row) => row.fixed_mode === "fixed45").map((row) => {
    const altitudeFactor = Math.exp(-0.04 * (row.altitude_m / 1000 - 45));
    const baseWithoutOriginalAltitude = row.impact_along_rate_delta_mps
      / Math.exp(0.082 * (row.altitude_m / 1000 - 45));
    return { ...row, impact_along_rate_delta_mps: baseWithoutOriginalAltitude * altitudeFactor * 1.8 };
  });
  const anchored = fitAnchoredImpactRateModel(anchoredRows, base);
  assert.equal(anchored.angle_sine_exponent, base.angle_sine_exponent);
  assert.equal(anchored.angle_sine_exponent_source, "inherited_from_multi_angle_calibration");
  assert.deepEqual(anchored.anchor_angles_deg, [45]);
  assert.ok(Math.abs(anchored.altitude_log_slope_per_km - -0.04) <= 0.0011);
  assert.ok(anchored.metrics.r2 > 0.999999);
});

test("excludes hardware loss, readback mismatch, and reasserted rows", () => {
  const clean = syntheticRows()[0];
  const lost = { ...clean, fixed_time_s: 100, fixed_airbrake_survival_fraction: 0.75, fixed_airbrake_part_count: 3 };
  const mismatched = { ...clean, fixed_time_s: 102, fixed_airbrake_deploy_angle_fields_deg: [45, 45, 70, 45] };
  const reasserted = { ...clean, fixed_time_s: 104, fixed_airbrake_angle_reassertion_count: 1 };
  const attitudeMismatch = { ...clean, fixed_time_s: 106, off_trajectories_planned_facing_error_deg: 0.2, fixed_trajectories_planned_facing_error_deg: 4 };
  const vesselLoss = { ...clean, fixed_time_s: 108, fixed_initial_vessel_part_count: 24, fixed_vessel_part_count: 23 };
  const report = { matched_rows: [clean, lost, mismatched, reasserted, attitudeMismatch, vesselLoss] };
  const selected = selectFitRows(report);
  assert.equal(readbackIsClean(clean), true);
  assert.equal(readbackIsClean(mismatched), false);
  assert.equal(readbackIsClean(reasserted), false);
  assert.equal(plannedAlignmentIsClean(clean), true);
  assert.equal(plannedAlignmentIsClean(attitudeMismatch), false);
  assert.equal(selected.force.length, 1);
  assert.equal(selected.impact.length, 1);
});

test("prefers the current matched-AoA profile for operational calibration", () => {
  const proxyRows = syntheticRows().map((row, index) => ({
    ...row,
    off_run_id: 1,
    fixed_run_id: row.fixed_mode === "fixed45" ? 2 : 3,
    fixed_time_s: index * 2,
    trajectories_profile_key: "proxy-key",
    trajectories_profile_id: "proxy",
  }));
  const matchedRows = syntheticRows().map((row, index) => ({
    ...row,
    off_run_id: 4,
    fixed_run_id: row.fixed_mode === "fixed45" ? 5 : 6,
    fixed_time_s: index * 2,
    extra_deceleration_mps2: row.extra_deceleration_mps2 * 2,
    impact_along_rate_delta_mps: row.impact_along_rate_delta_mps * 2,
    trajectories_profile_key: "matched-key",
    trajectories_profile_id: "matched10",
  }));
  const report = {
    ready_for_angle_response_fit: true,
    ready_for_matched10_validation: true,
    matched10_validation: { profile_key: "matched-key" },
    selected_pair: { trajectories_profile_key: "proxy-key", trajectories_profile_id: "proxy" },
    selected_fixed45_pair: { trajectories_profile_key: "proxy-key" },
    profile_sets: [{ profile_id: "proxy", profile_key: "proxy-key" }, { profile_id: "matched10", profile_key: "matched-key" }],
    matched_rows: [...proxyRows, ...matchedRows],
    merged_runs: [],
    runs: [],
  };
  const model = fitPredictor(report);
  assert.equal(model.calibration_profile.profile_id, "matched10");
  assert.ok(Math.abs(model.extra_drag_model.cda_at_mach_center_m2 - 5.4) < 1e-6);
  assert.equal(model.fit_rows.force, matchedRows.length);
  assert.deepEqual(model.trajectories_domain.altitude_m, [35000, 60000]);
  assert.equal(model.transfer_validation.ready, true);
  assert.equal(model.transfer_validation.profile_id, "proxy");
  assert.equal(model.transfer_validation.force_rows, proxyRows.length);
  assert.ok(model.transfer_validation.extra_drag_model.median_prediction_to_observation_ratio > 1.99);

  const proxyModel = fitPredictor(report, { profile: "proxy" });
  assert.equal(proxyModel.calibration_profile.profile_id, "proxy");
  assert.ok(Math.abs(proxyModel.extra_drag_model.cda_at_mach_center_m2 - 2.7) < 1e-6);
  assert.equal(proxyModel.transfer_validation.profile_id, "matched10");
  assert.ok(proxyModel.transfer_validation.extra_drag_model.median_prediction_to_observation_ratio < 0.51);
});
