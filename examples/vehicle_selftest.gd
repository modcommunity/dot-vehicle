extends Node

## Proves the handover holds, the exit sweep refuses a wall, and nothing leaks.
##
## [codeblock]
## godot --headless --path . res://examples/vehicle_selftest.tscn
## [/codeblock]
##
## [b]The tests that matter are the ones about getting out.[/b] Driving is where the
## prior art is; the handover is where the bugs are, and every one of them is a state a
## player can reach and a suite can only reach on purpose: a seat with two people in it,
## an exit into a wall, a vehicle destroyed with three riders aboard, a disconnect
## halfway through a corner. All of those are here, with real bodies in a real physics
## world, because a placement test against no colliders would pass anywhere.

const CAR := "res://fixtures/car.tscn"
const SKIFF := "res://fixtures/skiff.tscn"
const RIDER := "res://fixtures/rider.tscn"
const CRATE := "res://fixtures/crate.tscn"

const CHECKS := 155

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _world: Node3D = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-vehicle self-test")
	print("")

	_world = Node3D.new()
	add_child(_world)

	_test_seats()
	_test_tunables()
	_test_steering_falloff()
	_test_definitions()
	_test_catalogue()
	_test_commands()
	_test_spawning()
	_test_adopting()
	_test_authority()
	_test_budgets()
	_test_chassis()
	await _test_driving()
	_test_driver_steering()
	_test_driver_route()
	_test_driver_stuck()
	_test_driver_drives_a_car()
	_test_entering()
	_test_seat_rules()
	await _test_exit_placement()
	_test_exit_rules()
	await _test_carrying_the_rider()
	_test_destruction()
	_test_disconnects()
	await _test_no_leaked_nodes()
	_test_net_sync()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


# --- Builders -----------------------------------------------------------------

func _jeep() -> DotVehicleDef:
	var def := DotVehicleDef.make(&"jeep", CAR)
	def.category = &"car"
	def.cost = 4

	var driver := DotVehicleSeat.make(&"driver", true)
	driver.seat_offset = Vector3(-0.4, 0.9, -0.4)

	var passenger := DotVehicleSeat.make(&"passenger")
	passenger.seat_offset = Vector3(0.4, 0.9, -0.4)

	def.seats = [driver, passenger]

	var tuning := DotVehicleTunables.new()
	tuning.mass = 800.0
	tuning.max_exit_speed = 4.0
	def.tunables = tuning

	return def


func _catalogue() -> DotVehicleCatalogue:
	var cat := DotVehicleCatalogue.new()
	cat.add(_jeep())

	var skiff := DotVehicleDef.make(&"skiff", SKIFF)
	skiff.kind = DotVehicleDef.Kind.HOVER
	skiff.category = &"boat"
	skiff.seats = [DotVehicleSeat.make(&"driver", true)]
	cat.add(skiff)

	var scripted := DotVehicleDef.make(&"scripted", SKIFF)
	scripted.chassis_script_path = "res://fixtures/reverse_chassis.gd"
	scripted.seats = [DotVehicleSeat.make(&"driver", true)]
	cat.add(scripted)

	var broken := DotVehicleDef.make(&"broken", SKIFF)
	broken.chassis_script_path = "res://fixtures/not_a_chassis.gd"
	broken.seats = [DotVehicleSeat.make(&"driver", true)]
	cat.add(broken)

	var wreckable := DotVehicleDef.make(&"wreckable", SKIFF)
	wreckable.kind = DotVehicleDef.Kind.CUSTOM
	wreckable.max_health = 200.0
	wreckable.seats = [
		DotVehicleSeat.make(&"driver", true), DotVehicleSeat.make(&"passenger")
	]
	cat.add(wreckable)

	return cat


func _spawner(budget: int = 0) -> DotVehicleSpawner:
	var spawner := DotVehicleSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.authoritative = true
	spawner.world_budget = budget
	spawner.per_player_budget = 0
	spawner.spawn_interval = 0.0
	_world.add_child(spawner)
	return spawner


func _rider() -> CharacterBody3D:
	var scene: PackedScene = load(RIDER)
	var node := scene.instantiate() as CharacterBody3D
	_world.add_child(node)
	return node


## A static box in the world, for the exit sweep to be blocked by.
func _wall(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)
	body.global_position = at
	return body


# --- Data ---------------------------------------------------------------------

func _test_seats() -> void:
	print("seats")

	var seat := DotVehicleSeat.make(&"driver", true)
	_check(seat.validate().ok, "a seat validates")
	_check(seat.drives, "and a driving seat drives")
	_check(not seat.may_fire, "and a driver does not fire by default")
	_check(DotVehicleSeat.make(&"gunner").may_fire, "and a passenger does")

	var trapped := DotVehicleSeat.make(&"trapped")
	trapped.exit_offsets = []
	_check(
		not trapped.validate().ok,
		"a seat with no exit offsets is refused",
		"the moment a player finds one is the moment they are already in it"
	)

	var round_tripped := DotVehicleSeat.from_dictionary(seat.to_dictionary())
	_check(round_tripped.id == seat.id and round_tripped.drives, "a seat round trips")
	_check(
		round_tripped.exit_offsets.size() == seat.exit_offsets.size(),
		"including its exits"
	)


func _test_tunables() -> void:
	print("tunables")

	var tuning := DotVehicleTunables.new()
	_check(tuning.validate().ok, "the defaults are usable")

	tuning.brake_force = 10.0
	_check(
		not tuning.validate().ok,
		"a vehicle that cannot out-brake its own engine is refused",
		"it reads as having no brakes, and gets reported as a physics bug"
	)

	var configured := DotVehicleTunables.new()
	configured.apply_dictionary({"top_speed": 50.0, "mass": 1400.0})
	_check(
		configured.top_speed == 50.0 and configured.mass == 1400.0,
		"and it is a DotConfig, so a server retunes handling in a file"
	)


func _test_steering_falloff() -> void:
	print("steering")

	var tuning := DotVehicleTunables.new()
	tuning.steering_limit_deg = 30.0
	tuning.steering_speed_falloff = 0.4
	tuning.top_speed = 30.0

	var at_rest := tuning.steering_limit_at(0.0)
	var at_speed := tuning.steering_limit_at(30.0)

	_check(
		absf(rad_to_deg(at_rest) - 30.0) < 0.01,
		"full lock is available at a standstill",
		"%.1f deg" % rad_to_deg(at_rest)
	)
	_check(
		absf(rad_to_deg(at_speed) - 12.0) < 0.01,
		"and a fraction of it at the top speed",
		"%.1f deg" % rad_to_deg(at_speed)
	)
	_check(
		tuning.steering_limit_at(200.0) >= at_speed,
		"and it stops falling above the top speed",
		"a vehicle off a cliff would otherwise land unsteerable"
	)


func _test_definitions() -> void:
	print("definitions")

	var jeep := _jeep()
	_check(jeep.validate().ok, "a definition validates")
	_check(jeep.driver_seats().size() == 1, "and it has a driving seat")

	var scenery := DotVehicleDef.make(&"statue", CAR)
	_check(
		not scenery.validate().ok, "a vehicle with no seats is refused", "it is scenery"
	)

	var undriveable := DotVehicleDef.make(&"trailer", CAR)
	undriveable.seats = [DotVehicleSeat.make(&"passenger")]
	_check(
		not undriveable.validate().ok,
		"and so is one with no driving seat",
		"nobody could ever move it"
	)

	var clashing := DotVehicleDef.make(&"twin", CAR)
	clashing.seats = [
		DotVehicleSeat.make(&"driver", true), DotVehicleSeat.make(&"driver")
	]
	_check(
		not clashing.validate().ok,
		"and so are two seats sharing an id",
		"the second is unreachable, so the vehicle quietly holds one fewer person"
	)

	var by_class := DotVehicleDef.make(&"jeep", CAR)
	by_class.seats = [DotVehicleSeat.make(&"driver", true)]
	by_class.chassis_script_path = "MyChassis"
	_check(
		not by_class.validate().ok,
		"a chassis named by class rather than by path is refused"
	)

	var round_tripped := DotVehicleDef.from_dictionary(jeep.to_dictionary())
	_check(round_tripped.id == jeep.id, "a definition survives a round trip")
	_check(round_tripped.seat_count() == 2, "with its seats")
	_check(
		round_tripped.tuning().mass == 800.0,
		"and its handling",
		"%.0f" % round_tripped.tuning().mass
	)


func _test_catalogue() -> void:
	print("catalogue")

	var cat := _catalogue()
	_check(cat.size() == 5, "a catalogue holds what was added", "%d" % cat.size())
	_check(cat.get_vehicle(&"jeep") != null, "and finds by id")
	_check(cat.seating_at_least(2).size() == 2, "and can be asked for room for two")

	var rejected := PackedStringArray()
	var reloaded := DotVehicleCatalogue.from_dictionary({
		"vehicles": [
			{"id": "good", "scene": CAR, "seats": [{"id": "driver", "drives": true}]},
			{"id": "seatless", "scene": CAR},
		]
	}, rejected)

	_check(
		reloaded.size() == 1 and rejected.size() == 1,
		"one bad entry does not condemn the file",
		"%d kept, %d rejected" % [reloaded.size(), rejected.size()]
	)


func _test_commands() -> void:
	print("commands")

	var cmd := DotVehicleCommand.make(40.0, -9.0, 3.0)
	cmd.sanitise()
	_check(
		cmd.throttle == 1.0 and cmd.steer == -1.0 and cmd.brake == 1.0,
		"a command out of range is clamped",
		"a client is a program the player can edit"
	)

	var poisoned := DotVehicleCommand.new()
	poisoned.throttle = NAN
	poisoned.steer = NAN
	poisoned.aim_yaw = NAN
	poisoned.sanitise()
	_check(
		not is_nan(poisoned.throttle) and not is_nan(poisoned.steer),
		"and a NaN is refused rather than clamped",
		"clampf(NAN) is NAN, and one NaN ends a vehicle's transform for the round"
	)

	_check(DotVehicleCommand.new().is_idle(), "an empty command is idle")


# --- Spawning -----------------------------------------------------------------

func _test_spawning() -> void:
	print("spawning")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0), &"alice")

	_check(jeep != null, "a vehicle spawns")
	_check(jeep.is_alive(), "and is alive")
	_check(jeep.def.seat_count() == 2, "with its seats")
	_check(jeep.is_empty(), "and nobody in it")
	_check(spawner.world_count() == 1, "and the spawner knows about it")

	_check(
		jeep.body().mass == 800.0,
		"and the tunables' mass is written ONTO the body",
		"dot-props' bug: a catalogue saying one thing over a scene saying another"
	)

	_check(spawner.spawn(&"nothing", Vector3.ZERO) == null, "an unknown id is refused")

	spawner.queue_free()


## A body created by somebody else, made a vehicle.
##
## The case that put this method here is game-playground, where every spawnable is a
## `DotPropInstance` so that a gravity gun can punt it — so the body exists, in the
## world, before anything knows it is a car.
func _test_adopting() -> void:
	print("adopting")

	var spawner := _spawner()

	var scene: PackedScene = load(CAR)
	var body := scene.instantiate() as Node3D
	_world.add_child(body)
	body.global_position = Vector3(0, 1, 40)

	var jeep := spawner.adopt(body, &"jeep", &"alice")

	_check(jeep != null, "a body somebody else made becomes a vehicle")
	_check(jeep.node == body, "over the node it was given, not a second one")
	_check(jeep.chassis is DotVehicleWheeled, "with its chassis attached")
	_check(spawner.world_count() == 1, "and it counts against the world budget")
	_check(
		jeep.position().distance_to(Vector3(0, 1, 40)) < 0.5,
		"and it is left where its host put it",
		"adopt places nothing: whoever made the body already decided"
	)

	_check(
		spawner.adopt(body, &"jeep", &"alice") == null,
		"the same body is refused a second time",
		"two chassis over one rigid body is twice the engine force, silently"
	)

	# The half that only fails on the deployment this exists for: dot-props frees the
	# node from its own undo stack, so this spawner must not free it as well.
	spawner.remove(jeep.instance_id)
	_check(is_instance_valid(body), "removing an adopted vehicle leaves its node alone")
	_check(spawner.world_count() == 0, "but the spawner has let go of it")

	body.queue_free()
	spawner.queue_free()


func _test_authority() -> void:
	print("authority")

	var client := DotVehicleSpawner.new()
	client.catalogue = _catalogue()
	client.authoritative = false
	_world.add_child(client)

	_check(client.spawn(&"jeep", Vector3.ZERO) == null, "a client may not spawn")
	_check(client.world_count() == 0, "and nothing appeared")

	client.queue_free()


func _test_budgets() -> void:
	print("budgets")

	var spawner := _spawner(10)

	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"alice") != null, "one fits")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"alice") != null, "and a second")
	_check(
		spawner.spawn(&"jeep", Vector3.ZERO, &"alice") == null,
		"and a third is over the world budget",
		"counted in cost, not in bodies"
	)

	spawner.per_player_budget = 4
	spawner.world_budget = 0
	spawner.clear_all()

	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"bob") != null, "bob gets one")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"bob") == null, "and not a second")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"carol") != null, "and carol is not affected")

	spawner.queue_free()


func _test_chassis() -> void:
	print("chassis")

	var spawner := _spawner()

	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	_check(jeep.chassis is DotVehicleWheeled, "a wheeled definition gets Godot's wheels")

	var skiff := spawner.spawn(&"skiff", Vector3(0, 1, 20))
	_check(skiff.chassis is DotVehicleHover, "a hover definition gets the hover chassis")

	var scripted := spawner.spawn(&"scripted", Vector3(0, 1, 40))
	_check(
		scripted.chassis != null and scripted.chassis is DotVehicleChassis,
		"and a definition naming a script by PATH gets that",
		"the shape a delivered chassis must have"
	)

	var broken := spawner.spawn(&"broken", Vector3(0, 1, 60))
	_check(broken != null, "a vehicle whose chassis is not a chassis still spawns",
		"deleting it would hide which script was wrong")
	_check(
		broken.chassis == null,
		"but is not given one",
		"or the tick after the spawn calls drive() on something with no such method"
	)

	var custom := spawner.spawn(&"wreckable", Vector3(0, 1, 80))
	_check(
		custom.chassis == null,
		"and a CUSTOM vehicle is deliberately given none"
	)

	# A wheeled definition over a scene with no wheels: the refusal that matters,
	# because the alternative is something that looks like a car for four seconds.
	var wrong := DotVehicleDef.make(&"wrong", SKIFF)
	wrong.seats = [DotVehicleSeat.make(&"driver", true)]
	spawner.catalogue.add(wrong)

	var mismatched := spawner.spawn(&"wrong", Vector3(0, 1, 100))
	_check(
		mismatched.chassis == null,
		"a wheeled definition over a scene with no VehicleBody3D is refused",
		"a body driven by central force looks like a car and behaves like a crate"
	)

	spawner.queue_free()


func _test_driving() -> void:
	print("driving")

	var spawner := _spawner()
	var ground := _wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1.0, 0))
	var rider := _rider()

	spawner.ride.enter(jeep, &"alice", rider)

	var before := jeep.position()

	spawner.set_command(jeep.instance_id, &"alice", DotVehicleCommand.make(1.0))

	for i in 90:
		spawner.tick(1.0 / 60.0)
		await get_tree().physics_frame

	var travelled := jeep.position().distance_to(before)

	_check(travelled > 1.0, "a vehicle with the throttle down moves",
		"%.2f m in 90 ticks" % travelled)
	_check(
		jeep.forward_speed() > 0.5,
		"and it moves FORWARD",
		"%.2f m/s" % jeep.forward_speed()
	)

	# The command is held, not consumed: a driver's input arrives at their frame rate
	# and the vehicle is simulated at the server's, so a consumed command gives a
	# vehicle that accelerates in stutters on any client below the tick rate.
	_check(jeep.command != null, "and the command is held rather than consumed")

	# Which way +1 steers. Godot's own sign is the opposite of this family's and the
	# translation lives in one place; a check that only measured "it turned" would pass
	# for a car that turns the wrong way, which is the bug the sign flip exists for.
	var heading_before := -jeep.node.global_transform.basis.z
	spawner.set_command(jeep.instance_id, &"alice", DotVehicleCommand.make(1.0, 1.0))

	for i in 150:
		spawner.tick(1.0 / 60.0)
		await get_tree().physics_frame

	var heading_after := -jeep.node.global_transform.basis.z
	var turned := atan2(heading_after.x, -heading_after.z) - atan2(heading_before.x, -heading_before.z)

	_check(
		turned > deg_to_rad(1.0),
		"and steering +1 turns RIGHT",
		"%.1f deg" % rad_to_deg(turned)
	)

	var passenger_cmd := DotVehicleCommand.make(1.0)
	_check(
		not spawner.set_command(jeep.instance_id, &"bob", passenger_cmd).ok,
		"somebody who is not driving cannot send a command",
		"or a passenger drives from the back seat"
	)

	ground.queue_free()
	spawner.queue_free()


# --- The handover -------------------------------------------------------------

# --- The driver ---------------------------------------------------------------

## A kinematic car with no physics in it at all.
##
## [b]Deliberately not a RigidBody.[/b] What is being tested is the decision — does the
## driver turn the right way, slow for the corner, notice it is stuck — and a real
## vehicle body answers that question through a suspension model, a friction model and
## a solver, none of which is this addon's and all of which would decide whether the
## check passed. This is a bicycle: throttle makes it go, steering turns it, and any
## failure in the section below is the driver's.
class ToyCar extends RefCounted:
	var position := Vector3.ZERO
	var yaw := 0.0
	var speed := 0.0

	var accel := 9.0
	var decel := 14.0
	var drag := 0.6
	var turn_rate := 1.6

	func forward() -> Vector3:
		return Vector3(-sin(yaw), 0.0, -cos(yaw))

	func right() -> Vector3:
		return Vector3(cos(yaw), 0.0, -sin(yaw))

	func velocity() -> Vector3:
		return forward() * speed

	func step(command: DotVehicleCommand, delta: float) -> void:
		speed += command.throttle * accel * delta
		speed -= command.brake * decel * delta * signf(speed)
		speed -= speed * drag * delta

		if command.handbrake:
			speed *= 0.9

		# Steering authority scales with speed, like a real one: a stationary car
		# cannot turn however far the wheel is turned.
		var authority := clampf(absf(speed) / 8.0, 0.0, 1.0)
		# +1 steers RIGHT, which is a negative yaw about +Y.
		yaw -= command.steer * turn_rate * authority * delta * signf(speed)

		position += forward() * speed * delta


func _drive_toy(
	driver: DotVehicleDriver, car: ToyCar, seconds: float, delta: float = 0.05
) -> int:
	var steps := int(seconds / delta)

	for i in steps:
		var command := driver.drive_from(
			car.position, car.forward(), car.right(), car.velocity(), delta
		)
		car.step(command, delta)

		if driver.is_arrived():
			return i

	return -1


func _test_driver_steering() -> void:
	print("driver steering")

	var driver := DotVehicleDriver.new()
	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT

	# +1 steers right, which is this family's convention and not Godot's — the
	# wheeled chassis flips it once, where the engine's own signs are documented.
	driver.set_target(Vector3(20, 0, -20))
	var to_the_right := driver.drive_from(
		Vector3.ZERO, forward, right, Vector3.ZERO, 0.05
	)
	_check(to_the_right.steer > 0.1, "a goal to the right steers right",
		"steer = %.2f" % to_the_right.steer)

	driver.set_target(Vector3(-20, 0, -20))
	var to_the_left := driver.drive_from(Vector3.ZERO, forward, right, Vector3.ZERO, 0.05)
	_check(to_the_left.steer < -0.1, "and one to the left steers left")

	driver.set_target(Vector3(0, 0, -40))
	var straight := driver.drive_from(Vector3.ZERO, forward, right, Vector3.ZERO, 0.05)
	_check(absf(straight.steer) < 0.05, "and one dead ahead steers straight")
	_check(straight.throttle > 0.0, "and gets some throttle")

	# The vehicle's own axes, not the world's. A car on a banked corner is rolled and a
	# world-space yaw is the wrong question.
	var rolled_right := Vector3(0.7, 0.7, 0.0).normalized()
	driver.set_target(Vector3(20, 0, -20))
	var banked := driver.drive_from(
		Vector3.ZERO, forward, rolled_right, Vector3.ZERO, 0.05
	)
	_check(banked.steer > 0.0, "steering is computed in the vehicle's own frame")

	# Slowing for a corner is what stops a follower understeering off every bend.
	driver.target_speed = 20.0
	driver.set_target(Vector3(0, 0, -100))
	var on_a_straight := driver.drive_from(
		Vector3.ZERO, forward, right, forward * 5.0, 0.05
	)

	driver.set_target(Vector3(-3, 0, 1))
	var into_a_corner := driver.drive_from(
		Vector3.ZERO, forward, right, forward * 18.0, 0.05
	)

	_check(
		on_a_straight.throttle > 0.0,
		"a straight ahead gets throttle at five metres a second"
	)
	_check(
		into_a_corner.brake > 0.0 and into_a_corner.throttle == 0.0,
		"and a hairpin at eighteen gets the brakes rather than a lift",
		"brake = %.2f" % into_a_corner.brake
	)

	var idle := DotVehicleDriver.new()
	var nothing := idle.drive_from(Vector3.ZERO, forward, right, forward * 10.0, 0.05)
	_check(
		idle.state == DotVehicleDriver.State.IDLE,
		"a driver with nowhere to go is idle"
	)
	_check(
		nothing.brake >= 1.0,
		"and brakes rather than coasting, or 'arrived' means 'went past'"
	)


func _test_driver_route() -> void:
	print("driver route")

	var driver := DotVehicleDriver.new()
	driver.set_route(PackedVector3Array([
		Vector3(0, 0, -20), Vector3(0, 0, -40), Vector3(0, 0, -60),
	]))

	_check(driver.has_route(), "a route is taken")
	_check(driver.index == 0, "starting at the first waypoint")
	_check(not driver.is_last_waypoint(), "which is not the last one")

	# Standing on the first waypoint advances past it rather than circling it: a
	# waypoint radius tighter than the turning circle is a car orbiting a point it
	# cannot quite touch.
	driver.drive_from(Vector3(0, 0, -20), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	_check(driver.index == 1, "arriving at one moves on to the next", "%d" % driver.index)

	# Walked in order, deliberately. A driver handed a position beyond the next
	# waypoint does not skip to the end: the route is the route, and a follower that
	# jumped to whichever point was nearest would cut a hairpin by driving through the
	# middle of it.
	driver.drive_from(Vector3(0, 0, -59), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	_check(
		driver.index == 1,
		"and standing past a waypoint does not skip the ones in between",
		"index %d" % driver.index
	)

	driver.drive_from(Vector3(0, 0, -40), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	driver.drive_from(Vector3(0, 0, -59), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	_check(driver.is_arrived(), "and the last one ends the route")
	_check(
		driver.drive_from(
			Vector3(0, 0, -59), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
		).brake >= 1.0,
		"after which it brakes"
	)

	# Look-ahead aims past the corner rather than at it, which is the difference
	# between cutting every bend and taking a line through them.
	var cornering := DotVehicleDriver.new()
	cornering.look_ahead = 5.0
	cornering.set_route(PackedVector3Array([Vector3(0, 0, -30), Vector3(30, 0, -30)]))

	var aimed := cornering.drive_from(
		Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
	)

	cornering.look_ahead = 0.0
	cornering.index = 0
	var square := cornering.drive_from(
		Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
	)

	_check(
		aimed.steer > square.steer,
		"look-ahead turns into the corner earlier than aiming at the waypoint",
		"%.3f against %.3f" % [aimed.steer, square.steer]
	)

	driver.clear()
	_check(
		not driver.has_route() and driver.state == DotVehicleDriver.State.IDLE,
		"a cleared route leaves the driver idle"
	)


func _test_driver_stuck() -> void:
	print("driver getting unstuck")

	var driver := DotVehicleDriver.new()
	driver.stuck_time = 0.5
	driver.reverse_time = 0.4
	driver.set_target(Vector3(0, 0, -50))

	# A car against a lamppost: full throttle, no movement. Without this every vehicle
	# AI ends the round parked against the first thing it hit.
	var command: DotVehicleCommand = null
	for i in 20:
		command = driver.drive_from(
			Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
		)

	_check(
		driver.state == DotVehicleDriver.State.REVERSING,
		"a driver asking for throttle and going nowhere decides it is stuck"
	)
	_check(command.throttle < 0.0, "and reverses")

	# Backing out along the line you drove in on puts you back where you were.
	driver.set_target(Vector3(30, 0, -30))
	driver.state = DotVehicleDriver.State.REVERSING
	var backing := driver.drive_from(
		Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
	)
	_check(
		backing.steer < 0.0,
		"turning the wheel the other way, which is what a person does",
		"steer = %.2f" % backing.steer
	)

	# And it gives up reversing rather than backing away for ever.
	#
	# Watched across the loop rather than checked at the end: a car that is still
	# against the lamppost when it stops reversing is stuck again a moment later, so
	# the end state is REVERSING and the thing being tested is that it ever left.
	var went_forward_again := false

	for i in 40:
		driver.drive_from(Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
		if driver.state == DotVehicleDriver.State.DRIVING:
			went_forward_again = true

	_check(
		went_forward_again,
		"and stops reversing once it has had long enough, rather than backing away for ever"
	)

	# A vehicle that is moving is not stuck, however slowly it is going somewhere.
	var moving := DotVehicleDriver.new()
	moving.stuck_time = 0.5
	moving.set_target(Vector3(0, 0, -50))

	for i in 40:
		moving.drive_from(
			Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.FORWARD * 6.0, 0.05
		)

	_check(
		moving.state == DotVehicleDriver.State.DRIVING,
		"a vehicle that is moving is never stuck"
	)

	var patient := DotVehicleDriver.new()
	patient.stuck_time = 0.0
	patient.set_target(Vector3(0, 0, -50))
	for i in 40:
		patient.drive_from(Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	_check(
		patient.state == DotVehicleDriver.State.DRIVING,
		"and a stuck time of zero disables the whole thing"
	)


func _test_driver_drives_a_car() -> void:
	print("driver end to end")

	# The check that is worth all the others: does something actually get there.
	var car := ToyCar.new()
	var driver := DotVehicleDriver.new()
	driver.target_speed = 12.0
	driver.set_route(PackedVector3Array([
		Vector3(0, 0, -40),
		Vector3(40, 0, -40),
		Vector3(40, 0, 0),
	]))

	var took := _drive_toy(driver, car, 60.0)

	_check(took > 0, "a driver takes a car round three corners", "%d ticks" % took)
	_check(
		car.position.distance_to(Vector3(40, 0, 0)) < driver.arrive_radius * 2.0,
		"and ends up at the last waypoint",
		"%.1f m away" % car.position.distance_to(Vector3(40, 0, 0))
	)
	_check(driver.is_arrived(), "and says so")

	# Never a NaN, whatever the arithmetic did on the way. One NaN reaching a physics
	# body puts its transform beyond recovery for the rest of the round, and the
	# vehicle vanishes rather than erroring.
	var clean := ToyCar.new()
	var probe := DotVehicleDriver.new()
	probe.set_route(PackedVector3Array([Vector3(0, 0, -30), Vector3(0, 0, -30)]))

	var sane := true
	for i in 200:
		var command := probe.drive_from(
			clean.position, clean.forward(), clean.right(), clean.velocity(), 0.05
		)
		if is_nan(command.throttle) or is_nan(command.steer) or is_nan(command.brake):
			sane = false
		clean.step(command, 0.05)

	_check(sane, "and never produces a NaN, even from two identical waypoints")

	var reversed := ToyCar.new()
	reversed.yaw = PI
	var turner := DotVehicleDriver.new()
	turner.target_speed = 10.0
	turner.set_target(Vector3(0, 0, -40))

	var turned := _drive_toy(turner, reversed, 40.0)
	_check(
		turned > 0,
		"a car facing entirely the wrong way turns round and gets there",
		"%d ticks" % turned
	)

	var nowhere := DotVehicleDriver.new()
	_check(
		nowhere.drive(null, 0.05).is_idle(),
		"and driving a vehicle that is not there is an idle command, not a crash"
	)

	# The wiring, which is the half that is usually missing: a driver nothing calls is
	# a driver that does not exist. An empty vehicle with an autopilot drives itself.
	var spawner := _spawner()
	var vehicle := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	_check(vehicle != null, "a vehicle spawns for the autopilot check")

	vehicle.autopilot = DotVehicleDriver.new()
	vehicle.autopilot.set_target(Vector3(0, 1, -40))

	for i in 5:
		spawner.tick(0.05)

	_check(
		vehicle.autopilot.state == DotVehicleDriver.State.DRIVING,
		"an empty vehicle with an autopilot is driven by it"
	)

	# And a person takes it over rather than fighting it for the wheel.
	var rider := _rider()
	_world.add_child(rider)
	spawner.ride.enter(vehicle, &"alice", rider)
	spawner.set_command(vehicle.instance_id, &"alice", DotVehicleCommand.make(0.0, 0.0, 1.0))

	var before := vehicle.autopilot.index
	for i in 5:
		spawner.tick(0.05)

	_check(
		vehicle.autopilot.index == before,
		"and a person in the seat wins: the autopilot is not consulted at all"
	)

	spawner.queue_free()


func _test_entering() -> void:
	print("getting in")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))

	var seated: Array[StringName] = []
	# A captured Array rather than a counter: a GDScript lambda captures locals by
	# VALUE, so a counter incremented in a callback stays zero outside it.
	spawner.ride.on_seated = func(rider: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat) -> void:
		seated.append(rider)

	var entered := spawner.ride.enter(jeep, &"alice", _rider())
	_check(entered.ok, "a rider gets in")
	_check(
		(entered.value as DotVehicleSeat).id == &"driver",
		"and an empty vehicle seats them as the driver",
		"definition order, which is what everybody expects and nobody specifies"
	)
	_check(jeep.driver() == &"alice", "and they are driving")
	_check(seated.size() == 1, "and the game is told, so it can stop their controller")

	_check(
		not spawner.ride.enter(jeep, &"bob", _rider(), &"driver").ok,
		"a second rider cannot take a taken seat"
	)

	var second := spawner.ride.enter(jeep, &"bob", _rider())
	_check(second.ok and (second.value as DotVehicleSeat).id == &"passenger",
		"but is seated in the next free one")
	_check(jeep.is_full(), "and the vehicle is full")

	_check(
		not spawner.ride.enter(jeep, &"carol", _rider()).ok,
		"and a third is refused"
	)

	spawner.queue_free()


func _test_seat_rules() -> void:
	print("seat rules")

	var spawner := _spawner()
	var one := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	var two := spawner.spawn(&"jeep", Vector3(0, 1, 30))

	spawner.ride.enter(one, &"alice", _rider())

	_check(
		not spawner.ride.enter(two, &"alice", _rider()).ok,
		"somebody already riding cannot get into a second vehicle",
		"silently moving them teleports a player out of a moving car"
	)
	_check(spawner.ride.is_riding(&"alice"), "and they are still in the first")
	_check(
		spawner.vehicle_of_rider(&"alice") == one,
		"and the reverse lookup agrees"
	)

	_check(
		spawner.nearest_free(Vector3(0, 1, 29), 5.0) == two,
		"the nearest vehicle with a free seat is what a use prompt finds"
	)

	spawner.queue_free()


func _test_exit_placement() -> void:
	print("getting out: the sweep")

	var spawner := _spawner()
	var ground := _wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(0, 0.5, 0))
	var rider := _rider()

	spawner.ride.enter(jeep, &"alice", rider)

	await get_tree().physics_frame

	var seat := jeep.def.get_seat(&"driver")
	var open := spawner.ride.find_exit_position(jeep, seat)

	_check(open.ok, "an exit into open ground is found")
	_check(
		(open.value as Vector3).distance_to(jeep.position()) < 4.0,
		"and it is beside the vehicle"
	)

	# Walls on the first two candidates: the sweep must fall through to the third
	# rather than putting the player in the rock.
	var left := _wall(Vector3(-2.0, 1.0, 0.0), Vector3(1.5, 3, 6))
	var right := _wall(Vector3(2.0, 1.0, 0.0), Vector3(1.5, 3, 6))

	await get_tree().physics_frame

	var squeezed := spawner.ride.find_exit_position(jeep, seat)
	_check(squeezed.ok, "with both sides blocked, a later candidate is used")
	_check(
		absf((squeezed.value as Vector3).x - jeep.position().x) < 1.0,
		"and it is not one of the blocked ones",
		"x = %.2f" % (squeezed.value as Vector3).x
	)

	# Boxed in on every side. Refusing is the correct answer: teleporting the player
	# anyway is how they get outside a map.
	var back := _wall(Vector3(0.0, 1.0, -3.0), Vector3(6, 3, 1.5))
	var above := _wall(Vector3(0.0, 3.0, 0.0), Vector3(6, 1.5, 6))

	await get_tree().physics_frame

	var boxed := spawner.ride.find_exit_position(jeep, seat)
	_check(
		not boxed.ok,
		"and with every candidate blocked, the exit is REFUSED",
		"every game that teleports the player anyway has this bug"
	)

	var attempted := spawner.ride.exit(jeep, &"alice")
	_check(not attempted.ok, "so the rider stays in")
	_check(jeep.driver() == &"alice", "and is still driving")

	var forced := spawner.ride.exit(jeep, &"alice", true)
	_check(
		forced.ok,
		"but a forced exit still puts them somewhere",
		"a destroyed vehicle has to empty even when there is no room"
	)

	for wall in [left, right, back, above, ground]:
		wall.queue_free()

	spawner.queue_free()


func _test_exit_rules() -> void:
	print("getting out: the rules")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	spawner.ride.enter(jeep, &"alice", _rider())

	var body := jeep.body()
	body.linear_velocity = Vector3(0, 0, -30)

	_check(
		not spawner.ride.may_exit(jeep).ok,
		"a rider may not get out at 30 m/s"
	)

	body.linear_velocity = Vector3.ZERO
	_check(spawner.ride.may_exit(jeep).ok, "and may when it has stopped")

	# Upside down AND moving. The inversion rule has to win, or the one state a player
	# cannot drive out of is the one they cannot leave.
	body.linear_velocity = Vector3(0, 0, -30)
	jeep.node.global_transform = Transform3D(
		Basis(Vector3.FORWARD, PI), jeep.node.global_position
	)

	_check(jeep.is_inverted(), "an overturned vehicle knows it is overturned")
	_check(
		spawner.ride.may_exit(jeep).ok,
		"and a rider may always leave one, whatever its speed",
		"a rule that kept them in is a rule that kills them"
	)

	spawner.queue_free()


func _test_carrying_the_rider() -> void:
	print("carrying the rider")

	# Two frames, and 400 metres away from everything else in this file.
	#
	# `queue_free` is DEFERRED, so the walls the exit-placement test boxed a vehicle in
	# with are still in the physics space for the rest of the frame — and the first
	# version of this test spawned its vehicle at the same origin and found every exit
	# blocked by scenery a previous test thought it had removed. It read exactly like a
	# broken ejection.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var spawner := _spawner()
	var ground := _wall(Vector3(400, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(400, 0.5, 0))
	var rider := _rider()
	var original_parent := rider.get_parent()

	var layer_before := rider.collision_layer

	spawner.ride.enter(jeep, &"alice", rider)

	_check(
		rider.get_parent() == jeep.node,
		"the rider's node is parented into the vehicle",
		"the only thing that survives a vehicle rolling over"
	)
	_check(
		rider.collision_layer == 0 and rider.collision_mask == 0,
		"and taken out of the physics world",
		"a rider still colliding shoves the vehicle they are riding in"
	)

	var got_out := spawner.ride.exit(jeep, &"alice")

	_check(got_out.ok, "and they get out again")
	_check(
		rider.get_parent() == original_parent,
		"back into the world they came from"
	)
	_check(
		rider.collision_layer == layer_before,
		"with their collision restored",
		"a rider left on layer 0 walks through the map for the rest of the round"
	)
	_check(
		rider.get_parent() != jeep.node
			and rider.global_position.distance_to(jeep.position()) > 1.0,
		"and standing beside the vehicle rather than inside it",
		"%.2f m" % rider.global_position.distance_to(jeep.position())
	)
	_check(not spawner.ride.is_riding(&"alice"), "and the bookkeeping is undone")

	ground.queue_free()
	spawner.queue_free()


func _test_destruction() -> void:
	print("destruction")

	var spawner := _spawner()
	var wreckable := spawner.spawn(&"wreckable", Vector3(0, 1, 0))
	var alice := _rider()
	var bob := _rider()

	spawner.ride.enter(wreckable, &"alice", alice)
	spawner.ride.enter(wreckable, &"bob", bob)

	_check(wreckable.occupant_count() == 2, "two riders aboard")

	_check(spawner.damage(wreckable.instance_id, 50.0) == 50.0, "it takes damage")
	_check(wreckable.health == 150.0, "and health comes off")

	var wrecked: Array[StringName] = []
	spawner.destroyed.connect(func(_v: DotVehicleInstance, by: StringName) -> void:
		wrecked.append(by))

	spawner.damage(wreckable.instance_id, 500.0, &"alice")

	_check(wrecked.size() == 1, "an overkill destroys it")
	_check(not wreckable.is_alive(), "and it is gone")
	_check(
		not spawner.ride.is_riding(&"alice") and not spawner.ride.is_riding(&"bob"),
		"and EVERYBODY is put down first",
		"a rider in a freed vehicle is parented to nothing: invisible and unkillable"
	)
	_check(
		is_instance_valid(alice) and alice.get_parent() != null,
		"with their nodes back in a real parent"
	)

	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 30))
	_check(
		spawner.damage(jeep.instance_id, 9999.0) == 0.0,
		"and a vehicle with no max_health is indestructible",
		"a real answer a sandbox wants, not an oversight"
	)
	_check(jeep.is_alive(), "and survives")

	spawner.queue_free()


func _test_disconnects() -> void:
	print("disconnects")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0), &"alice")
	spawner.ride.enter(jeep, &"bob", _rider())

	_check(spawner.owner_left(&"alice") == 0,
		"a disconnect does not remove the owner's vehicle by default",
		"it would delete the car its passengers are riding in")
	_check(jeep.is_alive(), "so bob keeps driving")
	_check(spawner.vehicles_of(&"alice").is_empty(),
		"but it is disowned, so a departed player's budget is not held")

	spawner.clean_up_on_leave = true
	var second := spawner.spawn(&"jeep", Vector3(0, 1, 40), &"carol")
	_check(spawner.owner_left(&"carol") == 1, "a server that wants the other rule gets it")
	_check(not second.is_alive(), "and the vehicle goes")

	spawner.queue_free()


func _test_no_leaked_nodes() -> void:
	print("no leaks")

	var holder := Node3D.new()
	_world.add_child(holder)

	var spawner := DotVehicleSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.authoritative = true
	spawner.world_budget = 0
	spawner.per_player_budget = 0
	spawner.spawn_interval = 0.0
	spawner.world_ref = DotNodeRef.of_self()
	holder.add_child(spawner)

	for i in 6:
		spawner.spawn(&"jeep", Vector3(0, 1, float(i) * 20.0))

	# A real count of the tree, not of the dictionary: a budget that counted its own
	# bookkeeping would pass while leaking bodies.
	_check(spawner.get_child_count() == 6, "six vehicles are six nodes",
		"%d" % spawner.get_child_count())

	spawner.clear_all()
	await get_tree().process_frame
	await get_tree().process_frame

	_check(spawner.get_child_count() == 0, "and clearing them frees every one",
		"%d left" % spawner.get_child_count())

	holder.queue_free()


# --- Replication --------------------------------------------------------------

func _test_net_sync() -> void:
	print("replication")

	var specs := DotVehicleNetSync.specs()
	_check(specs.size() == 11, "there is a spec for what crosses the wire",
		"%d" % specs.size())

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(3, 1, -4))
	spawner.ride.enter(jeep, &"alice", _rider())

	var probe := _NetProbe.new()

	# Rolled over onto its side: the case a yaw-only wire format cannot carry, and the
	# reason this one sends a whole quaternion.
	var rolled := Basis(Vector3.FORWARD, deg_to_rad(70.0))
	jeep.node.global_transform = Transform3D(rolled, Vector3(3, 1, -4))

	DotVehicleNetSync.pull(jeep, probe)

	_check(probe.net_x == 3.0 and probe.net_z == -4.0, "a pull copies the position")
	_check(probe.net_health == 100, "and an indestructible vehicle reads as full health",
		"a client cannot tell 'no health' from 'not destructible'")

	var node := Node3D.new()
	_world.add_child(node)
	DotVehicleNetSync.apply(node, probe)

	var received := node.global_transform.basis.get_rotation_quaternion()
	var sent := rolled.get_rotation_quaternion()

	_check(
		received.angle_to(sent) < deg_to_rad(1.0),
		"and the whole orientation survives the wire",
		"%.2f deg out" % rad_to_deg(received.angle_to(sent))
	)
	_check(
		absf(node.global_transform.basis.get_scale().x - 1.0) < 0.01,
		"without the vehicle changing size",
		"four independently quantised components do not make a unit quaternion"
	)

	_check(
		DotVehicleNetSync.is_seat_occupied(probe.net_occupancy, 0),
		"the driver's seat reads as occupied"
	)
	_check(
		not DotVehicleNetSync.is_seat_occupied(probe.net_occupancy, 1),
		"and the empty one does not"
	)

	for degrees in [-30.0, 0.0, 12.5, 32.0]:
		var back := DotVehicleNetSync.dequantise_steering(
			DotVehicleNetSync.quantise_steering(deg_to_rad(degrees))
		)
		_check(
			absf(rad_to_deg(back) - degrees) < 1.0,
			"steering survives quantisation at %.1f degrees" % degrees,
			"%.2f deg out" % absf(rad_to_deg(back) - degrees)
		)

	node.queue_free()
	spawner.queue_free()


## The receiving half of a replication, without dot-net in the project.
class _NetProbe:
	extends RefCounted

	var net_x: float = 0.0
	var net_y: float = 0.0
	var net_z: float = 0.0
	var net_qx: int = 0
	var net_qy: int = 0
	var net_qz: int = 0
	var net_qw: int = 0
	var net_speed: int = 0
	var net_steering: int = 0
	var net_health: int = 0
	var net_occupancy: int = 0
