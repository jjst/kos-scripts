# Copilot instructions

## kOS documentation

As part of this repository's `copilot-setup-steps` workflow, the kOS upstream docs are cloned to `.copilot-reference/kos-docs` inside the workspace.

Use `.copilot-reference/kos-docs/doc/source` as a local reference for kOS documentation when working on scripts in this repository.

When implementing any common or recurring KSP logic, you **must** check the local kOS documentation first and use it as the authoritative reference.

### Local kOS documentation index

Docs root: `.copilot-reference/kos-docs/doc/source`

- Main entry: `index.rst`
- Full table of contents: `contents.rst`
- Top-level guides:
  - `tutorials.rst`
  - `general.rst`
  - `language.rst`
  - `math.rst`
  - `commands.rst`
  - `structures.rst`
  - `addons.rst`
- Section directories:
  - `tutorials/`
  - `general/`
  - `language/`
  - `math/`
  - `commands/`
  - `structures/`
  - `addons/`
- Supporting references:
  - `library.rst`
  - `bindings.rst`
  - `changes.rst`
  - `getting_help.rst`
  - `downloads_links.rst`
  - `about.rst`
  - `contribute.rst`

## Linting

`kos-language-server` is installed as a dev dependency and can be used to validate `.ks` files without running the game.

After editing any `.ks` file, you **must** run:

```sh
npm run lint -- --strict
```

This performs syntax validation and static analysis (undeclared symbols, unused variables) across all `.ks` files in the repo. **Do not commit unless this command exits 0.** Both errors and warnings are treated as failures in strict mode — do not introduce new ones.

The script communicates with the language server over LSP stdio — it exits 0 on clean, 1 on errors (or warnings in strict mode), 2 on timeout.
