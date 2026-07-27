class_name TrackModel
extends RefCounted
## What the road actually is, worked out once from its geometry.
##
## The AI used to drive by scanning a handful of points ahead every frame and
## reacting to whatever it found. That is why a quick driver crashed: reacting
## to a corner is always too late, because the moment you can see that you are
## going too fast is the moment it is already too late to do anything about it.
## A driver who has walked the stage knows the corner is coming, knows how long
## it runs for, and knows where to brake — before there is anything to see.
##
## So this is the recce. It reads the centreline and turns it into the things a
## driver actually has in their head:
##
##   * where each corner starts, where it tightens, and where it lets go
##   * how sharp each one is, and how far it runs
##   * how long the straight before it is
##   * which of those straights are long enough that a pass could be finished
##     before the next braking point
##
## All of it comes from the curve, so it works on a track nobody has annotated
## and on a track added tomorrow. Nothing here knows anything about any car —
## that is the speed profile's job, and it is deliberately separate, because
## the road is the same for everybody and what you can do on it is not.

## Distance between samples, in metres. Fine enough that a hairpin is a dozen
## points rather than three, coarse enough that a forty-kilometre stage is
## still a few thousand samples and solves in milliseconds.
const SPACING_M := 3.0

## Above this curvature the road is a corner rather than a straight — one over
## a radius, so this is a 90 metre radius. Chosen because a 90 metre bend is
## the point at which a rally car has to think about it, and anything larger is
## a straight you can hold flat.
const CORNER_CURVATURE := 1.0 / 90.0
## A corner has to be at least this long to be a corner rather than a kink in
## the surveying. Without it, sampling noise on a straight produces a hundred
## one-sample "corners" and the model becomes useless.
const MIN_CORNER_LENGTH_M := 8.0
## Two corners closer together than this are one corner with a breath in the
## middle — a chicane or an S — and have to be treated as one, because you
## cannot use the road between them for anything.
const CORNER_MERGE_GAP_M := 14.0

## A straight has to be at least this long before a pass down it is realistic.
## Below this the cars are still sorting themselves out from the last corner.
const MIN_PASS_STRAIGHT_M := 90.0
## And the road has to be wide enough for two cars with something to spare.
const MIN_PASS_WIDTH_M := 7.0


## One corner, from the point the driver has to start thinking about it to the
## point they can stop.
class Bend extends RefCounted:
	## Indices into the model's sample arrays.
	var entry: int = 0
	var apex: int = 0
	var exit: int = 0
	## Distances along the road, in metres.
	var entry_s: float = 0.0
	var apex_s: float = 0.0
	var exit_s: float = 0.0
	## The tightest radius anywhere in it, in metres. This is the number that
	## decides how slowly it has to be taken.
	var min_radius: float = 1000.0
	## +1 for a left-hander, -1 for a right.
	var direction: float = 1.0
	## How far the road turns through it, in radians. A 30-degree kink and a
	## hairpin can share a radius; only this tells them apart.
	var turned: float = 0.0

	func length_m() -> float:
		return exit_s - entry_s

	## A hairpin is slow and long; a fast sweeper is neither. Used to decide
	## whether a corner is worth setting up for.
	func is_slow() -> bool:
		return min_radius < 40.0

	func describe() -> String:
		var hand := "left" if direction > 0.0 else "right"
		return "%s %.0f m radius, %.0f deg over %.0f m" % [
			hand, min_radius, rad_to_deg(turned), length_m()]


## A stretch where a pass can be started with a realistic chance of finishing
## it before somebody has to brake.
class PassZone extends RefCounted:
	var start_s: float = 0.0
	## Where the braking for the next corner begins for a typical car. Past
	## this, a pass is a collision.
	var end_s: float = 0.0
	## The corner it runs into, which is what the pass has to be completed
	## before. Null on a stage that ends in a straight.
	var into: Bend = null

	func length_m() -> float:
		return end_s - start_s


# --- Sampled road -----------------------------------------------------------

var spec: TrackSpec
var closed: bool = true
var width_m: float = 10.0
var length_m: float = 0.0

## Position in world pixels at each sample.
var positions: PackedVector2Array = PackedVector2Array()
## Unit tangent and left-hand normal at each sample.
var directions: PackedVector2Array = PackedVector2Array()
var normals: PackedVector2Array = PackedVector2Array()
## Signed curvature in 1/metres. Positive turns left.
var curvature: PackedFloat32Array = PackedFloat32Array()
var surfaces: PackedInt32Array = PackedInt32Array()

var corners: Array[Bend] = []
var pass_zones: Array[PassZone] = []


static func analyse(builder: TrackBuilder) -> TrackModel:
	var m := TrackModel.new()
	m.spec = builder.spec
	m.closed = builder.spec.closed
	m.width_m = builder.spec.width
	m._sample(builder)
	m._measure_curvature()
	m._find_corners()
	m._find_pass_zones()
	return m


# --- Sampling ---------------------------------------------------------------

func _sample(builder: TrackBuilder) -> void:
	var ppm := GameConfig.PIXELS_PER_METRE
	length_m = builder.total_length_px / ppm
	var count := maxi(int(length_m / SPACING_M), 8)
	positions.resize(count)
	directions.resize(count)
	normals.resize(count)
	curvature.resize(count)
	surfaces.resize(count)

	for i in count:
		var offset_px := float(i) * SPACING_M * ppm
		positions[i] = builder.curve.sample_baked(
			clampf(offset_px, 0.0, builder.total_length_px))
		surfaces[i] = int(builder.surface_at_offset(offset_px))

	# Tangents from the sampled points themselves rather than from the curve.
	# The curve's own tangent is exact, and that is the problem: it reports the
	# spline's direction at a point, which on a coarse spline wobbles between
	# control points in a way the road does not. What the driver cares about is
	# the direction the road goes over the next few metres.
	for i in count:
		var ahead := positions[_wrap(i + 1)]
		var behind := positions[_wrap(i - 1)]
		var dir := (ahead - behind).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.RIGHT
		directions[i] = dir
		normals[i] = Vector2(-dir.y, dir.x)


## Index arithmetic that wraps on a circuit and clamps on a stage, which is the
## difference between a lap and a finish line.
func _wrap(i: int) -> int:
	var n := positions.size()
	if n == 0:
		return 0
	if closed:
		return ((i % n) + n) % n
	return clampi(i, 0, n - 1)


# --- Curvature --------------------------------------------------------------

## Menger curvature: the reciprocal radius of the circle through three points.
##
## The obvious alternative — the change in heading between consecutive samples,
## divided by the distance — is the same quantity in principle and far worse in
## practice, because it differentiates a noisy angle. This differentiates
## nothing; it is a closed-form circle fit, so a sampling wobble moves the
## answer a little instead of spiking it.
func _measure_curvature() -> void:
	var ppm := GameConfig.PIXELS_PER_METRE
	for i in positions.size():
		var a := positions[_wrap(i - 2)] / ppm
		var b := positions[i] / ppm
		var c := positions[_wrap(i + 2)] / ppm
		var ab := b - a
		var bc := c - b
		var ca := a - c
		var cross := ab.cross(bc)
		var denominator := ab.length() * bc.length() * ca.length()
		if absf(denominator) < 0.001:
			curvature[i] = 0.0
			continue
		# 4 * signed area / product of side lengths. The sign comes free from
		# the cross product, which is exactly the left/right handedness wanted.
		curvature[i] = 2.0 * cross / denominator

	_smooth(curvature, 2)


## A short box blur over a sampled series, run in place. Two passes takes the
## edge off sampling noise without moving where a corner starts.
func _smooth(values: PackedFloat32Array, passes: int) -> void:
	for pass_index in passes:
		var copy := values.duplicate()
		for i in values.size():
			values[i] = (copy[_wrap(i - 1)] + copy[i] * 2.0 + copy[_wrap(i + 1)]) * 0.25


## Radius in metres at a sample. Enormous on a straight, which is correct.
func radius_at(i: int) -> float:
	var k := absf(curvature[_wrap(i)])
	return 100000.0 if k < 0.00001 else 1.0 / k


# --- Corners ----------------------------------------------------------------

func _find_corners() -> void:
	corners.clear()
	var count := curvature.size()
	if count < 8:
		return

	# Runs of consecutive samples that are bent enough to be a corner. Collected
	# first as raw spans and tidied afterwards, because deciding where a corner
	# ends while still walking into it does not work: an S-bend looks like two
	# corners until you have seen both.
	var spans: Array = []
	var open := -1
	var limit := count if closed else count
	for i in limit:
		var bent := absf(curvature[i]) > CORNER_CURVATURE
		if bent and open < 0:
			open = i
		elif not bent and open >= 0:
			spans.append([open, i - 1])
			open = -1
	if open >= 0:
		spans.append([open, limit - 1])

	# On a circuit a corner that straddles the start line arrives as two spans,
	# one at each end of the array. They are one corner.
	if closed and spans.size() >= 2:
		var first: Array = spans[0]
		var last: Array = spans[-1]
		if int(first[0]) == 0 and int(last[1]) == count - 1:
			spans[0] = [int(last[0]) - count, int(first[1])]
			spans.remove_at(spans.size() - 1)

	# Merge the ones that are really one corner with a breath in the middle.
	var merged: Array = []
	for span in spans:
		if not merged.is_empty():
			var previous: Array = merged[-1]
			var gap := (float(span[0]) - float(previous[1])) * SPACING_M
			if gap < CORNER_MERGE_GAP_M:
				previous[1] = span[1]
				continue
		merged.append(span.duplicate())

	for span in merged:
		var corner := _build_corner(int(span[0]), int(span[1]))
		if corner != null and corner.length_m() >= MIN_CORNER_LENGTH_M:
			corners.append(corner)


func _build_corner(from_i: int, to_i: int) -> Bend:
	if to_i < from_i:
		return null
	var c := Bend.new()
	c.entry = _wrap(from_i)
	c.exit = _wrap(to_i)
	c.entry_s = float(from_i) * SPACING_M
	c.exit_s = float(to_i) * SPACING_M

	var sharpest := 0.0
	var apex_index := from_i
	var turned := 0.0
	var signed_sum := 0.0
	for i in range(from_i, to_i + 1):
		var k: float = curvature[_wrap(i)]
		turned += absf(k) * SPACING_M
		signed_sum += k
		if absf(k) > sharpest:
			sharpest = absf(k)
			apex_index = i

	c.apex = _wrap(apex_index)
	c.apex_s = float(apex_index) * SPACING_M
	c.min_radius = 100000.0 if sharpest < 0.00001 else 1.0 / sharpest
	# The handedness of the corner as a whole, not of its sharpest point: in an
	# S-bend merged into one corner those are different, and what a driver
	# needs to know is which way the thing mostly goes.
	c.direction = 1.0 if signed_sum >= 0.0 else -1.0
	c.turned = turned
	return c


## The corner a car at this point is heading into, and how far away it is.
## Returns null past the last corner of a stage.
func next_corner(s_m: float) -> Bend:
	if corners.is_empty():
		return null
	var here := fposmod(s_m, length_m) if closed else s_m
	var best: Bend = null
	var best_gap := INF
	for c in corners:
		var gap := c.entry_s - here
		if closed and gap < 0.0:
			gap += length_m
		if gap < 0.0:
			continue
		if gap < best_gap:
			best_gap = gap
			best = c
	return best


## How far to the start of the next corner, in metres. INF on a stage with no
## corner left in front of the car.
func distance_to_next_corner(s_m: float) -> float:
	var c := next_corner(s_m)
	if c == null:
		return INF
	var here := fposmod(s_m, length_m) if closed else s_m
	var gap := c.entry_s - here
	if closed and gap < 0.0:
		gap += length_m
	return gap


## The corner a car is currently inside, or null on a straight.
func corner_at(s_m: float) -> Bend:
	var here := fposmod(s_m, length_m) if closed else s_m
	for c in corners:
		if here >= c.entry_s and here <= c.exit_s:
			return c
	return null


# --- Where a pass is on -----------------------------------------------------

## The stretches long enough and wide enough that a car can pull alongside and
## be past before anybody has to brake.
##
## This is the thing the AI could never work out for itself. It knew there was
## a car in front and it knew it was faster; it had no idea whether there was
## two hundred metres of road to use or forty, so it committed to the same move
## in both cases and in one of them arrived at the corner side by side.
func _find_pass_zones() -> void:
	pass_zones.clear()
	if width_m < MIN_PASS_WIDTH_M:
		return   # a road this narrow has no overtaking on it anywhere
	if corners.is_empty():
		# No corners at all: the whole thing is one long pass zone.
		var whole := PassZone.new()
		whole.start_s = 0.0
		whole.end_s = length_m
		pass_zones.append(whole)
		return

	for index in corners.size():
		var into: Bend = corners[index]
		# The straight running into this corner starts where the previous one
		# lets go — on a circuit that wraps round the start line.
		var previous: Bend = corners[index - 1] if index > 0 else corners[-1]
		var straight_start := previous.exit_s
		var straight_end := into.entry_s
		if straight_end < straight_start:
			straight_end += length_m
		var straight = straight_end - straight_start
		if straight < MIN_PASS_STRAIGHT_M:
			continue

		var zone := PassZone.new()
		zone.into = into
		# The pass has to be *finished* before the braking point, not started
		# there, so the usable stretch stops well short of the corner. A
		# quarter of the straight is a reasonable stand-in for a braking zone
		# without needing to know which car is doing the braking; the speed
		# profile knows the real number and the driver checks it too.
		zone.start_s = fposmod(straight_start + straight * 0.15, length_m)
		zone.end_s = fposmod(straight_end - straight * 0.30, length_m)
		pass_zones.append(zone)


## Whether a pass started here has room to finish. The one question the AI
## needs answered before it commits to a move.
func pass_is_on(s_m: float) -> bool:
	var here := fposmod(s_m, length_m) if closed else s_m
	for zone in pass_zones:
		if zone.start_s <= zone.end_s:
			if here >= zone.start_s and here <= zone.end_s:
				return true
		# A zone that wraps past the start line.
		elif here >= zone.start_s or here <= zone.end_s:
			return true
	return false


## How much road is left in the pass zone the car is in, in metres. Zero when
## there is no move on. Lets a driver already alongside decide whether to press
## on or tuck back in.
func pass_room(s_m: float) -> float:
	var here := fposmod(s_m, length_m) if closed else s_m
	for zone in pass_zones:
		var start := zone.start_s
		var end := zone.end_s
		var inside := (here >= start and here <= end) if start <= end \
			else (here >= start or here <= end)
		if not inside:
			continue
		var room := end - here
		if room < 0.0:
			room += length_m
		return room
	return 0.0


# --- Lookups ----------------------------------------------------------------

func index_at(s_m: float) -> int:
	if positions.is_empty():
		return 0
	var here := fposmod(s_m, length_m) if closed else clampf(s_m, 0.0, length_m)
	return _wrap(int(round(here / SPACING_M)))


func distance_of(i: int) -> float:
	return float(_wrap(i)) * SPACING_M


## What the road is made of at a sample, as the tyre model understands it.
func surface_at(i: int) -> TireModel.Surface:
	if surfaces.is_empty():
		return TireModel.Surface.TARMAC
	return surfaces[_wrap(i)] as TireModel.Surface


## A one-line summary, for the bench and for anybody wondering whether the
## model read the road the way a person would.
func describe() -> String:
	var slow := 0
	for c in corners:
		if c.is_slow():
			slow += 1
	return "%.0f m, %d corners (%d slow), %d places to pass" % [
		length_m, corners.size(), slow, pass_zones.size()]
