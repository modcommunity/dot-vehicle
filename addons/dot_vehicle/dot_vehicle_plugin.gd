@tool
extends EditorPlugin

## Editor entry point for dot-vehicle. Registers inspector types only.
##
## No autoloads. A server running two worlds in one process holds two spawners, each
## with its own vehicle budget.

const _ICON := "res://addons/dot_vehicle/icon_placeholder.svg"

const _TYPES := [
	[
		"DotVehicleSpawner",
		"Node",
		"res://addons/dot_vehicle/runtime/dot_vehicle_spawner.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
