extends RefCounted

## The driver sections of the suite, split out of vehicle_selftest.gd to keep it readable.

var t: Node


func _init(suite: Node) -> void:
	t = suite



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


func test_driver_steering() -> void:
	t._section("driver steering")

	var driver := DotVehicleDriver.new()
	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT

	# +1 steers right, which is this family's convention and not Godot's — the
	# wheeled chassis flips it once, where the engine's own signs are documented.
	driver.set_target(Vector3(20, 0, -20))
	var to_the_right := driver.drive_from(
		Vector3.ZERO, forward, right, Vector3.ZERO, 0.05
	)
	t._check(to_the_right.steer > 0.1, "a goal to the right steers right",
		"steer = %.2f" % to_the_right.steer)

	driver.set_target(Vector3(-20, 0, -20))
	var to_the_left := driver.drive_from(Vector3.ZERO, forward, right, Vector3.ZERO, 0.05)
	t._check(to_the_left.steer < -0.1, "and one to the left steers left")

	driver.set_target(Vector3(0, 0, -40))
	var straight := driver.drive_from(Vector3.ZERO, forward, right, Vector3.ZERO, 0.05)
	t._check(absf(straight.steer) < 0.05, "and one dead ahead steers straight")
	t._check(straight.throttle > 0.0, "and gets some throttle")

	# The vehicle's own axes, not the world's. A car on a banked corner is rolled and a
	# world-space yaw is the wrong question.
	var rolled_right := Vector3(0.7, 0.7, 0.0).normalized()
	driver.set_target(Vector3(20, 0, -20))
	var banked := driver.drive_from(
		Vector3.ZERO, forward, rolled_right, Vector3.ZERO, 0.05
	)
	t._check(banked.steer > 0.0, "steering is computed in the vehicle's own frame")

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

	t._check(
		on_a_straight.throttle > 0.0,
		"a straight ahead gets throttle at five metres a second"
	)
	t._check(
		into_a_corner.brake > 0.0 and into_a_corner.throttle == 0.0,
		"and a hairpin at eighteen gets the brakes rather than a lift",
		"brake = %.2f" % into_a_corner.brake
	)

	var idle := DotVehicleDriver.new()
	var nothing := idle.drive_from(Vector3.ZERO, forward, right, forward * 10.0, 0.05)
	t._check(
		idle.state == DotVehicleDriver.State.IDLE,
		"a driver with nowhere to go is idle"
	)
	t._check(
		nothing.brake >= 1.0,
		"and brakes rather than coasting, or 'arrived' means 'went past'"
	)
	t._done()


func test_driver_route() -> void:
	t._section("driver route")

	var driver := DotVehicleDriver.new()
	driver.set_route(PackedVector3Array([
		Vector3(0, 0, -20), Vector3(0, 0, -40), Vector3(0, 0, -60),
	]))

	t._check(driver.has_route(), "a route is taken")
	t._check(driver.index == 0, "starting at the first waypoint")
	t._check(not driver.is_last_waypoint(), "which is not the last one")

	# Standing on the first waypoint advances past it rather than circling it: a
	# waypoint radius tighter than the turning circle is a car orbiting a point it
	# cannot quite touch.
	driver.drive_from(Vector3(0, 0, -20), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	t._check(driver.index == 1, "arriving at one moves on to the next", "%d" % driver.index)

	# Walked in order, deliberately. A driver handed a position beyond the next
	# waypoint does not skip to the end: the route is the route, and a follower that
	# jumped to whichever point was nearest would cut a hairpin by driving through the
	# middle of it.
	driver.drive_from(Vector3(0, 0, -59), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	t._check(
		driver.index == 1,
		"and standing past a waypoint does not skip the ones in between",
		"index %d" % driver.index
	)

	driver.drive_from(Vector3(0, 0, -40), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	driver.drive_from(Vector3(0, 0, -59), Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	t._check(driver.is_arrived(), "and the last one ends the route")
	t._check(
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

	t._check(
		aimed.steer > square.steer,
		"look-ahead turns into the corner earlier than aiming at the waypoint",
		"%.3f against %.3f" % [aimed.steer, square.steer]
	)

	driver.clear()
	t._check(
		not driver.has_route() and driver.state == DotVehicleDriver.State.IDLE,
		"a cleared route leaves the driver idle"
	)
	t._done()


func test_driver_stuck() -> void:
	t._section("driver getting unstuck")

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

	t._check(
		driver.state == DotVehicleDriver.State.REVERSING,
		"a driver asking for throttle and going nowhere decides it is stuck"
	)
	t._check(command.throttle < 0.0, "and reverses")

	# Backing out along the line you drove in on puts you back where you were.
	driver.set_target(Vector3(30, 0, -30))
	driver.state = DotVehicleDriver.State.REVERSING
	var backing := driver.drive_from(
		Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05
	)
	t._check(
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

	t._check(
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

	t._check(
		moving.state == DotVehicleDriver.State.DRIVING,
		"a vehicle that is moving is never stuck"
	)

	var patient := DotVehicleDriver.new()
	patient.stuck_time = 0.0
	patient.set_target(Vector3(0, 0, -50))
	for i in 40:
		patient.drive_from(Vector3.ZERO, Vector3.FORWARD, Vector3.RIGHT, Vector3.ZERO, 0.05)
	t._check(
		patient.state == DotVehicleDriver.State.DRIVING,
		"and a stuck time of zero disables the whole thing"
	)
	t._done()


func test_driver_drives_a_car() -> void:
	t._section("driver end to end")

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

	t._check(took > 0, "a driver takes a car round three corners", "%d ticks" % took)
	t._check(
		car.position.distance_to(Vector3(40, 0, 0)) < driver.arrive_radius * 2.0,
		"and ends up at the last waypoint",
		"%.1f m away" % car.position.distance_to(Vector3(40, 0, 0))
	)
	t._check(driver.is_arrived(), "and says so")

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

	t._check(sane, "and never produces a NaN, even from two identical waypoints")

	var reversed := ToyCar.new()
	reversed.yaw = PI
	var turner := DotVehicleDriver.new()
	turner.target_speed = 10.0
	turner.set_target(Vector3(0, 0, -40))

	var turned := _drive_toy(turner, reversed, 40.0)
	t._check(
		turned > 0,
		"a car facing entirely the wrong way turns round and gets there",
		"%d ticks" % turned
	)

	var nowhere := DotVehicleDriver.new()
	t._check(
		nowhere.drive(null, 0.05).is_idle(),
		"and driving a vehicle that is not there is an idle command, not a crash"
	)

	# The wiring, which is the half that is usually missing: a driver nothing calls is
	# a driver that does not exist. An empty vehicle with an autopilot drives itself.
	var spawner: DotVehicleSpawner = t._spawner()
	var vehicle := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	t._check(vehicle != null, "a vehicle spawns for the autopilot check")

	vehicle.autopilot = DotVehicleDriver.new()
	vehicle.autopilot.set_target(Vector3(0, 1, -40))

	for i in 5:
		spawner.tick(0.05)

	t._check(
		vehicle.autopilot.state == DotVehicleDriver.State.DRIVING,
		"an empty vehicle with an autopilot is driven by it"
	)

	# And a person takes it over rather than fighting it for the wheel.
	var rider: CharacterBody3D = t._rider()
	spawner.ride.enter(vehicle, &"alice", rider)
	spawner.set_command(vehicle.instance_id, &"alice", DotVehicleCommand.make(0.0, 0.0, 1.0))

	var before := vehicle.autopilot.index
	for i in 5:
		spawner.tick(0.05)

	t._check(
		vehicle.autopilot.index == before,
		"and a person in the seat wins: the autopilot is not consulted at all"
	)

	spawner.queue_free()
	t._done()
