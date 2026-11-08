"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  analyzeSegments,
  decodeKos,
  readSegment,
} = require("./analyze-reentry-telemetry.js");

function encodeKos(value) {
  if (Array.isArray(value)) {
    return { items: value.map(encodeKos), $type: "kOS.Safe.Encapsulation.ListValue" };
  }
  if (value && typeof value === "object") {
    const entries = [];
    for (const [key, child] of Object.entries(value)) entries.push(key, encodeKos(child));
    return { entries, $type: "kOS.Safe.Encapsulation.Lexicon" };
  }
  if (typeof value === "string") return { value, $type: "kOS.Safe.Encapsulation.StringValue" };
  if (typeof value === "boolean") return { value, $type: "kOS.Safe.Encapsulation.BooleanValue" };
  if (typeof value === "number") return { value, $type: Number.isInteger(value) ? "kOS.Safe.Encapsulation.ScalarIntValue" : "kOS.Safe.Encapsulation.ScalarDoubleValue" };
  return value;
}

function makeRun(runId, mode, profileId = "proxy", customFixedAngle = null, entryCorridorId = "trajectories_miss") {
  const fixedAngle = customFixedAngle ?? (mode === "fixed90" ? 90 : mode === "fixed60" ? 60 : mode === "fixed50" ? 50 : mode === "fixed45" ? 45 : mode === "fixed30" ? 30 : 0);
  const deployFraction = fixedAngle / 90;
  const samples = [];
  for (let i = 0; i < 30; i += 1) {
    const altitude = 70000 - i * (50000 / 29);
    samples.push({
      time_s: 1000 + i * 2,
      elapsed_s: i * 2,
      phase: "entry",
      latitude_deg: -0.1 + i * 0.01,
      longitude_deg: -74.5 + i * 0.01,
      altitude_asl_m: altitude,
      altitude_radar_m: altitude,
      surface_speed_mps: 2200 - i * 20,
      horizontal_speed_mps: 2100 - i * 20,
      vertical_speed_mps: -100 - i * 2,
      airspeed_mps: 2200 - i * 20,
      airspeed_rate_mps2: -8 - 4 * deployFraction,
      dynamic_pressure_atm: 0.001 + i * 0.001,
      dynamic_pressure_kpa: 0.101325 + i * 0.101325,
      density_from_q_kgpm3: 0.01 + i * 0.005,
      static_pressure_model_atm: 0.001 + i * 0.002,
      temperature_model_k: 220,
      density_model_kgpm3: 0.01 + i * 0.005,
      sound_speed_model_mps: 300,
      mach_model: (2200 - i * 20) / 300,
      static_pressure_sensor_kpa: 0,
      temperature_sensor_k: 0,
      acceleration_sensor_magnitude_mps2: 0,
      gravity_sensor_g: 0,
      gravity_model_mps2: 9.8,
      mass_t: 100,
      aoa_command_deg: 10,
      aoa_actual_deg: 10,
      trajectories_planned_aoa_deg: 10,
      trajectories_planned_facing_error_deg: profileId === "matched10" ? 0.1 : 5,
      airbrake_angle_command_deg: fixedAngle,
      airbrake_angle_deg: fixedAngle,
      airbrake_deploy_angle_fields_deg: [fixedAngle, fixedAngle, fixedAngle, fixedAngle],
      airbrake_deploy_angle_field_min_deg: fixedAngle,
      airbrake_deploy_angle_field_max_deg: fixedAngle,
      airbrake_deploy_angle_field_spread_deg: 0,
      airbrake_angle_reassertion_count: 0,
      airbrake_authority_limiter_fields_percent: [0, 0, 0, 0],
      airbrake_authority_limiter_field_min_percent: 0,
      airbrake_authority_limiter_field_max_percent: 0,
      airbrake_authority_limiter_field_spread_percent: 0,
      airbrake_part_count: 4,
      vessel_part_count: 24,
      brakes_action_group: mode === "fixed" || fixedAngle > 0,
      airbrake_pid_output_deg: 0,
      airbrake_pid_kp: 0,
      throttle_command: 0,
      has_trajectories_impact: true,
      impact_lat_deg: -0.1,
      impact_lng_deg: -74.5,
      impact_miss_m: 100000 - i * 1000,
      impact_along_miss_m: 100000 - i * (1000 + 500 * deployFraction),
      impact_cross_miss_m: 0,
    });
  }
  return {
    schema: "reentry_airbrake_predictor",
    schema_version: 1,
    status: "guided_landing_handoff",
    segment_index: 0,
    run: {
      run_id: runId,
      body: "Kerbin",
      body_radius_m: 600000,
      airbrake_control_mode: mode,
      trajectories_profile_id: profileId,
      entry_corridor_id: entryCorridorId,
      trajectories_descent_angles_deg: profileId === "matched10" ? [-170, -170, -170, -170] : [170, 170, 165, 165],
      trajectories_descent_grades: [true, true, true, true],
      trajectories_descent_modes: [true, true, true, true],
      entry_aoa_deg: 10,
      entry_steering_source: "scripted_signed_aoa",
      airbrake_fixed_angle_deg: fixedAngle,
      airbrake_part_count: 4,
      initial_vessel_part_count: 24,
      airbrake_actuator_speed_degps: 20,
      airbrake_authority_limiter_command_percent: 0,
      airbrake_authority_limiter_original_fields_percent: [90, 90, 90, 90],
      has_pressure_sensor: false,
      has_temperature_sensor: false,
      has_acceleration_sensor: false,
      has_gravity_sensor: false,
    },
    samples,
    events: [],
  };
}

test("decodes kOS typed lexicons and lists", () => {
  const source = { schema: "example", samples: [{ value: 42 }] };
  assert.deepEqual(decodeKos(encodeKos(source)), source);
});

test("reads a real-format segment and accepts a matched off/fixed90 pair", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "reentry-telemetry-test-"));
  const files = [];
  for (const [id, mode] of [[100, "off"], [101, "fixed90"]]) {
    const file = path.join(dir, `reentry_telemetry_${id}_${mode}_part_0.json`);
    fs.writeFileSync(file, JSON.stringify(encodeKos(makeRun(id, mode))), "utf8");
    files.push(file);
  }
  const report = analyzeSegments(files.map(readSegment));
  assert.equal(report.ready_for_differential_fit, true);
  assert.equal(report.selected_pair.comparable, true);
  assert.equal(report.selected_pair.matched_sample_count, 30);
  assert.equal(report.matched_rows[1].extra_deceleration_mps2, 4);
  assert.equal(report.matched_rows[1].impact_along_miss_delta_m, -500);
  assert.ok(report.matched_rows[3].extra_cd_area_m2 > 0);
  assert.ok(report.matched_rows[3].extra_cd_area_per_airbrake_m2 > 0);
  const fixedSample = report.merged_runs.find((run) => run.mode === "fixed90").samples.at(-1);
  assert.ok(Math.abs(fixedSample.airbrake_load_proxy_kpa - fixedSample.dynamic_pressure_kpa) < 1e-9);
  assert.ok(fixedSample.convective_heating_rate_proxy > 0);
  assert.ok(fixedSample.convective_heating_exposure_proxy > 0);
  assert.ok(fixedSample.airbrake_heating_exposure_proxy > 0);
  assert.equal(fixedSample.dynamic_pressure_fraction_of_run_peak, 1);
  assert.equal(report.matched_rows[0].entry_corridor_id, "trajectories_miss");
});

test("does not claim readiness without a fixed90 run", () => {
  const segment = { ...makeRun(100, "off"), source_file: "off.json" };
  const report = analyzeSegments([segment]);
  assert.equal(report.ready_for_differential_fit, false);
  assert.equal(report.readiness.has_fixed90_run, false);
});

test("accepts a fixed45 run and builds the deployment-angle response dataset", () => {
  const segments = [
    { ...makeRun(100, "off"), source_file: "off.json" },
    { ...makeRun(101, "fixed90"), source_file: "fixed90.json" },
    { ...makeRun(102, "fixed45"), source_file: "fixed45.json" },
  ];
  const report = analyzeSegments(segments);
  assert.equal(report.ready_for_differential_fit, true);
  assert.equal(report.ready_for_angle_response_fit, true);
  assert.equal(report.selected_fixed45_pair.comparable, true);
  assert.equal(report.selected_fixed45_pair.fixed_angle_deg, 45);
  assert.equal(report.selected_fixed45_pair.matched_sample_count, 30);
  assert.equal(report.matched_rows.filter((row) => row.fixed_mode === "fixed45").length, 30);
  assert.equal(report.matched_rows.find((row) => row.fixed_mode === "fixed45").extra_deceleration_mps2, 2);
});

test("includes a fixed60 run as an additional deployment-angle response point", () => {
  const segments = [
    { ...makeRun(100, "off"), source_file: "off.json" },
    { ...makeRun(103, "fixed60"), source_file: "fixed60.json" },
  ];
  const report = analyzeSegments(segments);
  assert.equal(report.selected_fixed60_pair.comparable, true);
  assert.equal(report.selected_fixed60_pair.fixed_angle_deg, 60);
  assert.equal(report.selected_fixed60_pair.matched_sample_count, 30);
  assert.equal(report.matched_rows.filter((row) => row.fixed_mode === "fixed60").length, 30);
});

test("includes a fixed50 run as an additional deployment-angle response point", () => {
  const segments = [
    { ...makeRun(100, "off"), source_file: "off.json" },
    { ...makeRun(104, "fixed50"), source_file: "fixed50.json" },
  ];
  const report = analyzeSegments(segments);
  assert.equal(report.selected_fixed50_pair.comparable, true);
  assert.equal(report.selected_fixed50_pair.fixed_angle_deg, 50);
  assert.equal(report.selected_fixed50_pair.matched_sample_count, 30);
  assert.equal(report.matched_rows.filter((row) => row.fixed_mode === "fixed50").length, 30);
});

test("keeps every validated custom fixed angle as a separate model-fit pair", () => {
  const segments = [
    { ...makeRun(100, "off", "matched10"), source_file: "off.json" },
    { ...makeRun(105, "fixed", "matched10", 52.5), source_file: "fixed-52-5.json" },
    { ...makeRun(106, "fixed", "matched10", 57.25), source_file: "fixed-57-25.json" },
  ];
  const report = analyzeSegments(segments);
  assert.equal(report.custom_fixed_pairs.length, 2);
  assert.deepEqual(report.custom_fixed_pairs.map((pair) => pair.fixed_angle_deg), [52.5, 57.25]);
  assert.equal(report.matched_rows.filter((row) => row.fixed_mode === "fixed").length, 60);
});

test("rejects a run with a missing telemetry segment", () => {
  const source = makeRun(200, "off").samples;
  const run = makeRun(200, "off").run;
  const report = analyzeSegments([
    { schema: "reentry_airbrake_predictor", schema_version: 1, status: "running", segment_index: 0, run, samples: source.slice(0, 15), events: [], source_file: "part0.json" },
    { schema: "reentry_airbrake_predictor", schema_version: 1, status: "guided_landing_handoff", segment_index: 2, run, samples: source.slice(15), events: [], source_file: "part2.json" },
  ]);
  assert.equal(report.runs[0].checks.contiguous_segments, false);
  assert.equal(report.runs[0].usable, false);
});

test("rejects a fixed-angle run when per-part readback diverges", () => {
  const segment = { ...makeRun(300, "fixed45"), source_file: "fixed45-mismatch.json" };
  segment.samples[10] = {
    ...segment.samples[10],
    airbrake_deploy_angle_fields_deg: [45, 45, 70, 45],
    airbrake_deploy_angle_field_max_deg: 70,
    airbrake_deploy_angle_field_spread_deg: 25,
    airbrake_angle_reassertion_count: 1,
  };
  const report = analyzeSegments([segment]);
  assert.equal(report.runs[0].checks.airbrake_angle_readback, false);
  assert.equal(report.runs[0].checks.no_airbrake_angle_reassertions, false);
  assert.equal(report.runs[0].airbrake_angle_field_max_spread_deg, 25);
  assert.equal(report.runs[0].usable, false);
});

test("never pairs runs from different Trajectories profiles", () => {
  const report = analyzeSegments([
    { ...makeRun(400, "off", "proxy"), source_file: "proxy-off.json" },
    { ...makeRun(401, "fixed90", "matched10"), source_file: "matched-fixed90.json" },
  ]);
  assert.equal(report.selected_pair, null);
  assert.equal(report.ready_for_differential_fit, false);
  assert.equal(report.matched_rows.length, 0);
});

test("never pairs runs from different entry corridors", () => {
  const report = analyzeSegments([
    { ...makeRun(410, "off", "matched10", null, "trajectories_miss"), source_file: "old-corridor-off.json" },
    { ...makeRun(411, "fixed60", "matched10", null, "entry_fpa29"), source_file: "fpa29-fixed60.json" },
  ]);
  assert.equal(report.selected_fixed60_pair, null);
  assert.equal(report.matched_rows.length, 0);
});

test("never pairs runs from different deorbit phase targets", () => {
  const off = { ...makeRun(420, "off", "matched10", null, "entry_fpa29"), source_file: "phase-180-off.json" };
  const fixed = { ...makeRun(421, "fixed60", "matched10", null, "entry_fpa29"), source_file: "phase-175-fixed60.json" };
  off.run.target_deorbit_phase_angle_deg = 180;
  off.run.actual_deorbit_burn_phase_angle_deg = 179.8;
  fixed.run.target_deorbit_phase_angle_deg = 175;
  fixed.run.actual_deorbit_burn_phase_angle_deg = 174.7;
  const report = analyzeSegments([off, fixed]);
  assert.equal(report.selected_fixed60_pair, null);
  assert.equal(report.matched_rows.length, 0);
  assert.equal(report.runs.find((run) => run.run_id === "421").target_deorbit_phase_angle_deg, 175);
  assert.equal(report.runs.find((run) => run.run_id === "421").actual_deorbit_burn_phase_angle_deg, 174.7);
});

test("rejects PID telemetry outside its recorded safe airbrake envelope", () => {
  const segment = { ...makeRun(430, "pid", "matched10", null, "entry_fpa29"), source_file: "pid-below-safe-min.json" };
  segment.run.airbrake_min_angle_deg = 60;
  segment.run.airbrake_max_angle_deg = 90;
  segment.samples = segment.samples.map((sample) => ({
    ...sample,
    airbrake_angle_command_deg: 45,
    airbrake_angle_deg: 45,
    airbrake_deploy_angle_fields_deg: [45, 45, 45, 45],
    airbrake_deploy_angle_field_min_deg: 45,
    airbrake_deploy_angle_field_max_deg: 45,
    brakes_action_group: true,
  }));
  const report = analyzeSegments([segment]);
  assert.equal(report.runs[0].checks.mode_compliance, false);
  assert.equal(report.runs[0].airbrake_min_angle_deg, 60);
  assert.equal(report.runs[0].airbrake_max_angle_deg, 90);
  assert.equal(report.runs[0].usable, false);
});

test("opens the closed-loop gate only when intact 60 and 90 degree landings bracket the target", () => {
  const targetLatitude = -0.0972;
  const targetLongitude = -74.2;
  const endpoint = (runId, mode, landingLongitude) => {
    const segment = { ...makeRun(runId, mode, "matched10", null, "entry_fpa29"), source_file: `${mode}.json` };
    segment.run.target_lat_deg = targetLatitude;
    segment.run.target_lng_deg = targetLongitude;
    segment.run.target_deorbit_phase_angle_deg = 175;
    segment.run.actual_deorbit_burn_phase_angle_deg = 174.8;
    segment.samples = segment.samples.map((sample) => ({ ...sample, latitude_deg: targetLatitude }));
    segment.samples.push({
      time_s: 1100,
      phase: "landing_final",
      latitude_deg: targetLatitude,
      longitude_deg: landingLongitude,
      altitude_asl_m: 0,
      altitude_radar_m: 0,
      surface_speed_mps: 0,
      vertical_speed_mps: 0,
      dynamic_pressure_kpa: 0,
      mass_t: 90,
      vessel_part_count: 24,
      airbrake_part_count: 4,
      vessel_status: "LANDED",
    });
    return segment;
  };
  const pid = endpoint(442, "pid", targetLongitude + 0.001);
  pid.status = "landed";
  pid.run.airbrake_min_angle_deg = 60;
  pid.run.airbrake_max_angle_deg = 90;
  pid.samples = pid.samples.map((sample, index) => {
    if (sample.phase !== "entry") return sample;
    const angle = [60, 75, 90][index % 3];
    return {
      ...sample,
      airbrake_angle_command_deg: angle,
      airbrake_angle_deg: angle,
      airbrake_deploy_angle_fields_deg: [angle, angle, angle, angle],
      airbrake_deploy_angle_field_min_deg: angle,
      airbrake_deploy_angle_field_max_deg: angle,
      brakes_action_group: true,
    };
  });
  pid.samples.push({
    time_s: 1090,
    phase: "guided_landing_handoff",
    latitude_deg: targetLatitude,
    longitude_deg: targetLongitude,
    impact_miss_m: 1000,
    vessel_part_count: 24,
    airbrake_part_count: 4,
  });
  const report = analyzeSegments([
    endpoint(440, "fixed60", targetLongitude + 0.01),
    endpoint(441, "fixed90", targetLongitude - 0.01),
    pid,
  ]);
  const validation = report.controllable_corridor_validation.find((item) => item.target_deorbit_phase_angle_deg === 175);
  assert.ok(validation);
  assert.equal(validation.endpoints_ready, true);
  assert.equal(validation.fixed60.full_integrity, true);
  assert.equal(validation.fixed90.full_integrity, true);
  assert.ok(validation.fixed60.landing_along_miss_m < 0);
  assert.ok(validation.fixed90.landing_along_miss_m > 0);
  assert.equal(validation.expected_angle_ordering, true);
  assert.equal(validation.target_bracketed, true);
  assert.equal(validation.closed_loop_test_ready, true);
  const closedLoop = report.closed_loop_validation.find((item) => item.run_id === "442");
  assert.ok(closedLoop);
  assert.equal(closedLoop.checks.corridor_ready, true);
  assert.equal(closedLoop.checks.safe_envelope_compliance, true);
  assert.ok(closedLoop.command_interior_fraction >= 0.3);
  assert.equal(closedLoop.passed, true);
});

test("accepts matched10 off/fixed30/fixed45/fixed90 transfer-validation runs", () => {
  const report = analyzeSegments([
    { ...makeRun(500, "off", "matched10"), source_file: "matched-off.json" },
    { ...makeRun(501, "fixed30", "matched10"), source_file: "matched-fixed30.json" },
    { ...makeRun(502, "fixed45", "matched10"), source_file: "matched-fixed45.json" },
    { ...makeRun(503, "fixed90", "matched10"), source_file: "matched-fixed90.json" },
  ]);
  assert.equal(report.ready_for_matched10_validation, true);
  assert.equal(report.runs[0].trajectories_planned_vector_alignment_ratio, 1);
  assert.equal(report.runs[0].trajectories_planned_vector_p90_error_deg, 0.1);
  assert.equal(report.selected_fixed30_pair.fixed_angle_deg, 30);
  assert.equal(report.profile_sets[0].fixed30_pair.comparable, true);
  assert.equal(report.matched_rows.filter((row) => row.fixed_mode === "fixed30").length, 30);
});

test("rejects matched10 telemetry that did not follow Trajectories' planned vector", () => {
  const segment = { ...makeRun(510, "off", "matched10"), source_file: "unverified-sign.json" };
  segment.samples = segment.samples.map((sample) => ({ ...sample, trajectories_planned_facing_error_deg: 20 }));
  const report = analyzeSegments([segment]);
  assert.equal(report.runs[0].checks.trajectories_planned_vector_alignment, false);
  assert.equal(report.runs[0].usable, false);
});

test("rejects matched10 telemetry when control-surface authority could override airbrake deployment", () => {
  const segment = { ...makeRun(515, "fixed30", "matched10"), source_file: "authority-90.json" };
  segment.run = { ...segment.run, airbrake_authority_limiter_command_percent: 90 };
  segment.samples = segment.samples.map((sample) => ({
    ...sample,
    airbrake_authority_limiter_fields_percent: [90, 90, 90, 90],
    airbrake_authority_limiter_field_min_percent: 90,
    airbrake_authority_limiter_field_max_percent: 90,
  }));
  const report = analyzeSegments([segment]);
  assert.equal(report.runs[0].checks.airbrake_authority_limiter_zero, false);
  assert.equal(report.runs[0].airbrake_authority_limiter_max_percent, 90);
  assert.equal(report.runs[0].usable, false);
});

test("rejects a matched fixed-angle run after any vessel part loss", () => {
  const segment = { ...makeRun(520, "fixed30", "matched10"), source_file: "part-loss.json" };
  segment.samples = segment.samples.map((sample, index) => ({ ...sample, vessel_part_count: index < 20 ? 24 : 23 }));
  const report = analyzeSegments([segment]);
  assert.equal(report.runs[0].checks.no_vessel_part_loss, false);
  assert.equal(report.runs[0].minimum_vessel_part_count, 23);
  assert.ok(report.runs[0].first_vessel_part_loss_altitude_m < 40000);
  assert.ok(report.runs[0].max_intact_dynamic_pressure_kpa < report.runs[0].max_dynamic_pressure_kpa);
  assert.equal(report.runs[0].usable, false);
});

test("counts a breakup as a survivability result while retaining clean pre-failure fit readiness", () => {
  const off = { ...makeRun(530, "off", "matched10"), source_file: "off.json" };
  const fixedRuns = [
    { id: 531, mode: "fixed30" },
    { id: 532, mode: "fixed45" },
    { id: 533, mode: "fixed90" },
  ].map(({ id, mode }) => {
    const segment = { ...makeRun(id, mode, "matched10"), source_file: `${mode}.json` };
    segment.samples = segment.samples.map((sample, index) => ({
      ...sample,
      vessel_part_count: index < 22 ? 24 : 23,
      airbrake_part_count: index < 22 ? 4 : 3,
    }));
    return segment;
  });
  const report = analyzeSegments([off, ...fixedRuns]);
  assert.equal(report.ready_for_matched10_validation, true);
  assert.equal(report.matched10_validation.fixed90_pair_comparable, true);
  assert.equal(report.matched10_survivability.corridor_has_full_integrity_result, false);
  assert.equal(report.matched10_survivability.runs.length, 3);
  assert.ok(report.matched10_survivability.runs.every((run) => !run.full_integrity));
  assert.ok(report.matched10_survivability.runs.every((run) => run.first_loss_airbrake_load_proxy_kpa > 0));
  assert.ok(report.matched10_survivability.runs.every((run) => run.first_loss_convective_heating_exposure_proxy > 0));
  assert.ok(report.matched10_survivability.runs.every((run) => run.first_loss_airbrake_heating_exposure_proxy > 0));
});

test("reports corridor survivability without requiring an off pair or predictor-fit alignment", () => {
  const corrected = { ...makeRun(540, "fixed60", "matched10", null, "entry_fpa29"), source_file: "corrected-corridor-fixed60.json" };
  corrected.status = "landed";
  corrected.samples = corrected.samples.map((sample) => ({
    ...sample,
    trajectories_planned_facing_error_deg: sample.dynamic_pressure_kpa > 0.5 ? 6 : 0.1,
  }));

  const report = analyzeSegments([corrected]);
  const corridor = report.survivability_by_profile_corridor.find((group) => group.entry_corridor_id === "entry_fpa29");
  assert.ok(corridor);
  assert.equal(corridor.corridor_has_full_integrity_result, true);
  assert.deepEqual(corridor.full_integrity_angles_deg, [60]);
  assert.equal(corridor.runs[0].full_integrity, true);
  assert.equal(corridor.runs[0].predictor_fit_usable, false);
});

test("extends survivability checks through landing telemetry segments", () => {
  const entry = makeRun(525, "fixed30", "matched10");
  const landing = {
    schema: "reentry_airbrake_predictor",
    schema_version: 2,
    status: "landed",
    segment_index: 1,
    run: entry.run,
    samples: [{
      time_s: 1100,
      phase: "landing_phase_1",
      altitude_asl_m: 15000,
      altitude_radar_m: 15000,
      dynamic_pressure_kpa: 40,
      vessel_part_count: 23,
      airbrake_part_count: 4,
      mass_t: 19,
    }],
    events: [],
    source_file: "landing-part-loss.json",
  };
  const report = analyzeSegments([{ ...entry, source_file: "entry.json" }, landing]);
  assert.equal(report.runs[0].status, "landed");
  assert.equal(report.runs[0].checks.no_vessel_part_loss, false);
  assert.equal(report.runs[0].first_vessel_part_loss_altitude_m, 15000);
  assert.equal(report.runs[0].first_vessel_part_loss_dynamic_pressure_kpa, 40);
});

test("selects the corrected signed matched10 set over an older rejected set", () => {
  const old = { ...makeRun(490, "off", "matched10"), source_file: "old-positive-sign.json" };
  old.run = { ...old.run, trajectories_descent_angles_deg: [170, 170, 170, 170] };
  old.samples = old.samples.map((sample) => ({ ...sample, trajectories_planned_facing_error_deg: 20 }));
  const report = analyzeSegments([
    old,
    { ...makeRun(500, "off", "matched10"), source_file: "corrected-off.json" },
    { ...makeRun(501, "fixed30", "matched10"), source_file: "corrected-fixed30.json" },
    { ...makeRun(502, "fixed45", "matched10"), source_file: "corrected-fixed45.json" },
    { ...makeRun(503, "fixed90", "matched10"), source_file: "corrected-fixed90.json" },
  ]);
  assert.equal(report.ready_for_matched10_validation, true);
  assert.match(report.matched10_validation.profile_key, /-170/);
});
