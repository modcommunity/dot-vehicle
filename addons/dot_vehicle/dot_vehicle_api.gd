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
#    written onto the body in REPLACE mode; DotVehicleWheeled.step_seconds();
#    DotVehicleCommand.brake_then_reverse() and STOPPED_BELOW (one key to brake and reverse,
#    opt-in); DotVehicleTunables.handbrake_grip_fraction (1.0, no change, by default). OLDEST
#    stays 1: a pack built before compiles and runs, with brakes that now mean their figures.
# 3: what comes off: DotVehicleDamage (parts and wheels as data, to_dict/apply_dict for the
#    wire), DotVehicleBreakage (feels contact and landing hits, burst tyres and lost wheels
#    that drag and pull, mass taken off with a load), DotVehicleDebris (budgeted loose pieces,
#    carve() for a one-piece model); DotVehicleWheeled.wheels(), set_wheel_grip(), wheel_grip().
const LEVEL := 3
const OLDEST := 1
