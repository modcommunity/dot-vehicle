class_name DotVehicleDriver
extends RefCounted

## Turns "go there" into a [DotVehicleCommand]. What lets something other than a
## person drive.
##
## [b]The gap this fills.[/b] dot-vehicle has always said a command is built by the
## game "from a keyboard, a gamepad, a touch layout or a bot" — and shipped the first
## three shapes and nothing for the fourth. So a vehicle could be driven and could not
## be driven [i]by anything[/i]: no convoy, no chase, no NPC that gets in a car, no
## demo of a vehicle that moves without somebody holding a key.
##
## [b]It knows nothing about physics and nothing about the world.[/b] It reads a
## position, a heading and a velocity, and returns throttle, steer and brake. That is
## deliberate three times over: it is testable with no physics server at all, it works
## for a chassis this addon has never seen, and it cannot accidentally become a second
## place where driving is simulated.
##
## [codeblock]
## var driver := DotVehicleDriver.new()
## driver.set_route(PackedVector3Array([a, b, c]))
##
## # Every tick, on the server:
## var command := driver.drive(vehicle, delta)
## vehicle.chassis.drive(command, delta)
## [/codeblock]
##
## [b]It does not path.[/b] Give it a route — from dot-npc's graph, from a spline a
## level designer drew, from four points in a config file — and it follows it. Deciding
## where to go is a different problem and putting it here would make this addon depend
## on a navigation one.

const CHANNEL := "vehicle"

## What the driver is currently doing. For a debug overlay and for a game that wants
## to know why its convoy has stopped.
enum State {
	IDLE,       ## Nowhere to go.
	DRIVING,    ## On the way.
	ARRIVED,    ## Close enough to the last waypoint.
	REVERSING,  ## Backing out of something it drove into.
}

# --- Route ---

## How close counts as having reached a middle waypoint.
##
## Generous on purpose. A car cannot stop on a point, and a waypoint radius tighter
## than the turning circle produces a vehicle that circles the waypoint it cannot quite
## touch — which looks exactly like a broken follower and is a number.
var waypoint_radius: float = 6.0

## How close counts as having arrived at the last one.
var arrive_radius: float = 3.0

## How far ahead to aim on a route.
##
## Steering at the next waypoint makes a vehicle cut every corner and then swing wide;
## aiming a little past it is what makes a racing line. Zero disables it.
var look_ahead: float = 4.0

# --- Speed ---

## Metres per second the driver tries to hold on a straight.
##
## Nothing here knows the vehicle's top speed — that is in its tunables and the driver
## deliberately does not read them, so one driver can serve a lorry and a go-kart. A
## game that wants "as fast as it will go" sets this from `tunables.top_speed`.
var target_speed: float = 14.0

## How much the corner ahead reduces the target speed.
##
## At 1.0 a right-angle turn cuts the target to nothing, which stops the vehicle dead
## in every corner; at 0 it takes every corner flat out and understeers off the road.
var corner_slowdown: float = 0.75

## How hard to brake when over the speed the corner allows. 0 coasts instead.
var brake_gain: float = 1.5

## Slow to this fraction of the target when closing on the final waypoint.
var arrive_slowdown: float = 0.35

# --- Steering ---

## The steering angle, in degrees, at which the command reaches full lock.
##
## Not the vehicle's steering limit, which is the chassis's business. This is how
## aggressively the driver asks: a small number makes it saw at the wheel, a large one
## makes it lazy about lining up.
var steering_response_deg: float = 35.0

## Above this steering demand and speed, pull the handbrake.
##
## Off by default (a handbrake turn is a driving style, not a way to get somewhere) and
## it is here because the alternative is every game writing it.
var handbrake_angle_deg: float = 120.0
var handbrake_min_speed: float = 12.0

# --- Getting unstuck ---

## Below this speed, while asking for throttle, counts as not moving.
var stuck_speed: float = 0.6

## Seconds of not moving before the driver decides it is stuck.
##
## [b]Every vehicle AI needs this and the ones that skip it are the ones that end up
## with a lorry against a lamppost for the rest of the round.[/b] Long enough not to
## trigger while pulling away from a standing start, short enough that a person
## watching does not have time to notice.
var stuck_time: float = 1.5

## Seconds spent reversing once it has decided it is stuck.
var reverse_time: float = 1.2

## Whether to steer the opposite way while reversing.
##
## On. Backing out along the line you drove in on puts you back where you were; turning
## the wheel the other way is what actually changes the situation, and it is what a
## person does without thinking about it.
var counter_steer_reversing: bool = true

var state: State = State.IDLE

## The route, world space. Empty for a driver aimed at a single point.
var route: PackedVector3Array = PackedVector3Array()

## Which waypoint is being driven to.
var index: int = 0

var _stuck_for: float = 0.0
var _reversing_for: float = 0.0
var _last_command: DotVehicleCommand = null


# --- Where to go --------------------------------------------------------------

## Follows a route. Resets everything about the last one.
func set_route(points: PackedVector3Array) -> void:
	route = points
	index = 0
	state = State.IDLE if points.is_empty() else State.DRIVING
	_stuck_for = 0.0
	_reversing_for = 0.0


## Drives at one point. The single-waypoint case, spelled out because it is most of
## them.
func set_target(point: Vector3) -> void:
	set_route(PackedVector3Array([point]))


func clear() -> void:
	set_route(PackedVector3Array())


func has_route() -> bool:
	return index < route.size()


## The point currently being driven to, or [param fallback].
func current_waypoint(fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return route[index] if has_route() else fallback


func is_last_waypoint() -> bool:
	return index >= route.size() - 1


# --- Driving ------------------------------------------------------------------

## One tick's command for a vehicle. The ordinary entry point.
func drive(vehicle: DotVehicleInstance, delta: float) -> DotVehicleCommand:
	if vehicle == null or not vehicle.is_alive():
		state = State.IDLE
		return DotVehicleCommand.new()

	var transform := vehicle.node.global_transform

	return drive_from(
		transform.origin,
		-transform.basis.z,
		transform.basis.x,
		vehicle.velocity(),
		delta
	)


## The same decision from raw numbers, for anything that is not a
## [DotVehicleInstance] — and for a test with no physics server in it.
##
## [param forward] and [param right] are the vehicle's own axes, so a vehicle on a
## banked corner steers in its own frame rather than in the world's. Both are
## normalised here; a caller passing a basis column has already normalised them and the
## second call costs nothing worth measuring.
func drive_from(
	position: Vector3,
	forward: Vector3,
	right: Vector3,
	velocity: Vector3,
	delta: float
) -> DotVehicleCommand:
	var command := DotVehicleCommand.new()

	if not has_route():
		state = State.ARRIVED if not route.is_empty() else State.IDLE
		# Braking rather than coasting on arrival. A vehicle handed no command rolls on
		# at whatever speed it had, and "arrived" then means "went past".
		command.brake = 1.0
		return _finish(command)

	var heading := forward.normalized() if forward.length_squared() > 0.0 else Vector3.FORWARD
	var side := right.normalized() if right.length_squared() > 0.0 else Vector3.RIGHT

	var speed := velocity.dot(heading)
	var goal := _advance_waypoints(position)

	if not has_route():
		state = State.ARRIVED
		command.brake = 1.0
		return _finish(command)

	var to_goal := goal - position
	to_goal.y = 0.0

	var distance := to_goal.length()

	if distance <= 0.001:
		command.brake = 1.0
		return _finish(command)

	var wanted := to_goal / distance

	# The signed angle, in the vehicle's own frame. A world-space yaw is wrong on
	# anything that pitches or rolls, and a vehicle on a hillside pitches.
	var forward_dot := clampf(wanted.dot(heading), -1.0, 1.0)
	var side_dot := wanted.dot(side)
	var angle := acos(forward_dot)
	var signed_angle := angle if side_dot >= 0.0 else -angle

	var was_reversing := state == State.REVERSING
	_track_stuck(speed, delta)

	# DEBUG on the EDGE into reversing, never per tick: "why has my convoy stopped" is
	# the question this state exists to answer, and a vehicle that gets stuck over and
	# over at one spot is a route through something solid, which is the level's bug.
	if state == State.REVERSING and not was_reversing:
		DotLog.debug(CHANNEL, "a driven vehicle is stuck; reversing out", {
			"position": position.snapped(Vector3(0.1, 0.1, 0.1)),
			"waypoint": index,
			"of": route.size(),
		})

	if state == State.REVERSING:
		return _finish(_reverse(command, signed_angle, delta))

	state = State.DRIVING

	# +1 steers right, and right is +X in the vehicle's own basis. That is
	# DotVehicleCommand's convention and not Godot's; DotVehicleWheeled flips it once,
	# where the engine's own signs are documented.
	command.steer = clampf(
		signed_angle / deg_to_rad(maxf(steering_response_deg, 1.0)), -1.0, 1.0
	)

	var wanted_speed := _speed_for(angle, distance)

	if speed > wanted_speed:
		# Braking rather than lifting off, because a vehicle that only lifts off enters
		# every corner at whatever speed the straight left it at.
		command.throttle = 0.0
		command.brake = clampf((speed - wanted_speed) * brake_gain / maxf(target_speed, 1.0), 0.0, 1.0)
	else:
		command.throttle = clampf(
			(wanted_speed - speed) / maxf(target_speed, 1.0) + 0.25, 0.0, 1.0
		)

	if (
		handbrake_angle_deg > 0.0
		and absf(signed_angle) >= deg_to_rad(handbrake_angle_deg)
		and speed >= handbrake_min_speed
	):
		command.handbrake = true

	return _finish(command)


## The speed to be doing, given how sharp the corner is and how close the end is.
func _speed_for(angle: float, distance: float) -> float:
	var sharpness := clampf(angle / PI, 0.0, 1.0)
	var wanted := target_speed * (1.0 - sharpness * corner_slowdown)

	if is_last_waypoint():
		# Eased down over the last stretch rather than switched at the radius. A
		# vehicle that drove flat out to the arrival circle and then braked stops
		# somewhere past it, every time.
		var closing := clampf(distance / maxf(arrive_radius * 4.0, 1.0), 0.0, 1.0)
		wanted = minf(wanted, target_speed * lerpf(arrive_slowdown, 1.0, closing))

	return maxf(wanted, 0.0)


## Moves past waypoints that have been reached. Returns the point to aim at.
func _advance_waypoints(position: Vector3) -> Vector3:
	while has_route():
		var point := route[index]
		var flat := point - position
		flat.y = 0.0

		var radius := arrive_radius if is_last_waypoint() else waypoint_radius

		if flat.length() > radius:
			break

		index += 1

	if not has_route():
		return position

	var goal := route[index]

	# Aim a little past the waypoint, along the leg that follows it. This is what makes
	# the difference between cutting every corner and taking a line through them.
	if look_ahead > 0.0 and index + 1 < route.size():
		var leg := route[index + 1] - goal
		if leg.length() > 0.001:
			goal += leg.normalized() * minf(look_ahead, leg.length() * 0.5)

	return goal


func _track_stuck(speed: float, delta: float) -> void:
	if state == State.REVERSING:
		_reversing_for += delta

		if _reversing_for >= reverse_time:
			state = State.DRIVING
			_reversing_for = 0.0
			_stuck_for = 0.0

		return

	var asking := _last_command != null and _last_command.throttle > 0.2

	if asking and absf(speed) < stuck_speed:
		_stuck_for += delta

		if stuck_time > 0.0 and _stuck_for >= stuck_time:
			state = State.REVERSING
			_reversing_for = 0.0
	else:
		_stuck_for = 0.0


func _reverse(
	command: DotVehicleCommand, signed_angle: float, _delta: float
) -> DotVehicleCommand:
	command.throttle = -1.0

	var steer := clampf(
		signed_angle / deg_to_rad(maxf(steering_response_deg, 1.0)), -1.0, 1.0
	)

	# Backing out along the line you drove in on puts you back where you were. Turning
	# the other way is what changes the situation — and reversing inverts the steering
	# geometry anyway, so the sign flip is what makes the wheel point where a person
	# would put it.
	command.steer = -steer if counter_steer_reversing else steer

	return command


func _finish(command: DotVehicleCommand) -> DotVehicleCommand:
	command.sanitise()
	_last_command = command
	return command


## Whether the driver has run out of route.
func is_arrived() -> bool:
	return state == State.ARRIVED


func state_name() -> String:
	return ["idle", "driving", "arrived", "reversing"][int(state)]


func describe() -> Dictionary:
	return {
		"state": state_name(),
		"waypoint": "%d/%d" % [index, route.size()],
		"stuck_for": "%.2f" % _stuck_for,
		"target_speed": target_speed,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("vehicle driver: %s, waypoint %d of %d" % [
		state_name(), index, route.size()
	])

	if _last_command != null:
		out.append("  last command: %s" % str(_last_command.describe()))

	return out


func _to_string() -> String:
	return "DotVehicleDriver(%s)" % state_name()
