# Flight telemetry

KSP is complex and a lot of things can go wrong. Unfortunately, as an agent you cannot directly observe the game, therefore it is **crucial** that you give yourself observability to have feedback loops to detect whether your changes work as intended when kOS code runs in-game.

- Follow `deorbit.ks` and `reentry.ks`. Use `check_line(ok, label, detail)` for named pass/fail checks with actual values, limits, and units before the summary.
- Use `log_line` to print and append timestamped messages to `1:/`. Use `transmit_log` with `HOMECONNECTION:ISCONNECTED` and `COPYPATH` to export to a unique `0:/` file periodically during waits and flight, and at phase changes and aborts.
- Log targets, transitions, bounded samples, and measured outcomes. Record the exact rejection or cutoff reason and state before cleanup.

## In-game tests

When you run on the gaming PC with KSP open, use the in-game test runner as your feedback loop. README "In-game tests" covers setup and how to make saves.

- Run `npm run test:ingame -- <test-id>` after changing flight code. The tests are listed in `tests/tests.json`. The command copies the scripts into the game, loads the test's save, runs it, and prints the `[FAIL]` / `[!]` / `[PASS]` lines from the test's log. Exit code: 0 pass, 1 fail, 2 refused or couldn't run.
- On failure, read the log copy and the kOS screen transcript in `test-runs/` before changing code. A kOS error shows up in the transcript, not in the log.
- A test is an existing procedure run from a fixed save; its `check_line` (requirements) and `warn_line` (margins) checks are the verdict. Give new code checks the same way rather than writing separate assertions. Keep the `[PASS] label - detail` format stable: the runner parses it.
- Only use the sandbox test game. Don't make or replace saves (`npm run test:save`, `--force`) unless the operator asks: they're the fixed starting points every run is compared against. Never answer `test:save`'s idle-CPU question for the operator.
- If the runner refuses (CPU busy, save missing, CPU not in the telnet menu), report the exact message to the operator instead of working around it.

## Flight terminal UX

- Lead with the operator's next action. Keep the prompt visible until input arrives. Example: “Press Enter to arm satellite 2 of 4 and auto-warp.”
- During automatic phases, show what happens next and a countdown to the scheduled event. Example: “Satellite 2 of 4 releases in 1m 12s. Auto-warping. Stay on the carrier.”
- At a handoff, name the vessel to switch to and when to return. On failure, say whether the action happened, why it stopped, and how to recover.
- Use `CLEARSCREEN.` to redraw a single status view at a bounded cadence during automatic waits and clear it before the next instruction. Keep raw samples in the log.
- Use `TERMINAL:INPUT:CLEAR()` once before waiting for a fresh confirmation to discard buffered keystrokes. Leave the prompt visible while waiting.

## Known quirks and workarounds

- `TRANSFER` is a reserved kOS built-in. Use a name such as `departure_window` for variables instead. The live compiler rejects it even when lint passes.

- Stock SAS can stay in Stability Assist after a mode request, especially after warp. At settled 1x, enable SAS, allow it to settle, explicitly set `SASMODE` to `"STABILITYASSIST"`, then `WAIT 0.` before selecting the target mode. Verify the mode and measured alignment before applying thrust.
