class_name DotVehicleRide
extends RefCounted

## Getting in and getting out. The half of a vehicle every game gets wrong.
##
## [b]The handover is the hard part, not the driving.[/b] A player in a vehicle is a
## player their controller must stop simulating, whose camera belongs to the vehicle,
## whose collision is the vehicle's, and who has to be put back [i]somewhere legal[/i]
## when they get out — with the vehicle possibly upside down, against a cliff, or moving
## at 30 m/s. Suspension has prior art in every engine; this does not, and it is where
## the bugs are.
##
## [b]Exit placement is a query, not a constant.[/b] A seat that carried "put them down
## here" as a fixed offset is a way through walls: park against a rock face and the
## offset is inside the rock. So a seat carries candidates in preference order, this
## sweeps a body-sized shape at each in turn, and [b]refuses the exit when none of them
## is free[/b]. Refusing is the correct answer. Every game that teleports the player
## anyway has this bug, and it is how players get outside a map.
##
## [b]What this addon does NOT know is what a rider is.[/b] Stopping a controller,
## moving a camera and hiding a mesh are the game's, and they arrive as callables. What
## this owns is the bookkeeping nobody can get right twice: who is in what, what their
## node's parent and collision were before, and where they may be put down.

const CHANNEL := "vehicle.ride"

## A rider got in.
signal entered(vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat)

## A rider got out. [param at] is where they were put down.
signal exited(
	vehicle: DotVehicleInstance, rider_id: StringName, seat: DotVehicleSeat, at: Vector3
)

## An enter or exit was refused, and why. For telling the player.
##
## [b]Emitted rather than swallowed.[/b] "I pressed use and nothing happened" is the
## commonest complaint about vehicles and the reason is almost always one the player
## could have been told: the seat is taken, they are going too fast, there is a wall
## where they would have got out.
signal refused(rider_id: StringName, vehicle_id: StringName, reason: String)

## Called when a rider is seated: `func(rider_id, vehicle, seat) -> void`.
##
## Where a game stops its own controller, parents its camera and switches its input.
## dot-vehicle cannot do any of that without naming dot-player-controller, and naming it
## would make this addon fail to parse in a project that does not have it.
var on_seated: Callable = Callable()

## Called when a rider is put down: `func(rider_id, vehicle, seat, at) -> void`.
var on_unseated: Callable = Callable()

## Physics mask the exit sweep tests against.
var exit_mask: int = 1

## Whether this manager reparents rider nodes into their seats.
##
## [b]On, and a game that draws its riders differently turns it off.[/b] A first-person
## game with no visible body has nothing to reparent and would rather its player node
## stayed where it was; a third-person game needs the body to move with the vehicle, and
## reparenting is the only way that survives a vehicle rolling over.
var carry_rider_nodes: bool = true

## Rider id -> instance id of the vehicle they are in.
##
## The reverse index of [member DotVehicleInstance.occupants]. Both exist because both
## questions are asked constantly: "who is in this vehicle" when it explodes, and "what
## is this player in" on every frame of their own input.
var _rider_vehicle: Dictionary = {}

## Rider id -> what their node was before they got in, so it can be put back.
var _stowed: Dictionary = {}

var enter_count: int = 0
var exit_count: int = 0
var refusal_count: int = 0


# --- Getting in ---------------------------------------------------------------

## Puts [param rider_id] into [param vehicle]. An empty [param seat_id] takes any seat.
##
## [param rider_node] may be null for a game that does not carry rider nodes.
func enter(
	vehicle: DotVehicleInstance,
	rider_id: StringName,
	rider_node: Node3D = null,
	seat_id: StringName = &""
) -> DotResult:
	if vehicle == null or not vehicle.is_alive():
		return _refuse(rider_id, &"", "That vehicle is not there any more.")

	if rider_id == &"":
		return _refuse(rider_id, vehicle.def.id, "A rider needs an id.")

	if _rider_vehicle.has(rider_id):
		# Refused rather than silently moved. A player who is already in something and
		# presses use on another vehicle should be told, not teleported out of a moving
		# car — and a game that wants the transfer can call `exit` and then `enter`.
		return _refuse(
			rider_id, vehicle.def.id, "You are already in a vehicle."
		)

	var seat := (
		vehicle.def.get_seat(seat_id) if seat_id != &"" else vehicle.first_free_seat()
	)

	if seat == null:
		return _refuse(
			rider_id, vehicle.def.id,
			"No such seat." if seat_id != &"" else "That vehicle is full."
		)

	if vehicle.is_seat_taken(seat.id):
		return _refuse(rider_id, vehicle.def.id, "That seat is taken.")

	vehicle.occupants[seat.id] = rider_id
	_rider_vehicle[rider_id] = vehicle.instance_id

	if carry_rider_nodes and rider_node != null:
		_stow(rider_id, rider_node, vehicle, seat)

	enter_count += 1

	if on_seated.is_valid():
		on_seated.call(rider_id, vehicle, seat)

	entered.emit(vehicle, rider_id, seat)

	return DotResult.success(seat)


## Parks the rider's node in the seat and remembers what it was doing.
func _stow(
	rider_id: StringName,
	rider_node: Node3D,
	vehicle: DotVehicleInstance,
	seat: DotVehicleSeat
) -> void:
	var attach: Node = vehicle.node

	if seat.attach_path != ^"":
		var found := vehicle.node.get_node_or_null(seat.attach_path)

		if found != null:
			attach = found
		else:
			# A seat naming a node the scene does not have is a content error, and the
			# rider still has to go somewhere. Falling back to the root is right; doing
			# it silently is not, because the seat will be a metre out for ever and
			# nobody will know which of the two things is wrong.
			DotLog.warn(CHANNEL, "a seat names a node its vehicle does not have", {
				"vehicle": String(vehicle.def.id),
				"seat": String(seat.id),
				"path": String(seat.attach_path),
			})

	var record := {
		"node": rider_node,
		"parent": rider_node.get_parent(),
		"transform": rider_node.global_transform,
		"layer": 0,
		"mask": 0,
		"had_collision": false,
	}

	var collider := rider_node as CollisionObject3D

	if collider != null:
		# Taken out of the physics world rather than left in it. A rider still colliding
		# inside the vehicle they are riding is two bodies overlapping at every tick:
		# the solver pushes them apart, the vehicle is shoved by its own passenger, and
		# at speed the pair of them end up somewhere neither should be.
		record["layer"] = collider.collision_layer
		record["mask"] = collider.collision_mask
		record["had_collision"] = true
		collider.collision_layer = 0
		collider.collision_mask = 0

	_stowed[rider_id] = record

	var parent := rider_node.get_parent()

	if parent != null:
		parent.remove_child(rider_node)

	attach.add_child(rider_node)
	rider_node.position = seat.seat_offset
	rider_node.rotation = Vector3.ZERO


# --- Getting out --------------------------------------------------------------

## Takes [param rider_id] out of whatever they are in, if there is room to stand.
func exit(
	vehicle: DotVehicleInstance, rider_id: StringName, force: bool = false
) -> DotResult:
	if vehicle == null or not vehicle.is_alive():
		# The vehicle went away underneath them — destroyed, or removed by an admin.
		# The bookkeeping still has to be undone or the rider can never enter anything
		# again, so this is not an error path.
		return _eject(rider_id, Vector3.ZERO)

	var seat_id := vehicle.seat_of(rider_id)

	if seat_id == &"":
		return _refuse(rider_id, vehicle.def.id, "You are not in that vehicle.")

	var seat := vehicle.def.get_seat(seat_id)
	var tunables := vehicle.def.tuning()

	if not force:
		var allowed := may_exit(vehicle, tunables)

		if not allowed.ok:
			return _refuse(rider_id, vehicle.def.id, allowed.error.message)

	var placement := find_exit_position(vehicle, seat)

	if not placement.ok and not force:
		return _refuse(rider_id, vehicle.def.id, placement.error.message)

	# A forced exit with nowhere to stand still has to put them somewhere, and the
	# vehicle's own position is the least bad answer: it is inside the vehicle, which is
	# a place the game already accepted, rather than inside whatever the sweep hit.
	var at: Vector3 = placement.value if placement.ok else vehicle.position()

	vehicle.occupants.erase(seat_id)

	var result := _eject(rider_id, at)

	exit_count += 1

	if on_unseated.is_valid():
		on_unseated.call(rider_id, vehicle, seat, at)

	exited.emit(vehicle, rider_id, seat, at)

	return result


## Whether anybody may get out of [param vehicle] right now.
func may_exit(
	vehicle: DotVehicleInstance, tunables: DotVehicleTunables = null
) -> DotResult:
	var tuning := tunables if tunables != null else vehicle.def.tuning()

	# Checked FIRST, and it overrides the speed rule rather than adding to it.
	#
	# The one state a player must always be able to leave is the one they cannot drive
	# out of. A rule that kept somebody in an overturned vehicle because it was still
	# sliding is a rule that kills them, and they will report it as the vehicle being
	# broken rather than as a rule.
	if vehicle.is_inverted() and tuning.allow_exit_when_inverted:
		return DotResult.success(null)

	if tuning.max_exit_speed > 0.0 and vehicle.speed() > tuning.max_exit_speed:
		return DotResult.fail(
			DotError.CODE_STATE,
			"You are going too fast to get out.",
			"%.1f m/s of %.1f m/s" % [vehicle.speed(), tuning.max_exit_speed]
		)

	return DotResult.success(null)


## Where [param seat]'s rider would be put down, or a refusal.
##
## Sweeps the seat's candidates in order and returns the first with room. Public,
## because a game wants to grey out the "get out" prompt rather than let a player press
## it and be told no.
func find_exit_position(
	vehicle: DotVehicleInstance, seat: DotVehicleSeat
) -> DotResult:
	if vehicle == null or not vehicle.is_alive() or seat == null:
		return DotResult.fail(DotError.CODE_INVALID, "Nothing to get out of.")

	var transform := vehicle.node.global_transform
	var space := vehicle.node.get_world_3d().direct_space_state

	if space == null:
		# No physics world means nothing to be blocked by. Returning a refusal here
		# would make every exit impossible in a scene that has not been added to a
		# viewport, which is the state a suite building a vehicle by hand is in.
		return DotResult.success(transform * seat.exit_offsets[0])

	var shape := CapsuleShape3D.new()
	shape.radius = seat.exit_clearance
	shape.height = seat.exit_height

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = exit_mask
	query.exclude = _exclusions(vehicle)

	for offset in seat.exit_offsets:
		var candidate := transform * offset

		# The capsule is centred on the rider's middle, not on their feet. A sweep at
		# the exit position itself tests the space around their ankles and finds a
		# doorway they cannot fit through standing up.
		query.transform = Transform3D(Basis.IDENTITY, candidate + Vector3.UP * seat.exit_height * 0.5)

		if space.intersect_shape(query, 1).is_empty():
			return DotResult.success(candidate)

	return DotResult.fail(
		DotError.CODE_STATE,
		"There is no room to get out here.",
		"%d places tried" % seat.exit_offsets.size()
	)


## The RIDs the exit sweep must ignore: the vehicle, and everybody in it.
##
## [b]Everybody in it, not only the vehicle.[/b] A rider whose collision was restored
## before the sweep would block their own exit, and a second passenger sitting where the
## first is about to stand would block theirs — which is a two-seater nobody can get out
## of, and it only happens with two people in it.
func _exclusions(vehicle: DotVehicleInstance) -> Array[RID]:
	var out: Array[RID] = []

	var body := vehicle.body()

	if body != null:
		out.append(body.get_rid())

	# Keyed by SEAT, valued by rider. Iterating a Dictionary in GDScript walks its keys,
	# so the obvious `for rider_id in vehicle.occupants` walks seat ids and looks nothing
	# up — which is a sweep that excludes nobody, an exit blocked by the passenger
	# already sitting in it, and a two-seater nobody can get out of once it has two
	# people in it.
	for seat_id in vehicle.occupants:
		var record: Variant = _stowed.get(StringName(vehicle.occupants[seat_id]))

		if not (record is Dictionary):
			continue

		var node := (record as Dictionary).get("node")

		if node is CollisionObject3D and is_instance_valid(node):
			out.append((node as CollisionObject3D).get_rid())

	return out


## Undoes the stow: puts the node back where it came from, at [param at].
func _eject(rider_id: StringName, at: Vector3) -> DotResult:
	_rider_vehicle.erase(rider_id)

	var found: Variant = _stowed.get(rider_id)

	if not (found is Dictionary):
		return DotResult.success(at)

	var record: Dictionary = found
	_stowed.erase(rider_id)

	var node := record.get("node") as Node3D

	if node == null or not is_instance_valid(node):
		return DotResult.success(at)

	var parent := node.get_parent()

	if parent != null:
		parent.remove_child(node)

	var restore_to := record.get("parent") as Node

	if restore_to != null and is_instance_valid(restore_to):
		restore_to.add_child(node)
	else:
		# The world they came from is gone — a map change, or their spawn point being
		# freed. Left in the vehicle's tree rather than orphaned, because an orphaned
		# node leaks and a node in the wrong parent is visible.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The rider's world went away while they were riding.",
			String(rider_id)
		)

	node.global_transform = Transform3D(Basis.IDENTITY, at)

	if bool(record.get("had_collision", false)):
		var collider := node as CollisionObject3D
		collider.collision_layer = int(record.get("layer", 1))
		collider.collision_mask = int(record.get("mask", 1))

	return DotResult.success(at)


# --- Queries ------------------------------------------------------------------

## The instance id of what [param rider_id] is in, or 0.
func vehicle_id_of(rider_id: StringName) -> int:
	return int(_rider_vehicle.get(rider_id, 0))


func is_riding(rider_id: StringName) -> bool:
	return _rider_vehicle.has(rider_id)


func rider_count() -> int:
	return _rider_vehicle.size()


func _refuse(
	rider_id: StringName, vehicle_id: StringName, reason: String
) -> DotResult:
	refusal_count += 1
	refused.emit(rider_id, vehicle_id, reason)

	return DotResult.fail(DotError.CODE_FORBIDDEN, reason)


func describe() -> Dictionary:
	return {
		"riding": _rider_vehicle.size(),
		"entered": enter_count,
		"exited": exit_count,
		"refused": refusal_count,
		"carries_nodes": carry_rider_nodes,
	}
