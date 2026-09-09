# dot-vehicle

**Vehicles a game can drive, ride in and shoot from.** A catalogue of definitions,
handling as layered configuration, seats as data, and the handover between a player and
a vehicle.

Depends on **dot-core and nothing else**. Not on dot-fps-controller, not on dot-net, not
on dot-combat — each is a seam the host wires, and naming any of them would make this
addon fail to parse in a project that does not have it.

## The one idea

**The hard part is not the driving, it is the handover.** Suspension has prior art in
every engine and a raycast vehicle ships inside Godot. What does not ship anywhere is
the bookkeeping around a player who has stopped being a player: their controller must
stop simulating them, their camera belongs to the vehicle, their collision has to leave
the physics world, and when they get out they have to be put back *somewhere legal* —
with the vehicle possibly upside down, against a cliff, or moving at 30 m/s.

So `DotVehicleRide` was designed first and the chassis second.

**Exit placement is a query, not a constant.** A seat that carried "put them down here"
as an offset is a way through walls: park against a rock face and the offset is inside
the rock. A seat carries candidates in preference order, the ride sweeps a body-sized
capsule at each, and it **refuses the exit** when none is free. Refusing is the correct
answer. Every game that teleports the player anyway has this bug and it is how players
get outside a map.

The exclusions on that sweep are the subtle half: the vehicle **and everybody in it**. A
second passenger sitting where the first is about to stand would block their exit, which
is a two-seater nobody can get out of — and it only happens with two people in it.

## Server-authoritative, and not predicted

The same decision dot-props and dot-npc make, and here it costs the most: it is the
**driver's own input** going round trip, which is exactly what prediction exists to
hide. It was considered properly and rejected anyway.

A vehicle is a rigid body with a contact solver under it. Iteration order, island
membership and the last bits of every float differ between two machines, so two runs of
the same drive diverge in a second or two. A predicted vehicle is therefore a corrected
vehicle, and a correction on something a player is steering reads far worse than latency
does: latency is a delay, and a correction is the vehicle moving somewhere the player
did not put it.

**What is honest is smoothing.** A driver's client can interpolate the replicated
transform toward where it is going, which hides the snapshot rate without inventing
physics the server did not simulate. That is the game's to do in its renderer, and it is
why `DotVehicleNetSync` marks the transform interpolated.

## Layout

```
addons/dot_vehicle/
  core/
    dot_vehicle_def.gd        One kind of vehicle. Checkable without loading a scene.
    dot_vehicle_catalogue.gd  Every kind a server offers. JSON an operator edits.
    dot_vehicle_seat.gd       A seat, and where its rider may be put down.
    dot_vehicle_tunables.gd   A DotConfig of handling numbers.
    dot_vehicle_command.gd    What a driver is asking for this tick.
    dot_vehicle_instance.gd   One vehicle: body, occupants, chassis, health.
  runtime/
    dot_vehicle_spawner.gd    The node a game adds.
    dot_vehicle_ride.gd       Getting in and getting out. The handover.
    dot_vehicle_chassis.gd    How a command becomes motion. The subclass point.
    dot_vehicle_wheeled.gd    Godot's VehicleBody3D, with the tunables on its wheels.
    dot_vehicle_hover.gd      Our own raycast suspension. A hovercraft or a skiff.
  net/
    dot_vehicle_net_sync.gd   What replicates, as strings. Never names dot-net.
```

## Two measured facts about Godot's vehicle

Both confirmed against Godot's own `scene/3d/physics/vehicle_body_3d.cpp` in
`external-study/`, and both by running it on 4.7.2:

- **A positive `engine_force` drives the body along +Z.** The source applies
  `rollingFriction = -m_engineForce * step` along
  `m_forwardWS = surfaceNormal.cross(axle)`, which on a level surface with the wheel's
  local +X as its axle is `Y × X = -Z`. So the sign is inverted twice and the result is
  the opposite of `Node3D`'s forward, of `look_at`, and of every other convention in
  this family. **A car built the obvious way drives backwards while every number about
  it reads correctly**, which is exactly how this was found: `travelled > 1.0` passed and
  `forward_speed() > 0` did not.
- **A positive `steering` turns left.** `Basis(up, m_steering)` rotates about +Y.
  Measured: `steering = +0.5` yaws -5.4 degrees over 150 ticks.

`DotVehicleCommand` says forward is -Z and +1 steers right, because that is what the rest
of this family says. `DotVehicleWheeled` does the translation once. The suite asserts
**both directions**, not merely that the vehicle moved — a check that only measured "it
turned" would pass for a car that turns the wrong way.

Two more from the same source, and both are why the forces are divided:

- `set_engine_force` writes the same figure onto **every traction wheel**, so a
  four-wheel-drive scene given the whole number accelerates twice as hard as a
  rear-wheel-drive one from the same tunables.
- `set_brake` writes onto **every wheel**, traction or not.

## Why Godot's raycast vehicle is used rather than replaced

`VehicleBody3D` is Bullet's raycast vehicle: a ray per wheel, a spring along it, a
friction model at the contact point. Writing that again in GDScript would be the same
algorithm, several hundred lines slower, on the main thread — and it is the part that is
already correct.

What is **not** already there is the part `DotVehicleWheeled` is: wheel properties are
exported per wheel in a scene, so a definition wanting a heavier version of the same car
would need a second scene, and a server retuning grip would need a rebuild. Turning
`DotVehicleTunables` into wheel properties at spawn is what makes handling *data*.

`DotVehicleHover` exists to prove that abstraction. A boat and a hovercraft are the same
problem and neither can be a `VehicleBody3D`; if wheeled were the only chassis,
"subclass `DotVehicleChassis`" would be an untested promise, which in this family is the
same thing as a bug.

## Handling numbers that are not obvious

| | |
| --- | --- |
| `steering_speed_falloff` | **The most important number in the file.** Full lock available at speed is a vehicle that spins on the first corner and a player who concludes the handling is broken. Every driving game has this and most do not tell you. |
| `steering_rate_deg` | A rate, not an angle, which is what stops a keyboard being an on/off switch. Full lock on the tick a key goes down flips anything with a high centre of mass. |
| `centre_of_mass_drop` | The difference between a car and a thing that rolls over at every corner. A rigid body's default centre of mass is its origin, which on a vehicle scene is at or above the axle line. |
| `rear_grip_fraction` | Under 1.0 makes the back end let go first, deliberately. A player can drive out of oversteer and cannot drive out of understeer. |
| `reverse_fraction` | A vehicle that reverses as fast as it drives is one nobody turns round, and that reads as broken handling rather than as a choice. |
| `max_exit_speed` | A player who leaps from a moving vehicle takes fall damage the game has not written, or lands inside the geometry the vehicle was about to occupy. |
| `allow_exit_when_inverted` | **Overrides the speed rule rather than adding to it.** The one state a player cannot drive out of must always be one they can leave; a rule that kept them in an overturned car is a rule that kills them. |

## Things that are refused, and why they are refused early

- **A seat with no exit offsets.** The moment a player finds one is the moment they are
  already in it.
- **Two seats sharing an id.** The second is unreachable, so the vehicle quietly holds
  one fewer person than it says.
- **A vehicle with no driving seat.** Nobody could ever move it.
- **A chassis or brain named by `class_name` rather than by path.** Caught at catalogue
  load, because a catalogue is read once at boot and a spawn happens mid-round.
- **Brakes weaker than half the engine.** Not fatal, and it reads as having no brakes at
  all — reported as a physics bug by whoever tuned the engine up.
- **A wheeled definition over a scene with no `VehicleBody3D`.** Limping through with
  `apply_central_force` looks like a working vehicle for four seconds and then behaves
  like a sliding crate, which gets reported as "the handling feels off" a week later.

## A disconnect does not remove the vehicle

The opposite of dot-props' default, and deliberately. A prop is a thing somebody built;
a vehicle is a thing somebody parked, usually with other people in it. Removing it when
the driver disconnects deletes the car three passengers are riding in. It is *disowned*
instead, so a departed player's budget is not held for ever, and
`clean_up_on_leave = true` is there for a server that wants the other rule.

Destruction is the case where everybody **must** come out, and it forces the exit:
a vehicle usually explodes somewhere awkward and there may be no room to stand. A rider
left in a freed vehicle is a player parented to nothing — invisible, unkillable, unable
to enter another vehicle for the rest of the round, with no error anywhere.

## Two bugs the suite found while this was being written

Both parsed cleanly, and one is a shape `game-dev/CLAUDE.md` already names:

- **The car drove backwards**, as above. Every count and distance was right.
- **`_exclusions` iterated occupants as riders.** `DotVehicleInstance.occupants` maps
  seat id to rider id, and iterating a `Dictionary` in GDScript walks its **keys** — so
  the obvious `for rider_id in vehicle.occupants` walked seat ids, looked nothing up, and
  produced a sweep that excluded nobody.

And one in the suite, worth as much as either: **`queue_free` is deferred**, so the walls
one test boxed a vehicle in with were still in the physics space when the next test ran.
It read exactly like a broken ejection. Tests that build colliders need their own
patch of world and a frame between them.

## Validating

```bash
cd godot/dot-vehicle
ln -s ../../dot-core/addons/dot_core addons/dot_core   # once

godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/dot_core/*' | \
  while read f; do godot --headless --path . --check-only --script "res://${f#./}"; done

timeout 180 godot --headless --path . res://examples/vehicle_selftest.tscn
```

114 checks. Exits non-zero on failure. Run the `--check-only` pass first: a scene whose
script fails to parse **hangs** rather than failing.

The suite drives real bodies through real physics frames, which is why it takes tens of
seconds rather than one. A placement test against no colliders would pass anywhere.

## Where a game plugs in

| To change | Where |
| --- | --- |
| What a vehicle is | `DotVehicleDef` in a `DotVehicleCatalogue` |
| How it handles | `DotVehicleTunables`, layered like every `DotConfig` |
| A kind that behaves differently | `DotVehicleChassis` subclass, named by path |
| Where riders sit and where they get out | `DotVehicleSeat` |
| What happens to a player who gets in | `DotVehicleRide.on_seated` / `on_unseated` |
| Whether rider nodes are carried at all | `DotVehicleRide.carry_rider_nodes` |
| What the exit sweep tests against | `DotVehicleRide.exit_mask` |
| Where vehicles are added | `DotVehicleSpawner.world_ref`, a `DotNodeRef` |
| Who may spawn what | `DotVehicleDef.entitlement` plus the spawner's `entitlements` callable |
| What replicates | `DotVehicleNetSync.specs()`, resolved by the game's bridge |

## Things deliberately not here

- **No prediction.** See above. It is a decision, not a gap.
- **No input.** A `DotVehicleCommand` is built by the game from a keyboard, a gamepad, a
  touch layout or a bot. dot-fps-controller's sampler is the model and naming it here
  would make this addon fail to parse without it.
- **No camera.** A vehicle camera is a game's, and `on_seated` is where it moves.
- **No damage model beyond a single health number.** Deformation, per-panel damage and
  wheels that come off are a game's; dot-combat is where a weapon lives.
- **No fuel, no gearbox, no engine audio.** Each is a game's, and each would be a number
  in `meta` rather than a fork.
- **No aircraft.** A helicopter is a different problem: lift is not suspension and there
  is no ground to raycast at. It would be a `DotVehicleChassis` subclass and probably
  its own addon.
- **No towing, no trailers, no vehicles carrying vehicles.** A joint between two rigid
  bodies is a physics problem the seats layer has nothing to say about.
- **No 2D.** Everything here is `Vector3`.
