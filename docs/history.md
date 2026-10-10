# History

Bugs worth recognising if they come back. All parsed cleanly. The rule each left is in [handover.md](handover.md) or [driving.md](driving.md).

- **The car drove backwards**, with every count and distance right: Godot's `engine_force` drives along +Z. Found because `forward_speed() > 0` failed while `travelled > 1.0` passed.
- **The exit sweep excluded nobody**: `_exclusions` iterated `occupants` (seat id to rider id) as if its keys were riders.
- **In the suite: `queue_free` is deferred**, so walls one test boxed a vehicle in with were still in the physics space when the next test ran. It read exactly like a broken ejection. Tests that build colliders need their own patch of world and a frame between them.
- **A seam documented and never built**: the command was "built from a keyboard, a gamepad, a touch layout or a bot", and nothing existed for the bot until `DotVehicleDriver`, which then also had to be called by something (`autopilot`).
- **The vehicle/chassis cycle leaked** every world's vehicles at exit (measured in mg-buses-from-hell, growing by one world each time its suite built another), with every `remove` path looking correct.
- **A game built a second `DotVehicleRide`** (mg-buses-from-hell): `describe()` reported nobody driving while somebody was, and a destroyed bus released no rider.
