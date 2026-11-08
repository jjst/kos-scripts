"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  adjustedTrajectoriesAlongMiss,
  extraDragDeceleration,
  extraTrajectoriesAlongRate,
  integrateRemainingCorrection,
  predictorForContext,
  solveFixedAngleForCorrection,
  stateInCalibrationDomain,
} = require("./airbrake-adjusted-predictor.js");

const predictor = {
  domain: { altitude_m: [40000, 60000], mach: [6, 8], dynamic_pressure_kpa: [0.1, 3], mass_t: [19, 21], airbrake_count: [4, 4] },
  extra_drag_model: { angle_sine_exponent: 2, mach_center: 7, cda_at_mach_center_m2: 3, cda_mach_slope_m2_per_mach: 0.5 },
  trajectories_along_rate_model: { angle_sine_exponent: 2, altitude_center_km: 50, altitude_log_slope_per_km: 0, scale: 100 },
};
const state = (time, altitude = 50000) => ({ time_s: time, altitude_m: altitude, mach: 7, dynamic_pressure_kpa: 1, mass_t: 20, airbrake_count: 4 });

test("computes instantaneous extra drag and Trajectories response", () => {
  assert.ok(Math.abs(extraDragDeceleration(predictor, state(0), 90) - 0.6) < 1e-12);
  assert.ok(Math.abs(extraTrajectoriesAlongRate(predictor, state(0), 90) - 20) < 1e-12);
  assert.ok(Math.abs(extraTrajectoriesAlongRate(predictor, state(0), 30) - 5) < 1e-12);
});

test("integrates only the remaining future response and adds it to current Trajectories miss", () => {
  const result = integrateRemainingCorrection(predictor, [state(0), state(5), state(10)], 90);
  assert.ok(Math.abs(result.remaining_correction_m - 200) < 1e-9);
  assert.equal(result.complete, true);
  assert.equal(adjustedTrajectoriesAlongMiss(1000, result), 1200);
});

test("reports clipped coverage instead of silently extrapolating", () => {
  const states = [state(0, 55000), state(5, 50000), state(10, 35000)];
  assert.throws(() => integrateRemainingCorrection(predictor, states, 90), /leaves the predictor calibration domain/);
  const clipped = integrateRemainingCorrection(predictor, states, 90, { domainPolicy: "clip" });
  assert.equal(clipped.remaining_correction_m, 100);
  assert.equal(clipped.coverage_fraction, 0.5);
  assert.equal(clipped.complete, false);
  assert.equal(clipped.interpretation, "calibrated-domain lower bound");
  assert.equal(stateInCalibrationDomain(predictor, state(0, 35000)), false);
});

test("clips Trajectories integration to its own response-fit domain", () => {
  const splitDomains = {
    ...predictor,
    domain: { ...predictor.domain, altitude_m: [40000, 60000] },
    trajectories_domain: { ...predictor.domain, altitude_m: [45000, 55000] },
  };
  assert.equal(stateInCalibrationDomain(splitDomains, state(0, 57500)), false);
  assert.equal(stateInCalibrationDomain(splitDomains, state(0, 50000)), true);
});

test("allows negligible paired-run drift around a zero-width calibration domain", () => {
  const exactDomain = { ...predictor, domain: { ...predictor.domain, mass_t: [20, 20] } };
  assert.equal(stateInCalibrationDomain(exactDomain, { ...state(0), mass_t: 20.001 }), true);
  assert.equal(stateInCalibrationDomain(exactDomain, { ...state(0), mass_t: 20.01 }), false);
});

test("solves deployment angle for a requested remaining correction", () => {
  const solution = solveFixedAngleForCorrection(predictor, [state(0), state(10)], 50);
  assert.ok(Math.abs(solution.angle_deg - 30) < 1e-8);
  assert.equal(solution.saturated, false);
  const saturated = solveFixedAngleForCorrection(predictor, [state(0), state(10)], 300);
  assert.equal(saturated.angle_deg, 90);
  assert.equal(saturated.saturated, true);
});

test("selects a corridor-specific Trajectories-response anchor", () => {
  const profileKeyObject = { entry_corridor_id: "entry_fpa29", airbrake_authority_limiter_percent: 0 };
  const withAdaptation = {
    ...predictor,
    profile_adaptations: [{
      profile_id: "matched10",
      profile_key: JSON.stringify(profileKeyObject),
      entry_corridor_id: "entry_fpa29",
      angle_anchors_deg: [60],
      domain: { ...predictor.domain, altitude_m: [45000, 60000] },
      trajectories_domain: { ...predictor.domain, altitude_m: [47000, 58000] },
      trajectories_along_rate_model: { ...predictor.trajectories_along_rate_model, scale: 250 },
    }],
  };
  const adapted = predictorForContext(withAdaptation, { profile_id: "matched10", corridor_id: "entry_fpa29" });
  assert.equal(adapted.trajectories_along_rate_model.scale, 250);
  assert.deepEqual(adapted.domain.altitude_m, [45000, 60000]);
  assert.deepEqual(adapted.trajectories_domain.altitude_m, [47000, 58000]);
  assert.equal(adapted.active_profile_adaptation.entry_corridor_id, "entry_fpa29");
  const adaptedFromDecodedCsv = predictorForContext(withAdaptation, { profile_key: profileKeyObject });
  assert.equal(adaptedFromDecodedCsv.trajectories_along_rate_model.scale, 250);
  const base = predictorForContext(withAdaptation, { profile_id: "matched10", corridor_id: "other" });
  assert.equal(base, withAdaptation);
});
