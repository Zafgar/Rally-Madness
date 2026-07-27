class_name TireModel
extends RefCounted
## Simplified Pacejka-style tire curves.
##
## The shape that matters for feel is: force climbs to a peak at a small slip
## angle, then falls away to a lower sliding value. The size of that drop, and
## how fast it happens, is the whole difference between a car that snaps into a
## spin and one that hangs out in a controllable drift.

## Slip angle (radians) at which lateral grip peaks on a stock tire. About 8
## degrees, which is where real tires live.
const BASE_PEAK_SLIP_ANGLE := 0.14
## Slip ratio at which longitudinal grip peaks.
const BASE_PEAK_SLIP_RATIO := 0.12
## Sliding friction as a fraction of peak. Below 1.0 is what makes a spin
## self-sustaining unless the driver catches it.
const SLIDE_RATIO := 0.72

## Surface identifiers used by track zones.
enum Surface { TARMAC, DIRT, GRAVEL, GRASS, SNOW, ICE, MUD }

## Base friction multiplier per surface, before the tire compound's own
## per-surface bonus is applied.
const SURFACE_GRIP := {
	Surface.TARMAC: 1.00,
	Surface.DIRT: 0.78,
	Surface.GRAVEL: 0.72,
	Surface.GRASS: 0.62,
	Surface.SNOW: 0.50,
	Surface.ICE: 0.28,
	Surface.MUD: 0.55,
}

## How much each surface drags on a rolling wheel.
const SURFACE_DRAG := {
	Surface.TARMAC: 1.0,
	Surface.DIRT: 1.5,
	Surface.GRAVEL: 1.7,
	Surface.GRASS: 2.6,
	Surface.SNOW: 2.2,
	Surface.ICE: 0.8,
	Surface.MUD: 4.0,
}


## Normalised force curve: rises to 1.0 at the peak, then decays toward
## SLIDE_RATIO. `release` scales how abruptly that decay happens — high values
## are snappy and punishing, low values are progressive and driftable.
static func curve(normalized_slip: float, release: float) -> float:
	var a := absf(normalized_slip)
	var f: float
	if a <= 1.0:
		f = sin(PI * 0.5 * a)
	else:
		var t := 1.0 - exp(-(a - 1.0) * maxf(release, 0.05) * 2.0)
		f = lerpf(1.0, SLIDE_RATIO, t)
	return signf(normalized_slip) * f


## Lateral force coefficient for a slip angle, signed to oppose the slip.
static func lateral(slip_angle: float, stats: VehicleStats) -> float:
	var peak := BASE_PEAK_SLIP_ANGLE * stats.slip_forgiveness
	return -curve(slip_angle / peak, stats.drift_release)


## Longitudinal force coefficient for a slip ratio.
static func longitudinal(slip_ratio: float, stats: VehicleStats) -> float:
	var peak := BASE_PEAK_SLIP_RATIO * stats.slip_forgiveness
	return curve(slip_ratio / peak, stats.drift_release)


## Effective friction coefficient for one axle, folding in the compound's
## surface specialisation. This is where gravel tires beat slicks in a forest.
static func surface_mu(stats: VehicleStats, surface: Surface, lateral_axis: bool) -> float:
	var base: float = SURFACE_GRIP.get(surface, 1.0)
	var compound := 1.0
	match surface:
		Surface.TARMAC:
			compound = stats.tarmac_grip
		Surface.DIRT, Surface.GRAVEL, Surface.MUD:
			compound = stats.dirt_grip
		Surface.SNOW, Surface.ICE:
			compound = stats.snow_grip
		Surface.GRASS:
			compound = (stats.dirt_grip + stats.tarmac_grip) * 0.5
	var axis_grip := stats.grip_lat if lateral_axis else stats.grip_long
	return base * compound * axis_grip


## Friction ellipse. A tire has one budget of grip to spend; asking for
## everything longitudinally leaves nothing for cornering. Returns the scale to
## apply to both components so the combined demand stays inside the circle.
static func combined_limit(fx: float, fy: float, fx_max: float, fy_max: float) -> float:
	if fx_max <= 0.0 or fy_max <= 0.0:
		return 0.0
	var demand := sqrt(pow(fx / fx_max, 2.0) + pow(fy / fy_max, 2.0))
	if demand <= 1.0:
		return 1.0
	return 1.0 / demand


static func surface_from_string(name: String) -> Surface:
	match name.to_lower():
		"tarmac", "asphalt", "road": return Surface.TARMAC
		"dirt": return Surface.DIRT
		"gravel": return Surface.GRAVEL
		"grass": return Surface.GRASS
		"snow": return Surface.SNOW
		"ice": return Surface.ICE
		"mud": return Surface.MUD
		_: return Surface.TARMAC
