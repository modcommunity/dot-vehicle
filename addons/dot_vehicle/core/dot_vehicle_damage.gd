class_name DotVehicleDamage
extends RefCounted

## What a vehicle has lost: parts that come off and wheels whose tyre has burst or that have
## come away, as data. No node, no physics, no randomness.
##
## [b]A hit is a change of speed at a point[/b] (metres a second, in the body's own frame),
## never a force or an impulse: a bumper that stands a 4 m/s knock stands it on a van and on a
## loaded tipper, which is what lets one table of strengths serve every vehicle in a game. The
## part nearest the point takes the most of it ([member Part.reach] is how far a hit is felt),
## and a hit below [member min_share] of a part's strength is ignored, so a long scrape along a
## rail wears nothing off while one hard swipe takes the mirror.
##
## [b]Deterministic on purpose.[/b] The same hits in the same order break the same parts on any
## machine, and [method to_dict] / [method apply_dict] carry the result, so the server decides and
## a client only shows: what is lost replicates as a list of ids and a state per wheel, never as
## bodies. [DotVehicleBreakage] is the node that feeds it hits and makes the losses physical.

## How much of its strength a hit must reach before a part notices it at all.
var min_share: float = 0.3

## A burst tyre's grip, as a fraction of the intact one's.
var popped_grip: float = 0.45

## A burst tyre's rolling radius, as a fraction: the corner sits lower on the rim.
var popped_radius: float = 0.84

## A burst tyre's thump: the vertical force at that corner, as a fraction of the corner's
## share of the weight, once a turn of the wheel. What makes the wheel shake.
var popped_wobble: float = 0.35

## A burst tyre's drag, as a fraction of the corner's load: it pulls toward that side.
var popped_drag: float = 0.06

## A lost wheel's corner sits on its hub: this fraction of the wheel's radius.
var hub_radius: float = 0.5

## A hub on the road grips like steel on stone.
var hub_grip: float = 0.2

## A hub on the road drags: this fraction of the corner's load, against its motion. The pull.
var hub_drag: float = 0.5

## How much of a part's strength a hit below [member min_share] still wears off it (health
## per strength): a long scrape along a rail does not take a mirror at once but it does not
## leave it pristine either. 0 turns fatigue off.
var fatigue: float = 0.04

## An intact tyre's wear (0 new, 1 flat) from every knock it feels, as a fraction of the
## knock over its tyre strength; a knock too small to count as a hit wears a tenth of that.
var wear_rate: float = 0.5

## The grip a fully worn (not yet burst) tyre has lost, as a fraction.
var worn_grip_loss: float = 0.4

## The thump a fully worn tyre puts into the body, as [member popped_wobble] does for a burst one.
var worn_wobble: float = 0.2

enum Wheel { INTACT, POPPED, LOST }


## One piece that can come off. [member node] names what is drawn (relative to the body), so
## [DotVehicleBreakage] can throw it; [member mass] is taken off the body when it goes (a load).
class Part:
	extends RefCounted
	var id: StringName = &""
	## What sort of piece: "panel", "door", "bumper", "mirror", "cargo" or a game's own.
	var kind: StringName = &"panel"
	## Where it is, in the body's frame.
	var centre: Vector3 = Vector3.ZERO
	## How far from [member centre] a hit still reaches it, metres.
	var reach: float = 1.0
	## The change of speed at its centre that takes it off in one hit, m/s.
	var strength: float = 5.0
	var mass: float = 0.0
	var node: NodePath = NodePath("")
	## 1 when whole; it goes at 0.
	var health: float = 1.0
	var lost: bool = false


## One wheel: [member tyre_strength] bursts the tyre, [member hub_strength] takes the wheel off.
class WheelState:
	extends RefCounted
	var centre: Vector3 = Vector3.ZERO
	var reach: float = 0.8
	var tyre_strength: float = 7.0
	var hub_strength: float = 12.0
	var tyre_health: float = 1.0
	var hub_health: float = 1.0
	var state: int = Wheel.INTACT
	## 0 new, 1 flat: grip goes and the wheel shakes before the tyre bursts.
	var wear: float = 0.0


## id -> [Part], in the order they were added.
var parts: Dictionary = {}
var wheels: Array[WheelState] = []


## Adds a part. Refuses a second with the same id or a strength that is not positive.
func add_part(id: StringName, kind: StringName, centre: Vector3, strength: float, reach: float = 1.0, mass: float = 0.0, node: NodePath = NodePath("")) -> DotResult:
	if id == &"" or parts.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "A part needs an id of its own.", String(id))

	if strength <= 0.0 or reach <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A part's strength and reach are positive.", String(id))

	var part := Part.new()
	part.id = id
	part.kind = kind
	part.centre = centre
	part.strength = strength
	part.reach = reach
	part.mass = maxf(mass, 0.0)
	part.node = node
	parts[id] = part
	return DotResult.success(part)


## Adds a wheel; its index is the order wheels were added in (a body's wheels in child order).
func add_wheel(centre: Vector3, tyre_strength: float, hub_strength: float, reach: float = 0.8) -> int:
	var w := WheelState.new()
	w.centre = centre
	w.tyre_strength = maxf(tyre_strength, 0.01)
	w.hub_strength = maxf(hub_strength, w.tyre_strength)
	w.reach = maxf(reach, 0.01)
	wheels.append(w)
	return wheels.size() - 1


## A knock of [param dv] m/s at [param at] (body frame). Returns what came of it, in order:
## [code]{"kind": "part", "id": ...}[/code], [code]{"kind": "worn", "wheel": i}[/code] (a
## quarter more wear), [code]{"kind": "popped", "wheel": i}[/code],
## [code]{"kind": "lost", "wheel": i}[/code].
func hit(at: Vector3, dv: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if dv <= 0.0:
		return out

	for id: StringName in parts:
		var part: Part = parts[id]

		if part.lost:
			continue

		var felt := dv * _falloff(at.distance_to(part.centre), part.reach)

		if felt < part.strength * min_share:
			if fatigue > 0.0 and felt > 0.0:
				part.health = maxf(part.health - felt / part.strength * fatigue, 0.05)
			continue

		part.health -= felt / part.strength

		if part.health <= 0.0:
			part.health = 0.0
			part.lost = true
			out.append({"kind": "part", "id": id})

	for i in wheels.size():
		var felt := dv * _falloff(at.distance_to(wheels[i].centre), wheels[i].reach)
		out.append_array(hit_wheel(i, felt))

	return out


## A knock straight into wheel [param index] (a hard landing, a kerb, something on the road).
func hit_wheel(index: int, dv: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if index < 0 or index >= wheels.size():
		return out

	var w := wheels[index]

	if w.state == Wheel.LOST:
		return out

	var worn_stage := false

	if w.state == Wheel.INTACT and dv > 0.0:
		var share := dv / w.tyre_strength
		var before := int(w.wear * 4.0)
		w.wear = minf(w.wear + share * wear_rate * (1.0 if dv >= w.tyre_strength * min_share else 0.1), 0.98)
		worn_stage = int(w.wear * 4.0) > before

	if w.state == Wheel.INTACT and dv >= w.tyre_strength * min_share:
		w.tyre_health -= dv / w.tyre_strength

		if w.tyre_health <= 0.0:
			w.tyre_health = 0.0
			w.state = Wheel.POPPED
			out.append({"kind": "popped", "wheel": index})

	# The hub feels every hit, so one big enough takes a whole wheel off at once.
	if dv >= w.hub_strength * min_share:
		w.hub_health -= dv / w.hub_strength

		if w.hub_health <= 0.0:
			w.hub_health = 0.0
			if w.state == Wheel.INTACT:
				w.state = Wheel.POPPED
				out.append({"kind": "popped", "wheel": index})
			w.state = Wheel.LOST
			out.append({"kind": "lost", "wheel": index})

	if worn_stage and out.is_empty():
		out.append({"kind": "worn", "wheel": index})

	return out


## Bursts a tyre now (a spike strip, a console command). Nothing if it is not intact.
func pop(index: int) -> Array[Dictionary]:
	if index < 0 or index >= wheels.size() or wheels[index].state != Wheel.INTACT:
		return []
	wheels[index].state = Wheel.POPPED
	wheels[index].tyre_health = 0.0
	return [{"kind": "popped", "wheel": index}]


## Takes a wheel off now.
func lose_wheel(index: int) -> Array[Dictionary]:
	if index < 0 or index >= wheels.size() or wheels[index].state == Wheel.LOST:
		return []
	var out: Array[Dictionary] = []
	if wheels[index].state == Wheel.INTACT:
		out.append({"kind": "popped", "wheel": index})
	wheels[index].state = Wheel.LOST
	wheels[index].hub_health = 0.0
	out.append({"kind": "lost", "wheel": index})
	return out


## Takes a part off now.
func lose_part(id: StringName) -> Array[Dictionary]:
	var part: Part = parts.get(id, null)
	if part == null or part.lost:
		return []
	part.lost = true
	part.health = 0.0
	return [{"kind": "part", "id": id}]


## Everything whole again (a respawn, a repair).
func repair() -> void:
	for id: StringName in parts:
		(parts[id] as Part).lost = false
		(parts[id] as Part).health = 1.0
	for w in wheels:
		w.state = Wheel.INTACT
		w.tyre_health = 1.0
		w.hub_health = 1.0
		w.wear = 0.0
	for id: StringName in parts:
		(parts[id] as Part).health = 1.0


func wheel_state(index: int) -> int:
	return wheels[index].state if index >= 0 and index < wheels.size() else Wheel.INTACT


## The grip wheel [param index] has left, as a fraction of an intact one's.
func grip_of(index: int) -> float:
	match wheel_state(index):
		Wheel.POPPED:
			return popped_grip
		Wheel.LOST:
			return hub_grip
	return 1.0 - worn_grip_loss * wear_of(index)


## Wheel [param index]'s wear, 0 new to 1 flat; a burst or lost wheel is fully worn.
func wear_of(index: int) -> float:
	if index < 0 or index >= wheels.size():
		return 0.0
	return 1.0 if wheels[index].state != Wheel.INTACT else wheels[index].wear


## How broken the vehicle looks, 0 whole to 1 wrecked: parts lost or worn, tyres burst or
## worn. What a smoke plume follows.
func distress() -> float:
	var total := 0.0
	var count := 0
	for id: StringName in parts:
		var part: Part = parts[id]
		if part.kind == &"cargo":
			continue
		total += 1.0 if part.lost else 1.0 - part.health
		count += 1
	for i in wheels.size():
		total += wear_of(i)
		count += 1
	return total / float(count) if count > 0 else 0.0


## The kilograms gone with the parts that have come off.
func mass_lost() -> float:
	var out := 0.0
	for id: StringName in parts:
		var part: Part = parts[id]
		if part.lost:
			out += part.mass
	return out


func lost_parts() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in parts:
		if (parts[id] as Part).lost:
			out.append(id)
	return out


## What has been lost, for the wire: [code]{"lost": [ids], "wheels": [state per wheel]}[/code].
## Health is not sent: a client never decides a loss.
func to_dict() -> Dictionary:
	var states: Array[int] = []
	for w in wheels:
		states.append(w.state)
	var ids: Array[String] = []
	for id in lost_parts():
		ids.append(String(id))
	var worn: Array[int] = []
	for w in wheels:
		worn.append(int(round(w.wear * 100.0)))
	return {"lost": ids, "wheels": states, "wear": worn}


## Takes on what [method to_dict] said (a client, a joiner). Returns what is newly lost, as
## [method hit] does, so the same handler shows it; a repair (fewer losses) is applied quietly.
func apply_dict(data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lost := {}

	for raw: Variant in data.get("lost", []):
		lost[StringName(str(raw))] = true

	for id: StringName in parts:
		var part: Part = parts[id]
		var now := lost.has(id)
		if now and not part.lost:
			out.append({"kind": "part", "id": id})
		part.lost = now
		part.health = 0.0 if now else 1.0

	var states: Array = data.get("wheels", [])

	for i in mini(states.size(), wheels.size()):
		var to := clampi(int(states[i]), Wheel.INTACT, Wheel.LOST)
		var w := wheels[i]
		if to > w.state:
			if w.state == Wheel.INTACT:
				out.append({"kind": "popped", "wheel": i})
			if to == Wheel.LOST:
				out.append({"kind": "lost", "wheel": i})
		w.state = to
		w.tyre_health = 1.0 if to == Wheel.INTACT else 0.0
		var worn: Array = data.get("wear", [])
		if i < worn.size():
			var was := w.wear
			w.wear = clampf(float(worn[i]) / 100.0, 0.0, 1.0) if to == Wheel.INTACT else 0.0
			if to == Wheel.INTACT and absf(w.wear - was) >= 0.05:
				out.append({"kind": "worn", "wheel": i})
		w.hub_health = 0.0 if to == Wheel.LOST else 1.0

	return out


static func _falloff(distance: float, reach: float) -> float:
	return clampf(1.0 - distance / reach, 0.0, 1.0)


func describe() -> Dictionary:
	var states := PackedStringArray()
	for w in wheels:
		states.append(["ok", "popped", "lost"][w.state])
	return {"parts": parts.size(), "lost": lost_parts().size(), "mass_lost": mass_lost(), "wheels": ",".join(states)}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["damage: %d of %d parts lost, %.0f kg gone" % [lost_parts().size(), parts.size(), mass_lost()]])
	for id: StringName in parts:
		var part: Part = parts[id]
		lines.append("  %-14s %-7s %s" % [id, part.kind, "lost" if part.lost else "%3.0f%%" % (part.health * 100.0)])
	for i in wheels.size():
		lines.append("  wheel %d       %s" % [i, ["intact", "popped", "lost"][wheels[i].state]])
	return lines
