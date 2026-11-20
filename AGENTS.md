# Flight telemetry

- Log named preflight checks with pass/fail results, actual values, limits, and units. Report each failed check before the summary.
- Record initial conditions, targets, state changes, and outcomes. Sample at a bounded rate. Log the exact reason and measured state before an abort or cutoff.
- Print and save the same timestamped messages locally. Export to a unique archive file at checkpoints when connected. Verify outcomes from measured behavior.
