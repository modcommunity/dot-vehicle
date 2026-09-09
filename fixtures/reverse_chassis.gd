extends "res://addons/dot_vehicle/runtime/dot_vehicle_chassis.gd"

## A chassis for the self-test: drives backwards, and counts its ticks.
##
## [b]Extends a PATH, not [code]DotVehicleChassis[/code], and the suite asserts that
## this file loads.[/b] It is the shape a chassis delivered inside a mounted dot-cloud
## pack must have, and writing the fixture the other way would make the suite pass for
## a shape the addon does not support.

var drives: int = 0
var last_throttle: float = 0.0


func _drive(command: DotVehicleCommand, _delta: float) -> void:
	drives += 1
	last_throttle = command.throttle

	var body := vehicle.body()

	if body != null:
		body.apply_central_force(body.global_transform.basis.z * engine_force_for(command.throttle))
