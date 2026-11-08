#!/usr/bin/env node

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const {
  integrateRemainingCorrection,
  predictorForContext,
  statePathFromSamples,
} = require("./airbrake-adjusted-predictor.js");
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

function runAngle(mode, rows) {
  if (mode === "off") return 0;
  const fitDomain = rows.filter((row) => row.dynamic_pressure_kpa >= 0.1 && row.dynamic_pressure_kpa <= 3);
  const candidates = (fitDomain.length ? fitDomain : rows)
    .map((row) => row.airbrake_estimated_angle_deg ?? row.effective_airbrake_command_deg ?? row.airbrake_angle_command_deg)
    .filter(finite);
  const value = median(candidates);
  return finite(value) ? Math.round(value * 10) / 10 : null;
}

function downsampleByAltitude(rows) {
  const bins = new Map();
  for (const row of rows) {
    if (!finite(row.altitude_asl_m)) continue;
    const altitudeKm = row.altitude_asl_m / 1000;
    if (altitudeKm < 20 || altitudeKm > 70) continue;
    const bin = Math.round(altitudeKm);
    const distance = Math.abs(altitudeKm - bin);
    if (!bins.has(bin) || distance < bins.get(bin).distance) bins.set(bin, { row, distance });
  }
  return [...bins.values()].map(({ row }) => ({
    altitude_km: Math.round(row.altitude_asl_m / 100) / 10,
    airspeed_mps: finite(row.airspeed_mps) ? Math.round(row.airspeed_mps * 10) / 10 : null,
    trajectories_undershoot_km: finite(row.impact_along_miss_m) ? Math.round(row.impact_along_miss_m / 100) / 10 : null,
    flight_path_angle_down_deg: finite(row.flight_path_angle_deg) ? Math.round(-row.flight_path_angle_deg * 100) / 100 : null,
    dynamic_pressure_kpa: finite(row.dynamic_pressure_kpa) ? Math.round(row.dynamic_pressure_kpa * 100) / 100 : null,
    heating_exposure_proxy: finite(row.convective_heating_exposure_proxy) ? Math.round(row.convective_heating_exposure_proxy * 10) / 10 : null,
    vessel_parts: row.vessel_part_count,
    airbrakes: row.airbrake_part_count,
  })).sort((a, b) => a.altitude_km - b.altitude_km);
}

function buildDashboardData(samples, pairs, report, predictor) {
  const summaries = new Map((report.runs ?? []).map((run) => [String(run.run_id), run]));
  const profileMetadata = (profileKey) => {
    try {
      return JSON.parse(profileKey);
    } catch {
      return {};
    }
  };
  const profileSetGroups = new Map();
  for (const set of report.profile_sets ?? []) {
    const metadata = profileMetadata(set.profile_key);
    const corridorId = metadata.entry_corridor_id ?? "trajectories_miss";
    const phaseTarget = finite(metadata.deorbit_phase_target_deg) ? metadata.deorbit_phase_target_deg : "unverified";
    const safeguard = metadata.airbrake_exposure_safeguard;
    const safeguardKey = safeguard
      ? `${safeguard.budget_units ?? "?"}u/${safeguard.cooldown_s ?? "?"}s`
      : "none";
    const dashboardProfileId = safeguard
      ? `${set.profile_id} · thermal ${safeguardKey}`
      : set.profile_id;
    const key = `${set.profile_id}|${corridorId}|${phaseTarget}|${safeguardKey}`;
    if (!profileSetGroups.has(key)) profileSetGroups.set(key, []);
    const completeRuns = set.run_ids.filter((runId) => summaries.get(String(runId))?.checks?.complete_status !== false).length;
    const authorityLocked = metadata.airbrake_authority_limiter_percent === 0;
    profileSetGroups.get(key).push({ set, corridorId, phaseTarget, safeguardKey, dashboardProfileId, score: Number(authorityLocked) * 1e6 + completeRuns * 1000 + set.run_ids.length });
  }
  const selectedProfileSets = [...profileSetGroups.values()].map((sets) => sets.sort((a, b) => b.score - a.score)[0]);
  const selectedRunIds = new Set(selectedProfileSets.flatMap(({ set }) => set.run_ids.map(String)));
  const dashboardProfileByRunId = new Map(selectedProfileSets.flatMap(({ set, dashboardProfileId }) =>
    set.run_ids.map((runId) => [String(runId), dashboardProfileId])));
  const selectedContexts = new Map(selectedProfileSets.map(({ set, corridorId, phaseTarget, dashboardProfileId }) => [
    set.profile_key,
    {
      profile_id: dashboardProfileId,
      profile_key: set.profile_key,
      corridor_id: corridorId,
      phase_target_deg: phaseTarget,
      predictor: predictorForContext(predictor, {
        profile_id: set.profile_id,
        profile_key: set.profile_key,
        corridor_id: corridorId,
      }),
    },
  ]));

  const grouped = new Map();
  for (const sample of samples) {
    const id = String(sample.run_id);
    if (!grouped.has(id)) grouped.set(id, []);
    grouped.get(id).push(sample);
  }

  const runs = [];
  for (const [runId, unsorted] of grouped) {
    if (selectedRunIds.size && !selectedRunIds.has(runId)) continue;
    const summary = summaries.get(runId);
    if (summary?.checks?.complete_status === false) continue;
    const rows = [...unsorted].sort((a, b) => (a.time_s ?? 0) - (b.time_s ?? 0));
    const entryRows = rows.filter((row) => row.phase === "entry");
    if (entryRows.length < 5) continue;
    const mode = entryRows[0].airbrake_control_mode ?? "unknown";
    const initialParts = Math.max(...rows.map((row) => row.vessel_part_count).filter(finite), -Infinity);
    const initialAirbrakes = Math.max(...rows.map((row) => row.airbrake_part_count).filter(finite), -Infinity);
    const lossRow = rows.find((row) => (finite(initialParts) && finite(row.vessel_part_count) && row.vessel_part_count < initialParts)
      || (finite(initialAirbrakes) && finite(row.airbrake_part_count) && row.airbrake_part_count < initialAirbrakes));
    const finalRow = rows.at(-1);
    runs.push({
      run_id: runId,
      mode,
      angle_deg: runAngle(mode, entryRows),
      profile_id: dashboardProfileByRunId.get(runId) ?? entryRows[0].trajectories_profile_id ?? "legacy",
      corridor_id: entryRows[0].entry_corridor_id ?? "trajectories_miss",
      phase_target_deg: finite(summary?.target_deorbit_phase_angle_deg)
        ? summary.target_deorbit_phase_angle_deg
        : finite(entryRows[0].target_deorbit_phase_angle_deg) ? entryRows[0].target_deorbit_phase_angle_deg : null,
      phase_key: finite(summary?.target_deorbit_phase_angle_deg)
        ? String(summary.target_deorbit_phase_angle_deg)
        : finite(entryRows[0].target_deorbit_phase_angle_deg) ? String(entryRows[0].target_deorbit_phase_angle_deg) : "unverified",
      target_entry_fpa_down_deg: entryRows[0].target_entry_fpa_down_deg,
      predicted_entry_fpa_down_deg: entryRows[0].predicted_entry_fpa_down_deg,
      measured_entry_fpa_down_deg: finite(entryRows[0].flight_path_angle_deg) ? -entryRows[0].flight_path_angle_deg : null,
      status: summary?.status ?? entryRows[0].run_status ?? "unknown",
      airbrake_cooldown_count: summary?.airbrake_cooldown_count ?? 0,
      airbrake_exposure_budget_units: summary?.airbrake_exposure_budget_units ?? null,
      airbrake_cooldown_duration_s: summary?.airbrake_cooldown_duration_s ?? null,
      max_dynamic_pressure_kpa: summary?.max_dynamic_pressure_kpa ?? Math.max(...entryRows.map((row) => row.dynamic_pressure_kpa).filter(finite), 0),
      max_intact_dynamic_pressure_kpa: summary?.max_intact_dynamic_pressure_kpa ?? null,
      max_airbrake_load_proxy_kpa: summary?.max_airbrake_load_proxy_kpa ?? null,
      max_intact_airbrake_load_proxy_kpa: summary?.max_intact_airbrake_load_proxy_kpa ?? null,
      max_intact_heat_exposure: summary?.max_intact_convective_heating_exposure_proxy ?? null,
      max_intact_airbrake_heat_exposure: summary?.max_intact_airbrake_heating_exposure_proxy ?? null,
      initial_parts: finite(initialParts) ? initialParts : null,
      final_parts: finalRow.vessel_part_count,
      initial_airbrakes: finite(initialAirbrakes) ? initialAirbrakes : null,
      final_airbrakes: finalRow.airbrake_part_count,
      first_loss_altitude_km: lossRow ? Math.round(lossRow.altitude_asl_m / 10) / 100 : null,
      first_loss_q_kpa: finite(summary?.first_vessel_part_loss_dynamic_pressure_kpa)
        ? summary.first_vessel_part_loss_dynamic_pressure_kpa
        : lossRow && finite(lossRow.dynamic_pressure_kpa) ? Math.round(lossRow.dynamic_pressure_kpa * 100) / 100 : null,
      first_loss_q_fraction_of_peak: summary?.first_vessel_part_loss_dynamic_pressure_fraction_of_run_peak ?? null,
      first_loss_load_proxy_kpa: summary?.first_vessel_part_loss_airbrake_load_proxy_kpa ?? null,
      first_loss_heat_exposure: summary?.first_vessel_part_loss_convective_heating_exposure_proxy ?? null,
      first_loss_airbrake_heat_exposure: summary?.first_vessel_part_loss_airbrake_heating_exposure_proxy ?? null,
      full_integrity: !lossRow,
      landing_miss_km: finite(summary?.landing_miss_m) ? summary.landing_miss_m / 1000 : null,
      landing_along_miss_km: finite(summary?.landing_along_miss_m) ? summary.landing_along_miss_m / 1000 : null,
      landing_cross_miss_km: finite(summary?.landing_cross_miss_m) ? summary.landing_cross_miss_m / 1000 : null,
      points: downsampleByAltitude(entryRows),
    });
  }
  runs.sort((a, b) => a.profile_id.localeCompare(b.profile_id)
    || a.corridor_id.localeCompare(b.corridor_id)
    || (a.angle_deg ?? 999) - (b.angle_deg ?? 999));

  const measuredCda = [];
  const measuredTrajectoryResponse = [];
  const dragModel = predictor.extra_drag_model ?? null;
  for (const { set, corridorId, dashboardProfileId } of selectedProfileSets) {
    const activePredictor = selectedContexts.get(set.profile_key)?.predictor ?? predictor;
    const trajectoryModel = activePredictor.trajectories_along_rate_model ?? null;
    const comparisons = [set.fixed30_pair, set.fixed45_pair, set.fixed50_pair, set.fixed60_pair, set.fixed90_pair, ...(set.custom_fixed_pairs ?? [])].filter(Boolean);
    for (const comparison of comparisons) {
      const cleanRows = pairs.filter((row) => String(row.fixed_run_id) === String(comparison.fixed_run_id)
        && finite(row.fixed_airbrake_estimated_angle_deg)
        && Math.abs(row.fixed_airbrake_estimated_angle_deg - comparison.fixed_angle_deg) <= 0.5
        && row.fixed_airbrake_survival_fraction >= 0.999
        && row.dynamic_pressure_kpa >= 0.1
        && row.dynamic_pressure_kpa <= 3
        && (!finite(row.fixed_trajectories_planned_facing_error_deg) || row.fixed_trajectories_planned_facing_error_deg <= 2));
      const values = cleanRows.filter((row) => finite(row.extra_cd_area_per_airbrake_m2)).map((row) => {
        if (!dragModel || !finite(row.mach)) return row.extra_cd_area_per_airbrake_m2;
        const localCda = dragModel.cda_at_mach_center_m2 + dragModel.cda_mach_slope_m2_per_mach * (row.mach - dragModel.mach_center);
        return localCda > 0 ? row.extra_cd_area_per_airbrake_m2 / localCda * dragModel.cda_at_mach_center_m2 : row.extra_cd_area_per_airbrake_m2;
      });
      if (values.length) measuredCda.push({
        profile_id: dashboardProfileId,
        corridor_id: corridorId,
        angle_deg: comparison.fixed_angle_deg,
        median_cda_per_airbrake_m2: median(values),
      });
      const trajectoryValues = cleanRows.filter((row) => finite(row.impact_along_rate_delta_mps)).map((row) => {
        if (!trajectoryModel || !(row.dynamic_pressure_kpa > 0) || !(row.fixed_airbrake_part_count > 0) || !(row.mass_t > 0) || !finite(row.altitude_m)) return row.impact_along_rate_delta_mps;
        const observedStateFactor = row.dynamic_pressure_kpa * row.fixed_airbrake_part_count / row.mass_t
          * Math.exp(trajectoryModel.altitude_log_slope_per_km * (row.altitude_m / 1000 - trajectoryModel.altitude_center_km));
        const referenceStateFactor = 1 * 4 / 20;
        return observedStateFactor > 0 ? row.impact_along_rate_delta_mps * referenceStateFactor / observedStateFactor : row.impact_along_rate_delta_mps;
      });
      if (trajectoryValues.length) measuredTrajectoryResponse.push({
        profile_id: dashboardProfileId,
        corridor_id: corridorId,
        angle_deg: comparison.fixed_angle_deg,
        median_impact_along_rate_delta_mps: median(trajectoryValues),
      });
    }
  }

  let calibrationCorridor = null;
  try {
    calibrationCorridor = JSON.parse(predictor.calibration_profile?.profile_key ?? "{}").entry_corridor_id ?? null;
  } catch {
    calibrationCorridor = null;
  }
  const adjustedPredictorScenarios = [];
  for (const { set, corridorId, dashboardProfileId } of selectedProfileSets) {
    const referenceRun = runs.find((run) => set.run_ids.map(String).includes(String(run.run_id))
      && run.profile_id === dashboardProfileId
      && run.corridor_id === corridorId
      && run.mode === "off");
    if (!referenceRun) continue;
    const activePredictor = selectedContexts.get(set.profile_key)?.predictor ?? predictor;
    for (const startAltitudeKm of [60, 55, 50, 45, 40]) {
      const futureStates = statePathFromSamples(samples, referenceRun.run_id, startAltitudeKm, 20);
      if (futureStates.length < 2) continue;
      for (const angleDeg of [30, 45, 50, 60, 70, 90]) {
        const integration = integrateRemainingCorrection(activePredictor, futureStates, angleDeg, { domainPolicy: "clip" });
        if (!(integration.covered_duration_s > 0)) continue;
        adjustedPredictorScenarios.push({
          profile_id: referenceRun.profile_id,
          corridor_id: referenceRun.corridor_id,
          reference_run_id: referenceRun.run_id,
          start_altitude_km: startAltitudeKm,
          angle_deg: angleDeg,
          remaining_correction_km: integration.remaining_correction_m / 1000,
          coverage_fraction: integration.coverage_fraction,
          interpretation: integration.interpretation,
          model_source: activePredictor.active_profile_adaptation ? "corridor adaptation" : "multi-angle calibration",
          angle_anchors_deg: activePredictor.active_profile_adaptation?.angle_anchors_deg ?? null,
        });
      }
    }
  }
  const trajectoryResponseModels = [...selectedContexts.values()].map((context) => ({
    profile_id: context.profile_id,
    corridor_id: context.corridor_id,
    phase_target_deg: context.phase_target_deg,
    model: context.predictor.trajectories_along_rate_model ?? null,
    source: context.predictor.active_profile_adaptation ? "corridor adaptation" : "multi-angle calibration",
    angle_anchors_deg: context.predictor.active_profile_adaptation?.angle_anchors_deg ?? null,
    warning: context.predictor.active_profile_adaptation?.warning ?? null,
  })).filter((entry) => entry.model);
  return {
    generated_at: new Date().toISOString(),
    runs,
    measured_cda: measuredCda,
    measured_trajectory_response: measuredTrajectoryResponse,
    trajectory_response_models: trajectoryResponseModels,
    adjusted_predictor_scenarios: adjustedPredictorScenarios,
    corridor_validations: report.controllable_corridor_validation ?? [],
    closed_loop_validations: report.closed_loop_validation ?? [],
    predictor: {
      calibration_profile_id: predictor.calibration_profile?.profile_id ?? null,
      calibration_corridor_id: calibrationCorridor,
      extra_drag_model: predictor.extra_drag_model ?? null,
      trajectories_along_rate_model: predictor.trajectories_along_rate_model ?? null,
      profile_adaptations: predictor.profile_adaptations ?? [],
      domain: predictor.domain ?? null,
    },
    readiness: {
      differential_fit: Boolean(report.ready_for_differential_fit),
      angle_response: Boolean(report.ready_for_angle_response_fit),
      matched_validation: Boolean(report.ready_for_matched10_validation),
    },
  };
}

function generateDashboard(data) {
  const serialized = JSON.stringify(data).replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Airbrake reentry telemetry</title>
<style>
:root{color-scheme:light dark;--bg:#f7f8fa;--fg:#18202a;--muted:#637083;--line:#d3d9e1;--panel:#fff;--s1:#2166d1;--s2:#d45f00;--s3:#6b4cc2;--s4:#07856f;--s5:#b13a57;--s6:#646b75;--bad:#c52b3a;--good:#16815d} @media(prefers-color-scheme:dark){:root{--bg:#11151b;--fg:#e7ebf0;--muted:#a5afbc;--line:#303844;--panel:#171d25;--s1:#69a4ff;--s2:#ff9a4c;--s3:#b699ff;--s4:#4bd0b4;--s5:#ff8399;--s6:#b7c0cc;--bad:#ff6874;--good:#5ad3a5}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif}main{max-width:1280px;margin:auto;padding:20px}h1{font-size:24px;margin:0 0 14px}h2{font-size:16px;margin:26px 0 8px}.controls{display:flex;gap:14px;flex-wrap:wrap;align-items:end}.controls label{display:grid;gap:4px;color:var(--muted)}select{font:inherit;color:var(--fg);background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:7px 30px 7px 9px}.legend{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0;color:var(--muted)}.legend span{display:inline-flex;align-items:center;gap:5px}.swatch{width:18px;border-top:3px solid currentColor}.charts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}.chart{min-width:0;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px}.chart svg{display:block;width:100%;height:auto}.chart-summary{margin:2px 10px 8px;color:var(--muted);font-size:12px;line-height:1.45}.chart-summary strong{color:var(--fg);font-weight:500}.model-note{color:var(--muted);font-size:12px;padding:0 10px 8px}.corridor-gate{margin:14px 0;padding:12px 14px;border:1px solid var(--line);border-left:4px solid var(--muted);border-radius:7px;background:var(--panel)}.corridor-gate.good{border-left-color:var(--good)}.corridor-gate.bad{border-left-color:var(--bad)}.grid{stroke:var(--line);stroke-width:1}.axis-label,.tick{fill:var(--muted);font-size:11px}.chart-title{fill:var(--fg);font-size:13px;font-weight:600}.series{fill:none;stroke-width:2}.after-loss{opacity:.28}.point{fill:var(--panel);stroke-width:1.5}.failure{stroke:var(--bad);stroke-width:2}.model{stroke:var(--fg);stroke-dasharray:6 4;fill:none;stroke-width:2}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;background:var(--panel)}th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);white-space:nowrap}th{color:var(--muted);font-weight:600}.bad{color:var(--bad)}.empty{color:var(--muted);padding:24px;text-align:center}@media(max-width:760px){.charts{grid-template-columns:1fr}main{padding:14px}}
</style></head><body><main>
<h1>Airbrake reentry telemetry</h1>
<div class="controls"><label>Trajectories profile<select id="profile"></select></label><label>Entry corridor<select id="corridor"></select></label><label>Deorbit phase<select id="phase"></select></label></div>
<div id="corridor-gate" class="corridor-gate"></div>
<div id="legend" class="legend" aria-label="Run legend"></div>
<div id="charts" class="charts"></div>
<h2>Empirical airbrake response</h2><div class="charts"><div id="model-chart" class="chart"></div><div id="trajectory-model-chart" class="chart"></div></div><div id="adjusted-predictor-chart" class="chart" style="margin-top:18px"></div>
<h2>Survivability</h2><div id="survivability-chart" class="chart" style="margin-bottom:18px"></div><div class="table-wrap"><table><thead><tr><th>Angle</th><th>Run</th><th>70 km measured / predicted FPA</th><th>Actual landing along / cross</th><th>Intact peak / entry max Q</th><th>First loss</th><th>Heat exposure at loss</th><th>Final craft</th><th>Status</th></tr></thead><tbody id="outcomes"></tbody></table></div>
</main><script>
const DATA=${serialized};
const profile=document.getElementById('profile'),corridor=document.getElementById('corridor'),phase=document.getElementById('phase'),corridorGate=document.getElementById('corridor-gate'),charts=document.getElementById('charts'),legend=document.getElementById('legend'),outcomes=document.getElementById('outcomes');
const colors=['var(--s1)','var(--s2)','var(--s3)','var(--s4)','var(--s5)','var(--s6)','var(--fg)'];
const metrics=[
  ['airspeed_mps','Airspeed','m/s','Speed through entry. Lower at the same altitude usually means earlier or stronger braking, but the lowest value is not automatically best because excess braking increases undershoot.'],
  ['trajectories_undershoot_km','Trajectories predicted undershoot','pad ahead (km)','Where Trajectories predicts impact relative to the pad. Closer to 0 km is better; positive means the pad is still ahead, while negative means a predicted overshoot.'],
  ['flight_path_angle_down_deg','Descent flight-path angle','degrees down','Steepness of descent. Higher means steeper; shallower entries usually reduce peak loads but can extend heating and change downrange travel, so neither direction is universally better.'],
  ['dynamic_pressure_kpa','Dynamic pressure','kPa','Aerodynamic loading through entry. Lower peaks are generally safer for the structure, provided the vehicle still sheds enough speed to land safely.'],
  ['heating_exposure_proxy','Cumulative heating exposure','proxy units','Accumulated convective-heating proxy. Lower is generally safer, but this is comparative telemetry rather than measured part temperature or a proven failure threshold.'],
];
const modelHelp={
  drag:'Additional drag produced per intact airbrake as deployment angle increases. Higher means stronger braking, not automatically a better overall trajectory; points are measured and the dashed line is the fit.',
  trajectory:'How quickly airbraking moves the Trajectories landing prediction at the reference state. Higher means more landing-point control authority; points are measured and the dashed line is the fit.',
  adjusted:'Estimated remaining landing-point displacement caused by airbrakes from each altitude. Higher means a larger expected correction, not better accuracy; values are lower bounds because uncovered states are excluded.',
  survivability:'Compares Q while intact, Q at first loss, and eventual entry max Q. Lower loading is generally safer, but no universal failure threshold has emerged; full-integrity markers are the strongest evidence.',
};
function option(select,value,label=value){const item=document.createElement('option');item.value=value;item.textContent=label;select.appendChild(item)}
[...new Set(DATA.runs.map(r=>r.profile_id))].forEach(v=>option(profile,v));
function syncCorridors(){const previous=corridor.value;corridor.innerHTML='';const values=[...new Set(DATA.runs.filter(r=>r.profile_id===profile.value).map(r=>r.corridor_id))];values.forEach(v=>option(corridor,v));if(values.includes(previous))corridor.value=previous;syncPhases()}
function syncPhases(){const previous=phase.value;phase.innerHTML='';const values=[...new Set(DATA.runs.filter(r=>r.profile_id===profile.value&&r.corridor_id===corridor.value).map(r=>r.phase_key))];values.sort((a,b)=>(Number(b)||-Infinity)-(Number(a)||-Infinity));values.forEach(v=>option(phase,v,v==='unverified'?'unverified / legacy':v+'°'));if(values.includes(previous))phase.value=previous;render()}
function svgNode(name,attrs={},text=''){const n=document.createElementNS('http://www.w3.org/2000/svg',name);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,v));if(text)n.textContent=text;return n}
function appendChartSummary(host,text){if(!host.querySelector('svg'))return;const note=document.createElement('p');note.className='chart-summary';const label=document.createElement('strong');label.textContent='How to read: ';note.append(label,document.createTextNode(text));host.appendChild(note)}
function extent(values,floorZero=false,fallback=[0,1]){const clean=values.filter(Number.isFinite);if(!clean.length)return fallback;let lo=Math.min(...clean),hi=Math.max(...clean);if(lo===hi){lo-=1;hi+=1}const pad=(hi-lo)*.08;return [floorZero?Math.max(0,lo-pad):lo-pad,hi+pad]}
function renderChart(runs,key,title,unit){const box=document.createElement('div');box.className='chart';const svg=svgNode('svg',{viewBox:'0 0 560 285',role:'img','aria-label':title+' by altitude, descending from 70 to 20 kilometres'});box.appendChild(svg);const m={l:58,r:14,t:34,b:42},w=560-m.l-m.r,h=285-m.t-m.b;const values=runs.flatMap(r=>r.points.map(p=>p[key]));const [y0,y1]=extent(values,key!=='trajectories_undershoot_km');const sx=x=>m.l+(70-x)/50*w,sy=y=>m.t+(y1-y)/(y1-y0)*h;svg.appendChild(svgNode('text',{x:m.l,y:18,class:'chart-title'},title));for(let i=0;i<=4;i++){const y=y0+(y1-y0)*i/4,py=sy(y);svg.appendChild(svgNode('line',{x1:m.l,y1:py,x2:m.l+w,y2:py,class:'grid'}));svg.appendChild(svgNode('text',{x:m.l-7,y:py+4,'text-anchor':'end',class:'tick'},Math.abs(y)>=100?y.toFixed(0):y.toFixed(1)))}[70,60,50,40,30,20].forEach(x=>svg.appendChild(svgNode('text',{x:sx(x),y:m.t+h+18,'text-anchor':'middle',class:'tick'},x)));svg.appendChild(svgNode('text',{x:m.l+w/2,y:280,'text-anchor':'middle',class:'axis-label'},'entry progression — altitude (km)'));svg.appendChild(svgNode('text',{x:12,y:m.t+h/2,transform:'rotate(-90 12 '+(m.t+h/2)+')','text-anchor':'middle',class:'axis-label'},unit));runs.forEach((run,index)=>{const points=run.points.filter(p=>Number.isFinite(p[key]));for(let i=1;i<points.length;i++){const a=points[i-1],b=points[i],after=Number.isFinite(run.first_loss_altitude_km)&&a.altitude_km<run.first_loss_altitude_km;svg.appendChild(svgNode('line',{x1:sx(a.altitude_km),y1:sy(a[key]),x2:sx(b.altitude_km),y2:sy(b[key]),class:'series'+(after?' after-loss':''),stroke:colors[index%colors.length]}))}if(Number.isFinite(run.first_loss_altitude_km)&&run.first_loss_altitude_km>=20&&run.first_loss_altitude_km<=70){const nearest=points.reduce((best,p)=>!best||Math.abs(p.altitude_km-run.first_loss_altitude_km)<Math.abs(best.altitude_km-run.first_loss_altitude_km)?p:best,null);if(nearest){const x=sx(nearest.altitude_km),y=sy(nearest[key]);svg.appendChild(svgNode('line',{x1:x-5,y1:y-5,x2:x+5,y2:y+5,class:'failure'}));svg.appendChild(svgNode('line',{x1:x+5,y1:y-5,x2:x-5,y2:y+5,class:'failure'}))}}});return box}
function renderModel(runs){const host=document.getElementById('model-chart');host.innerHTML='';const points=DATA.measured_cda.filter(p=>p.profile_id===profile.value&&p.corridor_id===corridor.value);const model=DATA.predictor.extra_drag_model;const calibrated=DATA.predictor.calibration_profile_id===profile.value&&DATA.predictor.calibration_corridor_id===corridor.value;if(!points.length&&!calibrated){host.innerHTML='<div class="empty">No comparable off/fixed pair exists in this corridor yet.</div>';return}const svg=svgNode('svg',{viewBox:'0 0 760 300',role:'img','aria-label':'Measured and fitted extra drag area by airbrake angle'});host.appendChild(svg);const m={l:65,r:20,t:34,b:44},w=760-m.l-m.r,h=300-m.t-m.b;const ymax=Math.max(3.5,...points.map(p=>p.median_cda_per_airbrake_m2))*1.08,sx=x=>m.l+x/90*w,sy=y=>m.t+(ymax-y)/ymax*h;svg.appendChild(svgNode('text',{x:m.l,y:18,class:'chart-title'},'Extra drag area per intact airbrake at Mach 6.75'));[0,1,2,3].forEach(y=>{svg.appendChild(svgNode('line',{x1:m.l,y1:sy(y),x2:m.l+w,y2:sy(y),class:'grid'}));svg.appendChild(svgNode('text',{x:m.l-8,y:sy(y)+4,'text-anchor':'end',class:'tick'},y))});[0,30,45,60,90].forEach(x=>svg.appendChild(svgNode('text',{x:sx(x),y:m.t+h+18,'text-anchor':'middle',class:'tick'},x+'°')));svg.appendChild(svgNode('text',{x:16,y:m.t+h/2,transform:'rotate(-90 16 '+(m.t+h/2)+')','text-anchor':'middle',class:'axis-label'},'extra CdA / brake (m²)'));if(model){let d='';for(let a=0;a<=90;a+=2){const y=model.cda_at_mach_center_m2*Math.sin(a*Math.PI/180)**model.angle_sine_exponent;d+=(a?'L':'M')+sx(a).toFixed(1)+','+sy(y).toFixed(1)}svg.appendChild(svgNode('path',{d,class:'model'}));svg.appendChild(svgNode('text',{x:m.l+w,y:18,'text-anchor':'end',class:'axis-label'},calibrated?'multi-angle fit':'transferred drag model'))}points.forEach(p=>{const c=svgNode('circle',{cx:sx(p.angle_deg),cy:sy(p.median_cda_per_airbrake_m2),r:5,fill:'var(--panel)',stroke:'var(--s1)','stroke-width':2});c.appendChild(svgNode('title',{},p.angle_deg+'° normalized median: '+p.median_cda_per_airbrake_m2.toFixed(3)+' m²'));svg.appendChild(c)})}
function renderTrajectoryModel(){const host=document.getElementById('trajectory-model-chart');host.innerHTML='';const points=(DATA.measured_trajectory_response||[]).filter(p=>p.profile_id===profile.value&&p.corridor_id===corridor.value);const entry=(DATA.trajectory_response_models||[]).find(p=>p.profile_id===profile.value&&p.corridor_id===corridor.value);const model=entry?.model;if(!points.length&&!model){host.innerHTML='<div class="empty">No comparable Trajectories-response pair exists in this corridor yet.</div>';return}const reference=a=>model?model.scale*4/20*Math.sin(a*Math.PI/180)**model.angle_sine_exponent:0;const ymax=Math.max(100,...points.map(p=>p.median_impact_along_rate_delta_mps),reference(90))*1.08;const svg=svgNode('svg',{viewBox:'0 0 760 300',role:'img','aria-label':'Measured and fitted Trajectories prediction response by airbrake angle'});host.appendChild(svg);const m={l:70,r:20,t:34,b:44},w=760-m.l-m.r,h=300-m.t-m.b,sx=x=>m.l+x/90*w,sy=y=>m.t+(ymax-y)/ymax*h;svg.appendChild(svgNode('text',{x:m.l,y:18,class:'chart-title'},'Trajectories prediction response at reference state'));for(let i=0;i<=3;i++){const y=ymax*i/3;svg.appendChild(svgNode('line',{x1:m.l,y1:sy(y),x2:m.l+w,y2:sy(y),class:'grid'}));svg.appendChild(svgNode('text',{x:m.l-8,y:sy(y)+4,'text-anchor':'end',class:'tick'},y.toFixed(0)))}[0,30,45,60,90].forEach(x=>svg.appendChild(svgNode('text',{x:sx(x),y:m.t+h+18,'text-anchor':'middle',class:'tick'},x+'°')));svg.appendChild(svgNode('text',{x:16,y:m.t+h/2,transform:'rotate(-90 16 '+(m.t+h/2)+')','text-anchor':'middle',class:'axis-label'},'extra impact-motion rate (m/s)'));if(model){let d='';for(let a=0;a<=90;a+=2)d+=(a?'L':'M')+sx(a).toFixed(1)+','+sy(reference(a)).toFixed(1);svg.appendChild(svgNode('path',{d,class:'model'}));const anchors=entry.angle_anchors_deg?.length?' · '+entry.angle_anchors_deg.join('/')+'° anchor':'';svg.appendChild(svgNode('text',{x:m.l+w,y:18,'text-anchor':'end',class:'axis-label'},entry.source+anchors))}points.forEach(p=>{const c=svgNode('circle',{cx:sx(p.angle_deg),cy:sy(p.median_impact_along_rate_delta_mps),r:5,fill:'var(--panel)',stroke:'var(--s2)','stroke-width':2});c.appendChild(svgNode('title',{},p.angle_deg+'° median: '+p.median_impact_along_rate_delta_mps.toFixed(1)+' m/s'));svg.appendChild(c)});svg.appendChild(svgNode('text',{x:m.l+w,y:m.t+h+36,'text-anchor':'end',class:'axis-label'},'reference: 45 km, q 1 kPa, 20 t, 4 brakes'));const check=model?.cumulative_validation?.groups?.[0];if(check){const note=document.createElement('div');note.className='model-note';note.textContent='Integrated fit-domain check: model '+(check.predicted_change_m/1000).toFixed(1)+' km vs observed '+(check.observed_change_m/1000).toFixed(1)+' km ('+(check.fixed_angle_deg??'?')+'°, in-sample).';host.appendChild(note)}}
function renderAdjustedPredictor(){const host=document.getElementById('adjusted-predictor-chart');host.innerHTML='';const scenarios=(DATA.adjusted_predictor_scenarios||[]).filter(p=>p.profile_id===profile.value&&p.corridor_id===corridor.value);if(!scenarios.length){host.innerHTML='<div class="empty">No calibrated remaining-correction horizon exists for this profile and corridor yet.</div>';return}const angles=[...new Set(scenarios.map(p=>p.angle_deg))].sort((a,b)=>a-b),ymax=Math.max(...scenarios.map(p=>p.remaining_correction_km))*1.08;const svg=svgNode('svg',{viewBox:'0 0 1120 330',role:'img','aria-label':'Remaining future Trajectories correction lower bound by altitude and airbrake angle'});host.appendChild(svg);const m={l:72,r:22,t:40,b:48},w=1120-m.l-m.r,h=330-m.t-m.b,sx=x=>m.l+(60-x)/20*w,sy=y=>m.t+(ymax-y)/ymax*h;svg.appendChild(svgNode('text',{x:m.l,y:19,class:'chart-title'},'Remaining future Trajectories correction · calibrated-domain lower bound'));for(let i=0;i<=4;i++){const y=ymax*i/4;svg.appendChild(svgNode('line',{x1:m.l,y1:sy(y),x2:m.l+w,y2:sy(y),class:'grid'}));svg.appendChild(svgNode('text',{x:m.l-8,y:sy(y)+4,'text-anchor':'end',class:'tick'},y.toFixed(0)))}[60,55,50,45,40].forEach(x=>svg.appendChild(svgNode('text',{x:sx(x),y:m.t+h+18,'text-anchor':'middle',class:'tick'},x)));svg.appendChild(svgNode('text',{x:m.l+w/2,y:325,'text-anchor':'middle',class:'axis-label'},'current altitude (km; future path follows selected off run)'));svg.appendChild(svgNode('text',{x:16,y:m.t+h/2,transform:'rotate(-90 16 '+(m.t+h/2)+')','text-anchor':'middle',class:'axis-label'},'remaining correction (km)'));angles.forEach((angle,index)=>{const points=scenarios.filter(p=>p.angle_deg===angle).sort((a,b)=>b.start_altitude_km-a.start_altitude_km);let d='';points.forEach((p,i)=>{d+=(i?'L':'M')+sx(p.start_altitude_km).toFixed(1)+','+sy(p.remaining_correction_km).toFixed(1)});svg.appendChild(svgNode('path',{d,class:'series',stroke:colors[index%colors.length]}));points.forEach(p=>{const c=svgNode('circle',{cx:sx(p.start_altitude_km),cy:sy(p.remaining_correction_km),r:3.5,class:'point',stroke:colors[index%colors.length]});c.appendChild(svgNode('title',{},angle+'° from '+p.start_altitude_km+' km: +'+p.remaining_correction_km.toFixed(1)+' km; '+(p.coverage_fraction*100).toFixed(0)+'% duration covered'));svg.appendChild(c)});svg.appendChild(svgNode('text',{x:sx(points[0].start_altitude_km)+7,y:sy(points[0].remaining_correction_km)-5,class:'axis-label'},angle+'°'))});const sixty=scenarios.find(p=>p.angle_deg===60&&p.start_altitude_km===60);if(sixty)svg.appendChild(svgNode('text',{x:m.l+w,y:32,'text-anchor':'end',class:'axis-label'},'60° from 60 km covers '+(sixty.coverage_fraction*100).toFixed(1)+'% of reference duration'))}
function renderSurvivabilityChart(runs){
  const host=document.getElementById('survivability-chart');host.innerHTML='';
  const usable=runs.filter(r=>Number.isFinite(r.angle_deg)&&Number.isFinite(r.max_dynamic_pressure_kpa));
  if(!usable.length){host.innerHTML='<div class="empty">No peak-Q survivability data exists for this corridor.</div>';return}
  const ymax=Math.max(...usable.flatMap(r=>[r.max_dynamic_pressure_kpa,r.max_intact_dynamic_pressure_kpa,r.first_loss_q_kpa].filter(Number.isFinite)))*1.14;
  const svg=svgNode('svg',{viewBox:'0 0 1120 330',role:'img','aria-label':'Peak dynamic pressure while intact, eventual entry peak, and dynamic pressure at first part loss by airbrake angle'});host.appendChild(svg);
  const m={l:72,r:24,t:42,b:50},w=1120-m.l-m.r,h=330-m.t-m.b,sx=x=>m.l+x/90*w,sy=y=>m.t+(ymax-y)/ymax*h;
  svg.appendChild(svgNode('text',{x:m.l,y:20,class:'chart-title'},'Peak Q while intact, eventual entry peak, and Q at first loss'));
  svg.appendChild(svgNode('text',{x:m.l+w,y:20,'text-anchor':'end',class:'axis-label'},'● full-integrity peak   □ failed-run intact peak   ○ eventual entry peak   × first loss'));
  for(let i=0;i<=4;i++){const y=ymax*i/4;svg.appendChild(svgNode('line',{x1:m.l,y1:sy(y),x2:m.l+w,y2:sy(y),class:'grid'}));svg.appendChild(svgNode('text',{x:m.l-8,y:sy(y)+4,'text-anchor':'end',class:'tick'},y.toFixed(0)))}
  [0,15,30,45,60,75,90].forEach(x=>svg.appendChild(svgNode('text',{x:sx(x),y:m.t+h+20,'text-anchor':'middle',class:'tick'},x+'°')));
  svg.appendChild(svgNode('text',{x:m.l+w/2,y:324,'text-anchor':'middle',class:'axis-label'},'fixed airbrake angle'));
  svg.appendChild(svgNode('text',{x:16,y:m.t+h/2,transform:'rotate(-90 16 '+(m.t+h/2)+')','text-anchor':'middle',class:'axis-label'},'dynamic pressure (kPa)'));
  usable.forEach(run=>{
    const x=sx(run.angle_deg),peakY=sy(run.max_dynamic_pressure_kpa);
    if(Number.isFinite(run.first_loss_q_kpa)){
      const lossY=sy(run.first_loss_q_kpa),intactY=Number.isFinite(run.max_intact_dynamic_pressure_kpa)?sy(run.max_intact_dynamic_pressure_kpa):lossY;
      svg.appendChild(svgNode('line',{x1:x,y1:peakY,x2:x,y2:Math.min(lossY,intactY),stroke:'var(--muted)','stroke-dasharray':'4 3'}));
      const eventual=svgNode('circle',{cx:x,cy:peakY,r:6,fill:'var(--panel)',stroke:'var(--bad)','stroke-width':2});eventual.appendChild(svgNode('title',{},run.angle_deg+'° · eventual entry peak '+run.max_dynamic_pressure_kpa.toFixed(2)+' kPa after a failure'));svg.appendChild(eventual);
      const intact=svgNode('rect',{x:x-5,y:intactY-5,width:10,height:10,fill:'var(--panel)',stroke:'var(--good)','stroke-width':2});intact.appendChild(svgNode('title',{},run.angle_deg+'° · peak while intact '+run.max_intact_dynamic_pressure_kpa.toFixed(2)+' kPa'));svg.appendChild(intact);
      const loss1=svgNode('line',{x1:x-6,y1:lossY-6,x2:x+6,y2:lossY+6,class:'failure'});loss1.appendChild(svgNode('title',{},run.angle_deg+'° · first loss '+run.first_loss_q_kpa.toFixed(2)+' kPa'));svg.appendChild(loss1);
      svg.appendChild(svgNode('line',{x1:x+6,y1:lossY-6,x2:x-6,y2:lossY+6,class:'failure'}));
    }else{
      const safe=svgNode('circle',{cx:x,cy:peakY,r:7,fill:'var(--good)',stroke:'var(--good)','stroke-width':2});safe.appendChild(svgNode('title',{},run.angle_deg+'° · full integrity through '+run.max_dynamic_pressure_kpa.toFixed(2)+' kPa'));svg.appendChild(safe);
    }
  });
}
function render(){const runs=DATA.runs.filter(r=>r.profile_id===profile.value&&r.corridor_id===corridor.value);legend.innerHTML='';runs.forEach((run,index)=>{const item=document.createElement('span');item.style.color=colors[index%colors.length];item.innerHTML='<i class="swatch"></i>'+(run.angle_deg===null?run.mode:run.angle_deg+'°')+' · '+run.run_id;legend.appendChild(item)});charts.innerHTML='';if(!runs.length){charts.innerHTML='<div class="empty">No runs in this profile and corridor.</div>'}else metrics.forEach(([key,title,unit,summary])=>{const chart=renderChart(runs,key,title,unit);appendChartSummary(chart,summary);charts.appendChild(chart)});renderModel(runs);appendChartSummary(document.getElementById('model-chart'),modelHelp.drag);renderTrajectoryModel();appendChartSummary(document.getElementById('trajectory-model-chart'),modelHelp.trajectory);renderAdjustedPredictor();appendChartSummary(document.getElementById('adjusted-predictor-chart'),modelHelp.adjusted);renderSurvivabilityChart(runs);appendChartSummary(document.getElementById('survivability-chart'),modelHelp.survivability);outcomes.innerHTML='';runs.forEach(run=>{const tr=document.createElement('tr');const fpa=(Number.isFinite(run.measured_entry_fpa_down_deg)?run.measured_entry_fpa_down_deg.toFixed(2)+'°':'n/a')+' / '+(Number.isFinite(run.predicted_entry_fpa_down_deg)?run.predicted_entry_fpa_down_deg.toFixed(2)+'°':'n/a');const loss=run.full_integrity?'none':run.first_loss_altitude_km.toFixed(2)+' km · '+run.first_loss_q_kpa.toFixed(2)+' kPa'+(Number.isFinite(run.first_loss_q_fraction_of_peak)?' · '+(run.first_loss_q_fraction_of_peak*100).toFixed(0)+'% entry max':'');const heat=run.full_integrity?'n/a':(Number.isFinite(run.first_loss_heat_exposure)?run.first_loss_heat_exposure.toFixed(1):'n/a')+' craft · '+(Number.isFinite(run.first_loss_airbrake_heat_exposure)?run.first_loss_airbrake_heat_exposure.toFixed(1):'n/a')+' brake';const q=(Number.isFinite(run.max_intact_dynamic_pressure_kpa)?run.max_intact_dynamic_pressure_kpa.toFixed(2):'n/a')+' / '+run.max_dynamic_pressure_kpa.toFixed(2)+' kPa';tr.innerHTML='<td>'+(run.angle_deg===null?run.mode:run.angle_deg+'°')+'</td><td>'+run.run_id+'</td><td>'+fpa+'</td><td>'+q+'</td><td class="'+(run.full_integrity?'':'bad')+'">'+loss+'</td><td>'+heat+'</td><td>'+((run.final_parts??'n/a')+'/'+(run.initial_parts??'n/a'))+' parts · '+((run.final_airbrakes??'n/a')+'/'+(run.initial_airbrakes??'n/a'))+' brakes</td><td>'+run.status+'</td>';outcomes.appendChild(tr)})}
const renderUnfiltered=render;
function signedAlong(value){if(!Number.isFinite(value))return 'n/a';return Math.abs(value).toFixed(2)+' km '+(value>0?'short':value<0?'long':'on target')}
function renderCorridorGate(){const validation=(DATA.corridor_validations||[]).find(v=>v.profile_id===profile.value&&v.entry_corridor_id===corridor.value&&String(v.target_deorbit_phase_angle_deg??'unverified')===phase.value);corridorGate.className='corridor-gate';if(!validation){corridorGate.textContent='Control corridor: awaiting complete fixed-60 and fixed-90 landing telemetry for this phase.';return}if(!validation.endpoints_ready){corridorGate.textContent='Control corridor: both fixed endpoints must land with full integrity before closed-loop testing.';return}corridorGate.classList.add(validation.closed_loop_test_ready?'good':'bad');corridorGate.textContent=(validation.closed_loop_test_ready?'READY for closed-loop test':'NOT READY for closed-loop test')+' — 60° '+signedAlong(validation.fixed60.landing_along_miss_m/1000)+', 90° '+signedAlong(validation.fixed90.landing_along_miss_m/1000)+', usable authority '+(validation.authority_span_m/1000).toFixed(2)+' km, midpoint '+signedAlong(validation.authority_midpoint_m/1000)+'.'}
function appendClosedLoopStatus(){const attempts=(DATA.closed_loop_validations||[]).filter(v=>v.profile_id===profile.value&&v.entry_corridor_id===corridor.value&&String(v.target_deorbit_phase_angle_deg??'unverified')===phase.value);if(!attempts.length)return;const latest=attempts.at(-1);corridorGate.textContent+=' Latest PID run '+latest.run_id+': '+(latest.passed?'PASS':'WAIT/FAIL')+', '+Math.round((latest.command_interior_fraction??0)*100)+'% interior command, handoff '+(Number.isFinite(latest.predicted_handoff_miss_m)?(latest.predicted_handoff_miss_m/1000).toFixed(2)+' km':'n/a')+', landing '+(Number.isFinite(latest.landing_miss_m)?(latest.landing_miss_m/1000).toFixed(2)+' km':'n/a')+'.';corridorGate.classList.add(latest.passed?'good':'bad')}
function renderPhaseAware(){const allRuns=DATA.runs;const selected=allRuns.filter(r=>r.profile_id===profile.value&&r.corridor_id===corridor.value&&r.phase_key===phase.value);DATA.runs=selected;renderUnfiltered();DATA.runs=allRuns;renderCorridorGate();appendClosedLoopStatus();const rows=[...outcomes.querySelectorAll('tr')];selected.forEach((run,index)=>{const cell=rows[index]?.insertCell(3);if(!cell)return;cell.textContent=Number.isFinite(run.landing_along_miss_km)?signedAlong(run.landing_along_miss_km)+' / '+(Number.isFinite(run.landing_cross_miss_km)?(run.landing_cross_miss_km>=0?'+':'')+run.landing_cross_miss_km.toFixed(2)+' km cross':'n/a'):'n/a'})}
render=renderPhaseAware;
profile.addEventListener('change',syncCorridors);corridor.addEventListener('change',syncPhases);phase.addEventListener('change',renderPhaseAware);if(profile.options.length){profile.value=[...profile.options].some(o=>o.value==='matched10')?'matched10':profile.options[0].value;syncCorridors()}
</script></body></html>`;
}

function parseArgs(argv) {
  const options = {
    samples: "telemetry/reentry_samples.csv",
    pairs: "telemetry/airbrake_pairs.csv",
    report: "telemetry/report.json",
    predictor: "telemetry/airbrake_predictor.json",
    out: "telemetry/airbrake-dashboard.html",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key === "--samples") options.samples = argv[++index];
    else if (key === "--pairs") options.pairs = argv[++index];
    else if (key === "--report") options.report = argv[++index];
    else if (key === "--predictor") options.predictor = argv[++index];
    else if (key === "--out") options.out = argv[++index];
    else throw new Error(`Unknown option: ${key}`);
  }
  return options;
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const samples = parseCsv(fs.readFileSync(options.samples, "utf8"));
  const pairs = parseCsv(fs.readFileSync(options.pairs, "utf8"));
  const report = JSON.parse(fs.readFileSync(options.report, "utf8"));
  const predictor = JSON.parse(fs.readFileSync(options.predictor, "utf8"));
  const data = buildDashboardData(samples, pairs, report, predictor);
  const output = path.resolve(options.out);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, generateDashboard(data), "utf8");
  console.log(`Dashboard: ${output}`);
  console.log(`Runs: ${data.runs.length} | measured CdA points: ${data.measured_cda.length} | Trajectories-response points: ${data.measured_trajectory_response.length} | adjusted scenarios: ${data.adjusted_predictor_scenarios.length}`);
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

module.exports = { buildDashboardData, generateDashboard, main, parseCsv };
