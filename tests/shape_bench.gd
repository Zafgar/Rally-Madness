extends SceneTree
## Scores candidate stage shapes with the game's own recce.
##
## The generator that draws these shapes measures them in its own reimplementation
## of the curve maths, and the two do not agree closely enough to tune against —
## the recce samples the baked curve, smooths it, merges short bends into one
## corner and then asks which way that corner goes, and a lap that wiggles
## inside a single long left-hander scores well on a sample-by-sample measure and
## badly on this one. This one is what matters: it is the same reading the AI
## drives to and the same one the suite checks.
##
## Reads a JSON file of { "candidates": [ { "id": …, "waypoints": [[x, y], …] } ] }
## and prints one line per candidate.
##
##   godot --headless --path . --script res://tests/shape_bench.gd -- <candidates.json>

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("SHAPE usage: --script res://tests/shape_bench.gd -- <candidates.json>")
		quit(1)
		return

	var file := FileAccess.open(args[0], FileAccess.READ)
	if file == null:
		print("SHAPE cannot read %s" % args[0])
		quit(1)
		return
	var doc = JSON.parse_string(file.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY:
		print("SHAPE %s is not a candidate file" % args[0])
		quit(1)
		return

	var template: TrackSpec = TrackSpec.load_all().get(String(doc.get("like", "gravel_loop")))
	for candidate in doc.get("candidates", []):
		var spec := TrackSpec.new()
		spec.id = String(candidate.get("id", "candidate"))
		spec.display_name = spec.id
		spec.closed = bool(candidate.get("closed", true))
		spec.width = float(candidate.get("width", template.width if template else 14.0))
		spec.default_surface = template.default_surface if template else TireModel.Surface.GRAVEL
		for p in candidate.get("waypoints", []):
			spec.waypoints.append(Vector2(float(p[0]), float(p[1])))

		var builder := TrackBuilder.new(spec)
		builder.walk()
		var model := TrackModel.analyse(builder)
		var km := maxf(model.length_m / 1000.0, 0.001)

		var changes := 0
		var slow := 0
		for i in model.corners.size():
			if model.corners[i].min_radius < 45.0:
				slow += 1
			if i > 0 and signf(model.corners[i].direction) \
					!= signf(model.corners[i - 1].direction):
				changes += 1
		if model.closed and model.corners.size() >= 2:
			if signf(model.corners[0].direction) \
					!= signf(model.corners[model.corners.size() - 1].direction):
				changes += 1

		print("SHAPE %s len=%.0f corners=%d slow=%d changes=%d per_km=%.1f" % [
			spec.id, model.length_m, model.corners.size(), slow, changes,
			float(changes) / km])
	quit()
