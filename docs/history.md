# History

Bugs worth recognising if they come back. All parsed cleanly. The rule each left is in [handover.md](handover.md) or [driving.md](driving.md).

- **The car drove backwards**, with every count and distance right: Godot's `engine_force` drives along +Z. Found because `forward_speed() > 0` failed while `travelled > 1.0` passed.
- **The exit sweep excluded nobody**: `_exclusions` iterated `occupants` (seat id to rider id) as if its keys were riders.
- **In the suite: `queue_free` is deferred**, so walls one test boxed a vehicle in with were still in the physics space when the next test ran. It read exactly like a broken ejection. Tests that build colliders need their own patch of world and a frame between them.
- **A seam documented and never built**: the command was "built from a keyboard, a gamepad, a touch layout or a bot", and nothing existed for the bot until `DotVehicleDriver`, which then also had to be called by something (`autopilot`).
- **The vehicle/chassis cycle leaked** every world's vehicles at exit (measured in mg-buses-from-hell, growing by one world each time its suite built another), with every `remove` path looking correct.
- **A game built a second `DotVehicleRide`** (mg-buses-from-hell): `describe()` reported nobody driving while somebody was, and a destroyed bus released no rider.
- **Every vehicle braked into a wall** (2026-10, found by mg-dangerous-delivery): the chassis handed `brake_force` in newtons to a wheel `brake` Godot reads as an impulse per step, so a car stopped from 50 km/h in 5.5 m, a loaded truck in 0.7 m, and doubling the mass changed nothing. Every suite passed: they asserted that a vehicle stopped, never how far it went doing it. The suite now measures the distance, at two tick rates and two masses.
- **A parked car would not drive off** (2026-10-12, game-playground): a body at rest sleeps, and a sleeping `VehicleBody3D` ignores its engine force. It hid behind the instant brakes and suites that always drove straight after a spawn; measuring a stopping distance from a car braked to a standstill found it.
