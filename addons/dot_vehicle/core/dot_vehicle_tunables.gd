@tool
class_name DotVehicleTunables
extends DotConfig

## How a vehicle handles, as numbers an operator can change without a build.
##
## [b]A [DotConfig], for [DotFpsTunables]'s reason.[/b] Handling is the half of a
## vehicle that is wrong until somebody drives it, and the difference between a server
## that can be retuned in a file and one that cannot is the difference between an
## evening's iteration and a fortnight of rebuilds. Layered identically to everything
## else here: exported defaults < JSON file < environment < command line.
##
## [b]Applied ONTO the body, never left to whatever the scene was saved with.[/b] This
## is dot-props' mass bug, which cost a night: a catalogue saying 900 kg over a scene
## saved at 20 kg gives a prop a physics gun refuses for being too heavy and a gravity
## gun throws like a beach ball. A vehicle has a dozen such numbers and one scene is
## routinely shared by several definitions, so it would be that bug twelve times.

@export_group("Engine")

## Peak driving force at the wheels, in newtons.
##
## Force rather than horsepower, because that is what a physics engine takes and the
## conversion needs a gearbox nobody here has.
@export_range(0.0, 100000.0, 10.0) var engine_force: float = 4200.0

## Metres per second the vehicle stops accelerating at.
##
## [b]A speed cap rather than a drag curve.[/b] A real drag curve is nicer and needs a
## frontal area, a coefficient and an air density that no operator will ever tune. This
## is one number that does what the curve was wanted for.
@export_range(0.0, 200.0, 0.5) var top_speed: float = 28.0

## Fraction of [member engine_force] available in reverse.
##
## Well under half, because a vehicle that reverses as fast as it drives is one nobody
## bothers to turn round, and that reads as broken handling rather than as a choice.
@export_range(0.0, 1.0, 0.01) var reverse_fraction: float = 0.35

## Braking force, in newtons. Separate from the engine, and usually larger.
@export_range(0.0, 100000.0, 10.0) var brake_force: float = 6000.0

## Braking force the handbrake applies to the rear only.
@export_range(0.0, 100000.0, 10.0) var handbrake_force: float = 12000.0

@export_group("Steering")

## Most the wheels turn, in degrees.
@export_range(0.0, 80.0, 0.5) var steering_limit_deg: float = 32.0

## Degrees of steering per second. The rate the wheels reach the limit at.
##
## [b]A rate rather than an instant angle, and it is what stops a keyboard from being
## an on/off switch.[/b] Full lock on the tick a key goes down flips anything with a
## centre of mass above its axles, and the fix people reach for — lowering the limit —
## makes the vehicle unable to turn at all at low speed.
@export_range(1.0, 720.0, 1.0) var steering_rate_deg: float = 140.0

## How much of the steering limit remains at [member top_speed].
##
## [b]The single most important number in this file.[/b] A vehicle with full lock
## available at speed is a vehicle that spins on the first corner and a player who
## concludes the handling is broken. Every driving game has this falloff and most do
## not tell you.
@export_range(0.05, 1.0, 0.01) var steering_speed_falloff: float = 0.35

## How fast the wheels return to centre with no input, in degrees per second.
@export_range(0.0, 720.0, 1.0) var steering_return_deg: float = 220.0

@export_group("Suspension")

## Travel, in metres.
@export_range(0.01, 2.0, 0.01) var suspension_travel: float = 0.25

## Stiffness, in the engine's units. Higher is a harder ride and less body roll.
@export_range(1.0, 500.0, 1.0) var suspension_stiffness: float = 45.0

## Damping on compression, 0 to 1.
@export_range(0.0, 1.0, 0.01) var damping_compression: float = 0.55

## Damping on relaxation, 0 to 1.
##
## Higher than compression, as it is on every real car: a spring that returns as fast as
## it compresses is one the vehicle bounces on after every kerb.
@export_range(0.0, 1.0, 0.01) var damping_relaxation: float = 0.75

@export_group("Grip")

## Sideways grip before the wheel slides, in the engine's friction-slip units.
@export_range(0.1, 20.0, 0.1) var friction_slip: float = 3.2

## Fraction of [member friction_slip] the rear wheels have.
##
## [b]Under 1.0 makes the back end let go first, and that is deliberate.[/b] Understeer
## is a vehicle that will not turn; oversteer is one that turns too much and can be
## caught. A player can drive out of the second and cannot drive out of the first.
@export_range(0.1, 2.0, 0.01) var rear_grip_fraction: float = 0.9

@export_group("Body")

## Mass in kilograms. Written onto the body at spawn.
@export_range(1.0, 100000.0, 1.0) var mass: float = 900.0

## How far below the body's origin the centre of mass is put, in metres.
##
## [b]The difference between a car and a thing that rolls over at every corner.[/b] A
## rigid body's default centre of mass is its origin, which on a vehicle scene is
## usually at the axle line or above it. Every physics-vehicle tutorial ends with this
## line and most of them do not say why.
@export_range(0.0, 3.0, 0.01) var centre_of_mass_drop: float = 0.5

@export_group("Rules")

## Metres per second above which a rider may not get out.
##
## 0 allows it at any speed. The default is a brisk walk: a player who leaps from a
## moving vehicle either takes the fall damage a game has not written or lands inside
## the geometry the vehicle was about to be in.
@export_range(0.0, 100.0, 0.5) var max_exit_speed: float = 4.0

## Whether a rider may get out of a vehicle that is upside down.
##
## [b]On, and it is the opposite of what the speed rule suggests.[/b] The one state a
## player must always be able to leave is the one they cannot drive out of. A rule that
## kept them in an overturned vehicle is a rule that kills them.
@export var allow_exit_when_inverted: bool = true


func env_prefix() -> String:
	return "DOT_VEHICLE_"


func cli_prefix() -> String:
	return "--vehicle-"


func steering_limit() -> float:
	return deg_to_rad(steering_limit_deg)


func steering_rate() -> float:
	return deg_to_rad(steering_rate_deg)


func steering_return() -> float:
	return deg_to_rad(steering_return_deg)


## The steering limit available at [param speed], in radians.
##
## Linear between full lock at rest and [member steering_speed_falloff] of it at
## [member top_speed], and clamped there rather than continuing to fall: a vehicle
## driven off a cliff arrives at the bottom above its top speed, and steering that kept
## shrinking would leave it unsteerable for several seconds after it landed.
func steering_limit_at(speed: float) -> float:
	if top_speed <= 0.0:
		return steering_limit()

	var t := clampf(absf(speed) / top_speed, 0.0, 1.0)

	return steering_limit() * lerpf(1.0, steering_speed_falloff, t)


func validate() -> DotResult:
	if top_speed <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"top_speed must be positive, or nothing ever accelerates.",
			"%.1f" % top_speed
		)

	if mass <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "A vehicle needs a positive mass.", "%.1f" % mass
		)

	if brake_force < engine_force * 0.5:
		# Not fatal, and worth refusing anyway: a vehicle that cannot out-brake its own
		# engine reads as having no brakes at all, and the operator who tuned the engine
		# up is the one who will report it as a physics bug.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"brake_force is less than half of engine_force, so this vehicle cannot stop itself.",
			"%.0f N against %.0f N" % [brake_force, engine_force]
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%.0f N to %.0f m/s, %.0f deg lock falling to %d%%, %.0f kg" % [
		engine_force,
		top_speed,
		steering_limit_deg,
		int(steering_speed_falloff * 100.0),
		mass,
	]
