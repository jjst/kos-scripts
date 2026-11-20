# Flight telemetry

- Follow `deorbit.ks` and `reentry.ks`. Use `check_line(ok, label, detail)` for named pass/fail checks with actual values, limits, and units before the summary.
- Use `log_line` to print and append timestamped messages to `1:/`. Use `transmit_log` with `HOMECONNECTION:ISCONNECTED` and `COPYPATH` to export to a unique `0:/` file periodically during waits and flight, and at phase changes and aborts.
- Log targets, transitions, bounded samples, and measured outcomes. Record the exact rejection or cutoff reason and state before cleanup.

## Known quirks and workarounds

- Stock SAS can stay in Stability Assist after a mode request, especially after warp. At settled 1x, enable SAS, allow it to settle, explicitly set `SASMODE` to `"STABILITYASSIST"`, then `WAIT 0.` before selecting the target mode. Verify the mode and measured alignment before applying thrust.
