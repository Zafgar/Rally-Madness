class_name DualSenseBackend
extends RumbleBackend
## Adaptive triggers on a PS5 controller.
##
## Godot has no native API for these. The L2/R2 resistance motors are driven by
## DualSense-specific HID output reports, which means a GDExtension that talks
## to the pad directly. This class is the seam: it detects such an extension at
## runtime and drives it, and does nothing at all when one is not installed.
##
## Rumble is inherited from RumbleBackend and works either way, so a build with
## no extension still gets everything except trigger resistance.
##
## The extension is expected to register an Engine singleton exposing:
##   set_trigger_effect(device_id, trigger, mode, start, end, strength, frequency)
##   reset_triggers(device_id)
## where trigger is 0 for L2 and 1 for R2, and mode matches TriggerEffect.Mode.
## Any extension matching that shape will work; the names below are the ones
## the common community builds use.

const SINGLETON_CANDIDATES := ["DualSense", "DualSenseAdapter", "PS5Controller"]

const TRIGGER_LEFT := 0
const TRIGGER_RIGHT := 1

var _adapter: Object = null
var _checked: bool = false
var _last_throttle: Dictionary = {}
var _last_brake: Dictionary = {}


func backend_name() -> String:
	_resolve_adapter()
	if _adapter == null:
		return "godot-rumble (no adaptive triggers: no DualSense extension found)"
	return "dualsense (%s)" % _adapter_name


var _adapter_name: String = ""


func supports_triggers() -> bool:
	_resolve_adapter()
	return _adapter != null


func _resolve_adapter() -> void:
	if _checked:
		return
	_checked = true
	for name in SINGLETON_CANDIDATES:
		if not Engine.has_singleton(name):
			continue
		var candidate := Engine.get_singleton(name)
		# Only accept something that actually exposes the calls we need,
		# rather than assuming any singleton with the right name will do.
		if candidate != null and candidate.has_method("set_trigger_effect"):
			_adapter = candidate
			_adapter_name = name
			return
	push_warning(
		"DualSenseBackend: no adaptive-trigger extension found; " +
		"rumble will work, trigger resistance will not.")


func set_triggers(device_id: int, throttle: TriggerEffect, brake: TriggerEffect) -> void:
	if device_id < 0:
		return
	_resolve_adapter()
	if _adapter == null:
		return

	# Trigger effects go over HID. Re-sending an unchanged effect every frame
	# floods the pad and adds latency to the thing meant to feel immediate, so
	# only genuine changes are pushed.
	var previous_throttle: TriggerEffect = _last_throttle.get(device_id)
	if throttle.differs_from(previous_throttle):
		_send(device_id, TRIGGER_RIGHT, throttle)
		_last_throttle[device_id] = throttle.duplicate_effect()

	var previous_brake: TriggerEffect = _last_brake.get(device_id)
	if brake.differs_from(previous_brake):
		_send(device_id, TRIGGER_LEFT, brake)
		_last_brake[device_id] = brake.duplicate_effect()


func _send(device_id: int, trigger: int, effect: TriggerEffect) -> void:
	_adapter.call("set_trigger_effect", device_id, trigger, int(effect.mode),
		effect.start, effect.end, effect.strength, effect.frequency)


func stop(device_id: int) -> void:
	super.stop(device_id)
	_last_throttle.erase(device_id)
	_last_brake.erase(device_id)
	if _adapter != null and _adapter.has_method("reset_triggers"):
		_adapter.call("reset_triggers", device_id)
