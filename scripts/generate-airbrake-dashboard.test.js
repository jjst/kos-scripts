"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { buildDashboardData, generateDashboard, parseCsv } = require("./generate-airbrake-dashboard.js");

test("parses quoted CSV fields and typed values", () => {
  const rows = parseCsv('run_id,fields,ok,value\n1,"[1,2]",true,2.5\n2,"a ""quote""",false,\n');
  assert.deepEqual(rows[0], { run_id: 1, fields: [1, 2], ok: true, value: 2.5 });
  assert.deepEqual(rows[1], { run_id: 2, fields: 'a "quote"', ok: false, value: null });
});

test("keeps entry corridors separate and records first loss", () => {
  const sample = (runId, corridor, altitude, parts = 35) => ({
    run_id: runId, phase: "entry", time_s: 70 - altitude, altitude_asl_m: altitude * 1000,
    airbrake_control_mode: "fixed60", trajectories_profile_id: "matched10", entry_corridor_id: corridor,
    dynamic_pressure_kpa: 1, airbrake_estimated_angle_deg: 60, airbrake_part_count: parts === 35 ? 4 : 3,
    vessel_part_count: parts, airspeed_mps: 2100, flight_path_angle_deg: -3, impact_along_miss_m: 1000,
  });
  const samples = [];
  for (let altitude = 70; altitude >= 64; altitude -= 1) samples.push(sample(1, "old", altitude));
  for (let altitude = 70; altitude >= 64; altitude -= 1) samples.push(sample(2, "new", altitude, altitude < 67 ? 34 : 35));
  const data = buildDashboardData(samples, [], { runs: [{ run_id: "2", max_dynamic_pressure_kpa: 3, max_intact_dynamic_pressure_kpa: 2 }] }, {});
  assert.equal(data.runs.length, 2);
  assert.equal(data.runs[0].corridor_id, "new");
  assert.equal(data.runs[0].first_loss_altitude_km, 66);
  assert.equal(data.runs[0].max_dynamic_pressure_kpa, 3);
  assert.equal(data.runs[0].max_intact_dynamic_pressure_kpa, 2);
  assert.equal(data.runs[1].corridor_id, "old");
  assert.equal(data.runs[1].full_integrity, true);
});

test("selects the current authority-locked profile set and drops incomplete runs", () => {
  const rows = (runId) => Array.from({ length: 6 }, (_, index) => ({
    run_id: runId, phase: "entry", time_s: index, altitude_asl_m: (70 - index) * 1000,
    airbrake_control_mode: "off", trajectories_profile_id: "matched10", entry_corridor_id: "same",
    dynamic_pressure_kpa: 1, airbrake_part_count: 4, vessel_part_count: 35,
  }));
  const report = {
    runs: [
      { run_id: "old", checks: { complete_status: true } },
      { run_id: "current", checks: { complete_status: true } },
      { run_id: "borked", checks: { complete_status: false } },
    ],
    profile_sets: [
      { profile_id: "matched10", profile_key: JSON.stringify({ entry_corridor_id: "same", airbrake_authority_limiter_percent: "unverified" }), run_ids: ["old"] },
      { profile_id: "matched10", profile_key: JSON.stringify({ entry_corridor_id: "same", airbrake_authority_limiter_percent: 0 }), run_ids: ["current", "borked"] },
    ],
  };
  const data = buildDashboardData([...rows("old"), ...rows("current"), ...rows("borked")], [], report, {});
  assert.deepEqual(data.runs.map((run) => run.run_id), ["current"]);
});

test("keeps deorbit phase calibrations separate in dashboard data", () => {
  const rows = (runId, phaseTarget) => Array.from({ length: 6 }, (_, index) => ({
    run_id: runId, phase: "entry", time_s: index, altitude_asl_m: (70 - index) * 1000,
    airbrake_control_mode: "fixed60", trajectories_profile_id: "matched10", entry_corridor_id: "entry_fpa29",
    target_deorbit_phase_angle_deg: phaseTarget, dynamic_pressure_kpa: 1, airbrake_estimated_angle_deg: 60,
    airbrake_part_count: 4, vessel_part_count: 35,
  }));
  const profileKey = (phaseTarget) => JSON.stringify({
    entry_corridor_id: "entry_fpa29",
    deorbit_phase_target_deg: phaseTarget,
    airbrake_authority_limiter_percent: 0,
  });
  const report = {
    runs: [
      { run_id: "phase180", target_deorbit_phase_angle_deg: 180, checks: { complete_status: true } },
      { run_id: "phase175", target_deorbit_phase_angle_deg: 175, landing_along_miss_m: -5000, landing_cross_miss_m: 500, landing_miss_m: 5025, checks: { complete_status: true } },
    ],
    profile_sets: [
      { profile_id: "matched10", profile_key: profileKey(180), run_ids: ["phase180"] },
      { profile_id: "matched10", profile_key: profileKey(175), run_ids: ["phase175"] },
    ],
    controllable_corridor_validation: [{ profile_id: "matched10", entry_corridor_id: "entry_fpa29", target_deorbit_phase_angle_deg: 175 }],
  };
  const data = buildDashboardData([...rows("phase180", 180), ...rows("phase175", 175)], [], report, {});
  assert.deepEqual(data.runs.map((run) => run.phase_key).sort(), ["175", "180"]);
  assert.equal(data.runs.find((run) => run.phase_key === "175").landing_along_miss_km, -5);
  assert.equal(data.corridor_validations.length, 1);
});

test("uses corridor adaptations for response curves and remaining-correction scenarios", () => {
  const oldKey = JSON.stringify({ entry_corridor_id: "old", airbrake_authority_limiter_percent: 0 });
  const correctedKey = JSON.stringify({ entry_corridor_id: "corrected", airbrake_authority_limiter_percent: 0 });
  const rows = (runId, corridor) => [60, 58, 56, 54, 52, 50].map((altitude, index) => ({
    run_id: runId,
    phase: "entry",
    time_s: index,
    altitude_asl_m: altitude * 1000,
    airbrake_control_mode: "off",
    trajectories_profile_id: "matched10",
    entry_corridor_id: corridor,
    dynamic_pressure_kpa: 1,
    mach_model: 7,
    mass_t: 20,
    airbrake_part_count: 4,
    vessel_part_count: 35,
    impact_along_miss_m: 1000,
  }));
  const responseModel = (scale) => ({
    angle_sine_exponent: 2,
    altitude_center_km: 45,
    altitude_log_slope_per_km: 0,
    scale,
  });
  const predictor = {
    calibration_profile: { profile_id: "matched10", profile_key: oldKey },
    domain: { altitude_m: [50000, 60000], mach: [6, 8], dynamic_pressure_kpa: [0.5, 2], mass_t: [20, 20], airbrake_count: [4, 4] },
    trajectories_along_rate_model: responseModel(10),
    profile_adaptations: [{
      profile_id: "matched10",
      profile_key: correctedKey,
      entry_corridor_id: "corrected",
      angle_anchors_deg: [60],
      domain: { altitude_m: [50000, 60000], mach: [6, 8], dynamic_pressure_kpa: [0.5, 2], mass_t: [20, 20], airbrake_count: [4, 4] },
      trajectories_along_rate_model: responseModel(20),
    }],
  };
  const report = {
    runs: [
      { run_id: "old-off", checks: { complete_status: true } },
      { run_id: "corrected-off", checks: { complete_status: true } },
    ],
    profile_sets: [
      { profile_id: "matched10", profile_key: oldKey, run_ids: ["old-off"] },
      { profile_id: "matched10", profile_key: correctedKey, run_ids: ["corrected-off"] },
    ],
  };
  const data = buildDashboardData([...rows("old-off", "old"), ...rows("corrected-off", "corrected")], [], report, predictor);
  const correctedModel = data.trajectory_response_models.find((entry) => entry.corridor_id === "corrected");
  assert.equal(correctedModel.source, "corridor adaptation");
  assert.equal(correctedModel.model.scale, 20);
  assert.deepEqual(correctedModel.angle_anchors_deg, [60]);
  const oldScenario = data.adjusted_predictor_scenarios.find((entry) => entry.corridor_id === "old" && entry.angle_deg === 60 && entry.start_altitude_km === 60);
  const correctedScenario = data.adjusted_predictor_scenarios.find((entry) => entry.corridor_id === "corrected" && entry.angle_deg === 60 && entry.start_altitude_km === 60);
  assert.equal(oldScenario.model_source, "multi-angle calibration");
  assert.equal(correctedScenario.model_source, "corridor adaptation");
  assert.equal(correctedScenario.remaining_correction_km, oldScenario.remaining_correction_km * 2);
});

test("generates a self-contained dashboard", () => {
  const html = generateDashboard({ runs: [], measured_cda: [], measured_trajectory_response: [], adjusted_predictor_scenarios: [], predictor: {}, readiness: {} });
  assert.match(html, /^<!doctype html>/);
  assert.match(html, /Airbrake reentry telemetry/);
  assert.match(html, /Deorbit phase/);
  assert.match(html, /Control corridor/);
  assert.match(html, /Peak Q while intact, eventual entry peak, and Q at first loss/);
  assert.match(html, /survivability-chart/);
  assert.match(html, /const DATA=/);
  assert.match(html, /entry progression — altitude \(km\)/);
  assert.match(html, /const sx=x=>m\.l\+\(70-x\)\/50\*w/);
  assert.match(html, /Closer to 0 km is better/);
  assert.match(html, /Lower peaks are generally safer/);
  assert.match(html, /neither direction is universally better/);
  assert.match(html, /not automatically a better overall trajectory/);
  assert.match(html, /no universal failure threshold has emerged/);
  assert.match(html, /className='chart-summary'/);
  assert.doesNotMatch(html, /fetch\(/);
  const embeddedScript = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
  assert.ok(embeddedScript);
  assert.doesNotThrow(() => new Function(embeddedScript));
});
