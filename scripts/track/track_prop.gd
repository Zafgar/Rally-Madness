class_name TrackProp
extends RefCounted
## One kind of thing that can be placed beside or on a track.
##
## A prop is data, not a scene: a name, a size, how it is drawn, and what
## happens if you hit it. That is what makes it reusable — a hay bale behaves
## the same on every track because there is one hay bale, and adding a new prop
## means adding an entry to props.json rather than a scene and a script.
##
## Two kinds matter, and they are different things:
##
##   scenery   outside the barrier. Drawn, never collided with, scattered by
##             theme. Cheap enough to have thousands of.
##   hazard    inside the barrier, in the road. Collided with, and hitting one
##             has a consequence — that is the whole point of it being there.

const PROPS_PATH := "res://data/props.json"

enum Kind {
	SCENERY,  ## decoration beyond the barrier
	HAZARD,   ## an obstacle on the racing surface
}

enum Shape {
	TREE,      ## a canopy with a trunk
	CONIFER,   ## a triangular canopy, snow-capped on winter themes
	BUSH,      ## a low irregular blob
	ROCK,      ## an angular grey lump
	POST,      ## a thin vertical marker
	BALE,      ## a round straw bale
	TYRE_WALL, ## a stack of tyres
	CONE,      ## a traffic cone
	SIGN,      ## a flat board on a post
	CRATE,     ## a wooden box
	BARREL,    ## a drum, usually water-filled
	SNOW_BANK, ## a heaped ridge of snow
}

var id: String = ""
var display_name: String = ""
var kind: Kind = Kind.SCENERY
var shape: Shape = Shape.TREE

## Radius in metres, and how much it varies from one instance to the next.
var radius_m: float = 2.0
var radius_variance: float = 0.3

var body_colour: Color = Color(0.24, 0.36, 0.20)
var detail_colour: Color = Color(0.16, 0.24, 0.14)

# --- Hazard behaviour -------------------------------------------------------
## Mass in kilograms. Light things are knocked aside; heavy things stop you.
var mass_kg: float = 40.0
## How much of a car's speed a hit scrubs off, 0..1.
var speed_penalty: float = 0.25
## Damage dealt to the car's body per hit, as a fraction of condition.
var damage: float = 0.02
## Whether the prop is moved by the impact rather than staying put.
var movable: bool = true
## Themes this prop belongs to. Empty means any.
var themes: Array[String] = []

## How often this prop is picked relative to the others in its theme. A cottage
## and a clump of scrub are both village scenery, but a village with as many
## cottages as clumps of scrub is a housing estate.
var weight: float = 1.0
## How far from the edge of the road this prop belongs, in metres. Hedges hug
## the verge; buildings stand back from it.
var near_m: float = 3.0
var far_m: float = 34.0

static var _props: Dictionary = {}
static var _ordered: Array[TrackProp] = []
static var _loaded: bool = false


static func load_all(path: String = PROPS_PATH) -> Dictionary:
	if _loaded:
		return _props
	_loaded = true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("TrackProp: cannot open %s" % path)
		return _props
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("TrackProp: %s is not a JSON object" % path)
		return _props
	for entry in parsed.get("props", []):
		var p := TrackProp.from_dict(entry)
		if p.id.is_empty():
			continue
		_props[p.id] = p
		_ordered.append(p)
	return _props


static func by_id(id: String) -> TrackProp:
	load_all()
	return _props.get(id)


static func all() -> Array[TrackProp]:
	load_all()
	return _ordered


## Every prop of a kind that suits a theme. Scenery scattering asks for this and
## picks from what comes back, so adding a prop to props.json puts it on every
## track of that theme without touching any track data.
static func for_theme(theme: String, kind: Kind) -> Array[TrackProp]:
	var out: Array[TrackProp] = []
	for p in all():
		if p.kind != kind:
			continue
		if p.themes.is_empty() or p.themes.has(theme):
			out.append(p)
	return out


static func clear_cache() -> void:
	_props.clear()
	_ordered.clear()
	_loaded = false


static func from_dict(d: Dictionary) -> TrackProp:
	var p := TrackProp.new()
	p.id = String(d.get("id", ""))
	p.display_name = String(d.get("name", p.id))
	p.kind = Kind.HAZARD if String(d.get("kind", "scenery")) == "hazard" else Kind.SCENERY
	p.shape = _shape_from_string(String(d.get("shape", "tree")))
	p.radius_m = float(d.get("radius_m", 2.0))
	p.radius_variance = float(d.get("radius_variance", 0.3))
	p.body_colour = Color.from_string(String(d.get("colour", "#3d5c33")), p.body_colour)
	p.detail_colour = Color.from_string(String(d.get("detail_colour", "#283d24")),
		p.detail_colour)
	p.mass_kg = float(d.get("mass_kg", 40.0))
	p.speed_penalty = float(d.get("speed_penalty", 0.25))
	p.damage = float(d.get("damage", 0.02))
	p.movable = bool(d.get("movable", true))
	for t in d.get("themes", []):
		p.themes.append(String(t))
	p.weight = float(d.get("weight", 1.0))
	p.near_m = float(d.get("near_m", 3.0))
	p.far_m = float(d.get("far_m", 34.0))
	return p


## Picks a prop from a palette by weight. Uniform picking makes every stage look
## like a catalogue page; weights make it look like somewhere.
static func pick(palette: Array[TrackProp], rng: RandomNumberGenerator) -> TrackProp:
	if palette.is_empty():
		return null
	var total := 0.0
	for p in palette:
		total += maxf(p.weight, 0.0)
	if total <= 0.0:
		return palette[rng.randi() % palette.size()]
	var roll := rng.randf() * total
	for p in palette:
		roll -= maxf(p.weight, 0.0)
		if roll <= 0.0:
			return p
	return palette[palette.size() - 1]


static func _shape_from_string(s: String) -> Shape:
	match s.to_lower():
		"conifer": return Shape.CONIFER
		"bush": return Shape.BUSH
		"rock": return Shape.ROCK
		"post": return Shape.POST
		"bale": return Shape.BALE
		"tyre_wall", "tire_wall": return Shape.TYRE_WALL
		"cone": return Shape.CONE
		"sign": return Shape.SIGN
		"crate": return Shape.CRATE
		"barrel": return Shape.BARREL
		"snow_bank": return Shape.SNOW_BANK
		_: return Shape.TREE


# --- Drawing ----------------------------------------------------------------

## Draws one instance onto a CanvasItem, in pixels.
##
## Every prop is drawn from primitives for the same reason the cars are: one
## file decides how everything looks, and a new prop costs a few lines rather
## than an art pipeline. `seed_value` varies each instance so a row of trees is
## not a row of identical trees.
func draw_at(
	canvas: CanvasItem,
	centre: Vector2,
	angle: float,
	radius_px: float,
	seed_value: int
) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	match shape:
		Shape.TREE: _draw_tree(canvas, centre, radius_px, rng)
		Shape.CONIFER: _draw_conifer(canvas, centre, radius_px, rng)
		Shape.BUSH: _draw_bush(canvas, centre, radius_px, rng)
		Shape.ROCK: _draw_rock(canvas, centre, radius_px, rng)
		Shape.POST: _draw_post(canvas, centre, radius_px)
		Shape.BALE: _draw_bale(canvas, centre, radius_px)
		Shape.TYRE_WALL: _draw_tyre_wall(canvas, centre, angle, radius_px)
		Shape.CONE: _draw_cone(canvas, centre, radius_px)
		Shape.SIGN: _draw_sign(canvas, centre, angle, radius_px)
		Shape.CRATE: _draw_crate(canvas, centre, angle, radius_px)
		Shape.BARREL: _draw_barrel(canvas, centre, radius_px)
		Shape.SNOW_BANK: _draw_snow_bank(canvas, centre, angle, radius_px)


## Seen from above, a tree is its canopy — the trunk only shows at the edges.
func _draw_tree(canvas: CanvasItem, c: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	canvas.draw_circle(c + Vector2(r * 0.22, r * 0.28), r, Color(0, 0, 0, 0.22))
	var lobes := 3 + rng.randi_range(0, 2)
	for i in lobes:
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(0.0, r * 0.38)
		canvas.draw_circle(c + Vector2(cos(a), sin(a)) * d, r * rng.randf_range(0.62, 0.86),
			body_colour)
	canvas.draw_circle(c, r * 0.30, detail_colour)


func _draw_conifer(canvas: CanvasItem, c: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	canvas.draw_circle(c + Vector2(r * 0.22, r * 0.28), r * 0.9, Color(0, 0, 0, 0.22))
	var spin := rng.randf_range(0.0, TAU)
	var points := PackedVector2Array()
	# A ragged star reads as a conifer from above where a circle reads as a bush.
	for i in 12:
		var a := spin + TAU * float(i) / 12.0
		var d: float = r if i % 2 == 0 else r * 0.52
		points.append(c + Vector2(cos(a), sin(a)) * d)
	canvas.draw_colored_polygon(points, body_colour)
	canvas.draw_circle(c, r * 0.22, detail_colour)


func _draw_bush(canvas: CanvasItem, c: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	for i in 3:
		var a := rng.randf_range(0.0, TAU)
		canvas.draw_circle(c + Vector2(cos(a), sin(a)) * r * 0.36,
			r * rng.randf_range(0.55, 0.80), body_colour)


func _draw_rock(canvas: CanvasItem, c: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	var points := PackedVector2Array()
	var spin := rng.randf_range(0.0, TAU)
	for i in 6:
		var a := spin + TAU * float(i) / 6.0
		points.append(c + Vector2(cos(a), sin(a)) * r * rng.randf_range(0.72, 1.0))
	canvas.draw_colored_polygon(points, body_colour)
	canvas.draw_circle(c - Vector2(r * 0.2, r * 0.2), r * 0.34, detail_colour)


func _draw_post(canvas: CanvasItem, c: Vector2, r: float) -> void:
	canvas.draw_circle(c, r * 0.42, body_colour)
	canvas.draw_circle(c, r * 0.22, detail_colour)


func _draw_bale(canvas: CanvasItem, c: Vector2, r: float) -> void:
	canvas.draw_circle(c + Vector2(r * 0.18, r * 0.22), r, Color(0, 0, 0, 0.28))
	canvas.draw_circle(c, r, body_colour)
	# Concentric rings, because a round bale seen from above is a spiral.
	for i in 3:
		canvas.draw_arc(c, r * (0.78 - 0.22 * float(i)), 0.0, TAU, 20, detail_colour, 1.4, true)


func _draw_tyre_wall(canvas: CanvasItem, c: Vector2, angle: float, r: float) -> void:
	var along := Vector2(cos(angle), sin(angle))
	canvas.draw_circle(c + Vector2(r * 0.16, r * 0.2), r * 1.1, Color(0, 0, 0, 0.30))
	for i in range(-1, 2):
		var p := c + along * (r * 0.95 * float(i))
		canvas.draw_circle(p, r * 0.55, body_colour)
		canvas.draw_circle(p, r * 0.26, detail_colour)


func _draw_cone(canvas: CanvasItem, c: Vector2, r: float) -> void:
	canvas.draw_circle(c, r, body_colour)
	canvas.draw_circle(c, r * 0.52, detail_colour)


func _draw_sign(canvas: CanvasItem, c: Vector2, angle: float, r: float) -> void:
	var along := Vector2(cos(angle), sin(angle)) * r
	var across := Vector2(-along.y, along.x) * 0.22
	canvas.draw_colored_polygon(PackedVector2Array([
		c - along - across, c + along - across, c + along + across, c - along + across]),
		body_colour)
	canvas.draw_circle(c, r * 0.18, detail_colour)


func _draw_crate(canvas: CanvasItem, c: Vector2, angle: float, r: float) -> void:
	var along := Vector2(cos(angle), sin(angle)) * r
	var across := Vector2(-along.y, along.x)
	canvas.draw_circle(c + Vector2(r * 0.16, r * 0.2), r * 1.05, Color(0, 0, 0, 0.26))
	canvas.draw_colored_polygon(PackedVector2Array([
		c - along - across, c + along - across, c + along + across, c - along + across]),
		body_colour)
	canvas.draw_line(c - along, c + along, detail_colour, 1.6, true)


func _draw_barrel(canvas: CanvasItem, c: Vector2, r: float) -> void:
	canvas.draw_circle(c + Vector2(r * 0.16, r * 0.2), r, Color(0, 0, 0, 0.28))
	canvas.draw_circle(c, r, body_colour)
	canvas.draw_arc(c, r * 0.62, 0.0, TAU, 18, detail_colour, 1.6, true)


func _draw_snow_bank(canvas: CanvasItem, c: Vector2, angle: float, r: float) -> void:
	var along := Vector2(cos(angle), sin(angle)) * r * 1.8
	var across := Vector2(-along.y, along.x) * 0.30
	canvas.draw_colored_polygon(PackedVector2Array([
		c - along - across, c + along - across, c + along + across, c - along + across]),
		body_colour)
	canvas.draw_line(c - along, c + along, detail_colour, 2.2, true)
