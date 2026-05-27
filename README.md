# kos-scripts

A bunch of [kOS](https://ksp-kos.github.io/KOS/) scripts for [Kerbal Space Program](https://www.kerbalspaceprogram.com/).

## Contents

- `boot/boomerang.ks` — boot script that copies `launch.ks`, `deorbit.ks`, and `land.ks` to local volume, then runs `launch.ks`
- `launch.ks` — gravity-turn ascent script targeting a circular orbit and saving the launch position for landing
- `deorbit.ks` — Trajectories-guided deorbit script targeting the saved landing position
- `land.ks` — descent and landing script that returns to the launch position saved by `launch.ks`
- `hop.ks` — standalone VTVL proof-of-concept vertical hop and landing

## Useful links

- kOS documentation: https://ksp-kos.github.io/KOS/contents.html
- kOS project site: https://ksp-kos.github.io/KOS/
- Kerbal Space Program: https://www.kerbalspaceprogram.com/
