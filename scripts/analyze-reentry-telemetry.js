#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const TELEMETRY_FILE = /^reentry_telemetry_.*_part_\d+\.json$/i;
const MIN_MATCH_DYNAMIC_PRESSURE_KPA = 0.1;
const MAX_MATCH_DYNAMIC_PRESSURE_KPA = 3;
const MAX_INITIAL_POSITION_DELTA_M = 5000;
// Empirical deployment response fitted from the matched-AoA fixed-angle runs.
// This converts raw dynamic pressure into a per-airbrake relative load proxy;
// it is intentionally not presented as a calibrated structural force limit.
const AIRBRAKE_ANGLE_RESPONSE_EXPONENT = 2.165;
const REQUIRED_SAMPLE_FIELDS = [
  "time_s",
  "phase",
  "altitude_asl_m",
  "airspeed_mps",
  "airspeed_rate_mps2",
  "vertical_speed_mps",
  "dynamic_pressure_kpa",
  "density_model_kgpm3",
  "mach_model",
  "mass_t",
  "latitude_deg",
  "longitude_deg",
  "aoa_command_deg",
  "aoa_actual_deg",
  "airbrake_angle_command_deg",
  "airbrake_part_count",
  "brakes_action_group",
  "has_trajectories_impact",
];
const ALTITUDE_BANDS = [
  [60000, 71000],
  [50000, 60000],
  [40000, 50000],
  [30000, 40000],
  [19000, 30000],
];

function decodeKos(value) {
  if (Array.isArray(value)) return value.map(decodeKos);
  if (!value || typeof value !== "object") return value;

  const type = typeof value.$type === "string" ? value.$type : "";
  if (/\.(?:StringValue|Scalar(?:Int|Double)?Value|BooleanValue)$/.test(type) && Object.hasOwn(value, "value")) {
    return decodeKos(value.value);
  }
  if (type.endsWith(".Lexicon") && Array.isArray(value.entries)) {
    const result = {};
    for (let i = 0; i + 1 < value.entries.length; i += 2) {
      result[String(decodeKos(value.entries[i]))] = decodeKos(value.entries[i + 1]);
    }
    return result;
  }
  if (Array.isArray(value.items) && type) return value.items.map(decodeKos);

  return Object.fromEntries(
    Object.entries(value)
      .filter(([key]) => key !== "$type")
      .map(([key, child]) => [key, decodeKos(child)]),
  );
}

function readSegment(file) {
  const raw = JSON.parse(fs.readFileSync(file, "utf8"));
  const segment = decodeKos(raw);
  if (!segment || segment.schema !== "reentry_airbrake_predictor") {
    throw new Error(`${file}: not a reentry_airbrake_predictor telemetry segment`);
  }
  if (!segment.run || segment.run.run_id === undefined) {
    throw new Error(`${file}: missing run metadata`);
  }
  return { ...segment, source_file: path.resolve(file) };
}

function discoverFiles(inputs = []) {
  const defaultArchive = path.resolve(__dirname, "..", "..", "Script");
  const roots = inputs.length ? inputs : [defaultArchive];
  const files = [];
  for (const root of roots) {
    const resolved = path.resolve(root);
    if (!fs.existsSync(resolved)) continue;
    const stat = fs.statSync(resolved);
    if (stat.isFile()) {
      if (resolved.toLowerCase().endsWith(".json")) files.push(resolved);
      continue;
    }
    for (const entry of fs.readdirSync(resolved, { withFileTypes: true })) {
      if (entry.isFile() && TELEMETRY_FILE.test(entry.name)) {
        files.push(path.join(resolved, entry.name));
      }
    }
  }
  return [...new Set(files)].sort();
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function expectedFixedAngle(run) {
  if (run.mode === "fixed" && finite(run.run.airbrake_fixed_angle_deg) && run.run.airbrake_fixed_angle_deg >= 0) {
    return run.run.airbrake_fixed_angle_deg;
  }
  if (finite(run.run.airbrake_fixed_angle_deg) && run.run.airbrake_fixed_angle_deg > 0) {
    return run.run.airbrake_fixed_angle_deg;
  }
  if (run.mode === "fixed30") return 30;
  if (run.mode === "fixed45") return 45;
  if (run.mode === "fixed50") return 50;
  if (run.mode === "fixed60") return 60;
  if (run.mode === "fixed90") return 90;
  return null;
}

function runProfileKey(run) {
  const metadata = run.run ?? {};
  const rounded = (values) => Array.isArray(values) ? values.map((value) => finite(value) ? Math.round(value * 1000) / 1000 : value) : null;
  if (Array.isArray(metadata.trajectories_descent_angles_deg)) {
    return JSON.stringify({
      angles: rounded(metadata.trajectories_descent_angles_deg),
      grades: metadata.trajectories_descent_grades ?? null,
      modes: metadata.trajectories_descent_modes ?? null,
      entry_aoa_deg: finite(metadata.entry_aoa_deg) ? Math.round(metadata.entry_aoa_deg * 1000) / 1000 : null,
      entry_corridor_id: metadata.entry_corridor_id ?? "trajectories_miss",
      deorbit_phase_target_deg: finite(metadata.target_deorbit_phase_angle_deg)
        ? Math.round(metadata.target_deorbit_phase_angle_deg * 1000) / 1000
        : "unverified",
      airbrake_authority_limiter_percent: finite(metadata.airbrake_authority_limiter_command_percent)
        ? Math.round(metadata.airbrake_authority_limiter_command_percent * 1000) / 1000
        : "unverified",
    });
  }
  return `id:${metadata.trajectories_profile_id ?? "legacy"}:aoa:${metadata.entry_aoa_deg ?? "unknown"}:corridor:${metadata.entry_corridor_id ?? "trajectories_miss"}:phase:${metadata.target_deorbit_phase_angle_deg ?? "unverified"}:authority:${metadata.airbrake_authority_limiter_command_percent ?? "unverified"}`;
}

function enrichSamples(samples, actuatorSpeed = 20, expectedAirbrakeCount = null) {
  const sorted = [...samples].sort((a, b) => (a.time_s ?? 0) - (b.time_s ?? 0));
  let previous = null;
  let estimatedAirbrakeAngle = 0;
  let previousAirbrakeHeatingRate = null;
  let previousConvectiveHeatingRate = null;
  let convectiveHeatingExposure = 0;
  let airbrakeHeatingExposure = 0;
  const enriched = sorted.map((sample) => {
    const result = { ...sample };
    const command = sample.airbrake_angle_command_deg ?? sample.airbrake_angle_deg ?? 0;
    result.effective_airbrake_command_deg = sample.brakes_action_group ? command : 0;
    if (previous && finite(sample.time_s) && finite(previous.time_s)) {
      const maxChange = Math.max(0, actuatorSpeed) * Math.max(0, sample.time_s - previous.time_s);
      const difference = result.effective_airbrake_command_deg - estimatedAirbrakeAngle;
      estimatedAirbrakeAngle += Math.max(-maxChange, Math.min(maxChange, difference));
    }
    result.airbrake_estimated_angle_deg = estimatedAirbrakeAngle;
    result.airbrake_fraction = estimatedAirbrakeAngle / 90;
    const boundedAngle = Math.max(0, Math.min(90, estimatedAirbrakeAngle));
    result.airbrake_angle_load_factor = Math.sin(boundedAngle * Math.PI / 180) ** AIRBRAKE_ANGLE_RESPONSE_EXPONENT;
    result.airbrake_load_proxy_kpa = finite(sample.dynamic_pressure_kpa)
      ? sample.dynamic_pressure_kpa * result.airbrake_angle_load_factor
      : null;
    result.convective_heating_rate_proxy = finite(sample.density_model_kgpm3) && sample.density_model_kgpm3 >= 0 && finite(sample.airspeed_mps)
      ? Math.sqrt(sample.density_model_kgpm3) * sample.airspeed_mps ** 3 / 1e9
      : null;
    result.airbrake_heating_rate_proxy = finite(result.convective_heating_rate_proxy)
      ? result.convective_heating_rate_proxy * result.airbrake_angle_load_factor
      : null;
    if (sample.phase === "entry" && previous?.phase === "entry" && finite(sample.time_s) && finite(previous.time_s)) {
      const dt = sample.time_s - previous.time_s;
      if (dt > 0 && finite(result.airbrake_heating_rate_proxy) && finite(previousAirbrakeHeatingRate)) {
        airbrakeHeatingExposure += (previousAirbrakeHeatingRate + result.airbrake_heating_rate_proxy) * 0.5 * dt;
      }
      if (dt > 0 && finite(result.convective_heating_rate_proxy) && finite(previousConvectiveHeatingRate)) {
        convectiveHeatingExposure += (previousConvectiveHeatingRate + result.convective_heating_rate_proxy) * 0.5 * dt;
      }
    }
    result.convective_heating_exposure_proxy = convectiveHeatingExposure;
    result.airbrake_heating_exposure_proxy = airbrakeHeatingExposure;
    result.airbrake_survival_fraction = expectedAirbrakeCount > 0 ? sample.airbrake_part_count / expectedAirbrakeCount : null;
    result.observed_deceleration_mps2 = finite(sample.airspeed_rate_mps2) ? -sample.airspeed_rate_mps2 : null;
    result.flight_path_angle_deg = finite(sample.vertical_speed_mps) && finite(sample.horizontal_speed_mps)
      ? Math.atan2(sample.vertical_speed_mps, sample.horizontal_speed_mps) * 180 / Math.PI
      : null;
    if (previous && previous.phase === sample.phase) {
      const dt = sample.time_s - previous.time_s;
      if (dt > 0) {
        if (finite(sample.impact_along_miss_m) && finite(previous.impact_along_miss_m)) {
          result.impact_along_rate_mps = (sample.impact_along_miss_m - previous.impact_along_miss_m) / dt;
        }
        if (finite(sample.impact_miss_m) && finite(previous.impact_miss_m)) {
          result.impact_miss_rate_mps = (sample.impact_miss_m - previous.impact_miss_m) / dt;
        }
      }
    }
    previous = sample;
    previousConvectiveHeatingRate = result.convective_heating_rate_proxy;
    previousAirbrakeHeatingRate = result.airbrake_heating_rate_proxy;
    return result;
  });
  const entry = enriched.filter((sample) => sample.phase === "entry");
  const peakDynamicPressure = entry.reduce((peak, sample) => Math.max(peak, sample.dynamic_pressure_kpa ?? 0), 0);
  const peakAirbrakeLoad = entry.reduce((peak, sample) => Math.max(peak, sample.airbrake_load_proxy_kpa ?? 0), 0);
  return enriched.map((sample) => ({
    ...sample,
    dynamic_pressure_fraction_of_run_peak: peakDynamicPressure > 0 && finite(sample.dynamic_pressure_kpa)
      ? sample.dynamic_pressure_kpa / peakDynamicPressure
      : null,
    airbrake_load_fraction_of_run_peak: peakAirbrakeLoad > 0 && finite(sample.airbrake_load_proxy_kpa)
      ? sample.airbrake_load_proxy_kpa / peakAirbrakeLoad
      : null,
  }));
}

function mergeSegments(segments) {
  const grouped = new Map();
  for (const segment of segments) {
    const key = String(segment.run.run_id);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(segment);
  }

  return [...grouped.entries()].map(([runId, parts]) => {
    parts.sort((a, b) => a.segment_index - b.segment_index);
    const samples = [];
    const events = [];
    for (const part of parts) {
      for (const sample of part.samples ?? []) {
        samples.push({ ...sample, telemetry_segment_index: part.segment_index });
      }
      for (const event of part.events ?? []) {
        events.push({ ...event, telemetry_segment_index: part.segment_index });
      }
    }
    const finalPart = parts.at(-1);
    return {
      run_id: runId,
      run: parts[0].run,
      mode: parts[0].run.airbrake_control_mode,
      status: finalPart.status,
      segments: parts.map((part) => part.segment_index),
      source_files: parts.map((part) => part.source_file),
      samples: enrichSamples(samples, parts[0].run.airbrake_actuator_speed_degps ?? 20, parts[0].run.airbrake_part_count ?? null),
      events: events.sort((a, b) => (a.time_s ?? 0) - (b.time_s ?? 0)),
    };
  }).sort((a, b) => Number(a.run_id) - Number(b.run_id));
}

function bandCounts(samples) {
  return ALTITUDE_BANDS.map(([low, high]) => ({
    label: `${Math.round(low / 1000)}-${Math.round(high / 1000)}km`,
    count: samples.filter((sample) => sample.altitude_asl_m >= low && sample.altitude_asl_m < high).length,
  }));
}

function summarizeRun(run) {
  const entry = run.samples.filter((sample) => sample.phase === "entry");
  const landingError = landingErrorForRun(run, entry);
  const pidMinimumAngle = finite(run.run.airbrake_min_angle_deg) ? run.run.airbrake_min_angle_deg : 30;
  const pidMaximumAngle = finite(run.run.airbrake_max_angle_deg) ? run.run.airbrake_max_angle_deg : 90;
  const dts = [];
  for (let i = 1; i < entry.length; i += 1) {
    const dt = entry[i].time_s - entry[i - 1].time_s;
    if (dt > 0) dts.push(dt);
  }
  const requiredPresent = REQUIRED_SAMPLE_FIELDS.map((field) => ({
    field,
    ratio: entry.length ? entry.filter((sample) => sample[field] !== undefined && sample[field] !== null).length / entry.length : 0,
  }));
  const modeCompliant = entry.length > 0 && entry.every((sample) => {
    const effective = sample.effective_airbrake_command_deg;
    if (run.mode === "off") return effective <= 0.5 && !sample.brakes_action_group;
    if (run.mode === "fixed") {
      const expected = expectedFixedAngle(run);
      return expected !== null && Math.abs(effective - expected) <= 1 && sample.brakes_action_group;
    }
    if (run.mode === "fixed30") return effective >= 29 && effective <= 31 && sample.brakes_action_group;
    if (run.mode === "fixed45") return effective >= 44 && effective <= 46 && sample.brakes_action_group;
    if (run.mode === "fixed50") return effective >= 49 && effective <= 51 && sample.brakes_action_group;
    if (run.mode === "fixed60") return effective >= 59 && effective <= 61 && sample.brakes_action_group;
    if (run.mode === "fixed90") return effective >= 89;
    if (run.mode === "pid") return !sample.brakes_action_group || (effective >= pidMinimumAngle - 1 && effective <= pidMaximumAngle + 1);
    return false;
  });
  const segmentGaps = [];
  for (let i = 1; i < run.segments.length; i += 1) {
    if (run.segments[i] !== run.segments[i - 1] + 1) segmentGaps.push([run.segments[i - 1], run.segments[i]]);
  }
  const coverage = bandCounts(entry);
  const impactRatio = entry.length ? entry.filter((sample) => sample.has_trajectories_impact).length / entry.length : 0;
  const maxThrottle = entry.reduce((max, sample) => Math.max(max, Math.abs(sample.throttle_command ?? 0)), 0);
  const altitudeMax = entry.length ? Math.max(...entry.map((sample) => sample.altitude_asl_m)) : null;
  const altitudeMin = entry.length ? Math.min(...entry.map((sample) => sample.altitude_asl_m)) : null;
  const medianDt = median(dts);
  const maxGap = dts.length ? Math.max(...dts) : null;
  const expectedAirbrakeCount = run.run.airbrake_part_count ?? null;
  const minimumAirbrakeCount = entry.length ? Math.min(...entry.map((sample) => sample.airbrake_part_count ?? expectedAirbrakeCount ?? 0)) : null;
  const firstAirbrakeLoss = expectedAirbrakeCount > 0 ? entry.find((sample) => (sample.airbrake_part_count ?? expectedAirbrakeCount) < expectedAirbrakeCount) : null;
  const expectedVesselPartCount = run.run.initial_vessel_part_count ?? null;
  const entryVesselPartCountSamples = entry.filter((sample) => finite(sample.vessel_part_count));
  const vesselPartCountSamples = run.samples.filter((sample) => finite(sample.vessel_part_count));
  const vesselPartCountCoverageRatio = entry.length ? entryVesselPartCountSamples.length / entry.length : 0;
  const minimumVesselPartCount = vesselPartCountSamples.length ? Math.min(...vesselPartCountSamples.map((sample) => sample.vessel_part_count)) : null;
  const firstVesselPartLoss = expectedVesselPartCount > 0
    ? vesselPartCountSamples.find((sample) => sample.vessel_part_count < expectedVesselPartCount)
    : null;
  const intactEntry = expectedVesselPartCount > 0
    ? entry.filter((sample) => !finite(sample.vessel_part_count) || sample.vessel_part_count === expectedVesselPartCount)
    : entry;
  const angleReadbackSamples = entry.filter((sample) => Array.isArray(sample.airbrake_deploy_angle_fields_deg) && sample.airbrake_deploy_angle_fields_deg.length > 0);
  const activeAngleReadbacks = angleReadbackSamples.filter((sample) => sample.brakes_action_group);
  const compliantAngleReadbacks = activeAngleReadbacks.filter((sample) => sample.airbrake_deploy_angle_fields_deg.every((angle) => finite(angle) && Math.abs(angle - sample.airbrake_angle_command_deg) <= 0.5));
  const angleReadbackComplianceRatio = activeAngleReadbacks.length ? compliantAngleReadbacks.length / activeAngleReadbacks.length : null;
  const maximumAngleFieldSpread = angleReadbackSamples.length ? Math.max(...angleReadbackSamples.map((sample) => sample.airbrake_deploy_angle_field_spread_deg ?? Number.POSITIVE_INFINITY)) : null;
  const maximumAngleReassertions = angleReadbackSamples.length ? Math.max(...angleReadbackSamples.map((sample) => sample.airbrake_angle_reassertion_count ?? 0)) : null;
  const matchedProfile = run.run.trajectories_profile_id === "matched10";
  const authorityCommand = run.run.airbrake_authority_limiter_command_percent;
  const authorityProofRequired = matchedProfile || finite(authorityCommand);
  const authorityReadbackSamples = entry.filter((sample) => Array.isArray(sample.airbrake_authority_limiter_fields_percent)
    && sample.airbrake_authority_limiter_fields_percent.length > 0);
  const compliantAuthorityReadbacks = authorityReadbackSamples.filter((sample) => sample.airbrake_authority_limiter_fields_percent
    .every((authority) => finite(authority) && Math.abs(authority) <= 0.5));
  const authorityReadbackCoverageRatio = entry.length ? authorityReadbackSamples.length / entry.length : 0;
  const authorityReadbackComplianceRatio = authorityReadbackSamples.length
    ? compliantAuthorityReadbacks.length / authorityReadbackSamples.length
    : null;
  const maximumAuthorityField = authorityReadbackSamples.length
    ? Math.max(...authorityReadbackSamples.flatMap((sample) => sample.airbrake_authority_limiter_fields_percent))
    : null;
  const allAeroPlannedVectorSamples = entry.filter((sample) => sample.has_trajectories_impact
    && sample.aoa_command_deg > 0
    && sample.dynamic_pressure_kpa >= MIN_MATCH_DYNAMIC_PRESSURE_KPA
    && finite(sample.trajectories_planned_facing_error_deg)
    && sample.trajectories_planned_facing_error_deg >= 0);
  const plannedVectorSamples = allAeroPlannedVectorSamples.filter((sample) => sample.dynamic_pressure_kpa <= MAX_MATCH_DYNAMIC_PRESSURE_KPA);
  const plannedVectorErrors = plannedVectorSamples.map((sample) => sample.trajectories_planned_facing_error_deg).sort((a, b) => a - b);
  const allAeroPlannedVectorErrors = allAeroPlannedVectorSamples.map((sample) => sample.trajectories_planned_facing_error_deg).sort((a, b) => a - b);
  const plannedVectorAlignmentRatio = plannedVectorSamples.length
    ? plannedVectorSamples.filter((sample) => sample.trajectories_planned_facing_error_deg <= 2).length / plannedVectorSamples.length
    : null;
  const plannedVectorMedianError = plannedVectorErrors.length ? median(plannedVectorErrors) : null;
  const plannedVectorP90Error = plannedVectorErrors.length ? plannedVectorErrors[Math.min(plannedVectorErrors.length - 1, Math.floor(plannedVectorErrors.length * 0.9))] : null;
  const plannedVectorMaximumError = plannedVectorErrors.length ? plannedVectorErrors.at(-1) : null;
  const allAeroPlannedVectorAlignmentRatio = allAeroPlannedVectorSamples.length
    ? allAeroPlannedVectorSamples.filter((sample) => sample.trajectories_planned_facing_error_deg <= 2).length / allAeroPlannedVectorSamples.length
    : null;
  const allAeroPlannedVectorP90Error = allAeroPlannedVectorErrors.length
    ? allAeroPlannedVectorErrors[Math.min(allAeroPlannedVectorErrors.length - 1, Math.floor(allAeroPlannedVectorErrors.length * 0.9))]
    : null;
  const checks = {
    complete_status: run.status !== "running",
    contiguous_segments: segmentGaps.length === 0 && run.segments[0] === 0,
    enough_entry_samples: entry.length >= 20,
    full_altitude_envelope: altitudeMax >= 65000 && altitudeMin <= 21000,
    sample_cadence: medianDt !== null && medianDt >= 1 && medianDt <= 3.5 && maxGap <= 6,
    required_fields: requiredPresent.every((item) => item.ratio >= 0.98),
    trajectories_coverage: impactRatio >= 0.8,
    unpowered_entry: maxThrottle <= 0.001,
    mode_compliance: modeCompliant,
    airbrake_angle_readback: angleReadbackComplianceRatio === null || angleReadbackComplianceRatio >= 0.98,
    no_airbrake_angle_reassertions: maximumAngleReassertions === null || maximumAngleReassertions === 0,
    vessel_part_count_readback: !matchedProfile || run.mode === "off" || (expectedVesselPartCount > 0 && vesselPartCountCoverageRatio >= 0.98),
    no_vessel_part_loss: !matchedProfile || run.mode === "off" || (expectedVesselPartCount > 0 && minimumVesselPartCount === expectedVesselPartCount),
    airbrake_authority_limiter_zero: !authorityProofRequired || (finite(authorityCommand)
      && Math.abs(authorityCommand) <= 0.5
      && authorityReadbackCoverageRatio >= 0.98
      && authorityReadbackComplianceRatio >= 0.98),
    trajectories_planned_vector_alignment: !matchedProfile || (plannedVectorAlignmentRatio !== null
      && plannedVectorAlignmentRatio >= 0.9
      && plannedVectorP90Error !== null
      && plannedVectorP90Error <= 2),
    altitude_band_coverage: coverage.filter((band) => band.count >= 2).length >= 4,
  };
  return {
    run_id: run.run_id,
    mode: run.mode,
    trajectories_profile_id: run.run.trajectories_profile_id ?? "legacy",
    entry_corridor_id: run.run.entry_corridor_id ?? "trajectories_miss",
    target_entry_fpa_down_deg: run.run.target_entry_fpa_down_deg ?? null,
    predicted_entry_fpa_down_deg: run.run.predicted_entry_fpa_down_deg ?? null,
    target_deorbit_phase_angle_deg: run.run.target_deorbit_phase_angle_deg ?? null,
    actual_deorbit_burn_phase_angle_deg: run.run.actual_deorbit_burn_phase_angle_deg ?? null,
    airbrake_min_angle_deg: run.run.airbrake_min_angle_deg ?? null,
    airbrake_max_angle_deg: run.run.airbrake_max_angle_deg ?? null,
    measured_entry_fpa_down_deg: entry.length && finite(entry[0].flight_path_angle_deg) ? -entry[0].flight_path_angle_deg : null,
    landing_position_available: Boolean(landingError),
    landing_latitude_deg: landingError?.latitude_deg ?? null,
    landing_longitude_deg: landingError?.longitude_deg ?? null,
    landing_miss_m: landingError?.miss_m ?? null,
    landing_along_miss_m: landingError?.along_miss_m ?? null,
    landing_cross_miss_m: landingError?.cross_miss_m ?? null,
    status: run.status,
    segment_count: run.segments.length,
    segment_gaps: segmentGaps,
    sample_count: run.samples.length,
    entry_sample_count: entry.length,
    altitude_max_m: altitudeMax,
    altitude_min_m: altitudeMin,
    median_sample_dt_s: medianDt,
    max_sample_gap_s: maxGap,
    max_dynamic_pressure_kpa: entry.length ? Math.max(...entry.map((sample) => sample.dynamic_pressure_kpa ?? 0)) : null,
    max_intact_dynamic_pressure_kpa: intactEntry.length ? Math.max(...intactEntry.map((sample) => sample.dynamic_pressure_kpa ?? 0)) : null,
    max_airbrake_load_proxy_kpa: entry.length ? Math.max(...entry.map((sample) => sample.airbrake_load_proxy_kpa ?? 0)) : null,
    max_intact_airbrake_load_proxy_kpa: intactEntry.length ? Math.max(...intactEntry.map((sample) => sample.airbrake_load_proxy_kpa ?? 0)) : null,
    max_convective_heating_rate_proxy: entry.length ? Math.max(...entry.map((sample) => sample.convective_heating_rate_proxy ?? 0)) : null,
    max_airbrake_heating_rate_proxy: entry.length ? Math.max(...entry.map((sample) => sample.airbrake_heating_rate_proxy ?? 0)) : null,
    max_intact_convective_heating_exposure_proxy: intactEntry.length ? Math.max(...intactEntry.map((sample) => sample.convective_heating_exposure_proxy ?? 0)) : null,
    max_intact_airbrake_heating_exposure_proxy: intactEntry.length ? Math.max(...intactEntry.map((sample) => sample.airbrake_heating_exposure_proxy ?? 0)) : null,
    trajectories_impact_ratio: impactRatio,
    max_entry_throttle: maxThrottle,
    mode_compliant: modeCompliant,
    expected_airbrake_count: expectedAirbrakeCount,
    minimum_airbrake_count: minimumAirbrakeCount,
    first_airbrake_loss_altitude_m: firstAirbrakeLoss?.altitude_asl_m ?? null,
    airbrake_hardware_intact_ratio: entry.length && expectedAirbrakeCount > 0 ? entry.filter((sample) => sample.airbrake_part_count === expectedAirbrakeCount).length / entry.length : null,
    expected_vessel_part_count: expectedVesselPartCount,
    minimum_vessel_part_count: minimumVesselPartCount,
    vessel_part_count_readback_coverage_ratio: vesselPartCountCoverageRatio,
    first_vessel_part_loss_altitude_m: firstVesselPartLoss?.altitude_asl_m ?? null,
    first_vessel_part_loss_dynamic_pressure_kpa: firstVesselPartLoss?.dynamic_pressure_kpa ?? null,
    first_vessel_part_loss_dynamic_pressure_fraction_of_run_peak: firstVesselPartLoss?.dynamic_pressure_fraction_of_run_peak ?? null,
    first_vessel_part_loss_mach: firstVesselPartLoss?.mach_model ?? null,
    first_vessel_part_loss_airspeed_mps: firstVesselPartLoss?.airspeed_mps ?? null,
    first_vessel_part_loss_airbrake_angle_deg: firstVesselPartLoss?.airbrake_estimated_angle_deg ?? null,
    first_vessel_part_loss_airbrake_load_proxy_kpa: firstVesselPartLoss?.airbrake_load_proxy_kpa ?? null,
    first_vessel_part_loss_convective_heating_rate_proxy: firstVesselPartLoss?.convective_heating_rate_proxy ?? null,
    first_vessel_part_loss_airbrake_heating_rate_proxy: firstVesselPartLoss?.airbrake_heating_rate_proxy ?? null,
    first_vessel_part_loss_convective_heating_exposure_proxy: firstVesselPartLoss?.convective_heating_exposure_proxy ?? null,
    first_vessel_part_loss_airbrake_heating_exposure_proxy: firstVesselPartLoss?.airbrake_heating_exposure_proxy ?? null,
    vessel_hardware_intact_ratio: entry.length && expectedVesselPartCount > 0
      ? vesselPartCountSamples.filter((sample) => sample.vessel_part_count === expectedVesselPartCount).length / vesselPartCountSamples.length
      : null,
    airbrake_angle_readback_sample_count: angleReadbackSamples.length,
    airbrake_angle_readback_compliance_ratio: angleReadbackComplianceRatio,
    airbrake_angle_field_max_spread_deg: maximumAngleFieldSpread,
    airbrake_angle_reassertion_count: maximumAngleReassertions,
    airbrake_authority_limiter_command_percent: finite(authorityCommand) ? authorityCommand : null,
    airbrake_authority_limiter_readback_sample_count: authorityReadbackSamples.length,
    airbrake_authority_limiter_readback_coverage_ratio: authorityReadbackCoverageRatio,
    airbrake_authority_limiter_zero_compliance_ratio: authorityReadbackComplianceRatio,
    airbrake_authority_limiter_max_percent: maximumAuthorityField,
    entry_steering_source: run.run.entry_steering_source ?? "legacy",
    trajectories_planned_vector_sample_count: plannedVectorSamples.length,
    trajectories_planned_vector_alignment_ratio: plannedVectorAlignmentRatio,
    trajectories_planned_vector_median_error_deg: plannedVectorMedianError,
    trajectories_planned_vector_p90_error_deg: plannedVectorP90Error,
    trajectories_planned_vector_max_error_deg: plannedVectorMaximumError,
    trajectories_planned_vector_all_aero_sample_count: allAeroPlannedVectorSamples.length,
    trajectories_planned_vector_all_aero_alignment_ratio: allAeroPlannedVectorAlignmentRatio,
    trajectories_planned_vector_all_aero_p90_error_deg: allAeroPlannedVectorP90Error,
    sensors: {
      barometer: run.run.has_pressure_sensor ?? entry.some((sample) => Math.abs(sample.static_pressure_sensor_kpa ?? sample.static_pressure_sensor ?? 0) > 0),
      thermometer: run.run.has_temperature_sensor ?? entry.some((sample) => Math.abs(sample.temperature_sensor_k ?? sample.temperature_sensor ?? 0) > 0),
      accelerometer: run.run.has_acceleration_sensor ?? entry.some((sample) => Math.abs(sample.acceleration_sensor_magnitude_mps2 ?? sample.acceleration_sensor_magnitude ?? 0) > 0),
      gravimeter: run.run.has_gravity_sensor ?? entry.some((sample) => Math.abs(sample.gravity_sensor_g ?? sample.gravity_g ?? 0) > 0),
    },
    altitude_bands: coverage,
    required_fields: requiredPresent,
    checks,
    usable: Object.values(checks).every(Boolean),
  };
}

function haversineMeters(a, b, radius) {
  if (![a.latitude_deg, a.longitude_deg, b.latitude_deg, b.longitude_deg].every(finite)) return null;
  const rad = Math.PI / 180;
  const dLat = (b.latitude_deg - a.latitude_deg) * rad;
  const dLon = (b.longitude_deg - a.longitude_deg) * rad;
  const lat1 = a.latitude_deg * rad;
  const lat2 = b.latitude_deg * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * radius * Math.asin(Math.min(1, Math.sqrt(h)));
}

function wrappedLongitudeDeltaDegrees(from, to) {
  return ((to - from + 540) % 360) - 180;
}

function localOffsetMeters(from, to, radius) {
  if (![from.latitude_deg, from.longitude_deg, to.latitude_deg, to.longitude_deg].every(finite)) return null;
  const rad = Math.PI / 180;
  const meanLatitude = (from.latitude_deg + to.latitude_deg) * 0.5 * rad;
  return {
    east_m: wrappedLongitudeDeltaDegrees(from.longitude_deg, to.longitude_deg) * rad * radius * Math.cos(meanLatitude),
    north_m: (to.latitude_deg - from.latitude_deg) * rad * radius,
  };
}

function landingErrorForRun(run, entry) {
  const landing = [...run.samples].reverse().find((sample) => sample.phase === "landing_final"
    && finite(sample.latitude_deg) && finite(sample.longitude_deg));
  const target = {
    latitude_deg: run.run.target_lat_deg,
    longitude_deg: run.run.target_lng_deg,
  };
  const positionedEntry = entry.filter((sample) => finite(sample.latitude_deg) && finite(sample.longitude_deg));
  if (!landing || ![target.latitude_deg, target.longitude_deg].every(finite) || positionedEntry.length < 2) return null;

  const radius = run.run.body_radius_m ?? 600000;
  const track = localOffsetMeters(positionedEntry[0], positionedEntry.at(-1), radius);
  const landingToTarget = localOffsetMeters(landing, target, radius);
  if (!track || !landingToTarget) return null;
  const trackMagnitude = Math.hypot(track.east_m, track.north_m);
  if (trackMagnitude < 1) return null;
  const eastDirection = track.east_m / trackMagnitude;
  const northDirection = track.north_m / trackMagnitude;
  return {
    latitude_deg: landing.latitude_deg,
    longitude_deg: landing.longitude_deg,
    miss_m: haversineMeters(landing, target, radius),
    // Positive means the target remained ahead (undershoot); negative means
    // the craft passed the target along-track (overshoot).
    along_miss_m: landingToTarget.east_m * eastDirection + landingToTarget.north_m * northDirection,
    cross_miss_m: -landingToTarget.east_m * northDirection + landingToTarget.north_m * eastDirection,
  };
}

function nearestMatches(offRun, fixedRun) {
  const off = offRun.samples.filter((sample) => sample.phase === "entry" && sample.has_trajectories_impact);
  const fixed = fixedRun.samples.filter((sample) => sample.phase === "entry" && sample.has_trajectories_impact);
  const used = new Set();
  const matches = [];
  const radius = offRun.run.body_radius_m ?? fixedRun.run.body_radius_m ?? 600000;
  for (const deployed of fixed) {
    let best = null;
    for (let i = 0; i < off.length; i += 1) {
      if (used.has(i)) continue;
      const clean = off[i];
      if (![deployed.altitude_asl_m, clean.altitude_asl_m, deployed.airspeed_mps, clean.airspeed_mps, deployed.vertical_speed_mps, clean.vertical_speed_mps, deployed.mach_model, clean.mach_model, deployed.aoa_actual_deg, clean.aoa_actual_deg].every(finite)) continue;
      const differences = {
        altitude_m: Math.abs(deployed.altitude_asl_m - clean.altitude_asl_m),
        airspeed_mps: Math.abs(deployed.airspeed_mps - clean.airspeed_mps),
        vertical_speed_mps: Math.abs(deployed.vertical_speed_mps - clean.vertical_speed_mps),
        mach: Math.abs(deployed.mach_model - clean.mach_model),
        aoa_deg: Math.abs(deployed.aoa_actual_deg - clean.aoa_actual_deg),
        flight_path_angle_deg: Math.abs((deployed.flight_path_angle_deg ?? 0) - (clean.flight_path_angle_deg ?? 0)),
        position_m: haversineMeters(deployed, clean, radius),
      };
      if (differences.altitude_m > 2500 || differences.airspeed_mps > 250 || differences.vertical_speed_mps > 150 || differences.mach > 0.75 || differences.aoa_deg > 8 || differences.flight_path_angle_deg > 5 || differences.position_m === null || differences.position_m > 25000) continue;
      const cost = differences.altitude_m / 2000 + differences.airspeed_mps / 200 + differences.vertical_speed_mps / 100 + differences.mach / 0.5 + differences.aoa_deg / 5 + differences.flight_path_angle_deg / 3 + differences.position_m / 20000;
      if (!best || cost < best.cost) best = { index: i, clean, differences, cost };
    }
    if (!best) continue;
    used.add(best.index);
    const massT = (best.clean.mass_t + deployed.mass_t) / 2;
    const dynamicPressureKpa = (best.clean.dynamic_pressure_kpa + deployed.dynamic_pressure_kpa) / 2;
    const extraDeceleration = finite(best.clean.observed_deceleration_mps2) && finite(deployed.observed_deceleration_mps2) ? deployed.observed_deceleration_mps2 - best.clean.observed_deceleration_mps2 : null;
    const impactAlongRateDelta = finite(best.clean.impact_along_rate_mps) && finite(deployed.impact_along_rate_mps) ? deployed.impact_along_rate_mps - best.clean.impact_along_rate_mps : null;
    const fixedAirbrakeCount = deployed.airbrake_part_count ?? fixedRun.run.airbrake_part_count ?? null;
    const extraCdArea = finite(extraDeceleration) && dynamicPressureKpa > 0 ? massT * extraDeceleration / dynamicPressureKpa : null;
    matches.push({
      off_run_id: offRun.run_id,
      fixed_mode: fixedRun.mode,
      fixed_run_id: fixedRun.run_id,
      trajectories_profile_key: runProfileKey(fixedRun),
      trajectories_profile_id: fixedRun.run.trajectories_profile_id ?? offRun.run.trajectories_profile_id ?? "legacy",
      entry_corridor_id: fixedRun.run.entry_corridor_id ?? offRun.run.entry_corridor_id ?? "trajectories_miss",
      off_time_s: best.clean.time_s,
      fixed_time_s: deployed.time_s,
      altitude_m: (best.clean.altitude_asl_m + deployed.altitude_asl_m) / 2,
      mach: (best.clean.mach_model + deployed.mach_model) / 2,
      dynamic_pressure_kpa: dynamicPressureKpa,
      density_kgpm3: (best.clean.density_model_kgpm3 + deployed.density_model_kgpm3) / 2,
      mass_t: massT,
      aoa_actual_deg: (best.clean.aoa_actual_deg + deployed.aoa_actual_deg) / 2,
      off_deceleration_mps2: best.clean.observed_deceleration_mps2,
      fixed_deceleration_mps2: deployed.observed_deceleration_mps2,
      extra_deceleration_mps2: extraDeceleration,
      extra_drag_force_kn: finite(extraDeceleration) ? massT * extraDeceleration : null,
      extra_cd_area_m2: extraCdArea,
      extra_cd_area_per_airbrake_m2: finite(extraCdArea) && fixedAirbrakeCount > 0 ? extraCdArea / fixedAirbrakeCount : null,
      fixed_airbrake_estimated_angle_deg: deployed.airbrake_estimated_angle_deg,
      fixed_airbrake_fraction: deployed.airbrake_fraction,
      fixed_airbrake_deploy_angle_fields_deg: deployed.airbrake_deploy_angle_fields_deg ?? null,
      fixed_airbrake_deploy_angle_field_spread_deg: deployed.airbrake_deploy_angle_field_spread_deg ?? null,
      fixed_airbrake_angle_reassertion_count: deployed.airbrake_angle_reassertion_count ?? null,
      off_airbrake_authority_limiter_fields_percent: best.clean.airbrake_authority_limiter_fields_percent ?? null,
      fixed_airbrake_authority_limiter_fields_percent: deployed.airbrake_authority_limiter_fields_percent ?? null,
      off_airbrake_part_count: best.clean.airbrake_part_count ?? offRun.run.airbrake_part_count ?? null,
      fixed_airbrake_part_count: fixedAirbrakeCount,
      fixed_airbrake_survival_fraction: deployed.airbrake_survival_fraction,
      off_vessel_part_count: best.clean.vessel_part_count ?? null,
      fixed_vessel_part_count: deployed.vessel_part_count ?? null,
      off_initial_vessel_part_count: offRun.run.initial_vessel_part_count ?? null,
      fixed_initial_vessel_part_count: fixedRun.run.initial_vessel_part_count ?? null,
      off_trajectories_planned_facing_error_deg: best.clean.trajectories_planned_facing_error_deg ?? null,
      fixed_trajectories_planned_facing_error_deg: deployed.trajectories_planned_facing_error_deg ?? null,
      off_impact_along_rate_mps: best.clean.impact_along_rate_mps ?? null,
      fixed_impact_along_rate_mps: deployed.impact_along_rate_mps ?? null,
      impact_along_rate_delta_mps: impactAlongRateDelta,
      off_impact_along_miss_m: best.clean.impact_along_miss_m ?? null,
      fixed_impact_along_miss_m: deployed.impact_along_miss_m ?? null,
      impact_along_miss_delta_m: finite(best.clean.impact_along_miss_m) && finite(deployed.impact_along_miss_m)
        ? deployed.impact_along_miss_m - best.clean.impact_along_miss_m
        : null,
      impact_along_response_per_deploy_mps: finite(impactAlongRateDelta) && deployed.airbrake_fraction > 0.05 ? impactAlongRateDelta / deployed.airbrake_fraction : null,
      match_altitude_delta_m: best.differences.altitude_m,
      match_airspeed_delta_mps: best.differences.airspeed_mps,
      match_vertical_speed_delta_mps: best.differences.vertical_speed_mps,
      match_mach_delta: best.differences.mach,
      match_aoa_delta_deg: best.differences.aoa_deg,
      match_flight_path_angle_delta_deg: best.differences.flight_path_angle_deg,
      match_position_delta_m: best.differences.position_m,
      match_cost: best.cost,
    });
  }
  return matches;
}

function comparePair(offRun, fixedRun) {
  const offEntry = offRun.samples.find((sample) => sample.phase === "entry");
  const fixedEntry = fixedRun.samples.find((sample) => sample.phase === "entry");
  if (!offEntry || !fixedEntry) return { comparable: false, matches: [], checks: { initial_samples: false } };
  const radius = offRun.run.body_radius_m ?? fixedRun.run.body_radius_m ?? 600000;
  const initial = {
    altitude_delta_m: Math.abs(offEntry.altitude_asl_m - fixedEntry.altitude_asl_m),
    airspeed_delta_mps: Math.abs(offEntry.airspeed_mps - fixedEntry.airspeed_mps),
    vertical_speed_delta_mps: Math.abs(offEntry.vertical_speed_mps - fixedEntry.vertical_speed_mps),
    mass_relative_delta: Math.abs(offEntry.mass_t - fixedEntry.mass_t) / Math.max(offEntry.mass_t, fixedEntry.mass_t, 1),
    position_delta_m: haversineMeters(offEntry, fixedEntry, radius),
    aoa_delta_deg: Math.abs(offEntry.aoa_actual_deg - fixedEntry.aoa_actual_deg),
  };
  const matches = nearestMatches(offRun, fixedRun);
  const matchedBands = bandCounts(matches.map((match) => ({ altitude_asl_m: match.altitude_m })));
  const fixedAngle = expectedFixedAngle(fixedRun);
  const angleTolerance = fixedAngle === null ? null : Math.max(3, fixedAngle * 0.1);
  const stableDeployMatches = matches.filter((match) => fixedAngle !== null && Math.abs(match.fixed_airbrake_estimated_angle_deg - fixedAngle) <= angleTolerance && match.fixed_airbrake_part_count > 0);
  const requiresPlannedAlignment = fixedRun.run.trajectories_profile_id === "matched10";
  const plannedAlignedMatches = stableDeployMatches.filter((match) => !requiresPlannedAlignment || (
    finite(match.off_trajectories_planned_facing_error_deg)
    && finite(match.fixed_trajectories_planned_facing_error_deg)
    && match.off_trajectories_planned_facing_error_deg <= 2
    && match.fixed_trajectories_planned_facing_error_deg <= 2));
  const forceEstimateMatches = plannedAlignedMatches.filter((match) => finite(match.extra_cd_area_m2) && match.dynamic_pressure_kpa >= 0.1);
  const expectedAirbrakeCount = fixedRun.run.airbrake_part_count ?? null;
  const expectedVesselPartCount = fixedRun.run.initial_vessel_part_count ?? null;
  const intactForceMatches = forceEstimateMatches.filter((match) => (expectedAirbrakeCount === null || match.fixed_airbrake_part_count === expectedAirbrakeCount)
    && (expectedVesselPartCount === null || match.fixed_vessel_part_count === expectedVesselPartCount));
  const checks = {
    initial_samples: true,
    matching_trajectories_profile: runProfileKey(offRun) === runProfileKey(fixedRun),
    initial_altitude: initial.altitude_delta_m <= 500,
    initial_airspeed: initial.airspeed_delta_mps <= 25,
    initial_vertical_speed: initial.vertical_speed_delta_mps <= 25,
    initial_mass: initial.mass_relative_delta <= 0.005,
    initial_position: initial.position_delta_m !== null && initial.position_delta_m <= MAX_INITIAL_POSITION_DELTA_M,
    initial_aoa: initial.aoa_delta_deg <= 3,
    enough_state_matches: matches.length >= 20,
    enough_stable_deploy_matches: stableDeployMatches.length >= 15,
    enough_planned_aligned_matches: plannedAlignedMatches.length >= 15,
    enough_force_estimates: forceEstimateMatches.length >= 10,
    enough_intact_force_estimates: intactForceMatches.length >= 10,
    matched_altitude_coverage: matchedBands.filter((band) => band.count >= 2).length >= 4,
  };
  return {
    off_run_id: offRun.run_id,
    fixed_mode: fixedRun.mode,
    fixed_run_id: fixedRun.run_id,
    fixed_angle_deg: fixedAngle,
    trajectories_profile_key: runProfileKey(fixedRun),
    trajectories_profile_id: fixedRun.run.trajectories_profile_id ?? offRun.run.trajectories_profile_id ?? "legacy",
    entry_corridor_id: fixedRun.run.entry_corridor_id ?? offRun.run.entry_corridor_id ?? "trajectories_miss",
    initial,
    matched_sample_count: matches.length,
    stable_deploy_match_count: stableDeployMatches.length,
    planned_aligned_match_count: plannedAlignedMatches.length,
    force_estimate_match_count: forceEstimateMatches.length,
    intact_force_estimate_match_count: intactForceMatches.length,
    matched_altitude_bands: matchedBands,
    checks,
    comparable: Object.values(checks).every(Boolean),
    matches,
  };
}

function chooseBestPairForFixedRun(runs, fixed) {
  const offRuns = runs.filter((run) => run.mode === "off");
  const candidates = [];
  for (const off of offRuns) {
    if (runProfileKey(off) !== runProfileKey(fixed)) continue;
    const comparison = comparePair(off, fixed);
    const initialPenalty = comparison.initial ? comparison.initial.altitude_delta_m + comparison.initial.airspeed_delta_mps * 20 + comparison.initial.position_delta_m : Number.POSITIVE_INFINITY;
    candidates.push({ off, fixed, comparison, initialPenalty });
  }
  candidates.sort((a, b) => Number(b.comparison.comparable) - Number(a.comparison.comparable) || b.comparison.matched_sample_count - a.comparison.matched_sample_count || a.initialPenalty - b.initialPenalty);
  return candidates[0] ?? null;
}

function chooseBestPair(runs, fixedMode = "fixed90") {
  const candidates = runs.filter((run) => run.mode === fixedMode)
    .map((fixed) => chooseBestPairForFixedRun(runs, fixed))
    .filter(Boolean);
  candidates.sort((a, b) => Number(b.comparison.comparable) - Number(a.comparison.comparable) || b.comparison.matched_sample_count - a.comparison.matched_sample_count || a.initialPenalty - b.initialPenalty);
  return candidates[0] ?? null;
}

function analyzeSegments(segments) {
  const runs = mergeSegments(segments);
  const runSummaries = runs.map(summarizeRun);
  const summaryById = new Map(runSummaries.map((summary) => [summary.run_id, summary]));
  const groupedRuns = new Map();
  for (const run of runs) {
    const key = runProfileKey(run);
    if (!groupedRuns.has(key)) groupedRuns.set(key, []);
    groupedRuns.get(key).push(run);
  }
  const profileSets = [...groupedRuns.entries()].map(([profileKey, profileRuns]) => ({
    profile_key: profileKey,
    profile_id: profileRuns.map((run) => run.run.trajectories_profile_id).find(Boolean) ?? "legacy",
    runs: profileRuns,
    fixed30: chooseBestPair(profileRuns, "fixed30"),
    fixed45: chooseBestPair(profileRuns, "fixed45"),
    fixed50: chooseBestPair(profileRuns, "fixed50"),
    fixed60: chooseBestPair(profileRuns, "fixed60"),
    fixed90: chooseBestPair(profileRuns, "fixed90"),
    custom_fixed: profileRuns.filter((run) => run.mode === "fixed")
      .map((fixed) => chooseBestPairForFixedRun(profileRuns, fixed))
      .filter(Boolean),
  }));
  const pairUsable = (pair) => Boolean(pair
    && summaryById.get(pair.off.run_id)?.usable
    && summaryById.get(pair.fixed.run_id)?.usable
    && pair.comparison.comparable);
  // A breakup is a measured survivability result, not a reason to discard the
  // intact pre-failure rows. comparePair() independently requires enough clean,
  // state-matched, intact samples for predictor fitting.
  const pairFitReady = (pair) => Boolean(pair?.comparison.comparable);
  const pairSort = (field) => (a, b) => Number(pairUsable(b[field])) - Number(pairUsable(a[field]))
    || (b[field]?.comparison.matched_sample_count ?? 0) - (a[field]?.comparison.matched_sample_count ?? 0);
  const endpointSet = profileSets.filter((set) => set.fixed90).sort(pairSort("fixed90"))[0] ?? null;
  const angleSet = profileSets.filter((set) => set.fixed90 && set.fixed45).sort((a, b) =>
    Number(pairUsable(b.fixed90) && pairUsable(b.fixed45)) - Number(pairUsable(a.fixed90) && pairUsable(a.fixed45))
    || (b.fixed90.comparison.matched_sample_count + b.fixed45.comparison.matched_sample_count)
      - (a.fixed90.comparison.matched_sample_count + a.fixed45.comparison.matched_sample_count))[0] ?? null;
  const fixed45Set = profileSets.filter((set) => set.fixed45).sort(pairSort("fixed45"))[0] ?? null;
  const fixed50Set = profileSets.filter((set) => set.fixed50).sort(pairSort("fixed50"))[0] ?? null;
  const fixed60Set = profileSets.filter((set) => set.fixed60).sort(pairSort("fixed60"))[0] ?? null;
  const fixed30Set = profileSets.filter((set) => set.fixed30).sort(pairSort("fixed30"))[0] ?? null;
  const fixed90Pair = endpointSet?.fixed90 ?? null;
  const fixed45Pair = angleSet?.fixed45 ?? fixed45Set?.fixed45 ?? null;
  const fixed50Pair = fixed50Set?.fixed50 ?? null;
  const fixed60Pair = fixed60Set?.fixed60 ?? null;
  const fixed30Pair = fixed30Set?.fixed30 ?? null;
  const customFixedPairs = profileSets.flatMap((set) => set.custom_fixed);
  const readiness = {
    has_off_run: runs.some((run) => run.mode === "off"),
    has_fixed90_run: runs.some((run) => run.mode === "fixed90"),
    off_run_usable: fixed90Pair ? summaryById.get(fixed90Pair.off.run_id).usable : false,
    fixed90_run_usable: fixed90Pair ? summaryById.get(fixed90Pair.fixed.run_id).usable : false,
    matched_pair_comparable: fixed90Pair ? fixed90Pair.comparison.comparable : false,
  };
  const readyForDifferentialFit = Object.values(readiness).every(Boolean);
  const angleReadiness = {
    same_profile_off_45_90: Boolean(angleSet),
    differential_baseline_ready: angleSet ? pairUsable(angleSet.fixed90) : false,
    has_fixed45_run: runs.some((run) => run.mode === "fixed45"),
    fixed45_off_run_usable: angleSet ? summaryById.get(angleSet.fixed45.off.run_id).usable : false,
    fixed45_run_usable: angleSet ? summaryById.get(angleSet.fixed45.fixed.run_id).usable : false,
    matched_fixed45_pair_comparable: angleSet ? angleSet.fixed45.comparison.comparable : false,
  };
  const matched10Set = profileSets.filter((set) => set.profile_id === "matched10").sort((a, b) => {
    const score = (set) => Number(set.runs.some((run) => run.mode === "off" && summaryById.get(run.run_id)?.usable))
      + Number(pairFitReady(set.fixed30))
      + Number(pairFitReady(set.fixed45))
      + Number(pairFitReady(set.fixed90));
    return score(b) - score(a)
      || (b.fixed30?.comparison.matched_sample_count ?? 0) + (b.fixed45?.comparison.matched_sample_count ?? 0) + (b.fixed90?.comparison.matched_sample_count ?? 0)
        - (a.fixed30?.comparison.matched_sample_count ?? 0) - (a.fixed45?.comparison.matched_sample_count ?? 0) - (a.fixed90?.comparison.matched_sample_count ?? 0);
  })[0] ?? null;
  const matched10Validation = {
    has_profile: Boolean(matched10Set),
    profile_key: matched10Set?.profile_key ?? null,
    has_off_run: Boolean(matched10Set?.runs.some((run) => run.mode === "off" && summaryById.get(run.run_id)?.usable)),
    fixed30_pair_comparable: pairFitReady(matched10Set?.fixed30),
    fixed45_pair_comparable: pairFitReady(matched10Set?.fixed45),
    fixed90_pair_comparable: pairFitReady(matched10Set?.fixed90),
  };
  const matched10Pairs = matched10Set
    ? [matched10Set.fixed30, matched10Set.fixed45, matched10Set.fixed50, matched10Set.fixed60, matched10Set.fixed90, ...matched10Set.custom_fixed].filter(Boolean)
    : [];
  const matched10SurvivabilityRuns = matched10Pairs.map((pair) => {
    const summary = summaryById.get(pair.fixed.run_id);
    const fullIntegrity = summary?.expected_vessel_part_count > 0
      && summary.minimum_vessel_part_count === summary.expected_vessel_part_count;
    return {
      run_id: pair.fixed.run_id,
      mode: pair.fixed.mode,
      angle_deg: pair.comparison.fixed_angle_deg,
      status: summary?.status ?? null,
      fit_pair_comparable: pair.comparison.comparable,
      full_integrity: fullIntegrity,
      minimum_vessel_part_count: summary?.minimum_vessel_part_count ?? null,
      expected_vessel_part_count: summary?.expected_vessel_part_count ?? null,
      minimum_airbrake_count: summary?.minimum_airbrake_count ?? null,
      expected_airbrake_count: summary?.expected_airbrake_count ?? null,
      first_loss_altitude_m: summary?.first_vessel_part_loss_altitude_m ?? null,
      first_loss_dynamic_pressure_kpa: summary?.first_vessel_part_loss_dynamic_pressure_kpa ?? null,
      first_loss_dynamic_pressure_fraction_of_run_peak: summary?.first_vessel_part_loss_dynamic_pressure_fraction_of_run_peak ?? null,
      first_loss_mach: summary?.first_vessel_part_loss_mach ?? null,
      first_loss_airbrake_load_proxy_kpa: summary?.first_vessel_part_loss_airbrake_load_proxy_kpa ?? null,
      first_loss_convective_heating_rate_proxy: summary?.first_vessel_part_loss_convective_heating_rate_proxy ?? null,
      first_loss_airbrake_heating_rate_proxy: summary?.first_vessel_part_loss_airbrake_heating_rate_proxy ?? null,
      first_loss_convective_heating_exposure_proxy: summary?.first_vessel_part_loss_convective_heating_exposure_proxy ?? null,
      first_loss_airbrake_heating_exposure_proxy: summary?.first_vessel_part_loss_airbrake_heating_exposure_proxy ?? null,
      max_intact_airbrake_load_proxy_kpa: summary?.max_intact_airbrake_load_proxy_kpa ?? null,
      max_intact_convective_heating_exposure_proxy: summary?.max_intact_convective_heating_exposure_proxy ?? null,
      max_intact_airbrake_heating_exposure_proxy: summary?.max_intact_airbrake_heating_exposure_proxy ?? null,
    };
  }).sort((a, b) => a.angle_deg - b.angle_deg);
  const fullIntegrityAngles = matched10SurvivabilityRuns.filter((run) => run.full_integrity).map((run) => run.angle_deg);
  const matched10Survivability = {
    run_count: matched10SurvivabilityRuns.length,
    runs: matched10SurvivabilityRuns,
    full_integrity_angles_deg: fullIntegrityAngles,
    minimum_full_integrity_angle_deg: fullIntegrityAngles.length ? Math.min(...fullIntegrityAngles) : null,
    corridor_has_full_integrity_result: fullIntegrityAngles.length > 0,
  };
  // Survivability is an observed hardware outcome and does not require a
  // same-corridor off run or Trajectories/AoA fit alignment. Keep it grouped by
  // profile and corridor so a survivable corrected-corridor run cannot be
  // hidden by the older fit-calibration corridor.
  const survivabilityByProfileCorridor = profileSets.map((set) => {
    const resultRuns = set.runs.map((run) => {
      const summary = summaryById.get(run.run_id);
      const angle = expectedFixedAngle(run);
      if (angle === null || !summary?.checks.complete_status || !(summary.expected_vessel_part_count > 0) || summary.minimum_vessel_part_count === null) return null;
      const fullIntegrity = summary.minimum_vessel_part_count === summary.expected_vessel_part_count;
      return {
        run_id: run.run_id,
        mode: run.mode,
        angle_deg: angle,
        status: summary.status,
        predictor_fit_usable: summary.usable,
        full_integrity: fullIntegrity,
        minimum_vessel_part_count: summary.minimum_vessel_part_count,
        expected_vessel_part_count: summary.expected_vessel_part_count,
        minimum_airbrake_count: summary.minimum_airbrake_count,
        expected_airbrake_count: summary.expected_airbrake_count,
        first_loss_altitude_m: summary.first_vessel_part_loss_altitude_m,
        first_loss_dynamic_pressure_kpa: summary.first_vessel_part_loss_dynamic_pressure_kpa,
        first_loss_dynamic_pressure_fraction_of_run_peak: summary.first_vessel_part_loss_dynamic_pressure_fraction_of_run_peak,
        first_loss_airbrake_load_proxy_kpa: summary.first_vessel_part_loss_airbrake_load_proxy_kpa,
        first_loss_convective_heating_exposure_proxy: summary.first_vessel_part_loss_convective_heating_exposure_proxy,
        first_loss_airbrake_heating_exposure_proxy: summary.first_vessel_part_loss_airbrake_heating_exposure_proxy,
        max_dynamic_pressure_kpa: summary.max_dynamic_pressure_kpa,
        max_intact_airbrake_load_proxy_kpa: summary.max_intact_airbrake_load_proxy_kpa,
        max_intact_convective_heating_exposure_proxy: summary.max_intact_convective_heating_exposure_proxy,
        max_intact_airbrake_heating_exposure_proxy: summary.max_intact_airbrake_heating_exposure_proxy,
      };
    }).filter(Boolean).sort((a, b) => a.angle_deg - b.angle_deg || a.run_id - b.run_id);
    if (!resultRuns.length) return null;
    const fullIntegrityAnglesForCorridor = resultRuns.filter((run) => run.full_integrity).map((run) => run.angle_deg);
    return {
      profile_key: set.profile_key,
      profile_id: set.profile_id,
      entry_corridor_id: set.runs[0]?.run.entry_corridor_id ?? "trajectories_miss",
      run_count: resultRuns.length,
      runs: resultRuns,
      full_integrity_angles_deg: fullIntegrityAnglesForCorridor,
      minimum_full_integrity_angle_deg: fullIntegrityAnglesForCorridor.length ? Math.min(...fullIntegrityAnglesForCorridor) : null,
      corridor_has_full_integrity_result: fullIntegrityAnglesForCorridor.length > 0,
    };
  }).filter(Boolean).sort((a, b) => a.profile_id.localeCompare(b.profile_id) || a.entry_corridor_id.localeCompare(b.entry_corridor_id));
  const controllableCorridorValidation = profileSets.map((set) => {
    const latestEndpoint = (angle) => set.runs
      .map((run) => ({ run, summary: summaryById.get(run.run_id), angle: expectedFixedAngle(run) }))
      .filter((item) => item.angle !== null && Math.abs(item.angle - angle) < 0.01
        && item.summary?.checks.complete_status && item.summary.landing_position_available)
      .sort((a, b) => Number(b.run.run_id) - Number(a.run.run_id))[0] ?? null;
    const endpoint60 = latestEndpoint(60);
    const endpoint90 = latestEndpoint(90);
    if (!endpoint60 && !endpoint90) return null;
    const formatEndpoint = (endpoint) => {
      if (!endpoint) return null;
      const summary = endpoint.summary;
      const fullIntegrity = summary.expected_vessel_part_count > 0
        && summary.minimum_vessel_part_count === summary.expected_vessel_part_count;
      return {
        run_id: endpoint.run.run_id,
        angle_deg: endpoint.angle,
        full_integrity: fullIntegrity,
        landing_miss_m: summary.landing_miss_m,
        landing_along_miss_m: summary.landing_along_miss_m,
        landing_cross_miss_m: summary.landing_cross_miss_m,
      };
    };
    const fixed60 = formatEndpoint(endpoint60);
    const fixed90 = formatEndpoint(endpoint90);
    const endpointsReady = Boolean(fixed60?.full_integrity && fixed90?.full_integrity
      && finite(fixed60.landing_along_miss_m) && finite(fixed90.landing_along_miss_m));
    const expectedOrdering = endpointsReady && fixed60.landing_along_miss_m <= fixed90.landing_along_miss_m;
    const targetBracketed = endpointsReady && fixed60.landing_along_miss_m * fixed90.landing_along_miss_m <= 0;
    return {
      profile_key: set.profile_key,
      profile_id: set.profile_id,
      entry_corridor_id: set.runs[0]?.run.entry_corridor_id ?? "trajectories_miss",
      target_deorbit_phase_angle_deg: set.runs[0]?.run.target_deorbit_phase_angle_deg ?? null,
      fixed60,
      fixed90,
      endpoints_ready: endpointsReady,
      expected_angle_ordering: expectedOrdering,
      target_bracketed: targetBracketed,
      authority_span_m: endpointsReady ? fixed90.landing_along_miss_m - fixed60.landing_along_miss_m : null,
      authority_midpoint_m: endpointsReady ? (fixed60.landing_along_miss_m + fixed90.landing_along_miss_m) / 2 : null,
      closed_loop_test_ready: endpointsReady && expectedOrdering && targetBracketed,
    };
  }).filter(Boolean);
  const closedLoopValidation = runs.filter((run) => run.mode === "pid").map((run) => {
    const summary = summaryById.get(run.run_id);
    const entry = run.samples.filter((sample) => sample.phase === "entry");
    const active = entry.filter((sample) => sample.brakes_action_group && finite(sample.effective_airbrake_command_deg));
    const minimum = finite(run.run.airbrake_min_angle_deg) ? run.run.airbrake_min_angle_deg : 60;
    const maximum = finite(run.run.airbrake_max_angle_deg) ? run.run.airbrake_max_angle_deg : 90;
    const commands = active.map((sample) => sample.effective_airbrake_command_deg);
    const interiorCount = commands.filter((angle) => angle > minimum + 1 && angle < maximum - 1).length;
    const minimumCount = commands.filter((angle) => angle <= minimum + 1).length;
    const maximumCount = commands.filter((angle) => angle >= maximum - 1).length;
    const alongMisses = entry.map((sample) => sample.impact_along_miss_m).filter(finite);
    let alongZeroCrossings = 0;
    for (let index = 1; index < alongMisses.length; index += 1) {
      if (Math.sign(alongMisses[index]) !== 0 && Math.sign(alongMisses[index - 1]) !== 0
        && Math.sign(alongMisses[index]) !== Math.sign(alongMisses[index - 1])) alongZeroCrossings += 1;
    }
    const guidedHandoff = run.samples.find((sample) => sample.phase === "guided_landing_handoff");
    const corridor = controllableCorridorValidation.find((item) => item.profile_key === runProfileKey(run));
    const fullIntegrity = summary?.expected_vessel_part_count > 0
      && summary.minimum_vessel_part_count === summary.expected_vessel_part_count;
    const checks = {
      corridor_ready: corridor?.closed_loop_test_ready === true,
      completed_landing: summary?.status === "landed",
      full_integrity: fullIntegrity,
      safe_envelope_compliance: summary?.checks.mode_compliance === true,
      command_modulated_inside_envelope: commands.length > 0 && interiorCount / commands.length >= 0.05,
      guided_landing_handoff: Boolean(guidedHandoff),
      predicted_handoff_within_5km: finite(guidedHandoff?.impact_miss_m) && guidedHandoff.impact_miss_m <= 5000,
      actual_landing_position: summary?.landing_position_available === true,
      actual_landing_within_5km: finite(summary?.landing_miss_m) && summary.landing_miss_m <= 5000,
    };
    return {
      run_id: run.run_id,
      profile_id: run.run.trajectories_profile_id ?? "legacy",
      entry_corridor_id: run.run.entry_corridor_id ?? "trajectories_miss",
      target_deorbit_phase_angle_deg: run.run.target_deorbit_phase_angle_deg ?? null,
      status: summary?.status ?? null,
      checks,
      passed: Object.values(checks).every(Boolean),
      command_sample_count: commands.length,
      command_min_deg: commands.length ? Math.min(...commands) : null,
      command_max_deg: commands.length ? Math.max(...commands) : null,
      command_median_deg: commands.length ? median(commands) : null,
      command_at_min_fraction: commands.length ? minimumCount / commands.length : null,
      command_at_max_fraction: commands.length ? maximumCount / commands.length : null,
      command_interior_fraction: commands.length ? interiorCount / commands.length : null,
      initial_trajectories_along_miss_m: alongMisses[0] ?? null,
      final_entry_trajectories_along_miss_m: alongMisses.at(-1) ?? null,
      trajectories_along_zero_crossings: alongZeroCrossings,
      predicted_handoff_miss_m: guidedHandoff?.impact_miss_m ?? null,
      landing_miss_m: summary?.landing_miss_m ?? null,
      landing_along_miss_m: summary?.landing_along_miss_m ?? null,
      landing_cross_miss_m: summary?.landing_cross_miss_m ?? null,
      full_integrity: fullIntegrity,
    };
  });
  const serializableProfileSets = profileSets.map((set) => ({
    profile_key: set.profile_key,
    profile_id: set.profile_id,
    run_ids: set.runs.map((run) => run.run_id),
    fixed30_pair: set.fixed30 ? { ...set.fixed30.comparison, matches: undefined } : null,
    fixed45_pair: set.fixed45 ? { ...set.fixed45.comparison, matches: undefined } : null,
    fixed50_pair: set.fixed50 ? { ...set.fixed50.comparison, matches: undefined } : null,
    fixed60_pair: set.fixed60 ? { ...set.fixed60.comparison, matches: undefined } : null,
    fixed90_pair: set.fixed90 ? { ...set.fixed90.comparison, matches: undefined } : null,
    custom_fixed_pairs: set.custom_fixed.map((pair) => ({ ...pair.comparison, matches: undefined })),
  }));
  const matchedRows = profileSets.flatMap((set) => [set.fixed30, set.fixed45, set.fixed50, set.fixed60, set.fixed90, ...set.custom_fixed]
    .filter(Boolean)
    .flatMap((pair) => pair.comparison.matches));
  return {
    schema: "reentry_airbrake_telemetry_report",
    schema_version: 1,
    generated_at: new Date().toISOString(),
    run_count: runs.length,
    runs: runSummaries,
    selected_pair: fixed90Pair ? { ...fixed90Pair.comparison, matches: undefined } : null,
    selected_fixed45_pair: fixed45Pair ? { ...fixed45Pair.comparison, matches: undefined } : null,
    selected_fixed50_pair: fixed50Pair ? { ...fixed50Pair.comparison, matches: undefined } : null,
    selected_fixed60_pair: fixed60Pair ? { ...fixed60Pair.comparison, matches: undefined } : null,
    selected_fixed30_pair: fixed30Pair ? { ...fixed30Pair.comparison, matches: undefined } : null,
    custom_fixed_pairs: customFixedPairs.map((pair) => ({ ...pair.comparison, matches: undefined })),
    profile_sets: serializableProfileSets,
    readiness,
    angle_readiness: angleReadiness,
    matched10_validation: matched10Validation,
    matched10_survivability: matched10Survivability,
    survivability_by_profile_corridor: survivabilityByProfileCorridor,
    controllable_corridor_validation: controllableCorridorValidation,
    closed_loop_validation: closedLoopValidation,
    ready_for_differential_fit: readyForDifferentialFit,
    ready_for_angle_response_fit: Object.values(angleReadiness).every(Boolean),
    ready_for_matched10_validation: Object.values(matched10Validation).every(Boolean),
    merged_runs: runs,
    matched_rows: matchedRows,
  };
}

function csvEscape(value) {
  if (value === undefined || value === null) return "";
  const text = typeof value === "object" ? JSON.stringify(value) : String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function writeCsv(file, rows) {
  const columns = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const lines = [columns.map(csvEscape).join(",")];
  for (const row of rows) lines.push(columns.map((column) => csvEscape(row[column])).join(","));
  fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  fs.writeFileSync(file, `${lines.join("\n")}\n`, "utf8");
}

function flattenedSamples(runs) {
  return runs.flatMap((run) => run.samples.map((sample) => ({
    run_id: run.run_id,
    airbrake_control_mode: run.mode,
    trajectories_profile_id: run.run.trajectories_profile_id ?? "legacy",
    entry_corridor_id: run.run.entry_corridor_id ?? "trajectories_miss",
    target_entry_fpa_down_deg: run.run.target_entry_fpa_down_deg ?? null,
    predicted_entry_fpa_down_deg: run.run.predicted_entry_fpa_down_deg ?? null,
    target_deorbit_phase_angle_deg: run.run.target_deorbit_phase_angle_deg ?? null,
    actual_deorbit_burn_phase_angle_deg: run.run.actual_deorbit_burn_phase_angle_deg ?? null,
    run_status: run.status,
    ...sample,
  })));
}

function parseArgs(argv) {
  const options = { inputs: [], out: null, matchedOut: null, summaryOut: null, strict: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--out") options.out = argv[++i];
    else if (arg === "--matched-out") options.matchedOut = argv[++i];
    else if (arg === "--summary-out") options.summaryOut = argv[++i];
    else if (arg === "--strict") options.strict = true;
    else if (arg === "--help" || arg === "-h") options.help = true;
    else options.inputs.push(arg);
  }
  return options;
}

function formatNumber(value, digits = 1) {
  return finite(value) ? value.toFixed(digits) : "n/a";
}

function printReport(report, fileCount) {
  console.log(`Telemetry files: ${fileCount} | runs: ${report.run_count}`);
  for (const run of report.runs) {
    const failed = Object.entries(run.checks).filter(([, ok]) => !ok).map(([name]) => name);
    const airbrakeLoss = run.first_airbrake_loss_altitude_m === null ? "intact" : `first loss ${formatNumber(run.first_airbrake_loss_altitude_m / 1000)} km`;
    const vesselLoss = run.first_vessel_part_loss_altitude_m === null
      ? "intact"
      : `first loss ${formatNumber(run.first_vessel_part_loss_altitude_m / 1000)} km / ${formatNumber(run.first_vessel_part_loss_dynamic_pressure_kpa, 2)} kPa`;
    const vesselParts = run.expected_vessel_part_count === null ? "n/a" : `${run.minimum_vessel_part_count}/${run.expected_vessel_part_count} (${vesselLoss})`;
    const runLabel = run.usable
      ? "PASS"
      : run.checks.complete_status && run.checks.enough_entry_samples
        ? run.checks.no_vessel_part_loss ? "CHECK" : "FAIL"
        : "WAIT";
    console.log(`${runLabel} ${run.run_id} ${run.mode}: ${run.entry_sample_count} entry samples, ${formatNumber(run.altitude_max_m / 1000)}-${formatNumber(run.altitude_min_m / 1000)} km, qmax ${formatNumber(run.max_dynamic_pressure_kpa, 2)} kPa, loadmax ${formatNumber(run.max_airbrake_load_proxy_kpa, 2)} kPa-eq, TR ${(run.trajectories_impact_ratio * 100).toFixed(0)}%, vessel ${vesselParts}, airbrakes ${run.minimum_airbrake_count}/${run.expected_airbrake_count} (${airbrakeLoss}), status ${run.status}`);
    const angleReadback = run.airbrake_angle_readback_compliance_ratio === null ? "n/a" : `${(run.airbrake_angle_readback_compliance_ratio * 100).toFixed(0)}%`;
    const authorityReadback = run.airbrake_authority_limiter_zero_compliance_ratio === null
      ? "n/a"
      : `${(run.airbrake_authority_limiter_zero_compliance_ratio * 100).toFixed(0)}% at 0%, max ${formatNumber(run.airbrake_authority_limiter_max_percent)}%`;
    const plannedAlignment = run.trajectories_planned_vector_alignment_ratio === null ? "n/a" : `${(run.trajectories_planned_vector_alignment_ratio * 100).toFixed(0)}% <=2deg in 0.1-3kPa; median ${formatNumber(run.trajectories_planned_vector_median_error_deg)}deg, p90 ${formatNumber(run.trajectories_planned_vector_p90_error_deg)}deg`;
    const allAeroAlignment = run.trajectories_planned_vector_all_aero_alignment_ratio === null ? "n/a" : `${(run.trajectories_planned_vector_all_aero_alignment_ratio * 100).toFixed(0)}% <=2deg; p90 ${formatNumber(run.trajectories_planned_vector_all_aero_p90_error_deg)}deg`;
    console.log(`     sensors barometer=${run.sensors.barometer} thermometer=${run.sensors.thermometer} accelerometer=${run.sensors.accelerometer} gravimeter=${run.sensors.gravimeter} | angle readback=${angleReadback}, authority=${authorityReadback}, reassertions=${run.airbrake_angle_reassertion_count ?? "n/a"} | planned fit-domain=${plannedAlignment}, all-aero=${allAeroAlignment}${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
  if (report.selected_pair) {
    const pair = report.selected_pair;
    const failed = Object.entries(pair.checks).filter(([, ok]) => !ok).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} ${pair.fixed_mode}=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches, initial Δv=${formatNumber(pair.initial.airspeed_delta_mps)} m/s, Δpos=${formatNumber(pair.initial.position_delta_m)} m${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  } else {
    console.log("WAIT pair: both an off run and a fixed90 run are required");
  }
  if (report.selected_fixed45_pair) {
    const pair = report.selected_fixed45_pair;
    const failed = Object.entries(pair.checks).filter(([, ok]) => !ok).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} fixed45=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches, initial Δv=${formatNumber(pair.initial.airspeed_delta_mps)} m/s, Δpos=${formatNumber(pair.initial.position_delta_m)} m${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  } else {
    console.log("WAIT angle pair: both an off run and a fixed45 run are required");
  }
  if (report.selected_fixed60_pair) {
    const pair = report.selected_fixed60_pair;
    const failed = Object.entries(pair.checks).filter(([, passed]) => !passed).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} fixed60=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
  if (report.selected_fixed50_pair) {
    const pair = report.selected_fixed50_pair;
    const failed = Object.entries(pair.checks).filter(([, passed]) => !passed).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} fixed50=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
  for (const pair of report.custom_fixed_pairs ?? []) {
    const failed = Object.entries(pair.checks).filter(([, passed]) => !passed).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} fixed(${formatNumber(pair.fixed_angle_deg, 2)}deg)=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
  if (report.selected_fixed30_pair) {
    const pair = report.selected_fixed30_pair;
    const failed = Object.entries(pair.checks).filter(([, ok]) => !ok).map(([name]) => name);
    console.log(`${pair.comparable ? "PASS" : "WAIT"} pair[${pair.trajectories_profile_id}] off=${pair.off_run_id} fixed30=${pair.fixed_run_id}: ${pair.matched_sample_count} state matches${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
  console.log(report.ready_for_differential_fit ? "READY: telemetry is sufficient for the first differential airbrake fit." : "NOT READY: gather or repair the checks above before fitting the predictor.");
  console.log(report.ready_for_angle_response_fit ? "READY: off/45/90 telemetry is sufficient to fit deployment-angle response." : "ANGLE CURVE WAIT: add a comparable fixed45 run before fitting deployment-angle nonlinearity.");
  console.log(report.ready_for_matched10_validation
    ? "READY: matched10 off/30/45/90 dataset is complete; intact pre-failure rows are available for predictor validation."
    : "MATCHED10 WAIT: gather comparable matched10 off, fixed30, fixed45, and fixed90 runs.");
  for (const group of report.survivability_by_profile_corridor ?? []) {
    console.log(`SURVIVABILITY [${group.profile_id}/${group.entry_corridor_id}]`);
    for (const run of group.runs) {
      const loss = run.full_integrity
        ? `full integrity; qmax ${formatNumber(run.max_dynamic_pressure_kpa, 2)} kPa, loadmax ${formatNumber(run.max_intact_airbrake_load_proxy_kpa, 2)} kPa-eq`
        : `first loss ${formatNumber(run.first_loss_altitude_m / 1000)} km, q ${formatNumber(run.first_loss_dynamic_pressure_kpa, 2)} kPa (${formatNumber((run.first_loss_dynamic_pressure_fraction_of_run_peak ?? 0) * 100, 0)}% qmax), load ${formatNumber(run.first_loss_airbrake_load_proxy_kpa, 2)} kPa-eq, craft/brake heat exposure ${formatNumber(run.first_loss_convective_heating_exposure_proxy, 1)}/${formatNumber(run.first_loss_airbrake_heating_exposure_proxy, 1)}`;
      console.log(`${run.full_integrity ? "SURVIVED" : "FAILED"} ${formatNumber(run.angle_deg, 1)}deg run ${run.run_id}: ${loss}${run.predictor_fit_usable ? "" : " | excluded from strict predictor fit"}`);
    }
    if (group.corridor_has_full_integrity_result) {
      console.log(`CORRIDOR SURVIVED [${group.profile_id}/${group.entry_corridor_id}]: full integrity at ${group.full_integrity_angles_deg.map((angle) => formatNumber(angle, 1)).join(", ")} deg.`);
    } else {
      console.log(`CORRIDOR FAIL [${group.profile_id}/${group.entry_corridor_id}]: no tested fixed airbrake angle retained full vessel integrity.`);
    }
  }
  for (const validation of report.controllable_corridor_validation ?? []) {
    const phase = formatNumber(validation.target_deorbit_phase_angle_deg, 1);
    if (!validation.endpoints_ready) {
      console.log(`CONTROL CORRIDOR WAIT [${validation.profile_id}/${validation.entry_corridor_id}/phase ${phase}]: complete intact fixed60 and fixed90 landing positions are required.`);
      continue;
    }
    console.log(`${validation.closed_loop_test_ready ? "CONTROL CORRIDOR READY" : "CONTROL CORRIDOR FAIL"} [${validation.profile_id}/${validation.entry_corridor_id}/phase ${phase}]: 60deg along ${formatNumber(validation.fixed60.landing_along_miss_m / 1000, 2)} km, 90deg along ${formatNumber(validation.fixed90.landing_along_miss_m / 1000, 2)} km, authority ${formatNumber(validation.authority_span_m / 1000, 2)} km, midpoint ${formatNumber(validation.authority_midpoint_m / 1000, 2)} km; bracket=${validation.target_bracketed}, ordered=${validation.expected_angle_ordering}.`);
  }
  for (const validation of report.closed_loop_validation ?? []) {
    const failed = Object.entries(validation.checks).filter(([, passed]) => !passed).map(([name]) => name);
    console.log(`${validation.passed ? "CLOSED LOOP PASS" : "CLOSED LOOP WAIT/FAIL"} run ${validation.run_id}: command ${formatNumber(validation.command_min_deg, 1)}-${formatNumber(validation.command_max_deg, 1)} deg, interior ${formatNumber((validation.command_interior_fraction ?? 0) * 100, 0)}%, along zero crossings ${validation.trajectories_along_zero_crossings}, handoff ${formatNumber(validation.predicted_handoff_miss_m / 1000, 2)} km, landing ${formatNumber(validation.landing_miss_m / 1000, 2)} km${failed.length ? ` | needs: ${failed.join(", ")}` : ""}`);
  }
}

function usage() {
  console.log(`Usage: node scripts/analyze-reentry-telemetry.js [files/directories...] [options]

With no input, reads reentry telemetry from KSP's Ships/Script archive.

Options:
  --out FILE          Write all merged samples as CSV
  --matched-out FILE  Write profile-matched off/fixed30, off/fixed45, and off/fixed90 pairs as CSV
  --summary-out FILE  Write the sufficiency report as JSON
  --strict            Exit 2 unless the data is ready for a differential fit
  --help               Show this help`);
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    usage();
    return 0;
  }
  const files = discoverFiles(options.inputs);
  if (!files.length) {
    console.error("No reentry telemetry segments found. Run matched deorbits in off, fixed90, and fixed45 modes first.");
    return 1;
  }
  const report = analyzeSegments(files.map(readSegment));
  printReport(report, files.length);
  if (options.out) writeCsv(options.out, flattenedSamples(report.merged_runs));
  if (options.matchedOut) writeCsv(options.matchedOut, report.matched_rows);
  if (options.summaryOut) {
    const serializable = { ...report, merged_runs: undefined, matched_rows: undefined };
    fs.mkdirSync(path.dirname(path.resolve(options.summaryOut)), { recursive: true });
    fs.writeFileSync(options.summaryOut, `${JSON.stringify(serializable, null, 2)}\n`, "utf8");
  }
  return options.strict && !report.ready_for_differential_fit ? 2 : 0;
}

if (require.main === module) process.exitCode = main();

module.exports = {
  analyzeSegments,
  comparePair,
  decodeKos,
  discoverFiles,
  enrichSamples,
  flattenedSamples,
  main,
  mergeSegments,
  nearestMatches,
  readSegment,
  summarizeRun,
  writeCsv,
};
