# Driving: chassis, handling, the bot driver, and the network

## Server-authoritative, and not predicted

The same decision dot-props and dot-npc make, and here it costs the most: it is the **driver's own input** going round trip, which is exactly what prediction exists to hide. It was considered properly and rejected anyway.

A vehicle is a rigid body with a contact solver under it. Iteration order, island membership and the last bits of every float differ between two machines, so two runs of the same drive diverge in a second or two. A predicted vehicle is therefore a corrected vehicle, and a correction on something a player is steering reads far worse than latency does: latency is a delay, and a correction is the vehicle moving somewhere the player did not put it.

**What is honest is smoothing.** A driver's client can interpolate the replicated transform toward where it is going, which hides the snapshot rate without inventing physics the server did not simulate. That is the game's to do in its renderer, and it is why `DotVehicleNetSync` marks the transform interpolated.

## Two measured facts about Godot's vehicle

Both confirmed against Godot's `scene/3d/physics/vehicle_body_3d.cpp` and by running it on 4.7.2:

- **A positive `engine_force` drives the body along +Z.** The source applies `rollingFriction = -m_engineForce * step` along `m_forwardWS = surfaceNormal.cross(axle)`, which on a level surface with the wheel's local +X as its axle is `Y × X = -Z`. The sign is inverted twice and the result is the opposite of `Node3D`'s forward, of `look_at`, and of every other convention in this family. **A car built the obvious way drives backwards while every number about it reads correctly**: `travelled > 1.0` passed and `forward_speed() > 0` did not.
- **A positive `steering` turns left.** `Basis(up, m_steering)` rotates about +Y.

`DotVehicleCommand` says forward is -Z and +1 steers right, because that is what the rest of this family says. `DotVehicleWheeled` does the translation once. The suite asserts **both directions**, not merely that the vehicle moved: a check that only measured "it turned" would pass for a car that turns the wrong way.

Two more from the same source, and both are why the forces are divided:

- `set_engine_force` writes the same figure onto **every traction wheel**, so a four-wheel-drive scene given the whole number accelerates twice as hard as a rear-wheel-drive one from the same tunables.
- `set_brake` writes onto **every wheel**, traction or not.

## Brakes are forces, and Godot wants an impulse

`brake_force` and `handbrake_force` are newtons at the road. Godot's wheel `brake` is not: `_update_friction` uses it as Bullet's `maxImpulse` for the rolling friction at the contact, in newton-seconds, once per physics step (the engine force on the line above is multiplied by the step; the brake is not). Handed newtons, a wheel could cancel more motion every step than the car had, so every vehicle stopped as hard as its tyres allowed whatever its tunables said: the default car from 50 km/h in 5.5 m, a loaded delivery truck in 0.7 m, and a car of twice the mass in exactly the same distance.

`DotVehicleWheeled` writes `force × step / wheels` onto every wheel, with the handbrake's share **added** on the rear wheels. The step is `step_seconds()`, the body's physics delta (so `Engine.time_scale` and a game ticking its vehicles at its own rate change nothing), never the delta `drive()` was handed. Measured on the suite's 800 kg jeep with the default 8100 N: 8.96 m from 50 km/h at 60 ticks, 8.83 m at 120, 16.35 m at twice the mass. Two more facts from the same function: **a wheel with any engine force ignores its brake** (throttle and brake together is throttle), and **with neither, a wheel has no rolling resistance at all**, so a coasting vehicle is slowed only by the body's damping.

That damping is `tunables.linear_damp`, written onto the body in `REPLACE` mode by `apply_body()`. 0.1 per second is Godot's project default, kept so no consumer's handling moved; it is a drag proportional to speed, which on a 4 t truck at 19 m/s was 8.5 kN and capped its speed. A chassis that models its own air and rolling resistance (delivery's `DdDrivetrain`) sets 0. A body that set its own damping on top of the project's (Godot's default COMBINE mode adds them) carries the sum in the tunables instead: mg-smash-copter's chopper is 0.22, its 0.12 plus the 0.1.

The raycast vehicle does not lock a wheel: a handbrake slows the rear and never breaks it loose into a slide (measured: a one-second handbrake turn at 15 m/s yaws less than the same turn without it, before and after this change). The slide is `tunables.handbrake_grip_fraction`: the handbrake wheels' `wheel_friction_slip` times that while it is held, back the tick it is released. 1.0 by default, so nothing tuned before moved. It is a threshold, not a slope: on mg-buses-from-hell's 2 t bus, from 12 m/s at full lock for a second, 1.0 turned 14 degrees and stopped dead, 0.25 and 0.2 still turned less than no handbrake (41), 0.15 stepped the back end out (71 degrees, 7 m/s left) and 0.1 spun it round. A sliding tyre also brakes worse: the same bus's straight-line handbrake stop went from 6.3 m to 16 m. Tune it per vehicle by driving it, and render it.

## One key to brake and reverse

`DotVehicleCommand.brake_then_reverse(forward_speed)` turns a negative throttle into the foot brake while the vehicle still rolls forward faster than `STOPPED_BELOW` (0.8 m/s), and into reverse once it has nearly stopped; a positive throttle while rolling backwards brakes the same way. That is how a driving game's S key works, and reverse thrust is not a substitute: it is `reverse_fraction` of the engine, a fraction of the brake, so a bus on S took 21 m from 15 m/s against the brake's 7.6.

**Opt-in, called by the game where it maps keys to a command, never by the chassis.** A bot's three-point turn asks for reverse while still rolling forward and means it; a chassis that rewrote every negative throttle would change every autopilot in the family. The speed is the vehicle's `forward_speed()` read where the command is applied, which is the server. mg-buses-from-hell and game-playground call it; mg-dangerous-delivery does the same in its client sampler with its own threshold.

## Why Godot's raycast vehicle is used rather than replaced

`VehicleBody3D` is a raycast vehicle: a ray per wheel, a spring along it, a friction model at the contact point. Writing that again in GDScript would be the same algorithm, several hundred lines slower, on the main thread, and it is the part that is already correct.

What is **not** already there is the part `DotVehicleWheeled` is: wheel properties are exported per wheel in a scene, so a definition wanting a heavier version of the same car would need a second scene, and a server retuning grip would need a rebuild. Turning `DotVehicleTunables` into wheel properties at spawn is what makes handling *data*.

`DotVehicleHover` exists to prove that abstraction. A boat and a hovercraft are the same problem and neither can be a `VehicleBody3D`; if wheeled were the only chassis, "subclass `DotVehicleChassis`" would be an untested promise, which in this family is the same thing as a bug. `DotVehicleHover` deliberately does nothing with no ground under it (ground effect has nothing to push against). mg-smash-copter's helicopter is a game's own chassis named by `chassis_script_path`, which is the extension point working as meant: nothing here knows what a helicopter is.

## Handling numbers that are not obvious

| | |
| --- | --- |
| `steering_speed_falloff` | **The most important number in the file.** Full lock available at speed is a vehicle that spins on the first corner and a player who concludes the handling is broken. |
| `steering_rate_deg` | A rate, not an angle, which is what stops a keyboard being an on/off switch. Full lock on the tick a key goes down flips anything with a high centre of mass. |
| `centre_of_mass_drop` | The difference between a car and a thing that rolls over at every corner. A rigid body's default centre of mass is its origin, which on a vehicle scene is at or above the axle line. |
| `rear_grip_fraction` | Under 1.0 makes the back end let go first, deliberately. A player can drive out of oversteer and cannot drive out of understeer. |
| `reverse_fraction` | A vehicle that reverses as fast as it drives is one nobody turns round, and that reads as broken handling rather than as a choice. |
| `max_exit_speed` / `allow_exit_when_inverted` | See [handover.md](handover.md#the-hard-part-is-not-the-driving-it-is-the-handover). |

## The bot driver

`DotVehicleDriver` reads a position, a heading and a velocity and returns throttle, steer and brake. It knows nothing about physics and nothing about the world, deliberately three times over: it is testable with no physics server, it works for a chassis this addon has never seen, and it cannot quietly become a second place where driving is simulated.

**It does not path.** Give it a route (from dot-npc's graph, from a spline, from four points in a config file) and it follows it. Deciding where to go would make this addon depend on a navigation one.

- **The steering angle is computed in the vehicle's own basis**, not as a world yaw. A world yaw is the wrong question on anything that pitches or rolls, and a vehicle on a hillside pitches. `+1` steers right (`DotVehicleCommand`'s convention).
- **It brakes for corners rather than lifting off.** A driver that only lifts enters every corner at whatever speed the straight left it at, and understeers off the road.
- **It brakes on arrival rather than coasting.** A vehicle handed no command rolls on, and "arrived" then means "went past".
- **It notices being stuck and reverses out**, counter-steering while it reverses, because backing out along the line you drove in on puts you back where you were.

`waypoint_radius` defaults generously: a car cannot stop on a point, and a radius tighter than the turning circle produces a vehicle circling a waypoint it cannot quite touch.

**It is wired in.** `DotVehicleInstance.autopilot` is consulted by the spawner's tick for a vehicle with nobody in the driving seat; a driver nothing calls is a driver that does not exist. A person in the seat always wins: a passenger climbing into a convoy lorry takes it over rather than fighting the autopilot for the wheel.

The suite drives a **kinematic toy car** for the driver rather than a `VehicleBody3D`. What is tested is the decision (does it turn the right way, slow for the corner, notice it is stuck), and a real body answers that through a suspension model, a friction model and a solver, none of which is this addon's.

## Deliberately not here

- **No prediction.** A decision, not a gap.
- **No input.** A `DotVehicleCommand` is built by the game from a keyboard, a gamepad or a touch layout. dot-player-controller's sampler is the model, and naming it here would make this addon fail to parse without it. The bot case is `DotVehicleDriver`.
- **No pathfinding for the driver.**
- **No camera.** A vehicle camera is a game's, and `on_seated` is where it moves.
- **No damage model beyond a single health number.** Deformation, per-panel damage and wheels that come off are a game's; dot-combat is where a weapon lives.
- **No fuel, no gearbox, no engine audio.** Each is a game's, and each would be a number in `meta` rather than a fork.
- **No shipped aircraft chassis.** Lift is not suspension and there is no ground to raycast at; an aircraft is a `DotVehicleChassis` subclass by path, as mg-smash-copter's is.
- **No towing, no trailers, no vehicles carrying vehicles.** A joint between two rigid bodies is a physics problem the seats layer has nothing to say about.
- **No 2D.** Everything here is `Vector3`.
