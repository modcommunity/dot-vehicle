extends RefCounted

## dot-vehicle's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: the baseline (2026-09-26): DotVehicleDef, DotVehicleCatalogue, DotVehicleSeat,
#    DotVehicleTunables, DotVehicleCommand, DotVehicleInstance, DotVehicleSpawner,
#    DotVehicleRide, DotVehicleChassis, DotVehicleWheeled, DotVehicleHover, DotVehicleDriver,
#    DotVehicleNetSync.
# 2: brakes are forces (brake_force and handbrake_force are newtons times the physics step on
#    each wheel; before, Godot read them as an impulse per step); DotVehicleTunables.linear_damp,
#    written onto the body in REPLACE mode; DotVehicleWheeled.step_seconds(). OLDEST stays 1: a
#    pack built before compiles and runs, with brakes that now mean their figures.
const LEVEL := 2
const OLDEST := 1
