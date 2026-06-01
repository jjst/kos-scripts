# kos-scripts

A bunch of [kOS](https://ksp-kos.github.io/KOS/) scripts for [Kerbal Space Program](https://www.kerbalspaceprogram.com/).

## Contents

- `boot/boomerang.ks` - boot script that copies scripts to local volume and prompts which phase to start
- `launch.ks` - gravity-turn ascent to circular orbit
- `deorbit.ks` - Trajectories-guided deorbit burn and handoff to `reentry.ks`
- `reentry.ks` - atmospheric guidance; hands off to `land_guided.ks` when inside the descent envelope, otherwise `land_unguided.ks`
- `land_guided.ks` - PID-guided descent and landing burn
- `land_unguided.ks` - fallback airbrake descent and landing burn
- `hop.ks` - standalone VTVL vertical hop and landing

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

Both scripts copy all `.ks` files to `Ships/Script/` and `boot/*.ks` to `Ships/Script/boot/`.

## Useful links

- kOS documentation: https://ksp-kos.github.io/KOS/contents.html
- kOS project site: https://ksp-kos.github.io/KOS/
- Kerbal Space Program: https://www.kerbalspaceprogram.com/
