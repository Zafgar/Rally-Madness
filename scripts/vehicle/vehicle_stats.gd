class_name VehicleStats
extends RefCounted
## The resolved, ready-to-drive numbers for one car: base spec with every
## fitted part already folded in. The physics code reads only this, so it never
## has to care whether a value came from the factory or from a turbo kit.
##
## Every field here is a legal tuning target. Adding a new tunable stat means
## adding it here plus one entry in STAT_KEYS, and parts can address it
## immediately.

enum Drivetrain { FWD, RWD, AWD }

## Canonical list of modifiable stats. PartSpec validates against this so a typo
## in a data file fails loudly at load instead of silently doing nothing.
const STAT_KEYS := [
	"mass_kg", "weight_bias_front", "cg_height_m", "wheelbase_m", "track_width_m",
	"engine_torque_nm", "torque_curve_bias", "idle_rpm", "redline_rpm", "turbo_boost",
	"turbo_lag", "shift_time", "final_drive", "gear_spread", "clutch_grab",
	"grip_lat", "grip_long", "grip_balance_front", "slip_forgiveness", "drift_release",
	"tarmac_grip", "dirt_grip", "snow_grip", "tire_wear_rate",
	"max_steer_deg", "steering_rate", "steering_speed_falloff",
	"brake_force", "brake_bias_front", "handbrake_lock",
	"downforce", "drag_area", "rolling_resistance",
	"nitro_capacity", "nitro_power", "nitro_regen", "nitro_heat",
	"durability_body", "durability_engine", "durability_suspension", "crash_resistance",
	"awd_front_bias", "diff_lock_front", "diff_lock_rear", "suspension_travel",
]

# --- Identity (not tunable) ---
var spec_id: String = ""
var display_name: String = ""
var tier: int = 0
var drivetrain: Drivetrain = Drivetrain.RWD

# --- Mass & geometry ---
var mass_kg: float = 1200.0
## Fraction of static weight over the front axle. 0.5 is neutral; a front
## transverse engine car sits nearer 0.62, a mid-engine near 0.42.
var weight_bias_front: float = 0.55
var cg_height_m: float = 0.52
var wheelbase_m: float = 2.55
var track_width_m: float = 1.5

# --- Engine ---
var engine_torque_nm: float = 240.0
## Shifts where in the rev range peak torque lands. Negative = torquey low
## down (diesel-ish), positive = peaky top end (small turbo / high-revving NA).
var torque_curve_bias: float = 0.0
var idle_rpm: float = 900.0
var redline_rpm: float = 6800.0
## Multiplier on torque once boost is up. 1.0 means naturally aspirated.
var turbo_boost: float = 1.0
## Seconds for boost to build. Bigger turbo = more power, more lag.
var turbo_lag: float = 0.0

# --- Transmission ---
var gear_ratios: PackedFloat32Array = PackedFloat32Array([3.5, 2.1, 1.45, 1.1, 0.88, 0.72])
var reverse_ratio: float = 3.2
var final_drive: float = 3.9
## Scales the whole ratio set. <1 = longer legs / higher top speed,
## >1 = shorter / quicker acceleration.
var gear_spread: float = 1.0
var shift_time: float = 0.28
## How fast drive torque is restored after a shift. A race clutch snaps in.
var clutch_grab: float = 1.0

# --- Tires & grip ---
## Peak lateral force coefficient (roughly mu). ~1.0 road, ~1.4 slicks.
var grip_lat: float = 1.05
var grip_long: float = 1.10
## Splits grip between axles. >0.5 favours the front (understeer resistant,
## loose rear), <0.5 plants the rear.
var grip_balance_front: float = 0.5
## Widens the slip-angle peak. High values are forgiving and arcade-y, low
## values snap away past the limit.
var slip_forgiveness: float = 1.0
## How readily grip falls off past the peak, i.e. how happily it drifts and how
## controllable that drift is.
var drift_release: float = 1.0
## Per-surface multipliers. Rally tire choice lives here.
var tarmac_grip: float = 1.0
var dirt_grip: float = 1.0
var snow_grip: float = 1.0
var tire_wear_rate: float = 1.0

# --- Steering ---
var max_steer_deg: float = 32.0
## How quickly the wheels reach the commanded angle (1/s).
var steering_rate: float = 6.0
## How much steering authority is traded away with speed, for stability.
var steering_speed_falloff: float = 0.55

# --- Brakes ---
var brake_force: float = 1.0
var brake_bias_front: float = 0.62
## How completely the handbrake locks the rear. 1.0 = full lock, instant slide.
var handbrake_lock: float = 0.9

# --- Aero ---
var downforce: float = 0.0
var drag_area: float = 0.72
var rolling_resistance: float = 0.014

# --- Nitro ---
var nitro_capacity: float = 0.0
var nitro_power: float = 1.0
var nitro_regen: float = 0.0
var nitro_heat: float = 1.0

# --- Durability ---
var durability_body: float = 100.0
var durability_engine: float = 100.0
var durability_suspension: float = 100.0
## Scales incoming impact damage. Roll cages and armour lower this.
var crash_resistance: float = 1.0

# --- Drivetrain detail ---
## For AWD only: share of drive torque sent forward.
var awd_front_bias: float = 0.4
var diff_lock_front: float = 0.3
var diff_lock_rear: float = 0.5
var suspension_travel: float = 1.0

# --- Derived / bookkeeping ---
var total_part_value: int = 0
var fitted_parts: Dictionary = {}


func get_stat(key: String) -> float:
	return float(get(key))


func set_stat(key: String, value: float) -> void:
	set(key, value)


## Distance from the centre of gravity to each axle. Everything about weight
## transfer and slip angles is derived from these two.
func cg_to_front_axle() -> float:
	# Static front load = b / L, where b is the CoG-to-rear distance. So the
	# front axle sits (1 - bias) * L ahead of the CoG.
	return wheelbase_m * (1.0 - weight_bias_front)


func cg_to_rear_axle() -> float:
	return wheelbase_m * weight_bias_front


func drives_front() -> bool:
	return drivetrain != Drivetrain.RWD


func drives_rear() -> bool:
	return drivetrain != Drivetrain.FWD


## Share of drive torque reaching each axle, given the drivetrain layout.
func front_torque_share() -> float:
	match drivetrain:
		Drivetrain.FWD: return 1.0
		Drivetrain.RWD: return 0.0
		_: return clampf(awd_front_bias, 0.0, 1.0)


func gear_count() -> int:
	return gear_ratios.size()


## Effective ratio for a gear index (0-based forward gear), including spread
## and final drive.
func effective_ratio(gear_index: int) -> float:
	if gear_index < 0 or gear_index >= gear_ratios.size():
		return 0.0
	return gear_ratios[gear_index] * gear_spread * final_drive


func clone() -> VehicleStats:
	var s := VehicleStats.new()
	for key in STAT_KEYS:
		s.set(key, get(key))
	s.spec_id = spec_id
	s.display_name = display_name
	s.tier = tier
	s.drivetrain = drivetrain
	s.gear_ratios = gear_ratios.duplicate()
	s.reverse_ratio = reverse_ratio
	s.total_part_value = total_part_value
	s.fitted_parts = fitted_parts.duplicate()
	return s


## Single headline number used for matchmaking, event entry requirements and
## AI field generation. Deliberately crude but monotonic.
func performance_index() -> float:
	var power_to_weight := (engine_torque_nm * turbo_boost) / maxf(mass_kg, 1.0) * 1000.0
	var grip := (grip_lat + grip_long) * 0.5 * 100.0
	var nitro := nitro_capacity * 0.15
	var brakes := brake_force * 20.0
	return power_to_weight * 1.6 + grip * 0.9 + nitro + brakes
