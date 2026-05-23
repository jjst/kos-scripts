# Copilot instructions

## kOS documentation

As part of this repository's `copilot-setup-steps` workflow, the kOS upstream docs are cloned to `.copilot-reference/kos-docs` inside the workspace.

Use `.copilot-reference/kos-docs/doc/source` as a local reference for kOS documentation when working on scripts in this repository.

## Linting

`kos-language-server` is installed as a dev dependency and can be used to validate `.ks` files without running the game.

After editing any `.ks` file, run:

```sh
npm run lint
```

This performs syntax validation and static analysis (undeclared symbols, unused variables) across all `.ks` files in the repo. Fix any **errors** before committing; **warnings** are informational.

The script communicates with the language server over LSP stdio — it exits 0 on clean/warnings-only, 1 on errors, 2 on timeout.
