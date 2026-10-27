class_name DotVehicleExplosion
extends Node3D

## A vehicle's explosion, drawn: a fireball, a column of black smoke, sparks, a flash of light
## that dies in under a second. Particles are CPU-side so it runs in Compatibility and in a
## browser. Cleans itself up; [method spawn] is the whole API.

const LIFETIME := 9.0


## Puts an explosion at [param at] under [param parent] and returns it. [param power] 1 is a
## truck; 2 is twice the size.
static func spawn(parent: Node, at: Vector3, power: float = 1.0) -> DotVehicleExplosion:
	if parent == null or not parent.is_inside_tree():
		return null

	var boom := DotVehicleExplosion.new()
	boom.name = "Explosion"
	parent.add_child(boom)
	boom.global_position = at
	boom._build(maxf(power, 0.1))
	return boom


func _build(power: float) -> void:
	add_child(_burst("Fireball", 70, 1.5, 4.0 * power, 11.0 * power, 1.4 * power, Vector3(0, 2.0, 0), _fire_ramp(), 1.0))
	add_child(_burst("Smoke", 46, 7.0, 1.0 * power, 5.0 * power, 2.6 * power, Vector3(0, 3.0, 0), _smoke_ramp(), 0.55))
	add_child(_burst("Sparks", 90, 1.8, 6.0 * power, 20.0 * power, 0.12, Vector3(0, -9.8, 0), _spark_ramp(), 1.0))

	var light := OmniLight3D.new()
	light.name = "Flash"
	light.light_color = Color(1.0, 0.7, 0.3)
	light.light_energy = 14.0
	light.omni_range = 45.0 * power
	add_child(light)
	var fade := create_tween()
	var _t := fade.tween_property(light, "light_energy", 0.0, 0.9)

	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


func _burst(label: String, amount: int, life: float, speed_min: float, speed_max: float, size: float, gravity: Vector3, ramp: Gradient, spread: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = label
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.95
	p.emitting = true
	p.direction = Vector3.UP
	p.spread = 180.0 * spread
	p.initial_velocity_min = speed_min
	p.initial_velocity_max = speed_max
	p.gravity = gravity
	p.damping_min = 0.5
	p.damping_max = 2.0
	p.scale_amount_min = size * 0.6
	p.scale_amount_max = size
	p.color_ramp = ramp
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 0.6 if label == "Smoke" else 0.0))
	p.scale_amount_curve = curve
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = material
	p.mesh = mesh
	return p


static func _fire_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.6, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.6, 0.15, 0.95), Color(0.55, 0.15, 0.05, 0.7), Color(0.1, 0.05, 0.03, 0.0)])
	return g


static func _smoke_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	g.colors = PackedColorArray([Color(0.2, 0.17, 0.15, 0.0), Color(0.08, 0.08, 0.08, 0.85), Color(0.2, 0.2, 0.2, 0.0)])
	return g


static func _spark_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.45, 0.1, 1.0), Color(0.3, 0.1, 0.0, 0.0)])
	return g
