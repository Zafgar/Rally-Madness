extends Node
## Calibration bench: what the model says every car does, against what the real
## one does.
##
## Power and top speed are not authored — they fall out of the torque curve,
## the gearing and the drag area. That makes them the honest check on whether
## those numbers are right: a car that should make 240 hp and makes 310 here
## has a broken curve and will feel wrong to drive.
##
##   godot --headless --path . res://tests/spec_bench.tscn
##   godot --headless --path . res://tests/spec_bench.tscn -- tuned

## Tolerance before a car is flagged, as a fraction.
const POWER_TOLERANCE := 0.12
const SPEED_TOLERANCE := 0.15


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var show_tuned := args.size() > 0 and args[0] == "tuned"

	print("=== Rally Madness spec bench ===")
	print("%-28s %-5s %11s %11s %13s %13s %7s %7s" % [
		"car", "tier", "power hp", "(real)", "top km/h", "(real)", "0-100", "index"])

	var power_off := 0
	var speed_off := 0
	var missing := 0

	for spec in CarDatabase.all():
		var stats := TuningCalculator.resolve(spec, spec.default_loadout())
		var s: Dictionary = PerformanceModel.summary(stats)

		var power_note := ""
		var speed_note := ""
		if spec.reference_power_hp > 0.0:
			var error: float = (s["power_hp"] - spec.reference_power_hp) / spec.reference_power_hp
			if absf(error) > POWER_TOLERANCE:
				power_note = "  <-- %+.0f%%" % (error * 100.0)
				power_off += 1
		else:
			missing += 1
		if spec.reference_top_speed_kmh > 0.0:
			var error: float = (s["top_speed_kmh"] - spec.reference_top_speed_kmh) \
				/ spec.reference_top_speed_kmh
			if absf(error) > SPEED_TOLERANCE:
				speed_note = "  <== %+.0f%%" % (error * 100.0)
				speed_off += 1

		var zero_to_100: float = s["zero_to_100"]
		print("%-28s %-5d %11.0f %11.0f %13.0f %13.0f %7s %7.0f%s%s" % [
			spec.display_name(), spec.tier,
			s["power_hp"], spec.reference_power_hp,
			s["top_speed_kmh"], spec.reference_top_speed_kmh,
			("%.1f" % zero_to_100) if zero_to_100 < 60.0 else "-",
			stats.performance_index(), power_note, speed_note])

	print("\n%d cars off on power, %d off on top speed, %d without reference figures" % [
		power_off, speed_off, missing])

	if show_tuned:
		_report_tuned()
	get_tree().quit(0)


## What the best parts a chassis will accept actually buy it. The interesting
## check is that a fully built low-tier car stays clearly behind a stock car
## from a couple of tiers up — otherwise the whole progression is pointless.
func _report_tuned() -> void:
	print("\n=== stock vs fully built, within each chassis' upgrade ceiling ===")
	print("%-28s %-5s %8s %8s %8s %9s %10s %8s" % [
		"car", "tier", "stock", "built", "gain", "car cost", "build cost", "ceiling"])
	for spec in CarDatabase.all():
		var loadout := _best_loadout(spec)
		var stock := TuningCalculator.resolve(spec, spec.default_loadout())
		var built := TuningCalculator.resolve(spec, loadout)
		var stock_hp := PerformanceModel.peak_power_hp(stock)
		var built_hp := PerformanceModel.peak_power_hp(built)
		print("%-28s %-5d %8.0f %8.0f %7.0f%% %9d %10d %8d" % [
			spec.display_name(), spec.tier, stock_hp, built_hp,
			(built_hp / maxf(stock_hp, 1.0) - 1.0) * 100.0,
			spec.price, loadout.total_value(), spec.upgrade_ceiling])


## The most powerful legal part in every slot for this chassis.
func _best_loadout(spec: CarSpec) -> TuningLoadout:
	var loadout := spec.default_loadout()
	var stats := spec.to_base_stats()
	for slot in PartSpec.SLOTS:
		if not spec.accepts_slot(slot):
			continue
		var best: PartSpec = null
		for part in PartDatabase.for_slot(slot):
			if not spec.accepts_part(part) or not part.fits(stats):
				continue
			if best == null or part.price > best.price:
				best = part
		if best != null:
			loadout.set_part(slot, best.id)
	return loadout
