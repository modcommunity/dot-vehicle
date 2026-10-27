class_name DotVehicleSpray
extends CPUParticles3D

## Water thrown up behind a vehicle's tyres on a wet road: a mist plume that grows with speed.
## Add it as a child of the vehicle body, put it behind the rear axle ([member position]), set
## [member wet] from the weather and call [method drive] with the speed each frame. Purely
## visual, so it belongs on the client and on nothing the server simulates.

## Speed below which nothing is thrown, m/s.
const MIN_SPEED := 4.0

## Whether the road under the vehicle is wet.
var wet: bool = false


func _init() -> void:
	amount = 120
	lifetime = 0.9
	local_coords = false
	emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	emission_box_extents = Vector3(1.1, 0.05, 0.2)
	direction = Vector3(0.0, 1.0, 1.0)
	spread = 30.0
	initial_velocity_min = 1.5
	initial_velocity_max = 3.5
	gravity = Vector3(0.0, -4.0, 0.0)
	scale_amount_min = 0.5
	scale_amount_max = 1.2
	var mesh := SphereMesh.new()
	mesh.radius = 0.25
	mesh.height = 0.5
	mesh.radial_segments = 6
	mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.85, 0.9, 0.95, 0.22)
	mesh.material = material
	self.mesh = mesh
	emitting = false


## Once a frame with the vehicle's speed in m/s.
func drive(speed: float) -> void:
	var on := wet and absf(speed) > MIN_SPEED
	emitting = on
	if on:
		initial_velocity_max = 3.5 + absf(speed) * 0.1
