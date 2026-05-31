# kos-scripts

A bunch of [kOS](https://ksp-kos.github.io/KOS/) scripts for [Kerbal Space Program](https://www.kerbalspaceprogram.com/).

## Contents

- `boot/boomerang.ks` - boot script that copies `launch.ks`, `deorbit.ks`, `reentry.ks`, and `land.ks` to local volume and prompts which script to start
- `launch.ks` - gravity-turn ascent script targeting a circular orbit and saving the launch position for landing
- `deorbit.ks` - Trajectories-guided deorbit script that warps to the configured phase angle, burns toward a long entry aim point, and hands off to `reentry.ks`
- `reentry.ks` - atmospheric guidance script that manages AoA/airbrakes and only hands off to `land.ks` after reaching the 25 km / 1200 m/s / 10 km-ahead gate
- `land.ks` - descent and landing script that takes over after reentry handoff for the guided descent and landing burn
- `hop.ks` - standalone VTVL proof-of-concept vertical hop and landing

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
