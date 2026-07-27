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


## The inverse, for anything that needs to name a surface back — track themes,
## the HUD, and the stage summary all do.
static func surface_name(s: Surface) -> String:
	return ["tarmac", "dirt", "gravel", "grass", "snow", "ice", "mud"][clampi(int(s), 0, 6)]


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
