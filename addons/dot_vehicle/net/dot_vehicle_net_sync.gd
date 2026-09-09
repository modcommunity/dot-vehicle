class_name DotVehicleNetSync
extends RefCounted

## What a vehicle has to tell every client, and how to get it there.
##
## [b]dot-net is not a dependency and is not imported here.[/b] Only dot-core is a hard
## dependency in this family, and a script that [i]mentions[/i] a [code]class_name[/code]
## the project does not have fails to parse. Types are named as strings and a bridge
## resolves them with [code]DotNetVar.Type[spec.type][/code].
##
## [b]A full orientation, not a yaw.[/b] Every other replicated body in this family
## sends a yaw and reconstructs the rest, because a player stands upright. A vehicle
## does not: it pitches over crests, rolls in corners and ends up on its roof, and a
## client given only a yaw draws a car sliding flat through a barrel roll. The four
## quaternion components at ten bits each cost 40 bits and there is no cheaper honest
## answer — three Euler angles are the same size and gimbal lock in the one place it
## would show, which is a vehicle nose-up.
##
## [b]Everything is interpolated and nothing is predicted.[/b] See [DotVehicleSpawner]
## for the argument. The consequence for a bridge is that the driver's own client
## interpolates too: it is the only thing that hides the snapshot rate without
## inventing physics the server did not simulate.

## Position quantisation is the game's — an arena and an open world want different bit
## counts, and one number here would force the larger on both.
const YAW_BITS := 10

## Ten bits over -1..1 is a hundredth of a unit, which on a quaternion is well under a
## degree of error on any axis.
const QUAT_BITS := 10

## Speed as km/h, for a client's speedometer and its engine sound. Nine bits reaches
## 511, which is faster than anything with wheels on it.
const SPEED_BITS := 9

const HEALTH_BITS := 7

## Seat occupancy as a bit field. Sixteen seats is a bus; anything larger is a game that
## should be replicating its own roster rather than borrowing this field.
const OCCUPANCY_BITS := 16


static func specs() -> Array[Dictionary]:
	return [
		{"property": &"net_x", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_y", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_z", "type": "FLOAT", "bits": 0, "interpolated": true},
		{"property": &"net_qx", "type": "INT", "bits": QUAT_BITS + 1, "interpolated": true},
		{"property": &"net_qy", "type": "INT", "bits": QUAT_BITS + 1, "interpolated": true},
		{"property": &"net_qz", "type": "INT", "bits": QUAT_BITS + 1, "interpolated": true},
		{"property": &"net_qw", "type": "INT", "bits": QUAT_BITS + 1, "interpolated": true},
		{
			"property": &"net_speed",
			"type": "UINT",
			"bits": SPEED_BITS,
			"interpolated": true,
		},
		{
			"property": &"net_steering",
			"type": "INT",
			"bits": 8,
			"interpolated": true,
		},
		{
			"property": &"net_health",
			"type": "UINT",
			"bits": HEALTH_BITS,
			"interpolated": false,
		},
		{
			"property": &"net_occupancy",
			"type": "UINT",
			"bits": OCCUPANCY_BITS,
			"interpolated": false,
		},
	]


static func properties() -> Array[StringName]:
	var out: Array[StringName] = []

	for spec in specs():
		out.append(spec["property"])

	return out


## Copies a vehicle's state onto a replicating object.
static func pull(vehicle: DotVehicleInstance, into: Object) -> void:
	if vehicle == null or into == null or not vehicle.is_alive():
		return

	var transform := vehicle.node.global_transform
	var rotation := transform.basis.get_rotation_quaternion()

	into.set(&"net_x", transform.origin.x)
	into.set(&"net_y", transform.origin.y)
	into.set(&"net_z", transform.origin.z)
	into.set(&"net_qx", quantise_unit(rotation.x))
	into.set(&"net_qy", quantise_unit(rotation.y))
	into.set(&"net_qz", quantise_unit(rotation.z))
	into.set(&"net_qw", quantise_unit(rotation.w))
	into.set(&"net_speed", clampi(int(round(vehicle.speed() * 3.6)), 0, (1 << SPEED_BITS) - 1))
	into.set(&"net_health", quantise_health(vehicle))
	into.set(&"net_occupancy", occupancy_mask(vehicle))

	var chassis := vehicle.chassis as DotVehicleChassis
	# The wheels' angle is sent so a client can turn them.
	#
	# [b]It cannot be derived from anything else that is sent.[/b] A client watching a
	# vehicle go round a corner knows the body is rotating and not which way the wheels
	# are pointed — a car drifting sideways has its wheels on opposite lock — so a
	# client without this draws every vehicle with its wheels straight ahead, which is
	# the single most noticeable thing wrong with a networked car.
	into.set(&"net_steering", quantise_steering(chassis.steering if chassis != null else 0.0))


## Writes replicated state onto a mirroring node. The client half of [method pull].
##
## [b]Never call this on a vehicle this peer is the authority for.[/b] Writing a
## received transform onto something the local machine is simulating is the mistake
## three games in this family have shipped. On a client every vehicle is a mirror and it
## is always safe; the machine where it is wrong is the server.
static func apply(node: Node3D, from: Object) -> void:
	if node == null or from == null:
		return

	var rotation := Quaternion(
		dequantise_unit(int(from.get(&"net_qx"))),
		dequantise_unit(int(from.get(&"net_qy"))),
		dequantise_unit(int(from.get(&"net_qz"))),
		dequantise_unit(int(from.get(&"net_qw")))
	)

	# Normalised on arrival, and it is not optional: four independently quantised
	# components do not make a unit quaternion, and Basis(q) on one that is not unit
	# scales the whole vehicle. The symptom is a car that grows and shrinks as it turns,
	# which reads as a rendering bug rather than as a wire format.
	if rotation.length_squared() < 0.000001:
		rotation = Quaternion.IDENTITY
	else:
		rotation = rotation.normalized()

	node.global_transform = Transform3D(
		Basis(rotation),
		Vector3(
			float(from.get(&"net_x")),
			float(from.get(&"net_y")),
			float(from.get(&"net_z"))
		)
	)


## A quaternion component, -1..1, as a signed integer of [constant QUAT_BITS] plus sign.
static func quantise_unit(value: float) -> int:
	var scale := float((1 << QUAT_BITS) - 1)
	return clampi(int(round(clampf(value, -1.0, 1.0) * scale)), -int(scale), int(scale))


static func dequantise_unit(value: int) -> float:
	return float(value) / float((1 << QUAT_BITS) - 1)


## The steering angle as a signed byte over -90..90 degrees.
static func quantise_steering(radians: float) -> int:
	return clampi(int(round(rad_to_deg(radians) / 90.0 * 127.0)), -127, 127)


static func dequantise_steering(value: int) -> float:
	return deg_to_rad(float(value) / 127.0 * 90.0)


## Health as 0-100, rounded up so a live vehicle never reads as 0.
##
## An indestructible vehicle reads as 100 rather than as 0. A client cannot tell the
## difference between "no health" and "not destructible", and drawing an empty bar over
## a car nothing can hurt is worse than drawing a full one.
static func quantise_health(vehicle: DotVehicleInstance) -> int:
	if vehicle == null or vehicle.def == null or not vehicle.is_destructible():
		return 100

	if vehicle.health <= 0.0:
		return 0

	return clampi(int(ceil(vehicle.health / vehicle.def.max_health * 100.0)), 1, 100)


## Which seats are occupied, as a bit per seat in definition order.
##
## [b]A mask rather than the rider ids.[/b] A client needs to know which seats are full
## in order to draw a "get in" prompt and to place bodies; it does not need to know
## [i]who[/i] is in a seat it cannot see into, and sending ids would be a per-vehicle
## roster of everybody's position on the map.
static func occupancy_mask(vehicle: DotVehicleInstance) -> int:
	if vehicle == null or vehicle.def == null:
		return 0

	var mask := 0
	var seats := vehicle.def.seats

	for i in mini(seats.size(), OCCUPANCY_BITS):
		if vehicle.occupants.has(seats[i].id):
			mask |= 1 << i

	return mask


static func is_seat_occupied(mask: int, seat_index: int) -> bool:
	if seat_index < 0 or seat_index >= OCCUPANCY_BITS:
		return false

	return (mask & (1 << seat_index)) != 0
