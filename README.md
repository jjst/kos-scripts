# kos-scripts

A bunch of [kOS](https://ksp-kos.github.io/KOS/) scripts for [Kerbal Space Program](https://www.kerbalspaceprogram.com/).

## Contents

- `boot/boomerang.ks` - boot script that copies scripts to local volume and prompts which phase to start
- `launch.ks` - gravity-turn ascent to circular orbit
- `lib/launch.ks` - reusable gravity-turn ascent and circularisation for the Jeblink carrier
- `deorbit.ks` - Trajectories-guided deorbit burn and handoff to `reentry.ks`
- `reentry.ks` - atmospheric guidance; hands off to `land_guided.ks` when inside the descent envelope, otherwise `land_unguided.ks`
- `land_guided.ks` - PID-guided descent and landing burn
- `land_unguided.ks` - fallback airbrake descent and landing burn
- `hop.ks` - standalone VTVL vertical hop and landing
- `tests/` - in-game tests (see [In-game tests](#in-game-tests)) and their list in `tests/tests.json`
- `scripts/kos-drive.js` - in-game test runner and test-save maker, driven over kOS telnet

## Jeblink pad launch

Assign `boot/jeblink_carrier.ks` to the carrier CPU. Set up one Poodle as the
last ascent engine and a stock payload fairing with manual deploy available.
Disable staging for the fairing and all relay separators. In the pad tests, the
Poodle stage delta-v reading agreed with the vessel reading after staging was
disabled for the relay separators (see [issue #42](https://github.com/jjst/kos-scripts/issues/42)).
On the pad, enter the launch heading and target altitude, then press Enter to
arm launch. After circularisation, phasing starts after a 10-second countdown.
Press any key in the carrier terminal during the countdown to abort. Starting
the script in orbit still asks for Enter to begin phasing.

The first release and each release following a verified relay report start
their scheduled coast after a 10-second countdown. Press any key in the terminal
during the countdown or coast to cancel the release. Stay on the carrier at 1x
after separation until the relay reports. If it reports failure or no report
arrives within 90 in-game seconds, check the named relay manually, return to the
carrier, and press Enter to arm the next release.

## Installation

### Linux

```bash
./install.sh
```

Searches common Steam paths automatically. To specify a custom KSP directory:

```bash
./install.sh "/path/to/Kerbal Space Program"
```

### Windows

```bat
install.bat
```

Searches common Steam/Program Files paths automatically. To specify a custom KSP directory:

```bat
install.bat "C:\path\to\Kerbal Space Program"
```

Both scripts copy all `.ks` files to `Ships/Script/`, and `boot/`, `lib/` and `tests/` to the matching folders under it.

## In-game tests

A test is an existing procedure, such as `launch_to_orbit`, run from a fixed
save. Its own `check_line` / `warn_line` checks are the verdict:

- `[FAIL]` means a requirement wasn't met, and fails the test.
- `[!]` means a margin was missed, and only warns.

The runner works from the gaming PC while KSP is running. It:

1. copies the scripts into the game;
2. loads the test's save over kOS telnet;
3. runs the test;
4. reads the test's log from the archive and prints a summary.

```sh
npm run test:ingame -- smoke                    # quick check that the loop works
npm run test:ingame -- pad-launch               # launch_to_orbit from the pad save
npm run test:ingame -- --report-only <log-file> # summarise an existing log, no game needed
node scripts/kos-drive.js list                  # tests in tests/tests.json
```

The exit code is 0 when the test passes, 1 when it fails, and 2 when the runner
refused or couldn't run it. Each run keeps a copy of the log and a transcript of
the kOS screen in `test-runs/` (not committed). The screen transcript shows any
kOS error message.

### KSP setup (once)

- **Use a dedicated sandbox test game**, never a career save. Loading a test save
  replaces whatever you were flying (kOS writes `kos-backup-quicksave` first).
- **Turn on kOS telnet** with `SET CONFIG:TELNET TO TRUE.` in any kOS terminal.
  It's stored in kOS's own config file and listens on `127.0.0.1:5410`. It has no
  password, so keep it on loopback.
- **Turn on "Simulate in Background"** in KSP's main-menu settings. Otherwise KSP
  pauses when it loses focus, and the telnet server freezes with it.
- **The test vessel's kOS processor needs the name tag `test`**, or whatever its
  test entry names under `cpu`. Its tag must be unique among loaded vessels.
- **The test processor needs no boot file**, or one that exits at once. The
  runner types commands at the kOS prompt.
- **The test vessel needs a home connection**, so its log can be copied to the
  archive. It always has one on the pad.
- If `KSP_DIR` isn't set, the runner looks for KSP in the same places as
  `install.sh` / `install.bat`. Pass `--ksp-dir "<KSP folder>"` to override.

### Making a test save

1. **Set up the starting state** in the test game. For `pad`, put the test
   rocket on the pad. For a later test such as `rdv-parking`, fly there, for
   example by running `RUNPATH("0:/tests/pad_launch.ks", "pad-launch", "manual").`
   after `npm run test:ingame -- pad-launch` has written its options once.
2. **Settle at 1x, coasting,** and make sure no script is running on the test CPU.
3. **List the save first:** a test in `tests/tests.json` must name the save
   before `test:save` will accept it. Put that entry's craft-specific settings
   under `options`.
4. **Run `npm run test:save -- <save-name>`.** It asks you to confirm the CPU is
   idle (`--yes` skips the question). Then it checks the game state: saving
   allowed, 1x, the active vessel. It saves, and confirms the save exists. It
   refuses to replace an existing save unless you pass `--force`.
5. **Leave the save alone** unless the craft or scenario changes, then remake it
   deliberately with `--force`. Tests never create or change saves.

### Writing a test

- **Add a wrapper** under `tests/` that takes `PARAMETER test_id, run_token.`
- **Make it open a log, run the procedure, and finish with `end_test(run_token)`.**
  That copies the log to the archive and prints the `TEST-DONE` line the runner
  waits for.
- **Craft-specific settings go in the test's `options` in `tests/tests.json`.**
  The runner writes them to `0:/tests/options/<test-id>.json` for the wrapper to
  `READJSON`.
- **Write checks as usual:** `check_line` for requirements, with actual value,
  limit and units, and `warn_line` for margins.
- **The wrapper must not read terminal input.** The runner queues a probe line
  behind the test so it notices straight away if the script stops on a kOS error.

### Known limits

- **The runner reads kOS's screen through telnet.** Anything typed while a script
  is running reaches that script as key presses. So the runner first checks that
  the CPU answers at the prompt. `test:save` also asks you to confirm.
- **Some kOS and KSP behaviour hasn't been checked in-game yet:**
  - telnet surviving a save load;
  - the CPU reappearing in the telnet menu afterwards;
  - load times.

  The runner allows 3 minutes for a load and waits 5 s after the CPU reappears.

## Airbrake predictor telemetry

`reentry.ks` records versioned `reentry_telemetry_<run_id>_<mode>_<profile>_<corridor>_part_<n>.json` segments every two seconds and checkpoints them every 20 seconds. It keeps the existing human-readable `reentry.log` separately. When a home connection is available, completed JSON segments are copied to the archive volume and removed from the processor so long runs do not exhaust local storage.

See [`telemetry/README.md`](telemetry/README.md) for the experiment protocol, accepted and excluded run IDs, current calibration limits, artifact policy, and exact regeneration commands.

The default deorbit now uses the current matched-AoA, 2.9-degree entry corridor
with the known-survivable fixed-60 reference. Current-corridor runs can also be
started explicitly:

```ks
RUNPATH("1:/deorbit.ks"). // Current fixed-60 reference.
RUNPATH("1:/deorbit.ks", "off", "matched10", -1, "entry_fpa29").
RUNPATH("1:/deorbit.ks", "fixed90", "matched10", -1, "entry_fpa29").
RUNPATH("1:/deorbit.ks", "fixed90", "matched0", -1, "entry_fpa29", TRUE). // Isolated survival experiment.
```

In the Boomerang boot menu, option `2` is the normal deorbit entry point. It
prompts for any fixed angle from 0 through 90 degrees; exactly `0` selects true
brakes-off mode. Option `6` is the 175-degree-phase fixed-60 reference and option
`7` is the matching fixed-90 run. Option `8` is the isolated fixed-90,
zero-AoA reentry-survival experiment. It ignores geographic acceptance, keeps
the q-duty controller in charge through Mach 0.8 held continuously for five
seconds, records an independent entry PASS/FAIL from the initial vessel and
tagged-airbrake counts, and only then starts the unguided recovery descent.
Option `9` runs closed-loop airbrake guidance hard-clamped to the
validated 60-90 degree envelope; use it only after options 6 and 7 demonstrate
that the selected phase puts the target between the two fixed endpoints.
All use matched craft/Trajectories AoA and stop the deorbit burn at a predicted 2.9-degree
downward **surface-relative** flight-path angle at 70 km.
The old proxy-profile and old Trajectories-miss combinations remain available
through explicit `RUNPATH` parameters for historical reproduction, but are
intentionally absent from the normal menu.

`matched10` keeps the craft's operational, belly-first `+10` degree attitude and gives Trajectories the sign-converted `-10/-10/-10/-10` degree retrograde profile. `matched0` is the controlled surface-retrograde experiment: both the craft and Trajectories use zero AoA throughout entry. Trajectories defines the positive side oppositely, so the `matched10` conversion makes its `PLANNEDVEC` match the craft instead of flipping the craft onto its back. Cross-track roll correction is disabled for both matched profiles because Trajectories has no equivalent bank schedule. The historical `proxy` profile uses `+10/+10/+15/+15` in Trajectories' convention with operational cross-track correction enabled. Use the same 100 km simulation setup and craft for every run within a profile. During reentry, the script sets every tagged airbrake's control-surface authority limiter to `0` so attitude steering cannot add a hidden deflection to the commanded deployment angle; it records every limiter readback and restores the craft's original values at landing handoff. The analyzer includes the limiter command, entry-corridor ID, and thermal-safeguard policy in its profile key, never pairs runs from different corridors or safeguard strategies, and rejects matched-profile telemetry without proof that the limiters remained at zero. It also requires the measured facing to remain within 2 degrees of `PLANNEDVEC` through the low-dynamic-pressure fit domain.

Entry guidance includes an empirical **q-only duty-cycle** safeguard. Below
**10 kPa** dynamic pressure it leaves the requested fixed/PID deployment alone.
At or above 10 kPa it permits at most **10 continuous deployed seconds**, then
commands all airbrakes retracted for **1 second** before restarting the timer.
Leaving the high-q envelope resets the timer. The older angle-weighted
`sqrt(density) * airspeed^3` value remains in telemetry for analysis but no
longer controls the airbrakes: the accumulated units did not track the observed
heating closely enough to serve as a safety threshold. Q is also only an
empirical envelope selector, not a physical heat or part-temperature model.

The JSON includes vessel state, actual and commanded AoA, airbrake command, per-part deploy-angle field readback, surviving airbrake count, total vessel part count and actuator speed, PID state, dynamic and model static pressure, two density estimates, model Mach, optional pressure/temperature/acceleration/gravity sensor readings, thermal-safeguard state, and the Trajectories impact point and along/cross-track error. Sensors are not required: each optional read is presence-guarded and missing values are recorded as zero alongside run-level availability flags. A barometer validates static pressure, a thermometer captures ambient outside temperature (not part temperature), and an accelerometer adds an independent force measurement. The flight script verifies each airbrake field once per second, reasserts the command if another system changes it, and records every correction as an event. The analyzer reconstructs estimated physical angle from the command history and stock 20 deg/s actuator rate, and rejects instrumented runs with divergent readback or unexpected reassertions. Changes in tagged airbrake count or total vessel part count are recorded with altitude and dynamic pressure, so any structural loss is not misidentified as aerodynamic response and fixed-angle runs cannot pass the survivability gate after shedding hardware.

After collecting the desired baseline and fixed-angle runs, validate and merge the archive segments:

```powershell
npm.cmd run telemetry:analyze -- --out telemetry/reentry_samples.csv --matched-out telemetry/airbrake_pairs.csv --summary-out telemetry/report.json
npm.cmd run telemetry:fit -- --out telemetry/airbrake_predictor.json
npm.cmd run telemetry:visualize
```

With no input path, both tools read the adjacent KSP `Ships/Script` archive. The analyzer decodes kOS's typed `WRITEJSON` format, verifies segment continuity, sampling cadence, atmospheric/Trajectories coverage, mode compliance, unpowered entry, and matched initial conditions. The paired CSV contains nearest-state baseline/fixed-angle samples, estimated extra drag force and `CdA`, and the differential Trajectories along-track response. The report has separate readiness gates for the legacy endpoint fit, deployment-angle response, and matched-AoA validation. Add `--strict` to return a nonzero exit code until the endpoint dataset passes every first-fit gate.

The matched 30-90 degree series is complete. The analyzer reports measured
survivability separately from predictor-data readiness, so a breakup remains a
valid outcome while only intact pre-failure rows enter the fit. It also derives
an angle-adjusted dynamic-pressure load proxy and cumulative convective-heating
exposure for corridor and airbrake-safeguard analysis. See
[`telemetry/README.md`](telemetry/README.md) for the accepted run registry,
current coefficients, failure table, and next corridor experiment.

The broader 30-90 degree series remains useful for aerodynamic calibration, but
the demonstrated survivable closed-loop airbrake envelope is **60-90 degrees**.
PID guidance is hard-clamped to that range; lower fixed-angle modes are retained
only as explicitly selected experiments.

`npm.cmd run telemetry:refresh` runs the analyzer, refits the predictor, and
regenerates `telemetry/airbrake-dashboard.html` in one step. The dashboard keeps
Trajectories profiles and entry corridors separate, plots the flight traces and
prediction mismatch together, fades post-failure data, and shows model response
and survivability without editing hard-coded run IDs.

The adjusted-predictor core estimates the *remaining* future displacement of
Trajectories' impact prediction, because braking already flown is present in the
vessel state used by Trajectories. For example, use the selected off run as a
nominal future state path and evaluate fixed 60-degree braking with:

```powershell
npm.cmd run telemetry:predict -- --angle 60 --start-alt 60 --end-alt 20
```

By default it clips the integration to the fitted altitude/Mach/q/mass envelope
and labels the result a calibrated-domain lower bound. `--domain-policy strict`
rejects any uncovered segment; `extrapolate` must be requested explicitly.
After a survivable corrected-corridor run extends the intact fit envelope, this
same integration becomes the feed-forward correction layered over Trajectories.

The fitter uses only intact, positive-response matches above 0.1 kPa dynamic pressure and requires clean airbrake readback, zero authority contamination, unpowered entry, and aligned actual/Trajectories attitude in the fit domain. It automatically prefers the current fit-ready `matched10` profile and falls back to another fit-ready profile when necessary; pass `--profile ID_OR_KEY` to select one explicitly. It emits a physical extra-drag model and a one-step empirical model for how quickly the Trajectories along-track impact prediction moves under a given airbrake command. Other profiles are reported as transfer-validation metrics. The generated model records its calibration envelope, per-mode fit metrics, transfer results, source runs, and warnings; do not extrapolate it to another craft or atmosphere without new calibration runs.

## Useful links

- kOS documentation: https://ksp-kos.github.io/KOS/contents.html
- kOS project site: https://ksp-kos.github.io/KOS/
- Kerbal Space Program: https://www.kerbalspaceprogram.com/
