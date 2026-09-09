@tool
class_name DotVehicleDef
extends Resource

## One kind of vehicle a game can spawn.
##
## [b]A definition, not a scene[/b] — the same shape and the same reasoning as
## [code]DotPropDef[/code], [code]DotNpcDef[/code] and [code]DotMapDef[/code]. A spawn
## menu listing thirty vehicles must not load thirty scenes, and a server checking
## whether a player may have one must answer without loading any.
##
## [b]The chassis script is named by PATH, never by [code]class_name[/code].[/b] A
## mounted dot-cloud pack arrives long after the project's script cache was built, so a
## global class inside one resolves to nothing. This is the same rule dot-npc's brains
## and game-playground's entities already follow.

## How a chassis behaves, when a game has not brought its own script.
##
## [b]An enum of the shipped kinds rather than a free string[/b], because this selects
## a class in this addon. Anything else is a [member chassis_script_path].
enum Kind {
	## Godot's [VehicleBody3D]: raycast wheels, engine force, brakes, steering.
	WHEELED,
	## A body held above the ground by springs, steered by torque. Hovercraft, skiffs.
	HOVER,
	## Driven by the game entirely. dot-vehicle handles the seats and nothing else.
	CUSTOM,
}

@export_group("Identity")

## Stable id. What a spawn request names and what a cap is keyed on.
@export var id: StringName = &""

@export var display_name: String = ""

## Menu grouping: [code]"car"[/code], [code]"boat"[/code], [code]"air"[/code].
@export var category: StringName = &"vehicle"

@export_group("Content")

## The scene instantiated on spawn. Its root must be a [RigidBody3D] for the shipped
## chassis kinds, because a raycast vehicle is a rigid body with wheels on it.
@export var scene_path: String = ""

## A chassis script, by path. Empty to use [member kind].
##
## See the class note: never a [code]class_name[/code], because a mounted pack has no
## way to register one.
@export var chassis_script_path: String = ""

## The dot-cloud content id this vehicle lives in, or empty when it ships in the build.
@export var content_id: StringName = &""

@export_group("Behaviour")

@export var kind: Kind = Kind.WHEELED

## Handling. Null falls back to [DotVehicleTunables]' own defaults.
@export var tunables: DotVehicleTunables = null

## Seats, in the order a player is put into them when they ask for "any".
##
## [b]Driver first is a convention this addon relies on and does not enforce.[/b]
## [method first_free_seat] walks this array in order, so a player entering an empty
## vehicle should end up driving it — which is what everybody expects and what nobody
## thinks to specify.
@export var seats: Array[DotVehicleSeat] = []

@export_group("Limits")

## What one of these costs against a world budget.
@export_range(1, 100, 1) var cost: int = 4

## Health, for a game that lets vehicles be destroyed. 0 means indestructible.
##
## Zero rather than absent, because "this vehicle cannot be destroyed" is a real answer
## a sandbox wants and a game with no combat should not have to pick a number.
@export_range(0.0, 100000.0, 1.0) var max_health: float = 0.0

@export_group("Permission")

## An admin permission required to spawn one by hand. Empty for anybody.
@export var permission: String = ""

## An entitlement id a player must hold. Empty for anybody.
@export var entitlement: StringName = &""

@export var enabled: bool = true

@export var meta: Dictionary = {}


static func make(p_id: StringName, p_scene: String) -> DotVehicleDef:
	var def := DotVehicleDef.new()
	def.id = p_id
	def.scene_path = p_scene
	def.display_name = String(p_id).capitalize()
	return def


func name_or_id() -> String:
	return display_name if display_name != "" else String(id)


func is_local() -> bool:
	return content_id == &""


func seat_count() -> int:
	return seats.size()


func get_seat(seat_id: StringName) -> DotVehicleSeat:
	for seat in seats:
		if seat.id == seat_id:
			return seat

	return null


func driver_seats() -> Array[DotVehicleSeat]:
	var out: Array[DotVehicleSeat] = []

	for seat in seats:
		if seat.drives:
			out.append(seat)

	return out


## The tunables, never null. Callers get defaults rather than a crash.
func tuning() -> DotVehicleTunables:
	return tunables if tunables != null else DotVehicleTunables.new()


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A vehicle needs an id.")

	if scene_path == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A vehicle needs a scene path.", String(id)
		)

	if chassis_script_path != "" and not chassis_script_path.ends_with(".gd"):
		# Caught here rather than at spawn, because a catalogue is loaded once at boot
		# and a spawn happens in the middle of a round.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"chassis_script_path must be a path to a .gd script, not a class name.",
			"%s: %s" % [String(id), chassis_script_path]
		)

	if seats.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A vehicle with no seats is scenery.",
			String(id)
		)

	var seen := {}

	for seat in seats:
		var valid := seat.validate()

		if not valid.ok:
			return valid.wrap("Seat on %s is not usable." % String(id))

		if seen.has(seat.id):
			# Two seats with one id makes `get_seat` return the first and every enter
			# request land in it, so the second seat is unreachable and the vehicle
			# quietly holds one fewer person than it says.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Two seats share an id.",
				"%s: %s" % [String(id), String(seat.id)]
			)

		seen[seat.id] = true

	if driver_seats().is_empty() and kind != Kind.CUSTOM:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A vehicle with no driving seat can never be driven.",
			String(id)
		)

	if tunables != null:
		var tuned := tunables.validate()

		if not tuned.ok:
			return tuned.wrap("Handling for %s is not usable." % String(id))

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	var seat_entries: Array = []

	for seat in seats:
		seat_entries.append(seat.to_dictionary())

	var out := {
		"id": String(id),
		"scene": scene_path,
		"category": String(category),
		"kind": kind,
		"cost": cost,
		"seats": seat_entries,
	}

	if display_name != "":
		out["name"] = display_name
	if chassis_script_path != "":
		out["chassis"] = chassis_script_path
	if content_id != &"":
		out["content"] = String(content_id)
	if max_health > 0.0:
		out["health"] = max_health
	if permission != "":
		out["permission"] = permission
	if entitlement != &"":
		out["entitlement"] = String(entitlement)
	if not enabled:
		out["enabled"] = false
	if tunables != null:
		out["tuning"] = tunables.to_dictionary()
	if not meta.is_empty():
		# Duplicated: a Dictionary is a reference in GDScript, so handing this one out
		# lets whoever serialises a vehicle edit the shared definition.
		out["meta"] = meta.duplicate(true)

	return out


static func from_dictionary(data: Dictionary) -> DotVehicleDef:
	var def := DotVehicleDef.new()

	def.id = StringName(str(data.get("id", "")))
	def.scene_path = str(data.get("scene", ""))
	def.display_name = str(data.get("name", ""))
	def.category = StringName(str(data.get("category", "vehicle")))
	def.chassis_script_path = str(data.get("chassis", ""))
	def.content_id = StringName(str(data.get("content", "")))
	def.kind = _to_kind(data.get("kind", Kind.WHEELED))
	def.cost = clampi(int(data.get("cost", 4)), 1, 100)
	def.max_health = maxf(float(data.get("health", 0.0)), 0.0)
	def.permission = str(data.get("permission", ""))
	def.entitlement = StringName(str(data.get("entitlement", "")))
	def.enabled = bool(data.get("enabled", true))

	var raw_seats: Variant = data.get("seats", [])

	if raw_seats is Array:
		var seats: Array[DotVehicleSeat] = []

		for entry in (raw_seats as Array):
			if entry is Dictionary:
				seats.append(DotVehicleSeat.from_dictionary(entry as Dictionary))

		def.seats = seats

	var raw_tuning: Variant = data.get("tuning", null)

	if raw_tuning is Dictionary:
		var tuning := DotVehicleTunables.new()
		tuning.apply_dictionary(raw_tuning as Dictionary)
		def.tunables = tuning

	var meta_value: Variant = data.get("meta", {})
	def.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return def


static func _to_kind(value: Variant) -> Kind:
	var raw := int(value)
	return raw as Kind if raw >= 0 and raw < Kind.size() else Kind.WHEELED


func describe() -> Dictionary:
	return {
		"id": String(id),
		"kind": Kind.keys()[kind],
		"seats": seats.size(),
		"drivers": driver_seats().size(),
		"cost": cost,
		"handling": tuning().describe_summary(),
	}


func _to_string() -> String:
	return "DotVehicleDef(%s, %d seats)" % [String(id), seats.size()]
