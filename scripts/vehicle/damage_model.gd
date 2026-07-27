class_name DamageModel
extends RefCounted
## Crash damage, fire and write-off.
##
## Damage is tracked per component rather than as one health bar, because where
## you hit something should change how the car drives afterwards: a nose-first
## impact hurts the engine, a kerb strike ruins the suspension, and either one
## leaves a car that is still driveable but no longer competitive.

enum Component { BODY, ENGINE, SUSPENSION, TIRES }

const COMPONENT_NAMES := ["body", "engine", "suspension", "tires"]

## Engine integrity below this can start a fire.
const FIRE_RISK_THRESHOLD := 0.18
## Impact impulse that writes a stock body off outright, used to normalise
## everything else. Calibrated as a 1200 kg car meeting something solid at
## 50 m/s — roughly 180 km/h head-on into a barrier.
const REFERENCE_IMPULSE := 60000.0

var stats: VehicleStats
## component name -> integrity 0..1
var integrity: Dictionary = {"body": 1.0, "engine": 1.0, "suspension": 1.0, "tires": 1.0}

var on_fire: bool = false
var fire_timer: float = 0.0
var wrecked: bool = false
var wreck_cause: String = ""

signal damaged(component: String, amount: float, remaining: float)
signal caught_fire()
signal wrecked_out(cause: String)


func _init(p_stats: VehicleStats) -> void:
	stats = p_stats


func is_driveable() -> bool:
	return not wrecked


## Weighted overall condition, for the HUD and for repair pricing.
func overall() -> float:
	return (integrity["body"] * 0.35
		+ integrity["engine"] * 0.30
		+ integrity["suspension"] * 0.25
		+ integrity["tires"] * 0.10)


func snapshot() -> Dictionary:
	return integrity.duplicate()


func restore(saved: Dictionary) -> void:
	for key in integrity:
		if saved.has(key):
			integrity[key] = clampf(float(saved[key]), 0.0, 1.0)
	wrecked = integrity["body"] <= GameConfig.WRECK_THRESHOLD
	on_fire = false
	fire_timer = 0.0


func repair_all() -> void:
	for key in integrity:
		integrity[key] = 1.0
	on_fire = false
	fire_timer = 0.0
	wrecked = false
	wreck_cause = ""


func apply(component: String, amount: float) -> void:
	if amount <= 0.0 or wrecked:
		return
	var before: float = integrity[component]
	integrity[component] = clampf(before - amount, 0.0, 1.0)
	damaged.emit(component, amount, integrity[component])

	if component == "body" and integrity["body"] <= GameConfig.WRECK_THRESHOLD:
		_wreck("destroyed")


## Impact from a collision. `local_direction` is the contact normal expressed in
## the car's own frame, so we know whether it was nose, tail or flank.
func apply_impact(impulse: float, local_direction: Vector2) -> void:
	if wrecked:
		return
	if impulse < GameConfig.CRASH_IMPULSE_THRESHOLD:
		return

	# Durability and armour both soak impact before it reaches the components.
	var severity := impulse / REFERENCE_IMPULSE
	severity /= maxf(stats.crash_resistance, 0.05)

	var dir := local_direction.normalized()
	var frontal := maxf(-dir.x, 0.0)   # something pushing back into the nose
	var rear := maxf(dir.x, 0.0)
	var side := absf(dir.y)

	var body_scale := 100.0 / maxf(stats.durability_body, 1.0)
	var engine_scale := 100.0 / maxf(stats.durability_engine, 1.0)
	var susp_scale := 100.0 / maxf(stats.durability_suspension, 1.0)

	apply("body", severity * (0.55 + side * 0.25) * body_scale)
	if frontal > 0.25:
		apply("engine", severity * frontal * 0.65 * engine_scale)
	if rear > 0.25:
		apply("engine", severity * rear * 0.18 * engine_scale)
	if side > 0.3 or frontal > 0.4:
		apply("suspension", severity * (side * 0.6 + frontal * 0.3) * susp_scale)


## Landing from a jump. Anything above the safe speed goes through the
## suspension first and then into the body.
func apply_landing(vertical_speed: float) -> void:
	if wrecked:
		return
	var excess := vertical_speed - GameConfig.SAFE_LANDING_SPEED * stats.suspension_travel
	if excess <= 0.0:
		return
	var severity := (excess * excess) / 900.0 / maxf(stats.crash_resistance, 0.05)
	apply("suspension", severity * (100.0 / maxf(stats.durability_suspension, 1.0)))
	if excess > 8.0:
		apply("body", severity * 0.4 * (100.0 / maxf(stats.durability_body, 1.0)))


## Continuous wear from sliding and from surface abrasion.
func apply_tire_wear(delta: float, slip_magnitude: float, surface_drag: float) -> void:
	if wrecked:
		return
	var wear := slip_magnitude * surface_drag * stats.tire_wear_rate * delta * 0.0015
	if wear > 0.0:
		integrity["tires"] = clampf(integrity["tires"] - wear, 0.0, 1.0)


func update(delta: float, rng: RandomNumberGenerator) -> void:
	if wrecked:
		return

	if on_fire:
		fire_timer += delta
		# Fire eats everything; once it is lit the clock is running.
		var rate := delta / GameConfig.FIRE_BURN_OUT_TIME
		integrity["engine"] = maxf(integrity["engine"] - rate * 1.4, 0.0)
		integrity["body"] = maxf(integrity["body"] - rate, 0.0)
		if fire_timer >= GameConfig.FIRE_BURN_OUT_TIME or integrity["body"] <= 0.0:
			_wreck("burned_out")
		return

	if integrity["engine"] <= FIRE_RISK_THRESHOLD:
		# The worse the engine, the likelier it lights up on any given second.
		var engine_health: float = integrity["engine"]
		var risk := (FIRE_RISK_THRESHOLD - engine_health) / FIRE_RISK_THRESHOLD
		if rng.randf() < GameConfig.FIRE_IGNITION_RATE * risk * delta:
			ignite()


func ignite() -> void:
	if on_fire or wrecked:
		return
	on_fire = true
	fire_timer = 0.0
	caught_fire.emit()


func _wreck(cause: String) -> void:
	if wrecked:
		return
	wrecked = true
	wreck_cause = cause
	wrecked_out.emit(cause)
