@tool
class_name DotVehicleSeat
extends Resource

## One place a rider can be, as data.
##
## [b]Seats are data because exit placement is a query, not a constant.[/b] A seat that
## carried "put them down here" as a fixed offset is a way through walls: the vehicle is
## against a cliff, or upside down, or moving at 30 m/s, and the offset puts a player
## inside the rock. So a seat carries a [i]list of candidates in preference order[/i],
## in the vehicle's local space, and [DotVehicleRide] sweeps them and refuses the exit
## when none of them is free. Refusing is the correct answer and every game that
## teleports the player anyway has the bug.

## Stable id, unique within one vehicle. What an enter request names.
@export var id: StringName = &"driver"

@export var display_name: String = ""

## Whether this seat drives.
##
## [b]More than one is legal and it is not a mistake.[/b] A tank has a driver and a
## gunner; a two-stick vehicle has two drivers. What is not legal is a vehicle with
## none, which [method DotVehicleDef.validate] refuses.
@export var drives: bool = false

## Where the rider is parented, relative to the vehicle's root. Empty for the root.
##
## A path rather than an offset, so the seat follows a moving part — a turret, a door,
## a sidecar — without anything having to re-derive its transform every tick.
@export var attach_path: NodePath = ^""

## Where the rider sits, relative to [member attach_path].
@export var seat_offset: Vector3 = Vector3.ZERO

@export_group("What a rider may do")

## Whether the rider may look around independently of the vehicle.
##
## Off for a seat whose view is the vehicle's — a driver in a first-person cockpit with
## a fixed camera — and on for a passenger.
@export var may_aim: bool = true

## Whether the rider may use a weapon from here.
##
## [b]Separate from [member may_aim] deliberately.[/b] A passenger who may look around
## but not shoot is the commonest seat in a co-op game, and a game that had one flag
## would have to choose between a blind passenger and an armed one.
@export var may_fire: bool = false

## How far the rider may turn from the seat's forward, in degrees. 180 is free.
@export_range(0.0, 180.0, 1.0) var aim_yaw_limit_deg: float = 180.0

@export_group("Getting out")

## Candidate exit positions in the vehicle's local space, in preference order.
##
## Swept in order; the first one with room wins. The default is the left side, then the
## right, then the back, then above — which is the order that keeps a player out of the
## road on a right-hand-drive world and, when everything else fails, drops them on the
## roof rather than nowhere.
@export var exit_offsets: Array[Vector3] = [
	Vector3(-2.0, 0.5, 0.0),
	Vector3(2.0, 0.5, 0.0),
	Vector3(0.0, 0.5, -3.0),
	Vector3(0.0, 2.5, 0.0),
]

## Radius of the space a rider needs to be put down in, in metres.
@export_range(0.1, 5.0, 0.05) var exit_clearance: float = 0.45

## Height of that space, in metres. A player is taller than they are wide, and a sweep
## with one number refuses every doorway or accepts every crawlspace.
@export_range(0.2, 5.0, 0.05) var exit_height: float = 1.8

@export var meta: Dictionary = {}


static func make(p_id: StringName, p_drives: bool = false) -> DotVehicleSeat:
	var seat := DotVehicleSeat.new()
	seat.id = p_id
	seat.drives = p_drives
	seat.display_name = String(p_id).capitalize()
	seat.may_fire = not p_drives
	return seat


func name_or_id() -> String:
	return display_name if display_name != "" else String(id)


func aim_yaw_limit() -> float:
	return deg_to_rad(aim_yaw_limit_deg)


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A seat needs an id.")

	if exit_offsets.is_empty():
		# Refused here rather than at exit time, because the moment a player discovers
		# a seat with no way out is the moment they are already in it.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A seat with no exit offsets is a seat nobody can get out of.",
			String(id)
		)

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	var offsets: Array = []

	for offset in exit_offsets:
		offsets.append([offset.x, offset.y, offset.z])

	var out := {
		"id": String(id),
		"drives": drives,
		"offset": [seat_offset.x, seat_offset.y, seat_offset.z],
		"exits": offsets,
		"clearance": exit_clearance,
		"height": exit_height,
	}

	if display_name != "":
		out["name"] = display_name
	if attach_path != ^"":
		out["attach"] = String(attach_path)
	if not may_aim:
		out["aim"] = false
	if may_fire:
		out["fire"] = true
	if aim_yaw_limit_deg < 180.0:
		out["yaw_limit"] = aim_yaw_limit_deg
	if not meta.is_empty():
		# Duplicated: a Dictionary is a reference in GDScript, so handing this one out
		# lets whoever serialises a seat edit the shared definition.
		out["meta"] = meta.duplicate(true)

	return out


static func from_dictionary(data: Dictionary) -> DotVehicleSeat:
	var seat := DotVehicleSeat.new()

	seat.id = StringName(str(data.get("id", "")))
	seat.display_name = str(data.get("name", ""))
	seat.drives = bool(data.get("drives", false))
	seat.attach_path = NodePath(str(data.get("attach", "")))
	seat.seat_offset = _to_vector(data.get("offset", null), Vector3.ZERO)
	seat.may_aim = bool(data.get("aim", true))
	seat.may_fire = bool(data.get("fire", false))
	seat.aim_yaw_limit_deg = clampf(float(data.get("yaw_limit", 180.0)), 0.0, 180.0)
	seat.exit_clearance = maxf(float(data.get("clearance", 0.45)), 0.1)
	seat.exit_height = maxf(float(data.get("height", 1.8)), 0.2)

	var raw: Variant = data.get("exits", [])

	if raw is Array:
		var offsets: Array[Vector3] = []

		for entry in (raw as Array):
			offsets.append(_to_vector(entry, Vector3.ZERO))

		if not offsets.is_empty():
			seat.exit_offsets = offsets

	var meta_value: Variant = data.get("meta", {})
	seat.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return seat


static func _to_vector(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var arr := value as Array
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))

	return fallback


func describe() -> Dictionary:
	return {
		"seat": String(id),
		"drives": drives,
		"aim": may_aim,
		"fire": may_fire,
		"exits": exit_offsets.size(),
	}


func _to_string() -> String:
	return "DotVehicleSeat(%s%s)" % [String(id), " driver" if drives else ""]
