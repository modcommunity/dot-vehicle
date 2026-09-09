class_name DotVehicleWheeled
extends DotVehicleChassis

## A car. Godot's [VehicleBody3D] with this addon's tunables written onto its wheels.
##
## [b]Godot's raycast vehicle is used rather than replaced, and that was a decision.[/b]
## [VehicleBody3D] is Bullet's raycast vehicle: a ray per wheel, a spring along it, and
## a friction model at the contact point. Writing that again in GDScript would be the
## same algorithm, several hundred lines slower, running on the main thread — and it is
## the part that is already correct. What is [i]not[/i] already there is the half this
## class is: the wheel properties are exported per wheel in a scene, so a definition
## that wanted a heavier version of the same car would need a second scene, and a server
## retuning grip would need a rebuild. Turning [DotVehicleTunables] into wheel
## properties at spawn is what makes handling data.
##
## [b]It needs a [VehicleBody3D] root with [VehicleWheel3D] children.[/b] Refused
## loudly rather than limped through: a plain [RigidBody3D] driven by
## `apply_central_force` looks like a working vehicle for about four seconds and then
## behaves like a sliding crate, which is the sort of wrongness an operator reports as
## "the handling feels off" a week later.

## The wheels, in the order they were found. Cached, because walking the children of a
## body every tick for four nodes is work done sixty times a second for no reason.
var _wheels: Array[VehicleWheel3D] = []

## Wheels that steer — Godot's own `use_as_steering` flag says which.
var _steering_wheels: Array[VehicleWheel3D] = []

## Wheels that drive.
var _driven_wheels: Array[VehicleWheel3D] = []

## Wheels the handbrake acts on: the ones that neither steer nor drive, or the rear
## half when a game marked every wheel as both.
var _handbrake_wheels: Array[VehicleWheel3D] = []


func _setup() -> DotResult:
	var body := vehicle.node as VehicleBody3D

	if body == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A wheeled vehicle needs a VehicleBody3D at the root of its scene.",
			String(vehicle.def.id) if vehicle.def != null else "?"
		)

	for child in body.get_children():
		var wheel := child as VehicleWheel3D

		if wheel == null:
			continue

		_wheels.append(wheel)

		if wheel.use_as_steering:
			_steering_wheels.append(wheel)

		if wheel.use_as_traction:
			_driven_wheels.append(wheel)

	if _wheels.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A wheeled vehicle needs at least one VehicleWheel3D under its body.",
			String(vehicle.def.id) if vehicle.def != null else "?"
		)

	_pick_handbrake_wheels()
	_apply_wheel_tunables()

	return DotResult.success(self)


## The handbrake acts on the wheels that do not steer, and on the rear half otherwise.
##
## [b]Not on every wheel, which is what a first pass writes.[/b] A handbrake that locks
## the front is a vehicle that stops dead and cannot be turned into a slide, which is
## the only thing a handbrake is for in a game. The fallback exists because a scene
## whose wheels are all marked as steering and traction is common and should still get
## something sensible rather than nothing.
func _pick_handbrake_wheels() -> void:
	for wheel in _wheels:
		if not wheel.use_as_steering:
			_handbrake_wheels.append(wheel)

	if not _handbrake_wheels.is_empty():
		return

	# Sorted by their own Z, because the vehicle's forward is -Z: the largest Z is
	# furthest back. Positions rather than order in the scene, which nobody guarantees.
	var by_depth := _wheels.duplicate()
	by_depth.sort_custom(func(a: VehicleWheel3D, b: VehicleWheel3D) -> bool:
		return a.position.z > b.position.z)

	for i in maxi(by_depth.size() / 2, 1):
		_handbrake_wheels.append(by_depth[i])


func _apply_wheel_tunables() -> void:
	for wheel in _wheels:
		wheel.suspension_travel = tunables.suspension_travel
		wheel.suspension_stiffness = tunables.suspension_stiffness
		wheel.damping_compression = tunables.damping_compression
		wheel.damping_relaxation = tunables.damping_relaxation

		# The rear grip fraction is applied to the wheels the handbrake acts on, which
		# are the rear ones by the definition above. Making the back end let go first is
		# deliberate: understeer is a vehicle that will not turn and oversteer is one a
		# player can catch.
		var rear := _handbrake_wheels.has(wheel)
		wheel.wheel_friction_slip = (
			tunables.friction_slip * tunables.rear_grip_fraction
			if rear else tunables.friction_slip
		)


func _drive(command: DotVehicleCommand, _delta: float) -> void:
	var body := vehicle.node as VehicleBody3D

	if body == null:
		return

	# BOTH SIGNS ARE FLIPPED, and neither is a guess. Measured on 4.7.2 and confirmed
	# against Godot's own source (`scene/3d/physics/vehicle_body_3d.cpp`):
	#
	# - `rollingFriction = -m_engineForce * step`, applied along
	#   `m_forwardWS = surfaceNormal.cross(axle)`. With a level surface and the wheel's
	#   local +X as its axle that is `Y × X = -Z`, so a POSITIVE `engine_force` drives
	#   the body along **+Z** — the opposite of `Node3D`'s forward, of `look_at`, and of
	#   every other convention in this family. A car built the obvious way drives
	#   backwards while every number about it reads correctly.
	# - `Basis(up, m_steering)` rotates about +Y, so a POSITIVE `steering` turns
	#   **left**. Measured: `steering = +0.5` yaws -5.4 degrees over 150 ticks.
	#
	# `DotVehicleCommand` says forward is -Z and +1 steers right, because that is what
	# the rest of this family says. The translation belongs here, once, rather than in
	# every game that ever spawns a car.
	body.steering = -steering

	var force := engine_force_for(command.throttle)

	# Divided across the driven wheels, because Godot's `set_engine_force` writes the
	# SAME figure onto every wheel marked for traction — so a four-wheel-drive scene
	# given the whole number accelerates twice as hard as a rear-wheel-drive one from
	# the same tunables, and the operator who tuned it on one car finds the other
	# undriveable.
	body.engine_force = -force / float(maxi(_driven_wheels.size(), 1))

	var brake := tunables.brake_force * command.brake

	# Divided across EVERY wheel rather than the driven ones, because `set_brake` writes
	# its figure onto all of them — traction or not. Braking is a magnitude and has no
	# sign to flip: it opposes whatever the wheel is doing.
	body.brake = brake / float(maxi(_wheels.size(), 1))

	for wheel in _handbrake_wheels:
		wheel.brake = (
			tunables.handbrake_force / float(maxi(_handbrake_wheels.size(), 1))
			if command.handbrake else 0.0
		)


func describe() -> Dictionary:
	var out := super.describe()
	out["wheels"] = _wheels.size()
	out["driven"] = _driven_wheels.size()
	out["handbrake"] = _handbrake_wheels.size()
	return out
