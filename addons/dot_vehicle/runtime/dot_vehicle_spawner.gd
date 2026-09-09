@tool
class_name DotVehicleSpawner
extends Node

## Spawns, drives, seats and removes vehicles. The node a game with vehicles adds.
##
## [b]Server-authoritative, and a vehicle is not predicted.[/b] The same decision
## dot-props and dot-npc make, and here it costs the most: it is the [i]driver's own
## input[/i] going round trip, which is exactly what prediction exists to hide.
##
## It was considered properly and rejected anyway. A vehicle is a rigid body with a
## contact solver under it; the solver's iteration order, island membership and the last
## bits of every float differ between two machines, so two runs of the same drive
## diverge in a second or two. A predicted vehicle is therefore a corrected vehicle, and
## a correction on something a player is steering reads far worse than latency does:
## latency is a delay, and a correction is the vehicle moving somewhere the player did
## not put it.
##
## [b]What IS honest is smoothing.[/b] A driver's client can interpolate the replicated
## transform toward where it is going, which hides the snapshot rate without inventing
## any physics. That is the game's to do in its renderer, and it is why
## [DotVehicleNetSync] marks the transform interpolated.
##
## [codeblock]
## var vehicles := DotVehicleSpawner.new()
## vehicles.catalogue = catalogue
## vehicles.world_ref = DotNodeRef.of_path(^"../World")
## vehicles.authoritative = true
## add_child(vehicles)
##
## var jeep := vehicles.spawn(&"jeep", at, &"alice")
## vehicles.ride.enter(jeep, &"alice", alice_node)
##
## # Every simulated tick:
## vehicles.set_command(jeep.instance_id, &"alice", command)
## vehicles.tick(delta)
## [/codeblock]

const CHANNEL := "vehicle"

signal spawned(vehicle: DotVehicleInstance)

## A vehicle left the world. [param reason] is one of the REASON_* constants.
signal removed(vehicle: DotVehicleInstance, reason: StringName)

## It was destroyed. Fired before [signal removed], while the node still exists.
signal destroyed(vehicle: DotVehicleInstance, by: StringName)

signal refused(owner_id: StringName, vehicle_id: StringName, reason: String)

const REASON_DESTROYED := &"destroyed"
const REASON_LEFT := &"left"
const REASON_CLEANUP := &"cleanup"
const REASON_ADMIN := &"admin"

@export_group("Content")

@export var catalogue: DotVehicleCatalogue = null

@export_group("Limits")

## Most vehicles in the world at once, counted in [member DotVehicleDef.cost].
## 0 = unlimited.
@export_range(0, 1000, 1) var world_budget: int = 40

## Most one player may have out at once. 0 = unlimited.
@export_range(0, 100, 1) var per_player_budget: int = 4

## Seconds between one player's spawns. 0 = no wait.
@export_range(0.0, 60.0, 0.1) var spawn_interval: float = 1.0

## Whether a player's vehicles are removed when they leave.
##
## [b]Off by default, and the opposite of dot-props'.[/b] A prop is a thing somebody
## built and a vehicle is a thing somebody parked, usually with other people in it —
## removing it when the driver disconnects deletes the car three passengers are riding
## in. A server that wants the other behaviour turns this on.
@export var clean_up_on_leave: bool = false

@export_group("Wiring")

## Where spawned vehicles are added. Defaults to this node.
@export var world_ref: DotNodeRef = null

@export_group("Role")

## Whether this spawner may actually create vehicles. False on a client.
@export var authoritative: bool = false

## Getting in and getting out. Built here so a game has one to wire callbacks onto.
var ride: DotVehicleRide = null

## Instance id -> DotVehicleInstance.
var _vehicles: Dictionary = {}

## Owner id -> Array[int] of instance ids.
var _by_owner: Dictionary = {}

## Owner id -> simulated seconds when they last spawned one.
var _last_spawn: Dictionary = {}

## Simulated seconds. Advanced by [method tick], never a wall clock.
var _now: float = 0.0

var _world: Node = null

var spawn_count: int = 0
var refusal_count: int = 0
var destroy_count: int = 0


func _init() -> void:
	# Built in `_init` rather than in `_ready`, because a host wires `on_seated` onto it
	# straight after `new()` and before `add_child` — which is the order every example
	# in this family is written in, and a null there is a crash in the host's own setup.
	ride = DotVehicleRide.new()


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if catalogue == null:
		DotLog.warn(CHANNEL, "the vehicle spawner has no catalogue", {})


# --- The tick -----------------------------------------------------------------

## One simulated tick: every vehicle applies the command it is holding.
##
## Called by the game's simulation at the game's fixed rate, exactly as dot-npc's
## spawner and dot-match are — so handling does not change with the frame rate and a
## headless suite can drive a thousand ticks in no time at all.
func tick(delta: float) -> void:
	if not authoritative:
		return

	_now += delta

	# A copy, because a chassis may destroy its own vehicle — running out of fuel, or
	# an explosion — and removing from the dictionary being iterated skips every other
	# one.
	var ids: Array = _vehicles.keys()

	for id in ids:
		var found: Variant = _vehicles.get(id)

		if not (found is DotVehicleInstance):
			continue

		var vehicle: DotVehicleInstance = found

		if not vehicle.is_alive() or vehicle.chassis == null:
			continue

		# A vehicle with nobody driving it still gets a tick, with no command: it has
		# to coast, roll down hills and be stopped by its own brakes. Skipping empty
		# vehicles is what gives a parked car that ignores gravity on a slope.
		var command := vehicle.command if vehicle.driver() != &"" else null

		(vehicle.chassis as DotVehicleChassis).drive(command, delta)


## Hands a vehicle the driver's latest input.
##
## Refused when [param rider_id] is not the one driving, on the server, on every
## command — a client is a program the player can edit, and a passenger who could send
## a throttle would be driving from the back seat.
func set_command(
	instance_id: int, rider_id: StringName, command: DotVehicleCommand
) -> DotResult:
	var vehicle := get_vehicle(instance_id)

	if vehicle == null or not vehicle.is_alive():
		return DotResult.fail(DotError.CODE_STATE, "That vehicle is not there.")

	if vehicle.driver() != rider_id:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "You are not driving that vehicle."
		)

	vehicle.command = command

	if command != null and command.exit_requested:
		# Acted on here rather than left to the game, because the exit rules and the
		# placement sweep are this addon's and a game that had to remember to check
		# `exit_requested` is a game where one code path forgets.
		command.exit_requested = false
		return ride.exit(vehicle, rider_id)

	return DotResult.success(null)


# --- Spawning -----------------------------------------------------------------

## Spawns one vehicle. Null on refusal, with [signal refused] emitted.
func spawn(
	vehicle_id: StringName,
	at: Vector3,
	owner_id: StringName = &"",
	orientation: Basis = Basis.IDENTITY,
	entitlements: Callable = Callable()
) -> DotVehicleInstance:
	if not authoritative:
		_refuse(owner_id, vehicle_id, "This client may not spawn vehicles.")
		return null

	if catalogue == null:
		_refuse(owner_id, vehicle_id, "This server has no vehicle catalogue.")
		return null

	var def := catalogue.get_vehicle(vehicle_id)

	if def == null or not def.enabled:
		_refuse(owner_id, vehicle_id, "No such vehicle.")
		return null

	if def.entitlement != &"" and entitlements.is_valid():
		if not bool(entitlements.call(def.entitlement)):
			_refuse(owner_id, vehicle_id, "You do not have that vehicle.")
			return null

	var allowed := may_spawn(def, owner_id)

	if not allowed.ok:
		_refuse(owner_id, vehicle_id, allowed.error.message)
		return null

	if not ResourceLoader.exists(def.scene_path):
		# Distinguished from "no such vehicle" because the two need different fixes:
		# this one is a pack that is not mounted.
		_refuse(owner_id, vehicle_id, "That vehicle's content is not loaded here.")
		return null

	var scene: Resource = load(def.scene_path)

	if not (scene is PackedScene):
		_refuse(owner_id, vehicle_id, "That vehicle's scene is not a PackedScene.")
		return null

	var resolved := _resolve_world()

	if not resolved.ok:
		_refuse(owner_id, vehicle_id, resolved.error.message)
		return null

	var node := (scene as PackedScene).instantiate()

	if not (node is Node3D):
		node.queue_free()
		_refuse(owner_id, vehicle_id, "That vehicle's scene is not a Node3D.")
		return null

	var body := node as Node3D
	body.global_transform = Transform3D(orientation, at)

	(resolved.value as Node).add_child(body)

	var vehicle := DotVehicleInstance.new()
	vehicle.def = def
	vehicle.node = body
	vehicle.instance_id = body.get_instance_id()
	vehicle.owner_id = owner_id
	vehicle.spawned_at = _now
	vehicle.health = def.max_health

	_vehicles[vehicle.instance_id] = vehicle

	if not _by_owner.has(owner_id):
		_by_owner[owner_id] = []

	(_by_owner[owner_id] as Array).append(vehicle.instance_id)

	_last_spawn[owner_id] = _now
	spawn_count += 1

	var built := attach_chassis(vehicle)

	if not built.ok:
		# The vehicle still exists, for dot-npc's reason: deleting it would hide which
		# scene was wrong. A car that will not drive is a thing an operator can see and
		# name, and the warning beside it says what to fix.
		DotLog.warn(CHANNEL, "a vehicle spawned without a chassis", {
			"vehicle": String(def.id),
			"why": built.error.message,
		})

	spawned.emit(vehicle)

	return vehicle


## Whether [param owner_id] may spawn one more of [param def] right now.
func may_spawn(def: DotVehicleDef, owner_id: StringName = &"") -> DotResult:
	if spawn_interval > 0.0 and _last_spawn.has(owner_id):
		var elapsed := _now - float(_last_spawn[owner_id])

		if elapsed < spawn_interval:
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Slow down.",
				"%.2f s of %.2f s" % [elapsed, spawn_interval]
			)

	if world_budget > 0 and world_cost() + def.cost > world_budget:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"The server is at its vehicle limit.",
			"%d of %d" % [world_cost(), world_budget]
		)

	if per_player_budget > 0:
		var mine := owner_cost(owner_id)

		if mine + def.cost > per_player_budget:
			return DotResult.fail(
				DotError.CODE_QUOTA,
				"You are at your vehicle limit.",
				"%d of %d" % [mine, per_player_budget]
			)

	return DotResult.success(null)


## Builds and binds the chassis a definition asks for.
##
## Loaded by path when the definition names one, for the reason in [DotVehicleChassis]:
## a `class_name` cannot be resolved inside a mounted pack.
func attach_chassis(vehicle: DotVehicleInstance) -> DotResult:
	if vehicle == null or vehicle.def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No vehicle to build a chassis for.")

	var def := vehicle.def
	var chassis: DotVehicleChassis = null

	if def.chassis_script_path != "":
		if not ResourceLoader.exists(def.chassis_script_path):
			return DotResult.fail(
				DotError.CODE_IO, "That chassis script is not here.",
				def.chassis_script_path
			)

		var script: Resource = load(def.chassis_script_path)

		if not (script is GDScript):
			return DotResult.fail(
				DotError.CODE_INVALID, "That chassis is not a GDScript.",
				def.chassis_script_path
			)

		var made: Variant = (script as GDScript).new()

		if not (made is DotVehicleChassis):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A chassis must extend dot_vehicle_chassis.gd.",
				def.chassis_script_path
			)

		chassis = made
	else:
		match def.kind:
			DotVehicleDef.Kind.WHEELED:
				chassis = DotVehicleWheeled.new()
			DotVehicleDef.Kind.HOVER:
				chassis = DotVehicleHover.new()
			DotVehicleDef.Kind.CUSTOM:
				# Driven by the game entirely. dot-vehicle keeps the seats and the
				# bookkeeping and touches nothing else, which is the whole meaning of
				# the kind — so this is a success with no chassis, not a failure.
				return DotResult.success(null)

	var bound := chassis.bind(vehicle, def.tuning())

	if not bound.ok:
		return bound

	vehicle.chassis = chassis

	return DotResult.success(chassis)


func _refuse(owner_id: StringName, vehicle_id: StringName, reason: String) -> void:
	refusal_count += 1
	refused.emit(owner_id, vehicle_id, reason)


# --- Damage -------------------------------------------------------------------

## Hurts a vehicle. Returns how much health it actually lost.
##
## A definition with `max_health` of 0 is indestructible and takes none — which is a
## real answer a sandbox wants, not an oversight.
func damage(instance_id: int, amount: float, by: StringName = &"") -> float:
	var vehicle := get_vehicle(instance_id)

	if not authoritative or vehicle == null or not vehicle.is_alive():
		return 0.0

	if not vehicle.is_destructible() or amount <= 0.0:
		return 0.0

	var before := vehicle.health
	vehicle.health = maxf(vehicle.health - amount, 0.0)

	if vehicle.health <= 0.0:
		destroy(instance_id, by)

	return before - vehicle.health


## Destroys a vehicle, putting everybody in it on the ground first.
func destroy(instance_id: int, by: StringName = &"") -> bool:
	var vehicle := get_vehicle(instance_id)

	if vehicle == null or not vehicle.alive:
		return false

	vehicle.health = 0.0
	destroy_count += 1

	# Everybody out BEFORE the node is freed, and forced, because there may be no room
	# to stand — a vehicle usually explodes somewhere awkward. A rider left in a freed
	# vehicle is a player whose node is parented to nothing: invisible, unkillable, and
	# unable to enter another vehicle for the rest of the round, with no error anywhere.
	_evacuate(vehicle)

	destroyed.emit(vehicle, by)

	return remove(instance_id, REASON_DESTROYED)


func _evacuate(vehicle: DotVehicleInstance) -> void:
	# Copied, because `exit` erases from `occupants` and iterating a dictionary while
	# erasing from it skips entries.
	var riders: Array = vehicle.occupants.values().duplicate()

	for rider in riders:
		ride.exit(vehicle, StringName(rider), true)


# --- Removing -----------------------------------------------------------------

func remove(instance_id: int, reason: StringName = REASON_ADMIN) -> bool:
	if not authoritative:
		return false

	var found: Variant = _vehicles.get(instance_id)

	if not (found is DotVehicleInstance):
		return false

	var vehicle: DotVehicleInstance = found

	if not vehicle.is_empty():
		_evacuate(vehicle)

	_vehicles.erase(instance_id)

	if _by_owner.has(vehicle.owner_id):
		(_by_owner[vehicle.owner_id] as Array).erase(instance_id)

	# Announced BEFORE the node is freed, so a listener holding a reference can let go
	# while it still exists.
	removed.emit(vehicle, reason)

	# Marked dead immediately, which is not the same as freeing the node: `queue_free`
	# is deferred and `is_instance_valid` stays true for the rest of the frame.
	vehicle.alive = false
	vehicle.chassis = null

	if vehicle.node != null and is_instance_valid(vehicle.node):
		vehicle.node.queue_free()

	return true


func clear_owner(owner_id: StringName, reason: StringName = REASON_CLEANUP) -> int:
	var found: Variant = _by_owner.get(owner_id)

	if not (found is Array):
		return 0

	# Copied before iterating: remove() mutates this array.
	var ids: Array = (found as Array).duplicate()
	var count := 0

	for id in ids:
		if remove(int(id), reason):
			count += 1

	_by_owner.erase(owner_id)
	_last_spawn.erase(owner_id)

	return count


func clear_all(reason: StringName = REASON_ADMIN) -> int:
	var ids: Array = _vehicles.keys()
	var count := 0

	for id in ids:
		if remove(int(id), reason):
			count += 1

	return count


## Called by the host when a player disconnects.
func owner_left(owner_id: StringName) -> int:
	if not clean_up_on_leave:
		# Disowned but kept, which is the default: removing a disconnected player's
		# vehicle deletes the car three passengers are riding in.
		_by_owner.erase(owner_id)
		_last_spawn.erase(owner_id)
		return 0

	return clear_owner(owner_id, REASON_LEFT)


# --- Queries ------------------------------------------------------------------

func get_vehicle(instance_id: int) -> DotVehicleInstance:
	var found: Variant = _vehicles.get(instance_id)
	return found if found is DotVehicleInstance else null


## The vehicle a node belongs to, or null. For a shot, or a "press use" trace.
func vehicle_for_node(node: Node) -> DotVehicleInstance:
	if node == null:
		return null

	# Walks up, because a query hits a collider that may be a child of the vehicle's
	# root — a wheel, a door, a turret.
	var walk := node

	while walk != null:
		var found: Variant = _vehicles.get(walk.get_instance_id())

		if found is DotVehicleInstance:
			return found

		walk = walk.get_parent()

	return null


## What [param rider_id] is riding in, or null.
func vehicle_of_rider(rider_id: StringName) -> DotVehicleInstance:
	return get_vehicle(ride.vehicle_id_of(rider_id))


## The nearest vehicle to [param point] with a free seat, within [param radius].
##
## What a "press use to get in" prompt asks. Nearest rather than first, because a player
## standing between two cars means the one they are looking at, and nearest is the
## cheapest approximation of that which does not need their camera.
func nearest_free(point: Vector3, radius: float) -> DotVehicleInstance:
	var best: DotVehicleInstance = null
	var best_sq := radius * radius

	for id in _vehicles:
		var vehicle: DotVehicleInstance = _vehicles[id]

		if not vehicle.is_alive() or vehicle.is_full():
			continue

		var d_sq := vehicle.position().distance_squared_to(point)

		if d_sq <= best_sq:
			best_sq = d_sq
			best = vehicle

	return best


func world_count() -> int:
	return _vehicles.size()


func world_cost() -> int:
	var total := 0

	for id in _vehicles:
		total += (_vehicles[id] as DotVehicleInstance).def.cost

	return total


func owner_cost(owner_id: StringName) -> int:
	var found: Variant = _by_owner.get(owner_id)

	if not (found is Array):
		return 0

	var total := 0

	for id in (found as Array):
		var vehicle: Variant = _vehicles.get(int(id))

		if vehicle is DotVehicleInstance:
			total += (vehicle as DotVehicleInstance).def.cost

	return total


## Every live vehicle. A copy, because callers walk it to decide what to remove.
func all_vehicles() -> Array[DotVehicleInstance]:
	var out: Array[DotVehicleInstance] = []

	for id in _vehicles:
		var vehicle: DotVehicleInstance = _vehicles[id]

		if vehicle.is_alive():
			out.append(vehicle)

	return out


func vehicles_of(owner_id: StringName) -> Array[DotVehicleInstance]:
	var out: Array[DotVehicleInstance] = []
	var found: Variant = _by_owner.get(owner_id, [])

	if not (found is Array):
		return out

	for id in (found as Array):
		var vehicle: Variant = _vehicles.get(int(id))

		if vehicle is DotVehicleInstance:
			out.append(vehicle)

	return out


func now() -> float:
	return _now


func _resolve_world() -> DotResult:
	if world_ref == null:
		return DotResult.success(self)

	if _world != null and is_instance_valid(_world):
		return DotResult.success(_world)

	var resolved := world_ref.resolve(self)

	if not resolved.ok:
		return resolved.wrap("Could not find where to put spawned vehicles.")

	_world = resolved.value

	return DotResult.success(_world)


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"vehicles": _vehicles.size(),
		"cost": world_cost(),
		"budget": world_budget,
		"spawned": spawn_count,
		"destroyed": destroy_count,
		"refused": refusal_count,
		"ride": ride.describe() if ride != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("vehicles     %d (%d of %d cost)" % [
		_vehicles.size(), world_cost(), world_budget
	])
	out.append("riders       %d" % (ride.rider_count() if ride != null else 0))
	out.append("spawned %d  destroyed %d  refused %d" % [
		spawn_count, destroy_count, refusal_count
	])

	for id in _vehicles:
		var vehicle: DotVehicleInstance = _vehicles[id]
		out.append("  %-16s %s, %d aboard, %.1f m/s" % [
			String(vehicle.def.id),
			String(vehicle.owner_id) if vehicle.owner_id != &"" else "map",
			vehicle.occupant_count(),
			vehicle.speed(),
		])

	return out
