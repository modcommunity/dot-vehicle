# The handover, the spawner, and a vehicle's lifetime

## The hard part is not the driving, it is the handover

Suspension has prior art everywhere and a raycast vehicle ships inside Godot. What does not ship anywhere is the bookkeeping around a player who has stopped being a player: their controller must stop simulating them, their camera belongs to the vehicle, their collision has to leave the physics world, and when they get out they have to be put back *somewhere legal*, with the vehicle possibly upside down, against a cliff, or moving at 30 m/s. So `DotVehicleRide` was designed first and the chassis second.

**Exit placement is a query, not a constant.** A seat that carried "put them down here" as an offset is a way through walls: park against a rock face and the offset is inside the rock. A seat carries candidates in preference order, the ride sweeps a body-sized capsule at each, and it **refuses the exit** when none is free. Refusing is the correct answer. Every game that teleports the player anyway has this bug and it is how players get outside a map.

The exclusions on that sweep are the subtle half: the vehicle **and everybody in it**. A second passenger sitting where the first is about to stand would block their exit, which is a two-seater nobody can get out of, and it only happens with two people in it. `DotVehicleInstance.occupants` maps **seat id to rider id**; iterating the dictionary walks its keys, so `for rider_id in vehicle.occupants` walks seat ids and excludes nobody. Iterate the values.

`max_exit_speed` refuses an exit from a moving vehicle (a leap takes fall damage the game has not written, or lands inside the geometry the vehicle was about to occupy). `allow_exit_when_inverted` **overrides the speed rule rather than adding to it**: the one state a player cannot drive out of must always be one they can leave.

## One ride, and it is the spawner's

`DotVehicleSpawner` constructs a `DotVehicleRide` in `_init` and uses it to evacuate a vehicle destroyed with people in it, to answer `vehicle_of_rider`, and to count riders. A game that builds `DotVehicleRide.new()` beside it gets a *second* index, and those three then read one that is always empty: `describe()` reports nobody driving while somebody is, and a destroyed vehicle releases no rider. Assign the callbacks (`on_seated`, `on_unseated`) to `spawner.ride`.

## Refused early, at catalogue load

- **A seat with no exit offsets.** The moment a player finds one is the moment they are already in it.
- **Two seats sharing an id.** The second is unreachable, so the vehicle quietly holds one fewer person than it says.
- **A vehicle with no driving seat.** Nobody could ever move it.
- **A chassis or brain named by `class_name` rather than by path.** Caught at catalogue load, because a catalogue is read once at boot and a spawn happens mid-round, and a pack's `class_name` does not resolve.
- **Brakes weaker than half the engine.** Not fatal (reported), and it reads as having no brakes at all.
- **A wheeled definition over a scene with no `VehicleBody3D`.** Limping through with `apply_central_force` looks like a working vehicle for four seconds and then behaves like a sliding crate.

## A disconnect does not remove the vehicle

The opposite of dot-props' default, deliberately. A prop is a thing somebody built; a vehicle is a thing somebody parked, usually with other people in it. Removing it when the driver disconnects deletes the car three passengers are riding in. It is *disowned* instead, so a departed player's budget is not held for ever; `clean_up_on_leave = true` is there for a server that wants the other rule.

Destruction is the case where everybody **must** come out, and it forces the exit: a vehicle usually explodes somewhere awkward and there may be no room to stand. A rider left in a freed vehicle is a player parented to nothing: invisible, unkillable, unable to enter another vehicle for the rest of the round, with no error anywhere.

## The vehicle and its chassis point at each other

`DotVehicleInstance.chassis` holds the chassis and `DotVehicleChassis.vehicle` holds the vehicle back. Two `RefCounted`s referring to each other are **never freed** (GDScript has no cycle collector), so the pair outlives the spawner and takes the definition, the tunables, the seats and the last command with it.

Clearing one end reads exactly like the fix and is half of it. And the path that leaks hardest never calls `remove` at all: **a game is torn down by freeing its nodes**. So `_unbind` clears both ends and the spawner's `_exit_tree` walks whatever is left. dot-npc's `DotNpcBrain.unbind` is the same shape for the same reason. **Any pair of `RefCounted`s in this family that refer to each other is a leak**, and the symptom is never a crash: it is a number in a suite's exit line that everybody has learned to read past.

## `adopt()`, the second entry point

game-playground's first car could not use `spawn`: everything in that world is a `DotPropInstance` (on a prop budget, on an undo stack, pickup-able by a physics gun), and its prop spawner has already loaded the scene and placed the body by the time anything knows the definition. `adopt(body, id, owner)` is everything after the instantiate: the entitlement, the budget, the cooldown, the instance row, the chassis and the announcement. `spawn` is written in terms of it, so the two cannot drift.

- **It does not place or reparent the node.** Whoever created it has already decided where it goes.
- **It refuses a body that is already a vehicle.** Two instances over one node is two chassis writing engine force onto one rigid body: a car with twice the power its tunables say.
- **`remove` does not free an adopted node.** The host that made it owns its lifetime. The marker is `DotVehicleInstance.meta[META_ADOPTED]`; `is_adopted()` reads it.
- **The budget is still checked.** An adopted vehicle still occupies this spawner's world count, or `world_budget` would mean nothing on exactly the deployment this exists for.
