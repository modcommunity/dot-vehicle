@tool
class_name DotVehicleCatalogue
extends Resource

## Every vehicle a server offers, and the file an operator edits.
##
## Same shape and the same reasoning as [code]DotPropCatalogue[/code] and
## [code]DotNpcCatalogue[/code]: plain JSON, because the person maintaining it on a
## community server is a person with a text editor; one bad entry does not condemn the
## file; an exact id match wins a search.

const CHANNEL := "vehicle.catalogue"

const FORMAT_VERSION := 1

@export var vehicles: Array[DotVehicleDef] = []

@export var meta: Dictionary = {}

var _by_id: Dictionary = {}


func add(def: DotVehicleDef) -> DotResult:
	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No vehicle to add.")

	var valid := def.validate()

	if not valid.ok:
		return valid

	if _by_id.size() != vehicles.size():
		_reindex()

	if _by_id.has(def.id):
		var existing: DotVehicleDef = _by_id[def.id]
		vehicles[vehicles.find(existing)] = def
		_by_id[def.id] = def
		return DotResult.success(def)

	vehicles.append(def)
	_by_id[def.id] = def

	return DotResult.success(def)


## Download every pack this catalogue's vehicles live in.
##
## [b]Nothing used to fetch these.[/b] A DotVehicleDef has carried a `content_id` since it was
## written and it is serialised onto the wire, but no code anywhere asked dot-cloud for
## one — so a delivered vehicle was refused with "that vehicle's content is not loaded",
## forever, on a server that had configured it perfectly. The refusal is correct and
## that is what made it invisible: it reads as a missing pack rather than as a fetch
## that never happens.
##
## [b]At load, not on demand.[/b] A spawn request is a player's, and turning one into a
## download would let a player make this machine fetch — repeatedly, from whatever a
## manifest names — by asking for something that is not there. The catalogue is known
## before anyone connects, so this is a boot-time cost paid once. It also keeps the
## spawn path synchronous, which is what every caller of it already assumes.
##
## Non-fatal by construction: a pack that will not download leaves that vehicle
## unspawnable and everything else working. See [method DotContent.ensure_all] for the
## shape of the answer.
func ensure_content() -> DotResult:
	if _by_id.size() != vehicles.size():
		_reindex()

	var ids := PackedStringArray()

	for entry in vehicles:
		if entry != null and String(entry.content_id) != "":
			ids.append(String(entry.content_id))

	return await DotContent.ensure_all(ids)


func get_vehicle(id: StringName) -> DotVehicleDef:
	if _by_id.size() != vehicles.size():
		_reindex()

	var found: Variant = _by_id.get(id)
	return found if found is DotVehicleDef else null


func has(id: StringName) -> bool:
	return get_vehicle(id) != null


func size() -> int:
	return vehicles.size()


func remove(id: StringName) -> bool:
	_reindex()

	if not _by_id.has(id):
		return false

	vehicles.erase(_by_id[id])
	_by_id.erase(id)

	return true


func _reindex() -> void:
	_by_id.clear()

	for def in vehicles:
		_by_id[def.id] = def


## Every category, in alphabetical order. For a spawn menu's tabs.
func categories() -> PackedStringArray:
	var seen := {}

	for def in vehicles:
		if def.enabled:
			seen[String(def.category)] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out


func in_category(category: StringName) -> Array[DotVehicleDef]:
	var out: Array[DotVehicleDef] = []

	for def in vehicles:
		if def.enabled and def.category == category:
			out.append(def)

	return out


## Vehicles with room for at least [param riders] people.
func seating_at_least(riders: int) -> Array[DotVehicleDef]:
	var out: Array[DotVehicleDef] = []

	for def in vehicles:
		if def.enabled and def.seat_count() >= riders:
			out.append(def)

	return out


## Vehicles whose id or name contains [param text]. An exact id wins outright.
func search(text: String, limit: int = 30) -> Array[DotVehicleDef]:
	var needle := text.strip_edges().to_lower()
	var out: Array[DotVehicleDef] = []

	if needle == "":
		return out

	var exact := get_vehicle(StringName(needle))

	if exact != null:
		out.append(exact)
		return out

	for def in vehicles:
		if out.size() >= limit:
			break
		if String(def.id).to_lower().contains(needle) \
				or def.display_name.to_lower().contains(needle):
			out.append(def)

	return out


func to_dictionary() -> Dictionary:
	var entries: Array = []

	for def in vehicles:
		entries.append(def.to_dictionary())

	return {
		"format": FORMAT_VERSION,
		"vehicles": entries,
		"meta": meta.duplicate(true),
	}


## Reads a catalogue, keeping the good entries and reporting the bad ones.
##
## [b]One bad entry does not condemn the file.[/b] A community server's catalogue is
## hand-edited, and refusing to boot because entry forty has a seat with no exits means
## the operator has no vehicles at all rather than thirty-nine.
static func from_dictionary(
	data: Dictionary, rejected: PackedStringArray = PackedStringArray()
) -> DotVehicleCatalogue:
	var cat := DotVehicleCatalogue.new()

	var raw: Variant = data.get("vehicles", [])

	if raw is Array:
		for entry in (raw as Array):
			if not (entry is Dictionary):
				rejected.append("not an object")
				continue

			var added := cat.add(DotVehicleDef.from_dictionary(entry as Dictionary))

			if not added.ok:
				rejected.append(added.error.message if added.error != null else "invalid")

	var meta_value: Variant = data.get("meta", {})
	cat.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return cat


func describe() -> Dictionary:
	return {
		"vehicles": vehicles.size(),
		"categories": categories().size(),
	}
