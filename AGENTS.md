# Flight telemetry

- Follow `deorbit.ks` and `reentry.ks`. Use `check_line(ok, label, detail)` for named pass/fail checks with actual values, limits, and units before the summary.
- Use `log_line` to print and append timestamped messages to `1:/`. Use `transmit_log` with `HOMECONNECTION:ISCONNECTED` and `COPYPATH` to export to a unique `0:/` file periodically during waits and flight, and at phase changes and aborts.
- Log targets, transitions, bounded samples, and measured outcomes. Record the exact rejection or cutoff reason and state before cleanup.

## Flight terminal UX

- Lead with the operator's next action. Keep the prompt visible until input arrives. Example: “Press Enter to arm satellite 2 of 4 and auto-warp.”
- During automatic phases, show what happens next and a countdown to the scheduled event. Example: “Satellite 2 of 4 releases in 1m 12s. Auto-warping. Stay on the carrier.”
- At a handoff, name the vessel to switch to and when to return. On failure, say whether the action happened, why it stopped, and how to recover.
- Use `CLEARSCREEN.` to redraw a single status view at a bounded cadence during automatic waits and clear it before the next instruction. Keep raw samples in the log.
- Use `TERMINAL:INPUT:CLEAR()` once before waiting for a fresh confirmation to discard buffered keystrokes. Leave the prompt visible while waiting.

## Known quirks and workarounds

- Stock SAS can stay in Stability Assist after a mode request, especially after warp. At settled 1x, enable SAS, allow it to settle, explicitly set `SASMODE` to `"STABILITYASSIST"`, then `WAIT 0.` before selecting the target mode. Verify the mode and measured alignment before applying thrust.
