# kos-scripts

A bunch of [kOS](https://ksp-kos.github.io/KOS/) scripts for [Kerbal Space Program](https://www.kerbalspaceprogram.com/).

## Contents

- `boot/boomerang.ks` - boot script that copies `launch.ks`, `deorbit.ks`, and `land.ks` to local volume and prompts which script to start
- `launch.ks` - gravity-turn ascent script targeting a circular orbit and saving the launch position for landing
- `deorbit.ks` - Trajectories-guided deorbit script that warps to the configured phase angle, burns toward a long entry aim point, and can hand off to `land.ks`
- `land.ks` - descent and landing script with entry airbrake/AoA management, range-gated guidance, and landing telemetry
- `hop.ks` - standalone VTVL proof-of-concept vertical hop and landing

## Useful links

- kOS documentation: https://ksp-kos.github.io/KOS/contents.html
- kOS project site: https://ksp-kos.github.io/KOS/
- Kerbal Space Program: https://www.kerbalspaceprogram.com/
