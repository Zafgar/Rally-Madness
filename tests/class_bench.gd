extends Node
## Where every car sits against the competition class limits, stock and built.
##
## The class caps and the car roster have to agree with each other, and neither
## is obvious from reading the other. This prints, for every car: what it scores
## stock, what it scores with the best parts its chassis will accept, which
## class each of those lands in, and how much of that class's allowance it uses.
##
## Two failures show up immediately here. A class with nothing in it is content
## nobody will ever see. A class whose cars are all at 60% of the cap means
## every field is slower than the rules allow, which is what makes a career feel
## like the calendar has moved on without you.
##
##   godot --headless --path . res://tests/class_bench.tscn


func _ready() -> void:
	print("=== Rally Madness class bench ===")
	print("%-28s %-4s %9s %9s %8s %-8s %8s %-8s %6s" % [
		"car", "tier", "price", "build", "stock", "class", "built", "class", "use"])

	# class id -> counts, so an empty class is visible at the end.
	var stock_population := {}
	var built_population := {}
	for c in RaceClass.all():
		stock_population[c.id] = 0
		built_population[c.id] = 0

	for spec in CarDatabase.all():
		var stock := _index_of(spec, spec.default_loadout())
		var built := _index_of(spec, _best_loadout(spec))
		var stock_class := _class_for(spec, stock)
		var built_class := _class_for(spec, built)
		stock_population[stock_class.id] += 1
		built_population[built_class.id] += 1

		# How much of its own class's allowance a fully built car uses. Under
		# about 0.8 means the chassis cannot reach the class it sits in, which
		# is the same as saying it will never be competitive there.
		var use := 0.0
		if built_class.max_performance_index < 99999.0:
			use = built / built_class.max_performance_index

		print("%-28s %-4d %9d %9d %8.0f %-8s %8.0f %-8s %5.0f%%" % [
			spec.display_name(), spec.tier, spec.price, spec.full_build_cost(),
			stock, stock_class.short_name,
			built, built_class.short_name,
			use * 100.0])

	print("\n%-16s %8s %8s %10s %8s" % [
		"class", "cap", "stock", "built", "rating"])
	for c in RaceClass.all():
		print("%-16s %8s %8d %10d %8s" % [
			c.display_name,
			"-" if c.max_performance_index >= 99999.0 else str(int(c.max_performance_index)),
			stock_population[c.id], built_population[c.id],
			"%d+" % c.min_rating])

	get_tree().quit(0)


func _index_of(spec: CarSpec, loadout: TuningLoadout) -> float:
	return TuningCalculator.resolve(spec, loadout).performance_index()


## The most expensive part in every slot the chassis will accept — what the car
## becomes when a player with money is finished with it.
func _best_loadout(spec: CarSpec) -> TuningLoadout:
	var loadout := spec.default_loadout()
	for slot in PartDatabase.slots():
		var best: PartSpec = null
		for part in PartDatabase.for_slot(slot):
			if not spec.accepts_part(part):
				continue
			if best == null or part.price > best.price:
				best = part
		if best != null:
			loadout.set_part(slot, best.id)
	return loadout


## The lowest class that will accept a car at this performance index. Mirrors
## RaceClass.best_fit, but takes the index directly so a hypothetical build can
## be placed without owning the car.
func _class_for(spec: CarSpec, index: float) -> RaceClass:
	for c in RaceClass.all():
		if c.id == "open":
			continue
		if spec.tier < c.min_car_tier or spec.tier > c.max_car_tier:
			continue
		if index <= c.max_performance_index:
			return c
	return RaceClass.by_id("open")
