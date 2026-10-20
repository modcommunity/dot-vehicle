class_name DotVehicleBreakage
extends Node

## Makes a [DotVehicleDamage] physical on one vehicle body: it feels the hits, takes the parts
## off, and makes what is lost change the drive. A child of the body.
##
## [b]What it feels.[/b] Each physics step, the impulses on the body's own collision shapes
## (a rail, a rock, another truck, the road when it is on its side), summed and divided by the
## body's mass, are a change of speed at the impulse-weighted contact point; at
## [member hit_threshold] or more it is a hit. Wheels are rays and report no contact, so a wheel
## coming down on the road faster than [member landing_threshold] is a hit on that wheel.
##
## [b]What a loss does.[/b] A part's node is thrown (into [member debris], or hidden when there is
## none) and its mass leaves the body. A burst tyre rolls on a smaller radius with
## [member DotVehicleDamage.popped_grip] of its grip and thumps once a turn; a lost wheel's
## corner drops onto its hub ([member DotVehicleDamage.hub_radius]), stops driving, and drags
## (the pull to that side). The grip goes through [method DotVehicleWheeled.set_wheel_grip], so
## a game that changes the road's grip keeps the loss.
##
## [b]Who decides.[/b] [member simulate] is the server (or offline); a client's mirror sets it
## false, feels nothing, and is told what was lost through [method apply_state], which shows the
## same losses with the velocities the server sent. Nothing about it is predicted.

const CHANNEL := "vehicle.breakage"

## A part came off, a tyre burst or a wheel came away. [param event] is [DotVehicleDamage]'s
## with [code]at[/code] (world position) and [code]velocity[/code] (what the piece left with) added.
signal broke(event: Dictionary)

## Wheel [param wheel], burst or gone, is on the road at [param speed] m/s at [param at]: where a
## rim or a hub throws sparks. Every physics step while it lasts.
signal scraping(wheel: int, at: Vector3, speed: float)

var damage: DotVehicleDamage = null
var body: RigidBody3D = null

## The chassis whose wheels' grip is written; null for a body something else drives.
var chassis: DotVehicleWheeled = null

## Where thrown parts go. Null (a dedicated server) hides them instead.
var debris: DotVehicleDebris = null

## False on a client's mirror: nothing is felt, losses arrive through [method apply_state].
var simulate: bool = true

## The change of speed (m/s) in one step below which nothing is a hit.
var hit_threshold: float = 1.5

## How fast (m/s) a wheel may come down on the road before it is a hit on that wheel.
var landing_threshold: float = 6.0

## How hard a part is kicked away from what hit it, as a fraction of the hit, and at most.
var kick_share: float = 0.35
var kick_most: float = 6.0

## The body may not go lighter than this fraction of its mass at setup.
var min_mass_fraction: float = 0.2

## Kilograms the body has had taken off it by lost parts so far.
var mass_taken: float = 0.0

## The last hit felt (m/s, body frame), for a check.
var last_hit: float = 0.0
var last_hit_at: Vector3 = Vector3.ZERO

var _wheels: Array[VehicleWheel3D] = []
var _radius: Array[float] = []
var _phase: Array[float] = []
var _was_in_contact: Array[bool] = []
var _last_point_v: Array[Vector3] = []
var _parts: Dictionary = {}
var _start_mass: float = 0.0
var _mirror_last: Vector3 = Vector3.ZERO


## Binds to [param p_body], its [param p_damage] and (for a wheeled body) its [param p_chassis].
## A damage with no wheels is given one per [VehicleWheel3D] child, at [param tyre_strength] and
## [param hub_strength]. Part nodes are looked up now by [member DotVehicleDamage.Part.node].
func setup(p_body: RigidBody3D, p_damage: DotVehicleDamage, p_chassis: DotVehicleWheeled = null, tyre_strength: float = 7.0, hub_strength: float = 12.0) -> DotResult:
	if p_body == null or p_damage == null:
		return DotResult.fail(DotError.CODE_INVALID, "Breakage needs a body and a damage model.")

	body = p_body
	damage = p_damage
	chassis = p_chassis
	_start_mass = body.mass
	_wheels.clear()

	for child in body.get_children():
		if child is VehicleWheel3D:
			_wheels.append(child)

	if damage.wheels.is_empty():
		for wheel in _wheels:
			var _i := damage.add_wheel(wheel.position - Vector3(0, wheel.wheel_rest_length, 0), tyre_strength, hub_strength, wheel.wheel_radius * 2.0)

	for wheel in _wheels:
		_radius.append(wheel.wheel_radius)
		_phase.append(0.0)
		_was_in_contact.append(true)
		_last_point_v.append(Vector3.ZERO)

	for id: StringName in damage.parts:
		var part: DotVehicleDamage.Part = damage.parts[id]
		if not part.node.is_empty():
			var node := body.get_node_or_null(part.node) as Node3D
			if node != null:
				_parts[id] = node

	if simulate:
		body.contact_monitor = true
		body.max_contacts_reported = maxi(body.max_contacts_reported, 8)

	return DotResult.success(self)


## The node drawn for part [param id], if any.
func part_node(id: StringName) -> Node3D:
	return _parts.get(id, null)


## Hits the body at [param local_at] (its own frame) by [param dv] m/s, as a contact would: for a
## game's own hazards and for a check. Returns the events, already applied.
func hit(local_at: Vector3, dv: float) -> Array[Dictionary]:
	last_hit = dv
	last_hit_at = local_at
	var events := damage.hit(local_at, dv)
	_show(events, local_at, dv)
	return events


## A server's [method DotVehicleDamage.to_dict], shown. [param velocities] is part id or
## "wheel<i>" -> the [Vector3] the piece left with (the server's [code]velocity[/code]).
func apply_state(state: Dictionary, velocities: Dictionary = {}) -> Array[Dictionary]:
	var events := damage.apply_dict(state)

	for e in events:
		var key := str(e.get("id", "wheel%d" % int(e.get("wheel", -1))))
		if velocities.has(key):
			e["velocity"] = velocities[key]

	_show(events, Vector3.ZERO, 0.0)

	if events.is_empty() and damage.lost_parts().is_empty():
		_restore_all()

	return events


## Everything whole again: the parts come back from wherever they went (a respawn).
func repair() -> void:
	damage.repair()
	_restore_all()


func _physics_process(delta: float) -> void:
	if body == null or damage == null:
		return

	if simulate:
		_feel()

	_drive_wheels(delta)


func _feel() -> void:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())

	if state == null:
		return

	var total := Vector3.ZERO
	var at := Vector3.ZERO
	var weight := 0.0

	for i in state.get_contact_count():
		var impulse := state.get_contact_impulse(i)
		var size := impulse.length()
		total += impulse
		at += state.get_contact_local_position(i) * size
		weight += size

	if weight > 0.0:
		var dv := total.length() / maxf(body.mass, 1.0)
		if dv >= hit_threshold:
			# get_contact_local_position is in world space, despite its name (Godot 4).
			var _e := hit(body.to_local(at / weight), dv)

	for i in _wheels.size():
		var wheel := _wheels[i]
		var contact := wheel.is_in_contact()
		var point_v := body.linear_velocity + body.angular_velocity.cross(body.global_basis * wheel.position)

		if contact and not _was_in_contact[i]:
			var down := -_last_point_v[i].dot(wheel.get_contact_normal())
			if down >= landing_threshold:
				last_hit = down
				last_hit_at = wheel.position
				_show(damage.hit_wheel(i, down), wheel.position, down)

		_was_in_contact[i] = contact
		_last_point_v[i] = point_v


## The forces a burst tyre or a hub puts on the body, and the sparks.
func _drive_wheels(delta: float) -> void:
	var corner_load := body.mass * 9.8 / float(maxi(_wheels.size(), 1))

	for i in _wheels.size():
		var state := damage.wheel_state(i)

		if state == DotVehicleDamage.Wheel.INTACT:
			continue

		var wheel := _wheels[i]
		var offset := body.global_basis * wheel.position
		var point_v := body.linear_velocity + body.angular_velocity.cross(offset)
		var flat := point_v - Vector3.UP * point_v.y
		var speed := flat.length()

		if not simulate:
			# A mirror is frozen and moved by snapshots: its speed is how far it went, and its
			# wheels cast no rays, so the rim is taken to be on the road under the wheel.
			var moved := (body.global_position - _mirror_last).length() / maxf(delta, 0.001)
			if moved > 2.0 and moved < 80.0:
				scraping.emit(i, wheel.global_position - body.global_basis.y * wheel.wheel_radius, moved)
			continue

		if not wheel.is_in_contact():
			continue

		var drag_share := damage.popped_drag if state == DotVehicleDamage.Wheel.POPPED else damage.hub_drag

		if speed > 0.2:
			# Never more than stops the corner this step: a drag that overshoots is a shove.
			var most := body.mass * speed / maxf(delta, 0.001) * 0.25
			body.apply_force(-flat / speed * minf(drag_share * corner_load, most), offset)

		if state == DotVehicleDamage.Wheel.POPPED:
			_phase[i] += speed / maxf(wheel.wheel_radius, 0.05) * delta
			var thump := sin(_phase[i]) * damage.popped_wobble * corner_load
			body.apply_force(Vector3.UP * thump + body.global_basis.x * thump * 0.3, offset)

		# Only a hub throws sparks: a burst tyre is still rubber on the road (its shreds are the
		# "popped" event's to show).
		if state == DotVehicleDamage.Wheel.LOST and speed > 2.0:
			scraping.emit(i, wheel.get_contact_point(), speed)

	_mirror_last = body.global_position


func _show(events: Array[Dictionary], local_at: Vector3, dv: float) -> void:
	for e in events:
		match str(e.get("kind", "")):
			"part":
				_lose_part(e, local_at, dv)
			"popped":
				_set_wheel(int(e["wheel"]), e)
			"lost":
				_set_wheel(int(e["wheel"]), e)
				_throw_wheel(int(e["wheel"]), e, local_at, dv)

		broke.emit(e)


func _kick(from_local: Vector3, centre_local: Vector3, dv: float) -> Vector3:
	var away := body.global_basis * (centre_local - from_local)
	away.y = maxf(away.y, 0.0) + 0.5
	return away.normalized() * minf(dv * kick_share, kick_most)


func _point_velocity(local: Vector3) -> Vector3:
	return body.linear_velocity + body.angular_velocity.cross(body.global_basis * local)


func _lose_part(e: Dictionary, local_at: Vector3, dv: float) -> void:
	var part: DotVehicleDamage.Part = damage.parts[e["id"]]
	e["at"] = body.to_global(part.centre)

	if not e.has("velocity"):
		e["velocity"] = _point_velocity(part.centre) + (_kick(local_at, part.centre, dv) if dv > 0.0 else Vector3.ZERO)

	if part.mass > 0.0 and simulate:
		var floor_mass := _start_mass * min_mass_fraction
		var take := minf(part.mass, maxf(body.mass - floor_mass, 0.0))
		body.mass -= take
		mass_taken += take

	var node: Node3D = _parts.get(part.id, null)

	if node == null or not is_instance_valid(node) or not node.visible:
		return

	_throw_copy(node, e["velocity"], body.global_basis * Vector3(2.0, 1.0, -1.5), maxf(part.mass, 15.0))


## The drawn [param node] is hidden and a copy of it thrown, so a repair only has to show it
## again, whatever the debris has done with the copy since.
func _throw_copy(node: Node3D, velocity: Vector3, spin: Vector3, mass: float) -> void:
	if debris != null and node.is_inside_tree():
		var copy := node.duplicate() as Node3D
		node.get_parent().add_child(copy)
		copy.transform = node.transform
		var _b := debris.throw(copy, velocity, spin, mass)

	node.visible = false


func _set_wheel(i: int, _e: Dictionary) -> void:
	if i < 0 or i >= _wheels.size():
		return

	var wheel := _wheels[i]
	var state := damage.wheel_state(i)
	_e["at"] = wheel.global_position

	match state:
		DotVehicleDamage.Wheel.POPPED:
			wheel.wheel_radius = _radius[i] * damage.popped_radius
		DotVehicleDamage.Wheel.LOST:
			wheel.wheel_radius = _radius[i] * damage.hub_radius
			if not wheel.has_meta(&"dot_breakage_traction"):
				wheel.set_meta(&"dot_breakage_traction", wheel.use_as_traction)
			wheel.use_as_traction = false
		_:
			wheel.wheel_radius = _radius[i]

	if chassis != null:
		chassis.set_wheel_grip(wheel, damage.grip_of(i))
	else:
		wheel.wheel_friction_slip *= damage.grip_of(i)

	# The drawn tyre goes down with the radius.
	for child in wheel.get_children():
		if child is Node3D:
			if not child.has_meta(&"dot_breakage_scale"):
				child.set_meta(&"dot_breakage_scale", (child as Node3D).scale)
			var base: Vector3 = child.get_meta(&"dot_breakage_scale")
			(child as Node3D).scale = base * (damage.popped_radius if state == DotVehicleDamage.Wheel.POPPED else 1.0)


func _throw_wheel(i: int, e: Dictionary, local_at: Vector3, dv: float) -> void:
	if i < 0 or i >= _wheels.size():
		return

	var wheel := _wheels[i]
	var local := wheel.position

	if not e.has("velocity"):
		# A wheel that comes off rolls on: the body's speed there, and away from the hit.
		e["velocity"] = _point_velocity(local) + (_kick(local_at, local, dv) if dv > 0.0 else Vector3.ZERO) * 0.5

	for child in wheel.get_children():
		var drawn := child as Node3D

		if drawn == null or not drawn.visible:
			continue

		var spin := body.global_basis * Vector3(-(e["velocity"] as Vector3).length() / maxf(_radius[i], 0.1), 0.0, 0.0)
		_throw_copy(drawn, e["velocity"], spin, 60.0)


## Puts every thrown or hidden part back where it was drawn (a respawn).
func _restore_all() -> void:
	for id: StringName in _parts:
		var node: Node3D = _parts[id]
		if is_instance_valid(node):
			node.visible = true

	for i in _wheels.size():
		var wheel := _wheels[i]
		_set_wheel(i, {})
		wheel.use_as_traction = bool(wheel.get_meta(&"dot_breakage_traction", wheel.use_as_traction))
		wheel.remove_meta(&"dot_breakage_traction")
		for child in wheel.get_children():
			if child is Node3D:
				(child as Node3D).visible = true

	if simulate and mass_taken > 0.0:
		body.mass += mass_taken
		mass_taken = 0.0


func describe() -> Dictionary:
	var out := damage.describe() if damage != null else {}
	out["simulate"] = simulate
	out["mass_taken"] = mass_taken
	return out


func describe_lines() -> PackedStringArray:
	return damage.describe_lines() if damage != null else PackedStringArray()
