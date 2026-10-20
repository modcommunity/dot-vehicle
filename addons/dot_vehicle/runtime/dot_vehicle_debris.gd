class_name DotVehicleDebris
extends Node3D

## Where the pieces that come off a vehicle go: each a loose [RigidBody3D] that keeps the speed
## it had, lives [member lifetime] seconds, and shrinks away. At most [member budget] at once;
## the oldest goes first.
##
## [b]Debris is drawn, never simulated for the game.[/b] Rigid bodies do not come out the same
## on two machines, so a piece that could push a truck would put a server and its clients out
## of step. The pieces collide on [member collision_layer] against [member collision_mask] (a
## game sets the mask to its road and nothing that is driven), and a dedicated server, which
## draws nothing, does not make any: [DotVehicleBreakage] with no debris node only hides what came
## off. Each machine throws its own from the server's list of what was lost
## ([method DotVehicleDamage.to_dict]) and the velocity the server sent with it.

const CHANNEL := "vehicle.debris"

## How many pieces may lie about at once, every vehicle together.
@export_range(1, 512, 1) var budget: int = 32

## Seconds a piece stays, its last [member fade_seconds] spent shrinking.
@export_range(0.5, 600.0, 0.5) var lifetime: float = 14.0
@export_range(0.0, 10.0, 0.1) var fade_seconds: float = 1.0

@export_flags_3d_physics var collision_layer: int = 1
@export_flags_3d_physics var collision_mask: int = 1

## Nothing lighter, so a mirror's glass does not skate off at the speed of light.
@export var min_mass: float = 2.0

var _live: Array[RigidBody3D] = []
var _age: Dictionary = {}

## Every piece made, for a check.
var thrown_count: int = 0


## Takes [param node] (drawn, anywhere in the tree) into the world as a loose piece where it is
## now, moving at [param velocity] and turning at [param spin]. Its box is the meshes under it.
## Returns the body, or null when the node was not drawn.
func throw(node: Node3D, velocity: Vector3, spin: Vector3 = Vector3.ZERO, mass: float = 20.0) -> RigidBody3D:
	if node == null or not is_instance_valid(node) or not is_inside_tree():
		return null

	var where := node.global_transform
	var box := _bounds(node)
	var body := _body(mass, velocity, spin)
	add_child(body)
	body.global_transform = Transform3D(Basis.IDENTITY, where * box.get_center())

	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.owner = null
	body.add_child(node)
	node.visible = true
	node.global_transform = where
	_add_box(body, box, where)
	_keep(body)
	return body


## A loose box of [param size] that was never part of the model: a crate, a log, a shred of tyre.
func spawn_box(where: Transform3D, size: Vector3, material: Material, velocity: Vector3, spin: Vector3 = Vector3.ZERO, mass: float = 20.0) -> RigidBody3D:
	if not is_inside_tree():
		return null

	var body := _body(mass, velocity, spin)
	add_child(body)
	body.global_transform = where
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = material
	body.add_child(mesh)
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collider.shape = box
	body.add_child(collider)
	_keep(body)
	return body


## Moves the triangles of [param mesh] whose middle is inside [param region] (in the mesh's own
## frame) onto a new [MeshInstance3D] beside it, with the same materials, so a part of a one-piece
## model can come off on its own. Returns the new node (already in the tree, where the old one is),
## or null when no triangle was inside. The model's file is not touched.
static func carve(mesh: MeshInstance3D, region: AABB) -> MeshInstance3D:
	if mesh == null or mesh.mesh == null:
		return null

	var keep_mesh := ArrayMesh.new()
	var cut_mesh := ArrayMesh.new()
	var any := false
	var bounds := AABB()
	var has_bounds := false

	for s in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(s)
		var material := mesh.get_active_material(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()

		if idx.is_empty():
			idx.resize(verts.size())
			for i in verts.size():
				idx[i] = i

		var keep := PackedInt32Array()
		var cut := PackedInt32Array()

		for k in range(0, idx.size() - 2, 3):
			var middle := (verts[idx[k]] + verts[idx[k + 1]] + verts[idx[k + 2]]) / 3.0
			var inside := region.has_point(middle)
			var dest := cut if inside else keep
			dest.append(idx[k]); dest.append(idx[k + 1]); dest.append(idx[k + 2])

			if inside:
				for v in [verts[idx[k]], verts[idx[k + 1]], verts[idx[k + 2]]]:
					bounds = AABB(v, Vector3.ZERO) if not has_bounds else bounds.expand(v)
					has_bounds = true

		if not cut.is_empty():
			any = true
			arrays[Mesh.ARRAY_INDEX] = cut
			cut_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			cut_mesh.surface_set_material(cut_mesh.get_surface_count() - 1, material)

		if not keep.is_empty():
			arrays[Mesh.ARRAY_INDEX] = keep
			keep_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			keep_mesh.surface_set_material(keep_mesh.get_surface_count() - 1, material)

	if not any:
		return null

	mesh.mesh = keep_mesh
	var out := MeshInstance3D.new()
	out.mesh = cut_mesh
	out.transform = mesh.transform
	out.name = "%s_cut" % mesh.name
	# The piece's own box, kept on its mesh (which a duplicate shares), for culling and for _bounds.
	cut_mesh.custom_aabb = bounds
	if mesh.get_parent() != null:
		mesh.get_parent().add_child(out)
	return out


func live_count() -> int:
	return _live.size()


func clear() -> void:
	for body in _live:
		if is_instance_valid(body):
			body.queue_free()
	_live.clear()
	_age.clear()


func _process(delta: float) -> void:
	var i := 0

	while i < _live.size():
		var body := _live[i]

		if not is_instance_valid(body):
			_live.remove_at(i)
			continue

		var age := float(_age.get(body, 0.0)) + delta
		_age[body] = age
		var left := lifetime - age

		if left <= 0.0:
			_age.erase(body)
			_live.remove_at(i)
			body.queue_free()
			continue

		if left < fade_seconds:
			var f := maxf(left / maxf(fade_seconds, 0.01), 0.05)
			for child in body.get_children():
				if child is Node3D and not (child is CollisionShape3D):
					(child as Node3D).scale = Vector3.ONE * f * _base_scale(child)

		i += 1


func _body(mass: float, velocity: Vector3, spin: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Debris%d" % thrown_count
	body.mass = maxf(mass, min_mass)
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	body.linear_velocity = velocity
	body.angular_velocity = spin
	body.continuous_cd = velocity.length() > 15.0
	thrown_count += 1
	return body


func _keep(body: RigidBody3D) -> void:
	_live.append(body)
	_age[body] = 0.0

	while _live.size() > budget:
		var old := _live.pop_front() as RigidBody3D
		_age.erase(old)
		if is_instance_valid(old):
			old.queue_free()


## The scale a child had when it was thrown, so the fade shrinks from there.
func _base_scale(child: Node) -> float:
	if not child.has_meta(&"dot_debris_scale"):
		child.set_meta(&"dot_debris_scale", (child as Node3D).scale.x)
	return float(child.get_meta(&"dot_debris_scale"))


## The box round [param node]'s meshes, in its own frame (scaled meshes included).
static func _bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [node]
	var inverse := node.global_transform.affine_inverse()

	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var mesh := n as MeshInstance3D

		if mesh == null or mesh.mesh == null:
			continue

		# A carved piece keeps every vertex of the whole model (only its triangles are its own), so
		# its mesh's box is the whole body's; carve() keeps the piece's own as the custom box.
		var custom: AABB = (mesh.mesh as ArrayMesh).custom_aabb if mesh.mesh is ArrayMesh else AABB()
		var own := custom if custom.has_volume() else mesh.mesh.get_aabb()
		var local := (inverse * mesh.global_transform) * own if mesh.is_inside_tree() else own
		out = local if first else out.merge(local)
		first = false

	return out if not first else AABB(Vector3(-0.2, -0.2, -0.2), Vector3(0.4, 0.4, 0.4))


func _add_box(body: RigidBody3D, box: AABB, where: Transform3D) -> void:
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# The node's own scale is in [param where]; the box is in its unscaled frame.
	# Absolute: a mirrored node (a left wheel drawn from a right one) has a negative scale, and
	# a negative box clamps to the smallest, which dropped a whole wheel half into the road.
	var s := where.basis.get_scale().abs()
	shape.size = Vector3(maxf(box.size.x * s.x, 0.08), maxf(box.size.y * s.y, 0.08), maxf(box.size.z * s.z, 0.08))
	collider.shape = shape
	body.add_child(collider)
	collider.global_basis = where.basis.orthonormalized()
	collider.global_position = where * box.get_center()


func describe() -> Dictionary:
	return {"live": _live.size(), "budget": budget, "thrown": thrown_count}
