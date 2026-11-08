"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { evaluateHoldout } = require("./evaluate-airbrake-holdout.js");

test("scores a clean fixed-angle run against the frozen corridor model", () => {
  const profileKey = JSON.stringify({ entry_corridor_id: "entry_fpa29", airbrake_authority_limiter_percent: 0 });
  const domain = {
    altitude_m: [45000, 55000],
    mach: [6, 8],
    dynamic_pressure_kpa: [0.5, 2],
    mass_t: [20, 20],
    airbrake_count: [4, 4],
  };
  const dragModel = {
    angle_sine_exponent: 2,
    mach_center: 7,
    cda_at_mach_center_m2: 3,
    cda_mach_slope_m2_per_mach: 0,
  };
  const responseModel = {
    angle_sine_exponent: 2,
    altitude_center_km: 50,
    altitude_log_slope_per_km: 0,
    scale: 100,
  };
  const model = {
    domain,
    trajectories_domain: domain,
    extra_drag_model: dragModel,
    trajectories_along_rate_model: { ...responseModel, scale: 50 },
    profile_adaptations: [{
      profile_id: "matched10",
      profile_key: profileKey,
      entry_corridor_id: "entry_fpa29",
      angle_anchors_deg: [60],
      domain,
      trajectories_domain: domain,
      trajectories_along_rate_model: responseModel,
    }],
  };
  const pairs = Array.from({ length: 41 }, (_, index) => ({
    off_run_id: "off",
    fixed_run_id: "holdout",
    fixed_mode: "fixed",
    trajectories_profile_id: "matched10",
    trajectories_profile_key: profileKey,
    entry_corridor_id: "entry_fpa29",
    off_time_s: index,
    fixed_time_s: index,
    altitude_m: 54000 - index * 200,
    mach: 7,
    dynamic_pressure_kpa: 1,
    mass_t: 20,
    fixed_airbrake_part_count: 4,
    fixed_airbrake_survival_fraction: 1,
    fixed_airbrake_estimated_angle_deg: 45,
    extra_deceleration_mps2: 0.3,
    impact_along_rate_delta_mps: 10,
    impact_along_miss_delta_m: index * 10,
  }));
  const report = {
    runs: [{
      run_id: "holdout",
      predicted_entry_fpa_down_deg: 2.9,
      expected_vessel_part_count: 35,
      minimum_vessel_part_count: 35,
      expected_airbrake_count: 4,
      minimum_airbrake_count: 4,
      first_vessel_part_loss_altitude_m: null,
      airbrake_angle_reassertion_count: 0,
      checks: {
        airbrake_angle_readback: true,
        airbrake_authority_limiter_zero: true,
        no_airbrake_angle_reassertions: true,
      },
    }],
    profile_sets: [{
      profile_id: "matched10",
      profile_key: profileKey,
      fixed45_pair: {
        fixed_run_id: "holdout",
        initial: { airspeed_delta_mps: 1, position_delta_m: 100 },
      },
    }],
  };
  const result = evaluateHoldout(model, pairs, report, {
    runId: "holdout",
    expectedAngleDeg: 45,
    expectedCumulativeKm: 0.4,
    cumulativeToleranceKm: 0.001,
    minRows: 40,
    modelSha256: "TEST",
  });
  assert.equal(result.qualification_pass, true);
  assert.equal(result.predictor_pass, true);
  assert.ok(Math.abs(result.metrics.drag.median_prediction_to_observation_ratio - 1) < 1e-12);
  assert.ok(Math.abs(result.metrics.trajectories_response.median_prediction_to_observation_ratio - 1) < 1e-12);
  assert.equal(result.metrics.cumulative_response.groups[0].observed_change_m, 400);
  assert.equal(result.survivability.full_integrity, true);
});
