class_name CarEffects
extends Node2D
## Particles and lights that hang off one car.
##
## Everything is driven by state the physics already tracks, so nothing here
## can disagree with what the car is doing: spray comes from wheel slip and the
## surface under it, exhaust from throttle and revs, smoke from engine damage,
## fire from actually being on fire.

const PPM := GameConfig.PIXELS_PER_METRE

## Spray colour and how much of it a surface throws up.
const SURFACE_SPRAY := {
	TireModel.Surface.TARMAC: {"amount": 0.15, "colour": Color(0.55, 0.55, 0.58, 0.5)},
	TireModel.Surface.DIRT: {"amount": 1.0, "colour": Color(0.46, 0.33, 0.20, 0.95)},
	TireModel.Surface.GRAVEL: {"amount": 1.0, "colour": Color(0.50, 0.46, 0.38, 0.95)},
	TireModel.Surface.GRASS: {"amount": 0.8, "colour": Color(0.32, 0.45, 0.22, 0.8)},
	TireModel.Surface.SNOW: {"amount": 1.2, "colour": Color(0.92, 0.94, 0.98, 0.9)},
	TireModel.Surface.ICE: {"amount": 0.25, "colour": Color(0.82, 0.90, 0.95, 0.6)},
	TireModel.Surface.MUD: {"amount": 1.1, "colour": Color(0.32, 0.24, 0.15, 0.9)},
}

var _spray: CPUParticles2D
var _exhaust: CPUParticles2D
var _smoke: CPUParticles2D
var _fire: CPUParticles2D
var _headlight_left: PointLight2D
var _headlight_right: PointLight2D
var _light_texture: Texture2D
var _dot_texture: Texture2D

## Base emitter counts, so density can be scaled without losing the maximum.
var _base_amount: Dictionary = {}

var _rear_offset := Vector2.ZERO
var _front_offset := Vector2.ZERO
var _half_width := 20.0


func setup(stats: VehicleStats) -> void:
	_rear_offset = Vector2(-stats.cg_to_rear_axle() * PPM, 0.0)
	_front_offset = Vector2(stats.cg_to_front_axle() * PPM, 0.0)
	_half_width = stats.track_width_m * 0.5 * PPM

	_light_texture = _make_light_texture()
	# Without a texture a CPUParticles2D draws a single pixel, which at any
	# sensible zoom is invisible — the dust was being emitted all along and
	# simply could not be seen.
	_dot_texture = _make_dot_texture()
	_build_spray()
	_build_exhaust()
	_build_smoke()
	_build_fire()
	_build_headlights(stats)


# --- Construction -----------------------------------------------------------

func _make_particles(amount: int, lifetime: float, z: int) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.emitting = false
	p.local_coords = false   # particles stay where they were emitted
	p.z_index = z
	p.texture = _dot_texture
	add_child(p)
	_base_amount[p] = amount
	return p


func _build_spray() -> void:
	# Thrown up behind the driven wheels when the tread is sliding.
	_spray = _make_particles(110, 0.8, -4)
	_spray.position = _rear_offset
	_spray.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_spray.emission_rect_extents = Vector2(4.0, _half_width)
	_spray.direction = Vector2(-1, 0)
	_spray.spread = 32.0
	_spray.initial_velocity_min = 40.0
	_spray.initial_velocity_max = 150.0
	_spray.gravity = Vector2.ZERO
	_spray.damping_min = 90.0
	_spray.damping_max = 160.0
	_spray.scale_amount_min = 0.12
	_spray.scale_amount_max = 0.38
	_spray.scale_amount_curve = _fade_curve()


func _build_exhaust() -> void:
	_exhaust = _make_particles(24, 0.55, -3)
	_exhaust.position = _rear_offset + Vector2(-6.0, _half_width * 0.55)
	_exhaust.direction = Vector2(-1, 0)
	_exhaust.spread = 14.0
	_exhaust.initial_velocity_min = 12.0
	_exhaust.initial_velocity_max = 45.0
	_exhaust.gravity = Vector2.ZERO
	_exhaust.damping_min = 40.0
	_exhaust.damping_max = 70.0
	_exhaust.scale_amount_min = 0.14
	_exhaust.scale_amount_max = 0.34
	_exhaust.scale_amount_curve = _fade_curve()
	_exhaust.color = Color(0.72, 0.72, 0.74, 0.30)


func _build_smoke() -> void:
	# A hurt engine smokes from the bay, not the pipe.
	_smoke = _make_particles(32, 1.4, 4)
	_smoke.position = _front_offset * 0.6
	_smoke.direction = Vector2(0, -1)
	_smoke.spread = 60.0
	_smoke.initial_velocity_min = 8.0
	_smoke.initial_velocity_max = 26.0
	_smoke.gravity = Vector2.ZERO
	_smoke.scale_amount_min = 0.30
	_smoke.scale_amount_max = 0.95
	_smoke.scale_amount_curve = _grow_curve()
	_smoke.color = Color(0.22, 0.22, 0.24, 0.55)


func _build_fire() -> void:
	_fire = _make_particles(40, 0.6, 5)
	_fire.position = _front_offset * 0.6
	_fire.direction = Vector2(0, -1)
	_fire.spread = 45.0
	_fire.initial_velocity_min = 30.0
	_fire.initial_velocity_max = 90.0
	_fire.gravity = Vector2.ZERO
	_fire.scale_amount_min = 0.30
	_fire.scale_amount_max = 0.75
	_fire.scale_amount_curve = _fade_curve()
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.92, 0.45, 0.95))
	ramp.set_color(1, Color(0.85, 0.18, 0.05, 0.0))
	_fire.color_ramp = ramp


func _build_headlights(stats: VehicleStats) -> void:
	# Real Light2D cones rather than painted polygons, so they light the road
	# and other cars on a night stage instead of sitting on top of them.
	for side in [-1.0, 1.0]:
		var light := PointLight2D.new()
		light.texture = _light_texture
		light.position = _front_offset + Vector2(4.0, _half_width * 0.55 * side)
		light.energy = 0.0
		light.color = Color(1.0, 0.95, 0.82)
		light.texture_scale = 3.4 + stats.wheelbase_m * 0.25
		light.blend_mode = Light2D.BLEND_MODE_ADD
		light.shadow_enabled = false
		add_child(light)
		if side < 0.0:
			_headlight_left = light
		else:
			_headlight_right = light


## A soft round dot for particles to draw as.
func _make_dot_texture() -> Texture2D:
	const SIZE := 32
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var centre := Vector2(SIZE, SIZE) * 0.5
	for y in SIZE:
		for x in SIZE:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre) / (SIZE * 0.5)
			image.set_pixel(x, y, Color(1, 1, 1, pow(clampf(1.0 - d, 0.0, 1.0), 1.5)))
	return ImageTexture.create_from_image(image)


## A soft forward cone, generated so no texture asset is needed.
func _make_light_texture() -> Texture2D:
	const SIZE := 128
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var centre := Vector2(SIZE * 0.12, SIZE * 0.5)
	var reach := float(SIZE) * 0.88
	for y in SIZE:
		for x in SIZE:
			var offset := Vector2(x, y) - centre
			var distance := offset.length()
			# Angle from straight ahead decides the cone; distance the falloff.
			var angle := absf(offset.angle())
			var cone := clampf(1.0 - angle / deg_to_rad(34.0), 0.0, 1.0)
			var falloff := clampf(1.0 - distance / reach, 0.0, 1.0)
			var value := pow(cone, 1.6) * pow(falloff, 1.4)
			image.set_pixel(x, y, Color(1, 1, 1, value))
	return ImageTexture.create_from_image(image)


func _fade_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	return curve


func _grow_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.35))
	curve.add_point(Vector2(1.0, 1.0))
	return curve


## Scales an emitter's density without losing its configured maximum.
func _set_density(particles: CPUParticles2D, ratio: float) -> void:
	var base: int = _base_amount.get(particles, particles.amount)
	particles.amount = maxi(int(base * ratio), 1)


# --- Per-frame ---------------------------------------------------------------

func update(car: RallyCar) -> void:
	if car.stats == null or _spray == null:
		return
	_update_spray(car)
	_update_exhaust(car)
	_update_damage(car)
	_update_headlights(car)


func _update_spray(car: RallyCar) -> void:
	var surface: Dictionary = SURFACE_SPRAY.get(car.surface, SURFACE_SPRAY[TireModel.Surface.DIRT])
	# Sliding, spinning or locked — all of them throw the surface about.
	var slide := maxf(car.axle_rear.slip_magnitude, car.axle_front.slip_magnitude)
	var moving := car.speed_ms > 1.5 and not car.airborne
	var active: bool = moving and slide > 1.2 and float(surface["amount"]) > 0.05

	_spray.emitting = active
	if not active:
		return
	_spray.color = surface["colour"]
	var strength := clampf((slide - 1.2) * 0.5, 0.0, 1.0) * float(surface["amount"])
	_set_density(_spray, clampf(strength, 0.1, 1.0))
	# Thrown backwards relative to the car, so it trails properly at speed.
	_spray.direction = Vector2.LEFT.rotated(car.rotation)
	_spray.initial_velocity_max = 90.0 + car.speed_ms * 6.0


func _update_exhaust(car: RallyCar) -> void:
	var running: bool = not car.damage.wrecked
	_exhaust.emitting = running
	if not running:
		return
	_exhaust.direction = Vector2.LEFT.rotated(car.rotation)
	var load := car.command.throttle
	var revs := car.transmission.rpm / maxf(car.stats.redline_rpm, 1.0)
	_set_density(_exhaust, clampf(0.12 + load * 0.6 + revs * 0.3, 0.05, 1.0))
	# On the limiter, or with anti-lag fitted, it spits rather than puffs.
	if car.engine.rev_limiting:
		_exhaust.color = Color(1.0, 0.55, 0.18, 0.75)
		_exhaust.initial_velocity_max = 190.0
	else:
		_exhaust.color = Color(0.72, 0.72, 0.74, clampf(0.12 + load * 0.28, 0.1, 0.45))
		_exhaust.initial_velocity_max = 45.0 + load * 60.0


func _update_damage(car: RallyCar) -> void:
	var engine_health: float = car.damage.integrity["engine"]
	_smoke.emitting = engine_health < 0.55
	if _smoke.emitting:
		_set_density(_smoke, clampf((0.55 - engine_health) / 0.55, 0.15, 1.0))
	_fire.emitting = car.damage.on_fire


func _update_headlights(car: RallyCar) -> void:
	if _headlight_left == null:
		return
	var energy: float = 1.15 if car.lights_on else 0.0
	# A dead car's lights go out with it.
	if car.damage.wrecked:
		energy = 0.0
	_headlight_left.energy = energy
	_headlight_right.energy = energy
	# Steered lights, so a driver can see into a corner on a night stage.
	var aim := car.steer_angle * 0.55
	_headlight_left.rotation = aim
	_headlight_right.rotation = aim
