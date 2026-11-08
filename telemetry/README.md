# Airbrake reentry telemetry

This directory contains derived data and fitted models for measuring how the
Boomerang vessel's airbrakes alter the real reentry trajectory while the
Trajectories mod continues to predict a trajectory that does not include
deployed-airbrake drag.

## Source data

The source-of-truth telemetry is written by kOS beside this repository in
`Ships/Script/` as segmented files named:

```text
reentry_telemetry_<run_id>_<mode>_<profile>_<corridor>_part_<n>.json
```

The JSON files use kOS's typed `WRITEJSON` serialization. Do not treat a single
segment as a complete run: the analyzer joins all segments with the same run ID,
checks continuity, and merges the reentry and landing phases.

## Matched-AoA experiment protocol

The current comparable series uses:

- The same Simulation-mode 100 km Kerbin parking orbit and vessel.
- Actual belly-first `+10 deg` entry AoA.
- Trajectories' sign-converted `-10/-10/-10/-10 deg` descent profile, recorded
  as profile `matched10`.
- Cross-track roll correction disabled, because Trajectories has no equivalent
  bank schedule.
- Every tagged airbrake's control-surface authority limiter locked to `0%`, so
  steering cannot silently alter its commanded deployment angle.
- Whole-vessel and tagged-airbrake part counts recorded through splashdown,
  landing, or abort.

The fitter uses only intact, pre-failure state matches. It also excludes rows
whose airbrake angle or authority readback is contaminated, powered-entry rows,
and rows where the craft is more than 2 degrees away from Trajectories'
`PLANNEDVEC` inside the fitting domain.

## Current run registry

The original `trajectories_miss` corridor entered at about 3.49 degrees down at
70 km. It supplies the multi-angle fit, but it was too steep for a fair
survivability comparison:

| Run ID | Mode | Result | Use |
| --- | --- | --- | --- |
| `1785011593` | off | Entry baseline; tagged airbrakes intact | Matched baseline. Whole-vessel counting was added after this run, so total survival is visual-only. |
| `1785012757` | fixed 30 deg | Abort; minimum 16/35 vessel parts and 1/4 airbrakes | Intact pre-failure rows only. |
| `1785013509` | fixed 45 deg | Splashed; 34/35 parts and 3/4 airbrakes | Intact pre-failure rows only. |
| `1785014313` | fixed 50 deg | Splashed; 34/35 parts and 3/4 airbrakes | Intact pre-failure rows only. |
| `1785016154` | fixed 60 deg | Splashed; 34/35 parts and 3/4 airbrakes | Valid replacement run; intact pre-failure rows only. |
| `1785016786` | custom fixed 70 deg | Splashed; 33/35 parts and 2/4 airbrakes | Intact pre-failure rows only. |
| `1785359750` | fixed 90 deg | Splashed; 34/35 parts and 3/4 airbrakes | Valid high-angle endpoint; intact pre-failure rows only. |

The corrected `entry_fpa29` corridor targets 2.9 degrees down at 70 km:

| Run ID | Mode | Result | Use |
| --- | --- | --- | --- |
| `1793291305` | fixed 60 deg | Landed; 35/35 parts and 4/4 airbrakes | Clean deployed-brake anchor and first fully survivable run. |
| `1793292291` | off | Splashed; first loss after reentry handover at 19.0 km; 34/35 parts and 4/4 airbrakes | Same-corridor baseline for drag and Trajectories-response differencing. |
| `1793295120` | fixed 45 deg | Landed; first loss at 22.78 km; 34/35 parts and 3/4 airbrakes | Preregistered holdout against the frozen fixed-60 model, then second corrected-corridor response anchor. |
| `1793297199` | fixed 90 deg | Landed; 35/35 parts and 4/4 airbrakes | Clean full-deployment endpoint; no telemetry-recorded loss during entry, handoff, descent, or landing. |
| `1793299301` | fixed 52.5 deg | Landed; first loss at 28.18 km; 33/35 parts and 2/4 airbrakes | Failed midpoint boundary test; clean pre-failure rows remain valid for response fitting. |

The off/fixed-60 pair has 143 state matches and nearly identical initial conditions
(about 0.4 m/s airspeed and 134 m position difference). They are therefore the
best current evidence for separating the airbrake effect from the corridor
change.

The off/fixed-45 holdout has 152 state matches. Its frozen-model evaluation is
preserved in `entry_fpa29_fixed45_holdout.json`; the exact frozen predictor is
`entry_fpa29_fixed45_frozen_predictor.json`.

Known invalid runs are retained in the raw archive for diagnosis but must not be
used for calibration:

- `1785014951`: 60-degree run with a buggy, anomalously shallow deorbit.
- `1785015517`: aborted replacement with no entry samples.

The visually observed 0-degree/no-airbrake run was not survivable, but its
whole-vessel losses predate the part-count instrumentation.

## Regenerating the dataset

Run these commands from the repository root after KSP has checkpointed or
completed the desired simulations:

```powershell
npm.cmd run telemetry:analyze -- --out telemetry/reentry_samples.csv --matched-out telemetry/airbrake_pairs.csv --summary-out telemetry/report.json
npm.cmd run telemetry:fit -- --out telemetry/airbrake_predictor.json
npm.cmd run test:telemetry
```

Add `--strict` to `telemetry:analyze` when the command should fail until every
first-fit readiness gate is satisfied.

## Current calibrated model

The completed 30-90 degree matched dataset produces:

- Extra-drag fit: `sin(angle)^2.165`, R-squared `0.941`, RMSE
  `0.039 m/s^2`.
- Extra drag area per intact brake at Mach 6.75:
  `3.148 + 1.079 * (Mach - 6.75) m^2`, multiplied by the angle response.
- Trajectories along-track response fit: `sin(angle)^2.000`, R-squared `0.886`,
  RMSE `86.9 m/s`.
- Calibrated atmosphere envelope: `38.6-59.2 km`, `0.10-2.89 kPa`, and Mach
  `6.54-7.31`.
- Calibrated hardware state: four intact airbrakes on this vessel.

The 90-degree endpoint is now measured, but the Trajectories-response exponent
still reached its configured search ceiling. The coefficients are appropriate
for interpolation over the recorded 30-90 degree, high-altitude, intact-hardware
domain; they are not evidence for extrapolation outside it or for post-failure
behavior. This calibration domain is broader than the operational controller
envelope: survivability testing established **60-90 degrees** as the safe PID
range, while lower fixed angles remain historical or deliberately selected tests.

The physical drag model transfers well to the corrected corridor: on the clean
fixed-60 overlap it has R-squared `0.967`, RMSE `0.029 m/s^2`, and predicts a
median `96.7%` of the observed extra deceleration. The Trajectories landing-point
response does **not** transfer unchanged: the old response model has R-squared
`0.158` and predicts only a median `56.1%` of the observed response.

For `matched10/entry_fpa29`, the predictor therefore keeps the transferred drag
law but uses a corridor-specific Trajectories-response fit:

- The angle exponent remains `sin(angle)^2.000`, inherited from the old
  multi-angle experiment. The preregistered fixed-45 holdout supported this
  inherited response before the corrected-corridor refit.
- Corrected-corridor anchors: fixed 45, 52.5, 60, and 90 degrees.
- Response scale: `8884.34` at the reference state.
- Altitude log slope: `-0.028 / km`.
- Combined fit: R-squared `0.913`, RMSE `125.4 m/s`.
- Response-fit envelope: `43.4-55.7 km`, Mach `6.62-7.21`, and
  `0.20-1.41 kPa`. The independently transferred physical-drag check extends
  to `59.2 km` and `0.10 kPa`.
- Combined in-sample median integrated-response ratio: `0.943`. Over each
  run's clean fit interval, the refit predicts/observes `79.77/85.75 km` at
  45 degrees, `80.81/89.97 km` at 52.5 degrees, `87.82/91.92 km` at 60
  degrees, and `108.90/95.25 km` at 90 degrees.

The frozen fixed-45 holdout verdict was deliberately recorded before this
refit. Qualification passed. The Trajectories overlay passed all criteria:
median predicted/observed response `0.908`, normalized RMSE `0.175`, and
integrated observed/model response `63.67/60.53 km` against a preregistered
`61.41 +/- 10 km` expectation. The physical drag model passed its median-bias
criterion (`0.883`) but narrowly missed its normalized-RMSE cutoff
(`0.258` observed versus `0.250` required), so the overall frozen predictor
verdict remains `FAIL`, not retrospectively changed to a pass.

This is a real corridor adaptation, not a complete end-to-end landing predictor.
The dashboard and CLI clip integration outside that envelope and label the
result a calibrated-domain lower bound.

## Survivability and corridor finding

The analyzer treats part loss as an experimental outcome rather than marking
the entire run as missing. Predictor fitting still uses only clean, intact
pre-failure state matches. In the original 3.49-degree matched-AoA corridor
every fixed deployed angle lost at least one vessel part:

| Angle | First loss | Q at loss | Eventual max Q | Heating-dose proxy at loss | Final minimum |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 30 deg | 31.84 km | 8.92 kPa | 67.84 kPa | 61.8 | 16/35 parts, 1/4 brakes |
| 45 deg | 25.57 km | 21.77 kPa | 44.68 kPa | 74.7 | 34/35 parts, 3/4 brakes |
| 50 deg | 27.35 km | 16.41 kPa | 41.43 kPa | 66.3 | 34/35 parts, 3/4 brakes |
| 60 deg | 25.62 km | 20.31 kPa | 39.20 kPa | 69.4 | 34/35 parts, 3/4 brakes |
| 70 deg | 32.01 km | 7.71 kPa | 45.49 kPa | 49.0 | 33/35 parts, 2/4 brakes |
| 90 deg | 31.24 km | 8.60 kPa | 39.08 kPa | 51.1 | 34/35 parts, 3/4 brakes |

Neither instantaneous Q at failure nor eventual max Q defines a common failure
threshold. The cumulative heating-dose proxy, the time integral of
`sqrt(density) * airspeed^3`, groups the observed first losses more tightly, but
it is an empirical warning signal rather than a measured part temperature or a
proven safe limit. A conservative value around 40-45 proxy units is suitable
for warning/telemetry during the next corridor experiment, not yet for claiming
survivability.

The corrected 2.9-degree runs at 60 and 90 degrees retained the complete craft.
Peak dynamic pressure fell from `39.20 kPa` in the old fixed-60 run to
`35.28 kPa` at corrected-corridor 60 degrees, then to `32.73 kPa` at 90
degrees. The 90-degree run also had lower total craft heating exposure than the
60-degree run (`90.25` versus `94.71` proxy units), despite the higher
angle-weighted airbrake exposure (`90.24` versus `69.36`). The corrected
brakes-off run still lost one part after handover and had a much larger
landing-point error. The evidence therefore supports a combined
corridor-and-airbrake problem: the old corridor was too steep, while the
shallower corridor still needs sufficient airbraking.

The corrected fixed-45 run reached `42.13 kPa` peak dynamic pressure and lost
one airbrake/part at `22.78 km`, `29.94 kPa`, with craft/brake cumulative heat
exposure proxies `98.2/46.4`. It brackets the demonstrated minimum survivable
fixed angle above 45 and at or below 60 degrees; the 90-degree result confirms
that the top of the commanded range is also survivable. The 52.5-degree
midpoint failed earlier at `28.18 km`, `13.78 kPa`, Mach `5.96`, and
`1840.5 m/s`, losing two airbrakes/parts in the same telemetry interval. Its
craft/brake cumulative exposure at loss was `77.2/46.7`. Instantaneous Q at
failure remains a poor universal threshold (`7.71-29.94 kPa` across fixed-angle
failures). In the corrected corridor, eventual max Q declines from `42.13 kPa`
at failed 45 degrees to `35.28 kPa` at surviving 60 degrees and `32.73 kPa` at
surviving 90 degrees. Across all corridors, however, failed runs often reach
their maxima only after losing hardware. Peak Q while the craft was still intact
also does **not** define a universal threshold: the survivors remained intact
through `32.73-35.28 kPa`, while failed runs lost hardware after intact peaks of
only `7.27-27.87 kPa`. Eventual max Q is therefore a useful
trajectory-severity descriptor, not evidence for a causal or reactive failure
threshold. The chart shows intact peak, first-loss Q, and eventual entry peak
separately.

The fixed-90 run landed about `62.0 km` short of the pad, versus about `47.7 km`
short at fixed 60. These are unguided, terrain-dependent landings, so touchdown
damage is classified separately from aerodynamic survivability. The increasing
undershoot nevertheless confirms that greater deployment provides useful
downrange control authority. Trajectories showed only about `20.9 km` remaining
along-track miss near 20 km altitude for the 90-degree run, leaving a large
unmodelled landing displacement for the adjusted predictor to address.

At the 52.5-degree failure altitude, the intact 60-degree run was only about
`17 m/s` slower and carried nearly the same Q (`13.29` versus `13.78 kPa`), but
had slightly lower whole-craft heat exposure (`74.4` versus `77.2`). The
52.5-degree outcome therefore narrows the usable-angle boundary but does not
establish a universal Q or heating threshold. Its eventual landing about
`16.0 km` short is not a clean fixed-angle endpoint because half the airbrakes
were already gone; only intact pre-failure rows are used by the predictor.

Menu option `2` runs the corrected corridor with a prompted airbrake angle;
entering `0` launches true brakes-off mode. Options `6` and `7` are the
175-degree-phase fixed-60 and fixed-90 corridor-validation endpoints. Option `8`
is the dedicated fixed-52.5 minimum-survivability boundary test. Option `9` is
the closed-loop 60-90 degree controller and should run only after the two safe
fixed endpoints bracket the target. The telemetry records
`entry_corridor_id = entry_fpa29`, the requested flight-path angle, and the
future surface-frame prediction achieved when the burn stops, so the analyzer
cannot accidentally pair these runs with the older 3.49-degree corridor. The
historical proxy and old-corridor combinations are deliberately not exposed in
the normal boot menu.

With 45, 52.5, 60, and 90 degrees now measured, the demonstrated minimum
survivability boundary is bracketed between failed 52.5 and surviving 60
degrees. The next bisection point is 56.25 degrees; it should use the same
matched-AoA 2.9-degree corridor and the same full-integrity-through-landing
criterion.

## Repository artifact policy

Files prefixed with `live-` or `wrapup-` are disposable working snapshots. The
full sample CSV is also reproducible and should normally remain untracked.

The canonical set was regenerated after the corrected-corridor matched
90-degree run:

- `airbrake_predictor.json` - fitted coefficients and calibration envelope.
- `report.json` - run validation, readiness gates, and survivability summary.
- `airbrake-dashboard.html` - generated interactive comparison of flight traces,
  Trajectories mismatch, fitted drag response, and survivability by profile and
  entry corridor (ignored; regenerate with `npm.cmd run telemetry:visualize`).
- `airbrake_pairs.csv` - state-matched evidence used by the fitter.
- This README - protocol, accepted/excluded run IDs, and provenance.

`npm.cmd run telemetry:predict -- --run 1793292291 --angle 60` automatically
selects the `entry_fpa29` corridor adaptation and integrates the fitted
Trajectories impact-motion response over the selected off run's future state
path. It adds only the remaining future airbrake displacement to the current
Trajectories along-track miss, avoiding double-counting braking already encoded
in the current vessel state. Until intact telemetry covers the lower atmosphere,
the default clipped result is explicitly a lower bound rather than a complete
landing-point correction.

The large raw segmented JSON archive should remain in `Ships/Script/` or be
stored outside ordinary Git unless a dedicated large-file archive is adopted.
