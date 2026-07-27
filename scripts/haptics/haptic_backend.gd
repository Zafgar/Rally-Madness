class_name HapticBackend
extends RefCounted
## Where haptic output actually goes.
##
## Split from the feel logic so the same HapticState can drive a plain rumble
## pad, a DualSense with adaptive triggers, or nothing at all, without the
## gameplay code knowing or caring which.

func backend_name() -> String:
	return "none"


## Whether this backend can do adaptive trigger resistance, as opposed to just
## rumble. Callers use it to decide whether to surface the option in settings.
func supports_triggers() -> bool:
	return false


func set_rumble(_device_id: int, _low: float, _high: float) -> void:
	pass


func set_triggers(_device_id: int, _throttle: TriggerEffect, _brake: TriggerEffect) -> void:
	pass


## Called when a race ends or the game loses focus. A pad left buzzing after
## the player has put it down is a bug worth being careful about.
func stop(_device_id: int) -> void:
	pass
