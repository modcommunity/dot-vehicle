class_name DotVehicleHover
extends DotVehicleChassis

## A hovercraft: held above the ground by raycast springs, steered by torque.
##
## [b]It exists to prove the abstraction, and it is the honest second kind.[/b] A boat
## and a hovercraft are the same problem — a body with no wheels, held up by something,
## turned by a yaw torque rather than by steered contact patches — and neither of them
## can be a [VehicleBody3D]. If [DotVehicleWheeled] were the only chassis, "subclass
## `DotVehicleChassis`" would be an untested promise, which in this family is the same
## thing as a bug.
##
## The suspension here IS ours, unlike the wheeled case: four downward rays from the
## body's corners, a spring along each, damped by the velocity at the contact point. It
## is the same model Godot's wheels use, minus the friction — which is the point, since
## a hovercraft is a vehicle with no grip.

## How far above the ground it floats, in metres. From [DotVehicleTunables] via
## [member DotVehicleTunables.suspension_travel], so it retunes with everything else.
var ride_height: float = 1.0

## Sideways damping, as a fraction of the sideways velocity removed per second.
##
## [b]Not zero, and not one.[/b] Zero is a puck that never stops sliding sideways and
## cannot be aimed; one is a car with no wheels. Somewhere in between is a hovercraft,
## and this is the number a game actually tunes.
var lateral_damping: float = 1.4

## Physics mask the ground rays use.
var ground_mask: int = 1

## Where the springs push from, in body space. Four corners by default.
var _mounts: Array[Vector3] = []


func _setup() -> DotResult:
	var body := vehicle.body()

	if body == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A hover vehicle needs a RigidBody3D at the root of its scene.",
			String(vehicle.def.id) if vehicle.def != null else "?"
		)

	ride_height = maxf(tunables.suspension_travel * 4.0, 0.3)

	# Derived from the body's own collision shape rather than from a constant, so one
	# chassis serves a skiff and a barge. A constant here would put the springs inside
	# a large hull and outside a small one, and the small one would flip on its first
	# turn while the large one would not respond at all.
	var extent := _body_extent(body)

	_mounts = [
		Vector3(-extent.x, 0.0, -extent.z),
		Vector3(extent.x, 0.0, -extent.z),
		Vector3(-extent.x, 0.0, extent.z),
		Vector3(extent.x, 0.0, extent.z),
	]

	return DotResult.success(self)


func _body_extent(body: RigidBody3D) -> Vector3:
	for child in body.get_children():
		var shape := child as CollisionShape3D

		if shape == null or shape.shape == null:
			continue

		var box := shape.shape as BoxShape3D

		if box != null:
			return box.size * 0.5

		var sphere := shape.shape as SphereShape3D

		if sphere != null:
			return Vector3.ONE * sphere.radius

	# A hull nothing could measure. One metre is wrong for almost everything and is
	# wrong in a way that is visible immediately, which beats a number that happens to
	# work for the fixture and fails on the first real vehicle.
	return Vector3.ONE


func _drive(command: DotVehicleCommand, delta: float) -> void:
	var body := vehicle.body()

	if body == null:
		return

	var space := body.get_world_3d().direct_space_state
	var transform := body.global_transform
	var grounded := 0

	for mount in _mounts:
		var from := transform * mount
		var to := from + Vector3.DOWN * (ride_height * 2.0)

		var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
		query.exclude = [body.get_rid()]

		var hit := space.intersect_ray(query)

		if hit.is_empty():
			continue

		grounded += 1

		var distance := from.distance_to(hit["position"] as Vector3)
		var compression := clampf(1.0 - distance / ride_height, 0.0, 1.0)

		# Spring minus damper. Without the damper this is a trampoline: the spring
		# alone stores every bump and returns it, and the craft climbs its own
		# oscillation until it is bouncing metres into the air.
		var at_mount := body.linear_velocity + body.angular_velocity.cross(from - transform.origin)
		var closing := at_mount.dot(Vector3.UP)

		var force := (
			compression * tunables.suspension_stiffness * tunables.mass
			- closing * tunables.damping_compression * tunables.mass
		)

		body.apply_force(Vector3.UP * maxf(force, 0.0), from - transform.origin)

	if grounded == 0:
		# Nothing under it. Thrust in mid-air would let a player fly, which is a
		# different vehicle and should be a different chassis.
		return

	var forward := -transform.basis.z

	body.apply_central_force(forward * engine_force_for(command.throttle))

	if command.brake > 0.0 or command.handbrake:
		var braking := tunables.handbrake_force if command.handbrake else tunables.brake_force
		var along := body.linear_velocity.dot(forward)
		body.apply_central_force(-forward * signf(along) * braking * maxf(command.brake, 1.0 if command.handbrake else 0.0))

	# Steering is a torque, and it is scaled by speed rather than applied flat: a
	# hovercraft that could spin on the spot at a standstill is one a player uses as a
	# turret, and the vehicle stops being a vehicle.
	var authority := clampf(absf(vehicle.forward_speed()) / maxf(tunables.top_speed, 0.001), 0.1, 1.0)
	body.apply_torque(Vector3.UP * -steering * tunables.engine_force * authority * 0.5)

	# The lateral damper. Applied along the body's own right, so it removes sliding
	# without touching how fast the craft is going where it is pointed.
	var right := transform.basis.x
	var sideways := body.linear_velocity.dot(right)
	body.apply_central_force(-right * sideways * lateral_damping * tunables.mass * delta * 60.0)


func describe() -> Dictionary:
	var out := super.describe()
	out["mounts"] = _mounts.size()
	out["ride_height"] = "%.2f m" % ride_height
	return out
