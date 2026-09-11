This is the **vehicle** asset for TMC's **Dot** collection. It is what you add when players should be able to drive somewhere rather than only walk there.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Vehicles
**Vehicles for Godot 4.** A catalogue of definitions, handling as layered configuration, seats as data, and the part every game gets wrong: the handover.

Depends on **dot-core and nothing else**.

## The hard part is not the driving

A player in a vehicle is a player their controller must stop simulating, whose camera belongs to the vehicle, whose collision is the vehicle's, and who has to be put back **somewhere legal** when they get out, with the vehicle possibly upside down, against a cliff, or moving at 30 m/s.

So exit placement is a **query**, not a constant. A seat carries candidate positions in preference order, `DotVehicleRide` sweeps a body-sized capsule at each, and it **refuses the exit** when none of them is free. Refusing is the correct answer; every game that teleports the player anyway is a game players get outside the map in.

## Server-authoritative, and not predicted

Rigid-body simulation is not reproducible across machines, so a predicted vehicle is a constantly corrected one, and a correction on something a player is steering reads far worse than latency does. What is honest is smoothing: a driver's client interpolates the replicated transform, which hides the snapshot rate without inventing physics.

## Installing

Copy `addons/dot_vehicle/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project, and enable dot-vehicle in *Project → Project Settings → Plugins*.

## Five minutes

```gdscript
var vehicles := DotVehicleSpawner.new()
vehicles.authoritative = true                  # on the server only
vehicles.catalogue = catalogue
vehicles.world_ref = DotNodeRef.of_path(^"../World")

# Where the game stops the player's own controller and moves their camera.
vehicles.ride.on_seated = _player_got_in
vehicles.ride.on_unseated = _player_got_out

add_child(vehicles)

var jeep := vehicles.spawn(&"jeep", at, &"alice")
vehicles.ride.enter(jeep, &"alice", alice_node)

# Every simulated tick:
vehicles.set_command(jeep.instance_id, &"alice", command)
vehicles.tick(delta)
```

A definition:

```gdscript
var jeep := DotVehicleDef.make(&"jeep", "res://vehicles/jeep.tscn")

var driver := DotVehicleSeat.make(&"driver", true)
driver.seat_offset = Vector3(-0.4, 0.9, -0.4)

var gunner := DotVehicleSeat.make(&"gunner")
gunner.may_fire = true
gunner.attach_path = ^"Turret"

jeep.seats = [driver, gunner]
jeep.tunables = handling          # a DotConfig: retunable in a file
catalogue.add(jeep)
```

## Three chassis kinds, and your own

`WHEELED` is Godot's `VehicleBody3D` with the tunables written onto its wheels. `HOVER` is this addon's own raycast suspension on a plain `RigidBody3D`, such as a hovercraft, a skiff or a barge. `CUSTOM` is a game driving the thing entirely, with dot-vehicle keeping only the seats and the bookkeeping. Anything else is a `DotVehicleChassis` subclass, named by **path** so a mounted dot-cloud pack can deliver one.

## Two measured facts about Godot's vehicle

Both confirmed against `scene/3d/physics/vehicle_body_3d.cpp` and by running it:

- **A positive `engine_force` drives a `VehicleBody3D` along +Z**, which is the opposite of `Node3D`'s forward, of `look_at`, and of every other convention in this family. A car built the obvious way drives backwards while every number about it reads correctly.
- **A positive `steering` turns left.**

`DotVehicleCommand` uses this family's conventions and `DotVehicleWheeled` does the translation, once, so no game ever has to.

## Driving without a person

A `DotVehicleCommand` is throttle, steer and brake, and for the whole life of this addon the only thing that could produce one was somebody holding a key. `DotVehicleDriver` is the other half: give it a route and it drives.

```gdscript
var driver := DotVehicleDriver.new()
driver.target_speed = 16.0
driver.set_route(PackedVector3Array([checkpoint_a, checkpoint_b, depot]))

jeep.autopilot = driver          # the spawner's tick drives it from here
```

It steers in the vehicle's own frame (a car on a banked corner is rolled, and a world yaw is the wrong question), brakes for corners rather than lifting off, eases down to the last waypoint rather than braking at the arrival circle, and notices when it has been asking for throttle and going nowhere, then reverses out with the wheel turned the other way, which is what a person does without thinking about it.

**It does not path.** The route comes from dot-npc's graph, a spline, or four points in a config file. And a person in the driving seat always wins: an autopilot is only consulted for a vehicle nobody is driving.

## Validating

```bash
godot --headless --path . --import
timeout 180 godot --headless --path . res://examples/vehicle_selftest.tscn
```

114 checks, exits non-zero on failure.

## Licence

MIT.
