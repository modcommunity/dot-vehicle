# dot-vehicle

**Vehicles a game can drive, ride in and shoot from.** A catalogue of definitions, handling as layered configuration, seats as data, the handover between a player and a vehicle, two chassis (Godot's raycast `VehicleBody3D` and our own hover), a bot driver, and what replicates.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to vehicles. The reasoning is in [docs/](docs/).

**Depends on dot-core and nothing else.** Not dot-player-controller, dot-net or dot-combat: each is a seam the host wires, and naming any of them would make this addon fail to parse in a project that does not have it.

## Read before

| Read | Before |
| --- | --- |
| [docs/handover.md](docs/handover.md) | `DotVehicleRide`, seats and exits, the spawner, catalogue checks, disconnect and destruction, unbinding, `adopt()` |
| [docs/driving.md](docs/driving.md) | authority and replication, `DotVehicleWheeled` and Godot's signs, `DotVehicleHover`, a new chassis, the tunables, `DotVehicleDriver`, what is deliberately not here |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_vehicle/core/` | `DotVehicleDef` (checkable without a scene), `DotVehicleCatalogue` (JSON an operator edits), `DotVehicleSeat`, `DotVehicleTunables` (a `DotConfig`), `DotVehicleCommand` (one tick of intent), `DotVehicleInstance`, `DotVehicleDamage` (what has come off, as data) |
| `addons/dot_vehicle/runtime/` | `DotVehicleSpawner` (the node a game adds; owns the ride), `DotVehicleRide` (the handover), `DotVehicleChassis` (the subclass point), `DotVehicleWheeled`, `DotVehicleHover`, `DotVehicleDriver`, `DotVehicleBreakage` (hits, burst tyres, lost wheels, parts thrown), `DotVehicleDebris` (the budgeted loose pieces) |
| `addons/dot_vehicle/net/` | `DotVehicleNetSync`: what replicates, as strings; never names dot-net |
| `fixtures/` | scenes and a chassis-by-path for the suite |
| `examples/vehicle_selftest.tscn` | the suite; real bodies through real physics frames |

## Running and testing

- Link `addons/dot_core` once ([development setup](../../docs/development-setup.md)), then the family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)) and `timeout 180 godot --headless --path . res://examples/vehicle_selftest.tscn`. Exits non-zero on failure.
- Assert a direction, never only that something moved: a car that drives backwards travels as far as one that does not. [driving](docs/driving.md#two-measured-facts-about-godots-vehicle)
- Tests that build colliders need their own patch of world and a frame between them (`queue_free` is deferred). [history](docs/history.md)
- Consumers: game-playground (adopted cars), mg-buses-from-hell (the buses), mg-smash-copter (a game chassis), mg-dangerous-delivery (a truck bound without the seat handover, its own `DdDrivetrain`). mg-wipeout links the addon and drives nothing. Run the ones a change touches.

## Rules that bite

- Exits are a swept query over candidates in order, excluding the vehicle and every occupant, and refused when none is free. Never teleport the rider anyway. [handover](docs/handover.md#the-hard-part-is-not-the-driving-it-is-the-handover)
- `occupants` maps seat id to rider id; iterate values for riders. [handover](docs/handover.md#the-hard-part-is-not-the-driving-it-is-the-handover)
- `allow_exit_when_inverted` overrides `max_exit_speed`. [handover](docs/handover.md#the-hard-part-is-not-the-driving-it-is-the-handover)
- One ride: assign callbacks to `spawner.ride`, never construct a second `DotVehicleRide`. [handover](docs/handover.md#one-ride-and-it-is-the-spawners)
- Catalogue load refuses seats without exits, duplicate seat ids, no driving seat, a chassis named by `class_name`, and a wheeled kind without a `VehicleBody3D`. [handover](docs/handover.md#refused-early-at-catalogue-load)
- A disconnect disowns, never removes; destruction forces every rider out. [handover](docs/handover.md#a-disconnect-does-not-remove-the-vehicle)
- The vehicle/chassis pair is unbound at `remove` and at the spawner's `_exit_tree`; any `RefCounted` pair that refers both ways leaks. [handover](docs/handover.md#the-vehicle-and-its-chassis-point-at-each-other)
- `adopt()` never places, reparents or frees the node, refuses a body that is already a vehicle, and still counts against the budget. [handover](docs/handover.md#adopt-the-second-entry-point)
- Vehicles are server-authoritative and never predicted; a client smooths the interpolated transform. [driving](docs/driving.md#server-authoritative-and-not-predicted)
- Brakes are newtons: `DotVehicleWheeled` writes `force × physics step / wheels`, because Godot reads a wheel's `brake` as an impulse per step; a subclass that sets `brake` itself multiplies by `step_seconds()`. The body's linear damping is `tunables.linear_damp` (REPLACE), never the project's. [driving](docs/driving.md#brakes-are-forces-and-godot-wants-an-impulse)
- S that brakes and then reverses is `DotVehicleCommand.brake_then_reverse(forward_speed)`, called by the game's key mapping, never the chassis (a bot's reverse means reverse). [driving](docs/driving.md#one-key-to-brake-and-reverse)
- A handbrake slide is `handbrake_grip_fraction` (1.0 = none); a threshold, not a slope, and it lengthens the handbrake's straight stop. [driving](docs/driving.md#brakes-are-forces-and-godot-wants-an-impulse)
- `DotVehicleCommand`: forward is -Z, +1 steers right. Only `DotVehicleWheeled` translates to Godot's signs, and it divides engine force across traction wheels. [driving](docs/driving.md#two-measured-facts-about-godots-vehicle)
- A new kind of vehicle is a `DotVehicleChassis` subclass named by `chassis_script_path`, never a fork. [driving](docs/driving.md#why-godots-raycast-vehicle-is-used-rather-than-replaced)
- Debris never touches anything driven (`DotVehicleDebris.collision_mask` is the road): rigid bodies differ between machines, so each peer throws its own from the server's list and velocities. A hit is a change of speed at a point, never a force, so one strength table serves a van and a tipper. [driving](docs/driving.md#parts-that-come-off)
- The bot driver steers in the vehicle's own basis, brakes for corners and on arrival, reverses out when stuck, and never paths; a person in the seat beats the autopilot. [driving](docs/driving.md#the-bot-driver)

## Where a game plugs in

| To change | Where |
| --- | --- |
| How something that is not a person drives | `DotVehicleDriver`, on `DotVehicleInstance.autopilot` |
| How hard a driver corners, and when it gives up | `DotVehicleDriver.corner_slowdown` / `stuck_time` / `reverse_time` / `waypoint_radius` |
| What a vehicle is | `DotVehicleDef` in a `DotVehicleCatalogue` |
| How it handles | `DotVehicleTunables`, layered like every `DotConfig` (`handbrake_grip_fraction` for a handbrake slide) |
| Whether back brakes before it reverses | `DotVehicleCommand.brake_then_reverse()` in the game's key mapping |
| A kind that behaves differently | `DotVehicleChassis` subclass, named by path (`chassis_script_path`) |
| Where riders sit and where they get out | `DotVehicleSeat` |
| What happens to a player who gets in | `spawner.ride.on_seated` / `on_unseated` |
| Whether rider nodes are carried at all | `DotVehicleRide.carry_rider_nodes` |
| What the exit sweep tests against | `DotVehicleRide.exit_mask` |
| Where vehicles are added | `DotVehicleSpawner.world_ref`, a `DotNodeRef` |
| A body something else already created | `DotVehicleSpawner.adopt()` |
| Whether a leaving owner's vehicles go | `clean_up_on_leave` |
| Who may spawn what | `DotVehicleDef.entitlement` plus the spawner's `entitlements` callable |
| What replicates | `DotVehicleNetSync.specs()`, resolved by the game's bridge |
| What comes off, and how hard it has to be hit | `DotVehicleDamage.add_part` (strength is a change of speed at the part, m/s) and the wheels' tyre and hub strengths in `DotVehicleBreakage.setup` |
| What a burst tyre or a hub does to the drive | `DotVehicleDamage.popped_*` / `hub_*` |
| Where pieces go and how many | a `DotVehicleDebris` on `breakage.debris` (none on a server: parts are only hidden), its `budget` and `collision_mask` |
| A client showing the server's losses | `breakage.simulate = false`, then `apply_state(damage.to_dict(), velocities)` |

Deliberately not here: prediction, input, pathfinding, a camera, damage beyond parts and wheels (no deformation, no health per panel on the wire), fuel/gearbox/audio, a shipped aircraft chassis, towing, 2D. [driving](docs/driving.md#deliberately-not-here)
