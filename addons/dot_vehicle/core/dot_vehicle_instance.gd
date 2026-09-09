class_name DotVehicleInstance
extends RefCounted

## One vehicle in the world: its definition, its body, who is in it and its chassis.
##
## [b]The state is kept here and not on the node[/b], for [DotPropInstance]'s reason:
## metadata on a node is invisible to anything that did not put it there and unreachable
## once the node is freed — and the moment a vehicle's state matters most is the moment
## it is destroyed with three people in it.

var def: DotVehicleDef = null

## The body in the world. May be freed; check with [method is_alive].
var node: Node3D = null

## Godot's instance id for [member node]. The handle everything else uses.
##
## An int rather than the node, because a comparison against a freed [Node] is
## undefined and an int is an int.
var instance_id: int = 0

## Who spawned it: a player id, a director's id, or empty for the map.
var owner_id: StringName = &""

## Simulated seconds when it was spawned. Never a wall clock.
var spawned_at: float = 0.0

## Whether the spawner still considers this vehicle to exist.
##
## Separate from the node being valid, and it has to be: `queue_free()` is deferred, so
## `is_instance_valid` stays true for the rest of the frame after a vehicle is removed.
var alive: bool = true

var health: float = 0.0

## Seat id -> rider id. The occupancy, and the authority on who is where.
##
## [b]Kept here rather than on the rider[/b] because the question asked far more often
## is "who is in this vehicle" — a shot that hit it, an explosion, a vehicle being
## removed with people in it — and a per-rider record would have to be scanned to answer
## it. [DotVehicleRide] keeps the reverse index for the other direction.
var occupants: Dictionary = {}

## The chassis driving it, or null for [constant DotVehicleDef.Kind.CUSTOM].
var chassis: RefCounted = null

## The command last accepted from the driver. Applied every tick until replaced.
##
## [b]Held rather than consumed, deliberately.[/b] A driver's input arrives at their
## frame rate and the vehicle is simulated at the server's tick rate, so a command that
## was consumed once would give a vehicle that accelerates in stutters on any client
## whose frame rate is below the tick rate — which is every client on a 128-tick server.
var command: DotVehicleCommand = null

var meta: Dictionary = {}


func is_alive() -> bool:
	return alive and node != null and is_instance_valid(node)


func body() -> RigidBody3D:
	return node as RigidBody3D if is_alive() and node is RigidBody3D else null


func position() -> Vector3:
	return node.global_position if is_alive() else Vector3.ZERO


func velocity() -> Vector3:
	var rigid := body()
	return rigid.linear_velocity if rigid != null else Vector3.ZERO


func speed() -> float:
	return velocity().length()


## Speed along the vehicle's own forward. Negative when reversing.
##
## [b]Not the same as [method speed] and it is the one the rules want.[/b] A vehicle
## sliding sideways off a cliff has a large speed and is not going anywhere; a rule
## refusing an exit at speed should let that player out.
func forward_speed() -> float:
	if not is_alive():
		return 0.0

	return velocity().dot(-node.global_transform.basis.z)


## Whether the vehicle is more upside down than not.
func is_inverted() -> bool:
	if not is_alive():
		return false

	return node.global_transform.basis.y.dot(Vector3.UP) < 0.0


func seat_of(rider_id: StringName) -> StringName:
	for seat_id in occupants:
		if StringName(occupants[seat_id]) == rider_id:
			return seat_id

	return &""


func has_rider(rider_id: StringName) -> bool:
	return seat_of(rider_id) != &""


func is_seat_taken(seat_id: StringName) -> bool:
	return occupants.has(seat_id)


func occupant_count() -> int:
	return occupants.size()


func is_empty() -> bool:
	return occupants.is_empty()


func is_full() -> bool:
	return def != null and occupants.size() >= def.seat_count()


## Who is driving, or empty. The first driving seat with somebody in it.
func driver() -> StringName:
	if def == null:
		return &""

	for seat in def.driver_seats():
		if occupants.has(seat.id):
			return StringName(occupants[seat.id])

	return &""


## The first seat nobody is in, or null. Definition order, so the driver comes first.
func first_free_seat() -> DotVehicleSeat:
	if def == null:
		return null

	for seat in def.seats:
		if not occupants.has(seat.id):
			return seat

	return null


func health_fraction() -> float:
	if def == null or def.max_health <= 0.0:
		return 1.0

	return clampf(health / def.max_health, 0.0, 1.0)


func is_destructible() -> bool:
	return def != null and def.max_health > 0.0


func describe() -> Dictionary:
	return {
		"vehicle": String(def.id) if def != null else "?",
		"owner": String(owner_id),
		"alive": is_alive(),
		"riders": "%d/%d" % [
			occupants.size(), def.seat_count() if def != null else 0
		],
		"driver": String(driver()) if driver() != &"" else "-",
		"speed": "%.1f m/s" % speed(),
		"inverted": is_inverted(),
	}


func _to_string() -> String:
	return "DotVehicleInstance(%s, %d aboard)" % [
		String(def.id) if def != null else "?", occupants.size()
	]
