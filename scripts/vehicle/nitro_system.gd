class_name NitroSystem
extends RefCounted
## Nitrous: the "Madness" half of the name.
##
## The design goal is that nitro is a decision, not a button you hold. Heat
## builds while it is lit and only bleeds off when it is not, so a long burn
## costs engine health. Different bottles trade capacity against punch.

## Multiplier applied to engine torque at full nitro power rating of 1.0.
const BASE_POWER_GAIN := 0.55
## Charge consumed per second while active, at capacity 100.
const DRAIN_PER_SECOND := 22.0
## Heat added per second while active, and shed per second while off.
const HEAT_GAIN := 26.0
const HEAT_LOSS := 15.0
## Heat above this starts cooking the engine.
const OVERHEAT_THRESHOLD := 100.0
## Engine integrity lost per second while overheating.
const OVERHEAT_DAMAGE_RATE := 0.06
## Minimum charge needed to light it, so it cannot be spammed on fumes.
const MIN_ACTIVATION_CHARGE := 4.0

var stats: VehicleStats
var charge: float = 0.0
var heat: float = 0.0
var active: bool = false

signal state_changed(charge: float, is_active: bool)
signal overheating(damage: float)


func _init(p_stats: VehicleStats) -> void:
	stats = p_stats
	charge = stats.nitro_capacity


func has_nitro() -> bool:
	return stats.nitro_capacity > 0.0


func charge_fraction() -> float:
	if stats.nitro_capacity <= 0.0:
		return 0.0
	return clampf(charge / stats.nitro_capacity, 0.0, 1.0)


func heat_fraction() -> float:
	return clampf(heat / OVERHEAT_THRESHOLD, 0.0, 1.5)


## Returns the torque multiplier to hand to the engine this frame.
func update(delta: float, wants_nitro: bool, throttle: float) -> float:
	if not has_nitro():
		active = false
		return 1.0

	var was_active := active
	# Nitro needs throttle; it will not push a car that is not already driving.
	active = wants_nitro and charge > MIN_ACTIVATION_CHARGE and throttle > 0.2

	if active:
		charge -= DRAIN_PER_SECOND * delta * (stats.nitro_capacity / 100.0)
		charge = maxf(charge, 0.0)
		heat += HEAT_GAIN * delta * stats.nitro_heat
	else:
		heat -= HEAT_LOSS * delta
		heat = maxf(heat, 0.0)
		if stats.nitro_regen > 0.0:
			charge = minf(charge + stats.nitro_regen * delta, stats.nitro_capacity)

	if heat > OVERHEAT_THRESHOLD:
		var over := (heat - OVERHEAT_THRESHOLD) / OVERHEAT_THRESHOLD
		overheating.emit(OVERHEAT_DAMAGE_RATE * delta * (1.0 + over))

	if active != was_active:
		state_changed.emit(charge_fraction(), active)

	if not active:
		return 1.0
	# Power falls off as the bottle empties, so the last drops are weaker.
	var pressure := lerpf(0.65, 1.0, charge_fraction())
	return 1.0 + BASE_POWER_GAIN * stats.nitro_power * pressure


## Refilled between events, or at a pit trigger mid-race.
func refill() -> void:
	charge = stats.nitro_capacity
	heat = 0.0
	state_changed.emit(charge_fraction(), false)


## Awarded for the things the game wants to encourage: clean jumps, drifts,
## near misses. Only useful on bottles that support regeneration.
func award(amount: float) -> void:
	if stats.nitro_regen <= 0.0:
		return
	charge = minf(charge + amount, stats.nitro_capacity)
	state_changed.emit(charge_fraction(), active)
