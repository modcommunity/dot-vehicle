class_name DotVehicleWreck
extends Node

## Takes a vehicle through a crash: it tumbles, every knock tears more off, and it explodes ([DotVehicleExplosion]) on the first rest after an impact or after [member fuse] seconds.
## Also the smoke and fire that follow how broken a vehicle looks. Child of the body, beside its [DotVehicleBreakage].
## The simulating side calls [method crash]; a client only draws smoke from the replicated damage state.

const CHANNEL := "vehicle.wreck"

## The vehicle exploded at [param at] (world), the pieces having left with [param velocity].
signal exploded(at: Vector3, velocity: Vector3)

enum Phase { WHOLE, TUMBLING, BURNING }

var breakage: DotVehicleBreakage = null
var body: RigidBody3D = null
var phase: Phase = Phase.WHOLE

## Longest a crash lasts before it ends in the explosion, seconds.
var fuse: float = 5.0

## Shortest, so a single impact is not the whole show.
var min_tumble: float = 1.2

## A hit of this many m/s counts as an impact, and while tumbling the body feels a knock this
## small (a slide down a slope is many small ones, not one big).
var impact_dv: float = 0.6

## Shortest time between two impacts that each take parts off, so a scrape is a sequence, not one step.
var impact_gap: float = 0.3

## Each impact takes this many intact parts off, the nearest first.
var parts_per_impact: int = 2

## Every knock is this many times harder while tumbling.
var hit_scale: float = 3.0

## Slower than this (m/s) after an impact is at rest, and the end.
var rest_speed: float = 3.0

## How hard the explosion throws the body, as a multiple of its weight's worth of speed.
var blast: float = 7.0

## The fraction of damage ([method DotVehicleDamage.distress]) where smoke starts, and fire.
var smoke_from: float = 0.2
var fire_from: float = 0.6

## Smoke and fire are drawn (false on a dedicated server).
var draws: bool = true

var impacts: int = 0
var _time: float = 0.0
var _since_impact: float = 0.0
var _normal_threshold: float = 0.0
var _smoke: CPUParticles3D = null
var _fire: CPUParticles3D = null
var _shown: float = -1.0


func setup(p_body: RigidBody3D, p_breakage: DotVehicleBreakage) -> DotResult:
	if p_body == null or p_breakage == null:
		return DotResult.fail(DotError.CODE_INVALID, "A wreck needs a body and its breakage.")

	body = p_body
	breakage = p_breakage
	var _c := breakage.impact.connect(_on_impact)
	var _b := breakage.broke.connect(_on_broke)
	return DotResult.success(self)


## Starts the crash: the vehicle is thrown into a tumble and the knocks that follow tear it
## apart. [param spin] is the tumble to start with (angular velocity), by default one about the horizontal axis across its travel.
func crash(spin: Vector3 = Vector3.ZERO) -> void:
	if phase != Phase.WHOLE or body == null:
		return

	phase = Phase.TUMBLING
	_time = 0.0
	impacts = 0
	breakage.hit_scale = hit_scale
	_normal_threshold = breakage.hit_threshold
	breakage.hit_threshold = minf(_normal_threshold, impact_dv)
	_since_impact = impact_gap
	var v := body.linear_velocity
	var about := spin if spin != Vector3.ZERO else Vector3(v.z, 0.0, -v.x).normalized() * clampf(v.length() * 0.35, 2.0, 7.0)
	body.angular_velocity += about
	DotLog.debug(CHANNEL, "a crash", {"speed": "%.1f" % v.length()})


func is_wrecked() -> bool:
	return phase != Phase.WHOLE


## Everything whole again.
func reset() -> void:
	phase = Phase.WHOLE
	impacts = 0
	_time = 0.0
	if breakage != null:
		breakage.hit_scale = 1.0
		if _normal_threshold > 0.0:
			breakage.hit_threshold = _normal_threshold
	_shown = -1.0
	_update_plumes(0.0)


func _physics_process(delta: float) -> void:
	if body == null or breakage == null:
		return

	if phase == Phase.TUMBLING and breakage.simulate:
		_time += delta
		_since_impact += delta
		_scrape()
		var resting := impacts > 0 and body.linear_velocity.length() < rest_speed
		if _time >= fuse or (_time >= min_tumble and resting):
			explode()


## A body dragged down a slope presses on it too gently for any one step to be a knock; every
## [member impact_gap] seconds of touching it is one anyway, at the point it touches.
func _scrape() -> void:
	if _since_impact < impact_gap:
		return

	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())

	if state == null or state.get_contact_count() == 0:
		return

	var at := body.to_local(state.get_contact_local_position(0))
	var _e := breakage.hit(at, maxf(impact_dv, 1.0) * 3.0)


func _process(_delta: float) -> void:
	if body == null or breakage == null or breakage.damage == null:
		return

	var level := 1.0 if phase == Phase.BURNING else breakage.damage.distress()
	if absf(level - _shown) > 0.02:
		_shown = level
		_update_plumes(level)


## The end now: all that is left comes off and flies, the body is thrown and left burning.
func explode() -> void:
	if phase == Phase.BURNING or body == null:
		return

	phase = Phase.BURNING
	breakage.hit_scale = 1.0
	if _normal_threshold > 0.0:
		breakage.hit_threshold = _normal_threshold
	var centre := body.global_position
	var v := body.linear_velocity

	for id: StringName in breakage.damage.parts.keys():
		breakage.show_events(breakage.damage.lose_part(id), Vector3.ZERO, blast)

	for i in breakage.damage.wheels.size():
		breakage.show_events(breakage.damage.lose_wheel(i), Vector3.ZERO, blast)

	body.apply_central_impulse(Vector3.UP * body.mass * blast * 0.5)
	body.apply_torque_impulse(Vector3(0.6, 0.2, -0.8) * body.mass * blast * 0.25)
	breakage.broke.emit({"kind": "wrecked", "at": centre, "velocity": v})
	exploded.emit(centre, v)
	_update_plumes(1.0)


func _on_impact(local_at: Vector3, dv: float) -> void:
	if phase != Phase.TUMBLING or dv < impact_dv or _since_impact < impact_gap:
		return

	_since_impact = 0.0
	impacts += 1
	var order: Array = []

	for id: StringName in breakage.damage.parts:
		var part: DotVehicleDamage.Part = breakage.damage.parts[id]
		if not part.lost and part.kind != &"cargo":
			order.append([part.centre.distance_to(local_at), id])

	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	for k in mini(parts_per_impact, order.size()):
		breakage.show_events(breakage.damage.lose_part(order[k][1]), local_at, dv * hit_scale)

	# Cargo and tyres: the impact's own damage already scaled by hit_scale.


func _on_broke(event: Dictionary) -> void:
	# A client's mirror starts the plume when the server's explosion arrives.
	if str(event.get("kind", "")) == "wrecked" and phase != Phase.BURNING:
		phase = Phase.BURNING
		_shown = -1.0


func _update_plumes(level: float) -> void:
	if not draws or body == null or not body.is_inside_tree():
		return

	if _smoke == null:
		_smoke = _plume(Color(0.12, 0.12, 0.12, 0.7), 2.2, 1.1, 14, 4.0)
		_fire = _plume(Color(1.0, 0.55, 0.12, 0.9), 0.9, 0.8, 7, 2.0)
		_fire.mesh.material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_smoke.emitting = level >= smoke_from
	_smoke.amount = int(lerpf(6.0, 28.0, clampf(level, 0.0, 1.0)))
	_fire.emitting = level >= fire_from


func _plume(colour: Color, size: float, life: float, amount: int, rise: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = life * 1.6
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 25.0
	p.initial_velocity_min = rise * 0.6
	p.initial_velocity_max = rise
	p.gravity = Vector3(0, 0.5, 0)
	p.scale_amount_min = size * 0.5
	p.scale_amount_max = size
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([colour, Color(colour.r, colour.g, colour.b, 0.0)])
	p.color_ramp = g
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	p.mesh = mesh
	p.emitting = false
	body.add_child(p)
	p.position = Vector3(0.0, 0.9, -1.2)
	return p
