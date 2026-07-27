class_name TrackSpec
extends RefCounted
## A track described as a centreline plus a width, rather than as a hand-built
## scene.
##
## Everything the track needs — road surface, walls, checkpoints, the start
## grid, jumps and surface changes — is derived from that centreline at load
## time. New tracks are a few dozen numbers in tracks.json, which is what makes
## "the tracks are simple at first" a workable starting point rather than a
## content bottleneck.

const TRACKS_PATH := "res://data/tracks.json"

var id: String = ""
var display_name: String = ""
var closed: bool = true
## Road width in metres.
var width: float = 14.0
var default_surface: TireModel.Surface = TireModel.Surface.GRAVEL
## Centreline control points, in metres.
var waypoints: PackedVector2Array = PackedVector2Array()
## Checkpoints are placed every N metres along the centreline.
var checkpoint_spacing: float = 120.0

## [{ "at": waypoint_index, "launch": vertical m/s, "length": metres }]
var ramps: Array[Dictionary] = []
## [{ "from": idx, "to": idx, "surface": Surface }]
var surface_overrides: Array[Dictionary] = []

var description: String = ""


static func load_all(path: String = TRACKS_PATH) -> Dictionary:
	var out := {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TrackSpec: cannot open %s" % path)
		return out
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("TrackSpec: %s is not a JSON object" % path)
		return out
	for entry in parsed.get("tracks", []):
		var t := TrackSpec.from_dict(entry)
		if not t.id.is_empty():
			out[t.id] = t
	return out


static func from_dict(d: Dictionary) -> TrackSpec:
	var t := TrackSpec.new()
	t.id = String(d.get("id", ""))
	t.display_name = String(d.get("name", t.id))
	t.closed = bool(d.get("closed", true))
	t.width = float(d.get("width", 14.0))
	t.checkpoint_spacing = float(d.get("checkpoint_spacing", 120.0))
	t.description = String(d.get("description", ""))
	t.default_surface = TireModel.surface_from_string(String(d.get("surface", "gravel")))

	for p in d.get("waypoints", []):
		if p is Array and p.size() >= 2:
			t.waypoints.append(Vector2(float(p[0]), float(p[1])))

	for r in d.get("ramps", []):
		t.ramps.append({
			"at": int(r.get("at", 0)),
			"launch": float(r.get("launch", 6.0)),
			"length": float(r.get("length", 8.0)),
		})

	for s in d.get("surface_overrides", []):
		t.surface_overrides.append({
			"from": int(s.get("from", 0)),
			"to": int(s.get("to", 0)),
			"surface": TireModel.surface_from_string(String(s.get("surface", "tarmac"))),
		})
	return t


## Smooth curve through the waypoints, in pixels, ready to sample.
func build_curve() -> Curve2D:
	var curve := Curve2D.new()
	var ppm := GameConfig.PIXELS_PER_METRE
	var n := waypoints.size()
	if n < 2:
		return curve

	# Catmull-Rom style tangents give a smooth road through sparse control
	# points, which is what keeps the data files short.
	for i in n:
		var p := waypoints[i] * ppm
		var prev := waypoints[(i - 1 + n) % n] * ppm
		var next := waypoints[(i + 1) % n] * ppm
		if not closed:
			if i == 0:
				prev = p
			if i == n - 1:
				next = p
		var tangent := (next - prev) * 0.25
		curve.add_point(p, -tangent, tangent)

	if closed and n >= 2:
		var first := waypoints[0] * ppm
		var prev_last := waypoints[n - 1] * ppm
		var next_first := waypoints[1] * ppm
		var tangent := (next_first - prev_last) * 0.25
		curve.add_point(first, -tangent, tangent)
	return curve


func surface_at_waypoint(index: int) -> TireModel.Surface:
	for o in surface_overrides:
		if index >= int(o["from"]) and index <= int(o["to"]):
			return o["surface"]
	return default_surface
