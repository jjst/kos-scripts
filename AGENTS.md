# Flight telemetry

- Follow `deorbit.ks` and `reentry.ks`. Use `check_line(ok, label, detail)` for named pass/fail checks with actual values, limits, and units before the summary.
- Use `log_line` to print and append timestamped messages to `1:/`. Use `transmit_log` with `HOMECONNECTION:ISCONNECTED` and `COPYPATH` to export to a unique `0:/` filename at checkpoints.
- Log targets, transitions, bounded samples, and measured outcomes. Record the exact rejection or cutoff reason and state before cleanup.
