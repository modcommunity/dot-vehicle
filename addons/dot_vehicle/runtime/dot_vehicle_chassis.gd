class_name DotVehicleChassis
extends RefCounted

## How a vehicle turns a command into motion. The subclass point for a kind that
## behaves differently — a boat, a hovercraft, something tracked.
##
## [b]A [RefCounted] beside the body, not a script on it[/b], for [DotNpcBrain]'s
## reason: the body is the definition's scene and belongs to whoever made it, and a
## chassis that had to be the scene's root script would mean one scene per handling
## model. It also means one scene serves several catalogue entries at different weights,
## which is the cheap way to ship vehicles.
##
## [b]A delivered chassis extends this by PATH, never by name.[/b] A script inside a
## mounted dot-cloud pack cannot resolve a [code]class_name[/code] —
## [code]extends "res://addons/dot_vehicle/runtime/dot_vehicle_chassis.gd"[/code] works
## in a build and in a pack, and [code]extends DotVehicleChassis[/code] works in a build
## only.
##
## [b]This runs on the server only.[/b] See [DotVehicleSpawner] for why a vehicle is
## not predicted.

## The vehicle this drives. Set before [method _setup].
var vehicle: DotVehicleInstance = null

## Handling. Never null: [method DotVehicleDef.tuning] falls back to the defaults.
var tunables: DotVehicleTunables = null

## Where the steering actually is, in radians. Moves toward the command at the
## tunables' rate rather than jumping, which is what stops a keyboard being a switch.
var steering: float = 0.0


# --- Called by the spawner ----------------------------------------------------

func bind(p_vehicle: DotVehicleInstance, p_tunables: DotVehicleTunables) -> DotResult:
	vehicle = p_vehicle
	tunables = p_tunables

	if vehicle == null or not vehicle.is_alive():
		return DotResult.fail(DotError.CODE_INVALID, "No vehicle to drive.")

	apply_body()

	return _setup()


## Writes the tunables onto the body. Called once, before [method _setup].
##
## [b]Onto the body, never left to whatever the scene was saved with.[/b] This is
## dot-props' mass bug, which cost a night: a catalogue that says 900 kg over a scene
## saved at 20 kg gives a vehicle a physics gun refuses for being too heavy and a
## gravity gun throws like a beach ball, with nothing erroring either way.
func apply_body() -> void:
	var rigid := vehicle.body()

	if rigid == null:
		return

	rigid.mass = tunables.mass

	if tunables.centre_of_mass_drop > 0.0:
		# The difference between a car and a thing that rolls over at every corner. A
		# rigid body's default centre of mass is its origin, which on a vehicle scene is
		# usually at the axle line or above it.
		rigid.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		rigid.center_of_mass = Vector3(0.0, -tunables.centre_of_mass_drop, 0.0)


## One simulated tick of driving.
func drive(command: DotVehicleCommand, delta: float) -> void:
	if vehicle == null or not vehicle.is_alive() or tunables == null:
		return

	var cmd := command if command != null else DotVehicleCommand.new()
	cmd.sanitise()

	_advance_steering(cmd.steer, delta)
	_drive(cmd, delta)


## Moves the steering toward what was asked for, at the tunables' rate.
##
## Shared rather than left to each chassis, because the falloff with speed is a
## property of driving rather than of a wheel: a hovercraft that steered at full
## authority at 30 m/s is as unmanageable as a car that did.
func _advance_steering(wanted: float, delta: float) -> void:
	var limit := tunables.steering_limit_at(vehicle.forward_speed())
	var target := wanted * limit

	if absf(wanted) < 0.01:
		# Returning to centre is its own rate and is usually faster than steering into
		# a corner: a vehicle whose wheels crept back to centre understeers out of every
		# corner exit and reads as having no self-centring at all.
		steering = move_toward(steering, 0.0, tunables.steering_return() * delta)
		return

	steering = move_toward(steering, target, tunables.steering_rate() * delta)

	# Clamped after the move as well as before it, because the limit SHRINKS as the
	# vehicle speeds up: a wheel already at full lock when the throttle goes down would
	# otherwise stay there, above the limit for that speed, until the driver let go.
	steering = clampf(steering, -limit, limit)


# --- Subclass interface -------------------------------------------------------

## Called once, after the body is in the world and the tunables are on it.
func _setup() -> DotResult:
	return DotResult.success(null)


## Called every simulated tick with a sanitised command.
func _drive(_command: DotVehicleCommand, _delta: float) -> void:
	pass


# --- Helpers ------------------------------------------------------------------

## The engine force a throttle of [param throttle] is worth right now.
##
## Zero above the top speed, so a vehicle coasts rather than accelerating for ever.
## [b]Measured along the vehicle's own forward, not on the speed[/b]: a vehicle sliding
## sideways at 40 m/s is not travelling forward at all, and one that judged this on
## `speed()` would refuse to accelerate out of a slide, which is exactly when a driver
## needs it.
func engine_force_for(throttle: float) -> float:
	var forward := vehicle.forward_speed()

	if throttle > 0.0:
		if forward >= tunables.top_speed:
			return 0.0

		return tunables.engine_force * throttle

	if throttle < 0.0:
		if -forward >= tunables.top_speed * tunables.reverse_fraction:
			return 0.0

		return tunables.engine_force * tunables.reverse_fraction * throttle

	return 0.0


func describe() -> Dictionary:
	return {
		"chassis": get_script().resource_path.get_file() if get_script() != null else "?",
		"steering": "%.1f deg" % rad_to_deg(steering),
		"speed": "%.1f m/s" % (vehicle.forward_speed() if vehicle != null else 0.0),
	}
