class_name RacingLine
extends RefCounted
## The path through the road, as opposed to the road itself.
##
## Driving the centreline is slow, and it is slow in a way that is invisible
## from inside the car: the centreline through a corner has the radius of the
## corner, and a line that starts wide, touches the inside at the apex and runs
## wide again has a much larger one. Radius is speed, and the difference over a
## lap is far larger than any amount of bravery.
##
## The obvious way to build one is the textbook construction — outside at
## entry, inside at the apex, outside at exit — and it was tried here first. It
## does not work, and the way it fails is worth recording because it is not
## obvious: swinging the car across seven metres of road over the twenty metres
## before a corner is itself an arc, and that arc has a radius of about fifteen
## metres. On a forty-metre corner the "racing line" was tighter than the road
## it was supposed to improve, and the bench measured every track in the game as
## slower on the line than on the centreline.
##
## What is here instead never draws a line at all. It pulls a string taut
## inside the corridor of road, which gives the shortest way round, and then
## blends towards a smoothed version of that, which gives a flatter one. How
## far to blend is not a judgement call: every setting is tried and the one that
## measurably corners fastest is kept, so a line slower than the road it is on
## cannot be shipped. Out-in-out comes out of that on its own — not because
## anybody drew it, but because it genuinely is the flattest way through a
## corner.
##
## The line belongs to the track, not to a car. An ideal line does depend a
## little on what you are driving, and far less than it depends on where the
## road goes; one line per track that everybody shares is also what makes a
## field race each other rather than each drive its own private route.

## How much of the half-width the line may use. Not all of it: a car has width,
## and a line that puts the centre of the car on the white line puts half of it
## on the grass.
const USABLE_FRACTION := 0.74

## Passes of the taut-string relaxation. Each one is cheap and the whole thing
## converges, so this is generous rather than tuned.
const ITERATIONS := 120
## Over-relaxation. Above 1 the line moves further than the update asks for,
## which reaches the same answer in far fewer passes; above 2 it oscillates.
const RELAXATION := 1.6
## Smoothing passes applied to produce the flat line the bias blends towards.
const FLATTEN_PASSES := 12

var model: TrackModel
## Lateral offset from the centreline in metres, positive left, per sample.
var offsets: PackedFloat32Array = PackedFloat32Array()
## Curvature of the line itself, in 1/m. This — not the road's curvature — is
## what limits cornering speed.
var curvature: PackedFloat32Array = PackedFloat32Array()


## How far towards the flat line to try. The right amount depends on the road:
## on a wide track with well-separated corners, opening them out is worth a lot;
## on a narrow one where corners run into each other, opening one tightens the
## next and the taut line is better. Rather than pick a number and hope, all of
## them are solved and the one that actually corners fastest is kept.
##
## Zero is in the list on purpose. On some roads nothing beats the taut line,
## and on a couple nothing beats the centreline — and shipping a "racing line"
## that is slower than the road is the failure this whole search exists to make
## impossible.
const BIAS_CANDIDATES := [0.0, 0.25, 0.45, 0.65, 0.85, 1.0]


static func solve(p_model: TrackModel) -> RacingLine:
	# The taut solve is the expensive half and does not depend on the bias, so
	# it runs once and every candidate blends from the same result. Solving it
	# six times over cost three and a half seconds on the longest stage in the
	# game, which is three and a half seconds of a player watching nothing.
	var taut := RacingLine.new()
	taut.model = p_model
	taut._pull_taut()

	var best: RacingLine = null
	var best_gain := 0.0
	for bias in BIAS_CANDIDATES:
		var line := RacingLine.new()
		line.model = p_model
		line.offsets = taut.offsets.duplicate()
		line._flatten(float(bias))
		line._measure()
		var gain := line.gain_over_centreline()
		if best == null or gain > best_gain:
			best = line
			best_gain = gain

	# Nothing beat the road itself. That happens on a stage narrow enough that
	# there is no line to take, and driving the centreline is then the right
	# answer rather than a failure.
	if best_gain <= 0.0:
		var plain := RacingLine.new()
		plain.model = p_model
		plain._centreline()
		return plain
	return best


## Where the line runs, in world pixels.
func point_at(i: int) -> Vector2:
	var index := model._wrap(i)
	return model.positions[index] + model.normals[index] \
		* offsets[index] * GameConfig.PIXELS_PER_METRE


func radius_at(i: int) -> float:
	var k := absf(curvature[model._wrap(i)])
	return 100000.0 if k < 0.00001 else 1.0 / k


## Lateral offset at a distance along the track, in metres.
func offset_at(s_m: float) -> float:
	if offsets.is_empty():
		return 0.0
	return offsets[model.index_at(s_m)]


# --- The solve --------------------------------------------------------------

func _pull_taut() -> void:
	var count := model.positions.size()
	offsets.resize(count)
	curvature.resize(count)
	for i in count:
		offsets[i] = 0.0
	if count < 8:
		return

	var ppm := GameConfig.PIXELS_PER_METRE
	var limit := model.width_m * 0.5 * USABLE_FRACTION

	# Centreline and normals in metres, so the gradient is in metres and the
	# step size means something physical.
	var centre := PackedVector2Array()
	var normal := PackedVector2Array()
	centre.resize(count)
	normal.resize(count)
	for i in count:
		centre[i] = model.positions[i] / ppm
		normal[i] = model.normals[i]

	# Gauss-Seidel: pull each point towards the midpoint of its neighbours, in
	# place, so each update already sees the ones before it. Constrained to the
	# corridor, this converges to a string pulled taut inside the road — which
	# is the minimum-distance line, hugging the inside of every corner.
	#
	# Gradient descent on the bending energy was tried first and is the better
	# line in principle. In practice the energy is biharmonic, its largest
	# eigenvalue is around sixteen, and gradient descent on it is unstable for
	# any step above about an eighth. At the step first chosen it diverged, and
	# the clamp turned the divergence into a line that rang between the two
	# verges — measurably *worse* than the centreline on every track in the
	# game. This is slower to write down and cannot do that.
	for iteration in ITERATIONS:
		for i in count:
			# A stage has ends, and its ends must stay on the centreline or the
			# line wanders off the road before the start line.
			if not model.closed and (i < 2 or i >= count - 2):
				continue
			var previous := model._wrap(i - 1)
			var next := model._wrap(i + 1)
			var p_prev := centre[previous] + normal[previous] * offsets[previous]
			var p_next := centre[next] + normal[next] * offsets[next]
			var midpoint := (p_prev + p_next) * 0.5
			var wanted := normal[i].dot(midpoint - centre[i])
			offsets[i] = clampf(
				lerpf(offsets[i], wanted, RELAXATION), -limit, limit)



## Opens the corners out from the taut line.
##
## The taut line is the shortest way round, and the shortest way round is not
## the quickest: it hugs the inside of a corner and so takes it at the corner's
## own radius. Blending towards a smoothed version of itself gives a later apex
## and a wider entry and exit, which is what buys the speed. Everything stays
## inside the corridor because both ends of the blend are inside it.
func _flatten(bias: float) -> void:
	var count := offsets.size()
	if count < 8:
		curvature.resize(count)
		return
	curvature.resize(count)
	var limit := model.width_m * 0.5 * USABLE_FRACTION
	var flat := offsets.duplicate()
	for pass_index in FLATTEN_PASSES:
		var previous_pass := flat.duplicate()
		for i in count:
			if not model.closed and (i < 2 or i >= count - 2):
				continue
			flat[i] = (previous_pass[model._wrap(i - 1)]
				+ previous_pass[i] * 2.0
				+ previous_pass[model._wrap(i + 1)]) * 0.25
	for i in count:
		offsets[i] = clampf(lerpf(offsets[i], flat[i], bias), -limit, limit)


## The road itself, for the stages where nothing beats it.
func _centreline() -> void:
	var count := model.positions.size()
	offsets.resize(count)
	curvature.resize(count)
	for i in count:
		offsets[i] = 0.0
		curvature[i] = model.curvature[i]


func _measure() -> void:
	var ppm := GameConfig.PIXELS_PER_METRE
	var count := offsets.size()
	for i in count:
		var a := point_at(i - 2) / ppm
		var b := point_at(i) / ppm
		var c := point_at(i + 2) / ppm
		var ab := b - a
		var bc := c - b
		var ca := a - c
		var denominator := ab.length() * bc.length() * ca.length()
		if absf(denominator) < 0.001:
			curvature[i] = 0.0
			continue
		curvature[i] = 2.0 * ab.cross(bc) / denominator
	model._smooth(curvature, 2)


## How much more cornering speed the line is worth than the centreline, as a
## percentage, averaged over the corners.
##
## Measured from the tightest point anywhere within each corner on each path
## rather than at a fixed index. The whole purpose of the line is to move where
## the tightest point is, so comparing at one index compares the wrong part of
## the line — which is exactly the mistake that made the first version of this
## report look fine while the line was broken.
func gain_over_centreline() -> float:
	if model.corners.is_empty():
		return 0.0
	var total := 0.0
	for corner in model.corners:
		var road := 0.0
		var line := 0.0
		var span := maxi(int(corner.length_m() / TrackModel.SPACING_M), 1)
		for step in range(span + 1):
			var i := model._wrap(corner.entry + step)
			road = maxf(road, absf(model.curvature[i]))
			line = maxf(line, absf(curvature[i]))
		# Cornering speed goes with the square root of radius, and radius is
		# one over curvature.
		total += (sqrt(maxf(road, 0.00001) / maxf(line, 0.00001)) - 1.0) * 100.0
	return total / float(model.corners.size())
