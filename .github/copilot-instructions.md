# Copilot instructions

## kOS documentation

As part of this repository's `copilot-setup-steps` workflow, the kOS upstream docs are cloned to `.copilot-reference/kos-docs` inside the workspace.

Use `.copilot-reference/kos-docs/doc/source` as a local reference for kOS documentation when working on scripts in this repository.

When implementing any common or recurring KSP logic, you **must** check the local kOS documentation first and use it as the authoritative reference.

| File | What it contains | Why it is useful |
| --- | --- | --- |
| `tutorials/quickstart.rst` | End-to-end beginner workflow (terminal, editor, run flow, script file basics). | Fast sanity check for canonical script workflow and command formatting in examples. |
| `language/syntax.rst` | KerboScript syntax rules, operators, keywords, and statement termination rules. | Prevents syntax mistakes (especially periods, operators, and reserved words). |
| `language/flow.rst` | Control-flow constructs (`IF/ELSE`, `UNTIL`, `BREAK`, `LOCK`, etc.) and behavior notes. | Core for loops, branching, and runtime control patterns used in flight scripts. |
| `language/user_functions.rst` | Declaring/calling user functions, parameter handling, scope behavior (`local`/`global`). | Needed to structure reusable script logic cleanly and safely. |
| `commands/flight/cooked.rst` | High-level autopilot control (`LOCK STEERING`, `LOCK THROTTLE`) and constraints/warnings. | Primary reference for most launch/orbit/autopilot guidance logic. |
| `commands/flight/raw.rst` | Direct control input APIs via `SHIP:CONTROL:*` and raw control semantics. | Required when precise low-level control is needed beyond cooked steering. |
| `commands/flight/systems.rst` | Vessel system toggles and modes (`SAS`, `RCS`, `SASMODE`, action groups, control reference). | Critical for script-controlled vessel state transitions and avoiding control conflicts. |
| `commands/prediction.rst` | Future-state prediction APIs (`POSITIONAT`, `VELOCITYAT`, `ORBITAT`) and caveats. | Essential for maneuver planning, intercept timing, and trajectory-aware logic. |
| `structures/vessels/vessel.rst` | `Vessel` structure, key suffixes (thrust, mass, speed, resources, parts, control). | Central data model for reading ship state and making control decisions. |
| `structures/orbits/orbit.rst` | Orbit model, patches, orbital parameters, and `CREATEORBIT()` usage. | Supports robust orbital reasoning and patch-aware navigation logic. |
| `math/vector.rst` | Vector creation and operations (`V(x,y,z)`, vector suffixes, coordinate notes). | Foundation for velocity/position math and directional control calculations. |
| `math/direction.rst` | Direction/rotation concepts and constructors (`HEADING`, `R`, `LOOKDIRUP`, `ROTATEFROMTO`). | Key reference for accurate pointing and steering target construction. |
| `commands/runprogram.rst` | Script execution APIs (`RUNPATH`, `RUNONCEPATH`, `RUN`) and argument behavior. | Needed to compose multi-script programs and invoke modules correctly. |
| `commands/files.rst` | File/volume/directory/path behavior and file I/O conventions. | Important for loading configs/data and managing script assets across volumes. |
| `structures/misc/pidloop.rst` | Built-in `PIDLoop` structure, parameters, defaults, and examples. | Useful for stable control loops (throttle/attitude/hover tuning). |
| `structures/misc/steeringmanager.rst` | Steering manager internals and tuning suffixes (`PITCHPID`, `YAWPID`, etc.). | Advanced tuning reference for improving cooked steering performance. |

## Linting

`kos-language-server` is installed as a dev dependency and can be used to validate `.ks` files without running the game.

After editing any `.ks` file, you **must** run:

```sh
npm run lint -- --strict
```

This performs syntax validation and static analysis (undeclared symbols, unused variables) across all `.ks` files in the repo. **Do not commit unless this command exits 0.** Both errors and warnings are treated as failures in strict mode — do not introduce new ones.

The script communicates with the language server over LSP stdio — it exits 0 on clean, 1 on errors (or warnings in strict mode), 2 on timeout.

## Naming conventions

Use unit suffixes in variable names wherever relevant (for example `_m`, `_km`, `_s`, `_ms`, `_deg`, `_kg`).
This should be followed for new and modified variables when it helps reduce potential ambiguity and prevent unit mix-ups.
