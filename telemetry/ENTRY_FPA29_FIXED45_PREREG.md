# Preregistered evaluation: corrected-corridor fixed 45-degree run

Recorded before the run on **2026-10-29 at 17:22:45 Europe/Dublin**.

- Frozen predictor: `telemetry/airbrake_predictor.json`
- Predictor SHA-256: `9C80E67432BDDEC73C6A4772A836920F417005CB4974DEDD1FFA9B199C998393`
- Last telemetry present when recorded:
  `reentry_telemetry_1793292291_off_matched10_entry_fpa29_part_44.json`
- New experiment: menu `H`, entered angle `45`
- Baseline: corrected-corridor brakes-off run `1793292291`
- Existing anchor: corrected-corridor fixed-60 run `1793291305`

The frozen model must be evaluated against the new run before it is refitted
with any new fixed-45 data.

After the run, preserve that order with:

```powershell
npm.cmd run telemetry:analyze
npm.cmd run telemetry:evaluate:fixed45 -- --run NEW_RUN_ID --out telemetry/entry_fpa29_fixed45_holdout.json
npm.cmd run telemetry:fit
npm.cmd run telemetry:visualize
```

The holdout command refuses to run if the predictor's SHA-256 no longer matches
the frozen hash above. Its nonzero exit status means either qualification or a
preregistered predictor criterion failed; that result must still be retained
before any refit.

## Frozen predictions

The physical drag model uses `sin(angle)^2.165`. Relative to fixed 60 degrees,
fixed 45 degrees should produce **0.6447 times** the extra airbrake deceleration
at the same Mach, dynamic pressure, mass, and intact brake count.

The corrected-corridor Trajectories-response model currently inherits
`sin(angle)^2.000`. Relative to fixed 60 degrees, fixed 45 degrees should
therefore produce **0.6667 times** the landing-point response at a matched
state.

Within the existing response-fit envelope (`44.6-55.2 km`, Mach `6.67-7.19`,
and `0.21-1.18 kPa`), the fixed-60 model integrated to `92.11 km`. The frozen
fixed-45 prediction is therefore **61.41 km** of additional Trajectories
undershoot over the comparable envelope.

When integrated along the brakes-off reference path from 60 to 20 km with
out-of-domain segments clipped, the current CLI result is:

- Current Trajectories along-track miss at 60 km: `+14.71 km` (pad ahead).
- Predicted remaining fixed-45 airbrake correction: `+61.87 km`.
- Adjusted along-track miss: `+76.58 km`.
- Covered reference duration: `24.0%`.

The `+61.87 km` and `+76.58 km` values are calibrated-domain lower bounds, not
complete landing predictions.

## Run qualification

The run is a strict holdout only if all of the following are true:

1. It records profile `matched10`, corridor `entry_fpa29`, and fixed angle
   `45 +/- 0.5 deg` on every intact tagged airbrake.
2. Every tagged airbrake reports a `0%` authority limiter, with no angle
   reassertion or steering contamination.
3. The deorbit predictor reaches `2.9 +/- 0.1 deg` downward at the 70 km
   interface and does not hit a burn safety cap.
4. Initial comparison with run `1793292291` is within `5 m/s` airspeed and
   `2 km` surface position. Wider differences may still be exploratory but are
   not the primary holdout.
5. At least 40 clean, intact state matches remain inside the response-fit
   envelope, with actual attitude within 2 degrees of Trajectories' planned
   facing vector.

Part loss after the response-fit envelope does not invalidate clean pre-loss
predictor evidence. It does invalidate full-craft survivability.

## Frozen-model success criteria

Evaluate the frozen model before fitting the new run.

### Physical extra-drag model

Primary pass:

- Median predicted/observed extra-deceleration ratio is `0.85-1.15`.
- Normalized RMSE is no more than `0.25`.

R-squared is reported but is secondary for a single angle because it is highly
sensitive to the limited state range.

### Trajectories-response overlay

Primary pass:

- Median predicted/observed instantaneous response ratio is `0.80-1.20`.
- Normalized RMSE is no more than `0.30`.
- Integrated observed response is within `10 km` of the frozen `61.41 km`
  prediction. This corresponds to an expected acceptance interval of
  **51.41-71.41 km**.

These are holdout checks of the inherited angle response. A successful refit
afterward is not a substitute for passing them.

## Survivability interpretation

Survivability is a separate outcome from predictor accuracy:

- **35/35 parts and 4/4 airbrakes through termination:** fixed 45 degrees
  becomes the new lowest demonstrated survivable angle for this corridor.
- **Any loss after the clean model-fit interval:** predictor validation may
  still pass, but the safe fixed-angle boundary is bracketed above 45 and at or
  below 60 degrees.
- **Loss inside the model-fit interval:** survivability fails and the holdout is
  evaluated only if at least 40 uncontaminated pre-loss matches remain.

If the corridor hypothesis holds, fixed 45 should be materially safer than the
old 3.49-degree fixed-45 run. Full survival is plausible but deliberately not
assumed: the corrected brakes-off run still lost one part, so the evidence says
that both corridor and braking strength matter.

## Decision table

| Result | Conclusion | Next action |
| --- | --- | --- |
| Drag and response both pass; craft survives | The overlay generalizes to 45 degrees and 45 is inside the safe corridor | Keep the frozen angle law; next test a lower angle only if a wider control band is needed |
| Drag and response both pass; craft loses parts | Predictor is useful, but safe fixed angle is between 45 and 60 degrees | Test 50 or 55 degrees for survivability; keep pre-loss model evidence |
| Drag passes; response fails | Aerodynamic law transfers, but landing-point response has an unmodeled angle/corridor interaction | Do not claim a general adjusted predictor; fit a two-angle corridor response and gather another holdout |
| Drag fails | Current physical model is not transferable enough | Revisit model structure and gather at least one additional corrected-corridor angle |
| Qualification fails | The run is not a strict holdout | Diagnose and repeat 45 degrees before changing the model |
