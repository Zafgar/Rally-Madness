class_name TuningCalculator
extends RefCounted
## Folds a car's factory stats, its fitted parts, its setup sheet and its
## current damage into one VehicleStats the physics can drive.
##
## This is the only place where those four inputs meet. Anything that wants to
## know how a car actually performs — the physics, the garage preview, the
## matchmaking index — calls resolve() and gets the same answer.

## How far each setup slider can push a stat at full deflection. These are
## intentionally small: setup is for fine-tuning a car you already own, parts
## are for making it fundamentally faster.
const SETUP_AUTHORITY := {
	"brake_bias": 0.14,
	"diff_preload": 0.35,
	"ride_height": 0.10,
	"antiroll_balance": 0.12,
	"gear_length": 0.18,
	"awd_split": 0.30,
	"boost_pressure": 0.15,
	"rev_limit": 0.09,
}


## damage is an optional Dictionary of component -> integrity fraction (0..1).
static func resolve(
	spec: CarSpec,
	loadout: TuningLoadout = null,
	damage: Dictionary = {}
) -> VehicleStats:
	var stats := spec.to_base_stats()
	if loadout == null:
		loadout = spec.default_loadout()

	_apply_parts(stats, spec, loadout)
	_apply_setup(stats, loadout)
	_apply_damage(stats, damage)
	_clamp_to_sane_ranges(stats)
	return stats


static func _apply_parts(stats: VehicleStats, spec: CarSpec, loadout: TuningLoadout) -> void:
	# Additive terms are gathered first and multipliers second, so two +10%
	# parts stack to +21% rather than depending on dictionary order.
	var adds := {}
	var muls := {}
	var value := 0

	for slot in loadout.parts:
		var part := PartDatabase.get_part(loadout.parts[slot])
		if part == null:
			push_warning("Loadout references missing part '%s'" % loadout.parts[slot])
			continue
		# The chassis has the final say. A saved loadout from an older build,
		# or one edited by hand, must not be able to smuggle a race gearbox
		# onto a car that could never accept one.
		if not spec.accepts_part(part) or not part.fits(stats):
			continue
		value += part.price
		stats.fitted_parts[slot] = part.id
		for stat in part.modifiers:
			var m: Dictionary = part.modifiers[stat]
			adds[stat] = float(adds.get(stat, 0.0)) + m["add"]
			muls[stat] = float(muls.get(stat, 1.0)) * m["mul"]

	for stat in adds:
		stats.set_stat(stat, stats.get_stat(stat) + adds[stat])
	for stat in muls:
		stats.set_stat(stat, stats.get_stat(stat) * muls[stat])
	stats.total_part_value = value


static func _apply_setup(stats: VehicleStats, loadout: TuningLoadout) -> void:
	var s := loadout.setup

	var bias: float = float(s.get("brake_bias", 0.0))
	stats.brake_bias_front += bias * SETUP_AUTHORITY["brake_bias"]

	# Raising the limiter genuinely raises the redline. What it costs is decided
	# by MechanicalModel, which reads the same setting.
	var limiter := float(loadout.setup.get("rev_limit", 0.0))
	stats.redline_rpm *= 1.0 + maxf(limiter, 0.0) * SETUP_AUTHORITY["rev_limit"]

	# Named diff_preload rather than preload: the latter is a GDScript keyword.
	var diff_preload: float = float(s.get("diff_preload", 0.0))
	stats.diff_lock_front += diff_preload * SETUP_AUTHORITY["diff_preload"]
	stats.diff_lock_rear += diff_preload * SETUP_AUTHORITY["diff_preload"]

	# Lower is faster on tarmac but runs out of travel over rally jumps.
	var height: float = float(s.get("ride_height", 0.0))
	stats.cg_height_m += height * SETUP_AUTHORITY["ride_height"]
	stats.suspension_travel *= 1.0 + height * 0.35
	stats.tarmac_grip *= 1.0 - height * 0.08
	stats.dirt_grip *= 1.0 + height * 0.06

	# Positive shifts grip rearward: more front bite, looser tail.
	var arb: float = float(s.get("antiroll_balance", 0.0))
	stats.grip_balance_front += arb * SETUP_AUTHORITY["antiroll_balance"]

	var gearing: float = float(s.get("gear_length", 0.0))
	stats.gear_spread *= 1.0 - gearing * SETUP_AUTHORITY["gear_length"]

	if stats.drivetrain == VehicleStats.Drivetrain.AWD:
		var split: float = float(s.get("awd_split", 0.0))
		stats.awd_front_bias -= split * SETUP_AUTHORITY["awd_split"]

	# More boost, more power, more heat and more strain on a stock block.
	var boost: float = float(s.get("boost_pressure", 0.0))
	if stats.turbo_boost > 1.0:
		stats.turbo_boost += boost * SETUP_AUTHORITY["boost_pressure"]
		stats.durability_engine *= 1.0 - maxf(boost, 0.0) * 0.18
		stats.turbo_lag *= 1.0 + boost * 0.1


## Damage does not just subtract a number from a health bar — it changes how
## the car drives, so a limping car feels wrong before it dies.
static func _apply_damage(stats: VehicleStats, damage: Dictionary) -> void:
	if damage.is_empty():
		return
	var engine := clampf(float(damage.get("engine", 1.0)), 0.0, 1.0)
	var susp := clampf(float(damage.get("suspension", 1.0)), 0.0, 1.0)
	var body := clampf(float(damage.get("body", 1.0)), 0.0, 1.0)
	var tires := clampf(float(damage.get("tires", 1.0)), 0.0, 1.0)

	stats.engine_torque_nm *= lerpf(0.25, 1.0, engine)
	stats.turbo_boost = lerpf(1.0, stats.turbo_boost, engine)
	stats.redline_rpm *= lerpf(0.75, 1.0, engine)

	stats.grip_lat *= lerpf(0.55, 1.0, susp)
	stats.grip_long *= lerpf(0.65, 1.0, susp)
	# A bent corner pulls the car to one side and blunts the steering.
	stats.steering_rate *= lerpf(0.6, 1.0, susp)
	stats.max_steer_deg *= lerpf(0.7, 1.0, susp)

	stats.drag_area *= lerpf(1.35, 1.0, body)
	stats.downforce *= lerpf(0.4, 1.0, body)

	stats.grip_lat *= lerpf(0.5, 1.0, tires)
	stats.grip_long *= lerpf(0.6, 1.0, tires)
	stats.brake_force *= lerpf(0.6, 1.0, tires)


static func _clamp_to_sane_ranges(stats: VehicleStats) -> void:
	stats.mass_kg = maxf(stats.mass_kg, 300.0)
	stats.weight_bias_front = clampf(stats.weight_bias_front, 0.28, 0.72)
	stats.cg_height_m = clampf(stats.cg_height_m, 0.20, 1.10)
	stats.wheelbase_m = maxf(stats.wheelbase_m, 1.6)
	stats.grip_balance_front = clampf(stats.grip_balance_front, 0.25, 0.75)
	stats.brake_bias_front = clampf(stats.brake_bias_front, 0.30, 0.90)
	stats.awd_front_bias = clampf(stats.awd_front_bias, 0.05, 0.95)
	stats.diff_lock_front = clampf(stats.diff_lock_front, 0.0, 1.0)
	stats.diff_lock_rear = clampf(stats.diff_lock_rear, 0.0, 1.0)
	stats.turbo_boost = maxf(stats.turbo_boost, 1.0)
	stats.turbo_lag = maxf(stats.turbo_lag, 0.0)
	stats.shift_time = clampf(stats.shift_time, 0.04, 1.2)
	stats.gear_spread = clampf(stats.gear_spread, 0.55, 1.8)
	stats.grip_lat = maxf(stats.grip_lat, 0.15)
	stats.grip_long = maxf(stats.grip_long, 0.15)
	stats.slip_forgiveness = maxf(stats.slip_forgiveness, 0.25)
	stats.max_steer_deg = clampf(stats.max_steer_deg, 8.0, 55.0)
	stats.redline_rpm = maxf(stats.redline_rpm, stats.idle_rpm + 1500.0)
	stats.nitro_capacity = maxf(stats.nitro_capacity, 0.0)
	stats.drag_area = maxf(stats.drag_area, 0.15)


## Cost of putting a wrecked car back together. Starter-tier cars are always
## free to repair so a broke player is never locked out of the game.
static func repair_cost(spec: CarSpec, loadout: TuningLoadout, damage: Dictionary) -> int:
	if spec.tier <= GameConfig.STARTER_TIER:
		return 0
	var worst := 0.0
	for component in ["engine", "suspension", "body", "tires"]:
		worst += 1.0 - clampf(float(damage.get(component, 1.0)), 0.0, 1.0)
	var severity := worst / 4.0
	var base := float(spec.price) * 0.28
	var parts_value := float(loadout.total_value() if loadout else 0) * 0.15
	return int((base + parts_value) * severity)
