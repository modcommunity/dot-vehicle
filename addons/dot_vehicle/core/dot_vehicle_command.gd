class_name DotVehicleCommand
extends RefCounted

## What a driver is asking the vehicle to do this tick.
##
## [b]A command object rather than four arguments, for [code]DotFpsCommand[/code]'s
## reason[/b] — it is the thing a client sends, a demo records and a bot fabricates, and
## every one of those wants to build it without a controller present.
##
## [b]It is intent, not prediction.[/b] dot-player-controller's command exists so a client
## can simulate the same movement the server will; this one exists so a client can tell
## the server what it wants. A vehicle is rigid-body simulated and therefore not
## reproducible across machines, so the client sends this and draws what comes back.
## See [DotVehicleSpawner] for the whole argument and for what was considered instead.

## -1 (full reverse) to 1 (full throttle).
var throttle: float = 0.0

## -1 (left) to 1 (right). The wheels turn toward this at the tunables' rate, so a
## keyboard sending 1 and an analogue stick sending 0.4 differ in the angle reached,
## not in how abruptly it arrives.
var steer: float = 0.0

## 0 to 1.
var brake: float = 0.0

var handbrake: bool = false

## The rider wants out. Acted on once, on the tick it arrives.
var exit_requested: bool = false

## Where the rider is looking, as a yaw and pitch in radians, when the seat allows it.
var aim_yaw: float = 0.0
var aim_pitch: float = 0.0


static func make(
	p_throttle: float = 0.0, p_steer: float = 0.0, p_brake: float = 0.0
) -> DotVehicleCommand:
	var cmd := DotVehicleCommand.new()
	cmd.throttle = p_throttle
	cmd.steer = p_steer
	cmd.brake = p_brake
	return cmd


## Clamps everything into range. Called by the chassis before anything is applied.
##
## [b]On the server, on every command, whatever sent it.[/b] A client is a program the
## player can edit, and a throttle of 40 is 40 times the engine force with nothing
## erroring anywhere — the vehicle simply drives at an impossible speed and every other
## number stays plausible.
func sanitise() -> DotVehicleCommand:
	throttle = clampf(throttle, -1.0, 1.0)
	steer = clampf(steer, -1.0, 1.0)
	brake = clampf(brake, 0.0, 1.0)

	# NaN survives a clamp — `clampf(NAN, -1, 1)` is NAN — and one NaN reaching a
	# physics body puts its transform beyond recovery for the rest of the round, with
	# the vehicle vanishing rather than erroring. It costs three compares to refuse.
	if is_nan(throttle):
		throttle = 0.0
	if is_nan(steer):
		steer = 0.0
	if is_nan(brake):
		brake = 0.0

	aim_yaw = 0.0 if is_nan(aim_yaw) else fposmod(aim_yaw, TAU)
	aim_pitch = 0.0 if is_nan(aim_pitch) else clampf(aim_pitch, -PI * 0.5, PI * 0.5)

	return self


func is_idle() -> bool:
	return (
		absf(throttle) < 0.001
		and absf(steer) < 0.001
		and brake < 0.001
		and not handbrake
	)


func describe() -> Dictionary:
	return {
		"throttle": "%.2f" % throttle,
		"steer": "%.2f" % steer,
		"brake": "%.2f" % brake,
		"handbrake": handbrake,
	}
