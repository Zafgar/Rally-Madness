class_name CarAudio
extends Node2D
## Everything one car sounds like, positioned where the car is.
##
## Every voice is an AudioStreamPlayer2D parented to the car, so distance
## attenuation, stereo placement and doppler all come from the engine for free
## and a rival two hundred metres up the road sounds like one.
##
## The mix is entirely driven by what the car is doing. Nothing here decides to
## play a sound; it reads rpm, throttle, slip and boost every frame and sets
## volumes and pitches accordingly. That is why lifting off produces the right
## noise without anything having to notice that the player lifted off.

## Beyond this many metres a car is inaudible and its voices are stopped
## outright. Twelve cars each holding six players open would exhaust the voice
## budget for no benefit — most of the field is nowhere near you.
const AUDIBLE_RANGE_M := 190.0
## Cars further than this get the engine only. The tyres and turbo of a car you
## can barely hear are detail nobody will ever pick out.
const DETAIL_RANGE_M := 70.0

## How quickly mixed levels follow the car. Fast enough to feel connected to the
## throttle, slow enough not to zipper.
const LEVEL_SMOOTHING := 18.0

var car: RallyCar
var voice: EngineVoice

var _engine_on: Array[AudioStreamPlayer2D] = []
var _engine_off: Array[AudioStreamPlayer2D] = []
var _turbo: AudioStreamPlayer2D
var _tyre: AudioStreamPlayer2D
var _surface: AudioStreamPlayer2D
var _one_shot: AudioStreamPlayer2D

var _blow_off: AudioStreamWAV
var _flutter: AudioStreamWAV
var _gear_change: AudioStreamWAV
var _turbo_failure: AudioStreamWAV
var _engine_failure: AudioStreamWAV
var _puncture: AudioStreamWAV
var _impacts: Array[AudioStreamWAV] = []
var _surface_streams: Dictionary = {}

## Set once the voices exist. The loops cannot be started until both this is
## true and the node is in the tree, and which of those happens first depends
## on the caller — so both paths ask.
var _built: bool = false
var _loops_started: bool = false

var _previous_throttle: float = 0.0
var _previous_boost: float = 1.0
var _audible: bool = true
var _detailed: bool = true
## Levels are smoothed rather than set outright, so nothing steps.
var _tyre_level: float = 0.0
var _surface_level: float = 0.0
var _turbo_level: float = 0.0


## Builds every voice for one car. Called once, when the car is configured —
## baking is not free and doing it mid-race would stutter.
func setup(p_car: RallyCar, layout: EngineLayout, loadout: TuningLoadout) -> void:
	car = p_car
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(car.spec.id) if car.spec != null else 999

	var exhaust_tier := _part_tier(loadout, "exhaust")
	var intake_tier := _part_tier(loadout, "intake")
	voice = EngineVoice.bake(car.stats, layout, exhaust_tier, intake_tier)

	for band in voice.on_load.size():
		_engine_on.append(_make_player(voice.on_load[band], "Engine", -80.0,
			"EngineOn%d" % band))
		_engine_off.append(_make_player(voice.off_load[band], "Engine", -80.0,
			"EngineOff%d" % band))

	if car.stats.turbo_boost > 1.02:
		_turbo = _make_player(
			EffectVoices.bake_turbo_whistle(car.stats.turbo_boost, car.stats.turbo_lag, rng),
			"Engine", -80.0, "Turbo")
		_blow_off = EffectVoices.bake_blow_off(
			car.stats.turbo_boost, car.stats.turbo_lag, rng)
		_flutter = EffectVoices.bake_flutter(car.stats.turbo_lag, rng)

	_tyre = _make_player(EffectVoices.bake_tyre_squeal(rng), "Tyres", -80.0, "TyreSqueal")
	_surface = _make_player(EffectVoices.bake_surface_scrub(
		TireModel.Surface.TARMAC, rng), "Tyres", -80.0, "SurfaceScrub")
	# One scrub loop per surface, swapped as the car crosses zones. Baking all
	# of them up front costs a few kilobytes and avoids a hitch at the moment a
	# car leaves the road, which is the worst possible moment for one.
	for surface in [TireModel.Surface.TARMAC, TireModel.Surface.GRAVEL,
			TireModel.Surface.DIRT, TireModel.Surface.SNOW, TireModel.Surface.ICE,
			TireModel.Surface.GRASS, TireModel.Surface.MUD]:
		_surface_streams[surface] = EffectVoices.bake_surface_scrub(surface, rng)

	_one_shot = _make_player(null, "Impacts", 0.0, "OneShot")
	_gear_change = EffectVoices.bake_gear_change(car.stats.shift_time, rng)
	_turbo_failure = EffectVoices.bake_turbo_failure(rng)
	_engine_failure = EffectVoices.bake_engine_failure(rng)
	_puncture = EffectVoices.bake_puncture(rng)
	# Three severities rather than one scaled by volume: a heavy crash is a
	# different sound, not a louder one.
	for severity in [0.15, 0.5, 0.95]:
		_impacts.append(EffectVoices.bake_impact(severity, rng))

	_built = true
	_maybe_start_loops()
	car.landed.connect(_on_landed)
	EventBus.car_gear_changed.connect(_on_gear_changed)
	EventBus.car_failed.connect(_on_car_failed)


static func _part_tier(loadout: TuningLoadout, slot: String) -> int:
	if loadout == null:
		return 0
	var part := PartDatabase.get_part(loadout.get_part(slot))
	return part.tier if part != null else 0


func _make_player(stream: AudioStream, bus: String,
		volume_db: float, name_hint: String = "") -> AudioStreamPlayer2D:
	var player := AudioStreamPlayer2D.new()
	if not name_hint.is_empty():
		player.name = name_hint
	player.stream = stream
	player.volume_db = volume_db
	player.bus = bus if AudioServer.get_bus_index(bus) >= 0 else "Master"
	# Metres, converted to the pixel space the world actually uses.
	player.max_distance = AUDIBLE_RANGE_M * GameConfig.PIXELS_PER_METRE
	# Gentler than the physical inverse-square law, which in a game this size
	# makes anything not directly beside you inaudible.
	player.attenuation = 1.4
	player.panning_strength = 0.85
	add_child(player)
	return player


func _ready() -> void:
	_maybe_start_loops()


## Starts every continuous voice, once there is somewhere for it to play.
##
## A car is configured before it is added to the world — the race builds it,
## sets it up and then parents it — and an AudioStreamPlayer2D outside the tree
## refuses to play and does not remember that it was asked. So every engine,
## turbo and tyre loop in the game was told to start exactly once, at the only
## moment it could not, and the entire game ran silent apart from the one-shots.
## Hence asking from both ends rather than from whichever one happens to be
## later today.
func _maybe_start_loops() -> void:
	if _loops_started or not _built or not is_inside_tree():
		return
	_loops_started = true
	for player in _engine_on + _engine_off:
		player.play()
	if _turbo != null:
		_turbo.play()
	_tyre.play()
	_surface.play()


func _process(delta: float) -> void:
	if not _built or car == null or not is_instance_valid(car) or car.stats == null:
		return
	_maybe_start_loops()
	_update_audibility()
	if not _audible:
		return
	_update_engine(delta)
	_update_turbo(delta)
	_update_tyres(delta)


## Stops everything on a car nobody can hear. A stopped player costs nothing,
## and a twelve-car field with every voice running would spend the entire
## polyphony budget on cars off the far side of the stage.
func _update_audibility() -> void:
	var listener := AudioDirector.listener_position()
	var distance := global_position.distance_to(listener) / GameConfig.PIXELS_PER_METRE
	var audible := distance < AUDIBLE_RANGE_M
	var detailed := distance < DETAIL_RANGE_M

	if audible != _audible:
		_audible = audible
		for player in _engine_on + _engine_off:
			if audible:
				player.play()
			else:
				player.stop()
		_loops_started = audible
	if detailed != _detailed:
		_detailed = detailed
		for player in [_turbo, _tyre, _surface]:
			if player == null:
				continue
			if detailed and audible:
				player.play()
			else:
				player.stop()


## The engine: two rev bands crossfaded, each with an on-throttle and an
## off-throttle layer crossfaded against each other.
func _update_engine(delta: float) -> void:
	var rpm := car.transmission.rpm if car.transmission != null else car.stats.idle_rpm
	var blend := voice.band_blend(rpm)
	var lower := int(blend[0])
	var upper := int(blend[1])
	var upper_weight := float(blend[2])

	# Load, not throttle: an engine pulling hard at low revs is loaded even at
	# part throttle, and one at the limiter with the pedal down is not making
	# the same noise as one accelerating.
	var throttle := car.command.throttle
	var power := 1.0
	if car.mechanical != null:
		power = car.mechanical.power_multiplier()
	var load := clampf(throttle * power, 0.0, 1.0)
	# A car with no engine left makes no engine noise, which is a far better
	# signal that it has stopped than any message on the HUD.
	var master := clampf(power, 0.0, 1.0)
	if car.damage != null and car.damage.wrecked:
		master = 0.0

	for band in _engine_on.size():
		var band_weight := 0.0
		if band == lower:
			band_weight = 1.0 - upper_weight
		if band == upper:
			band_weight += upper_weight
		var pitch := voice.pitch_for(band, rpm)
		_set_voice(_engine_on[band], band_weight * load * master, pitch, delta)
		_set_voice(_engine_off[band], band_weight * (1.0 - load) * master * 0.75,
			pitch, delta)


## The turbo. Whistle rises and swells with the boost that is actually being
## made, and lifting off dumps it.
func _update_turbo(delta: float) -> void:
	if _turbo == null or car.engine == null:
		return
	var boost := car.engine.boost
	var over := clampf(boost - 1.0, 0.0, 2.0)
	var head_room := maxf(car.stats.turbo_boost - 1.0, 0.01)
	var spool := clampf(over / head_room, 0.0, 1.0)

	# The whistle climbs with turbine speed, which follows revs as well as
	# boost — a spooled turbo at 3000 rpm does not whistle like one at 7000.
	var rev_fraction := clampf(
		car.transmission.rpm / maxf(car.stats.redline_rpm, 1.0), 0.0, 1.2)
	_turbo.pitch_scale = clampf(0.55 + spool * 0.55 + rev_fraction * 0.30, 0.4, 1.9)
	_turbo_level = lerpf(_turbo_level, spool * spool * 0.55,
		clampf(delta * LEVEL_SMOOTHING, 0.0, 1.0))
	_turbo.volume_db = linear_to_db(maxf(_turbo_level, 0.0001))

	# Lifting off with boost up: dump valve. Flutter instead when there is a lot
	# of boost and a big laggy turbo, because that is when it happens.
	var lifted := _previous_throttle > 0.6 and car.command.throttle < 0.2
	if lifted and spool > 0.35:
		if car.stats.turbo_lag > 0.35 and spool > 0.7 and _flutter != null:
			_play_one_shot(_flutter, -4.0)
		elif _blow_off != null:
			_play_one_shot(_blow_off, -3.0)
	_previous_throttle = car.command.throttle
	_previous_boost = boost


## Tyres: a squeal when they are sliding on something that grips, and a scrub
## whose loudness follows speed on everything else.
func _update_tyres(delta: float) -> void:
	var slide := car.wheel_slip
	var speed := car.speed_ms
	var smoothing := clampf(delta * LEVEL_SMOOTHING, 0.0, 1.0)

	# Only surfaces that can grip can squeal. Sliding on gravel throws stones;
	# it does not scream.
	var squeal_surface := car.surface == TireModel.Surface.TARMAC
	var squeal := 0.0
	if squeal_surface and speed > 4.0:
		squeal = clampf((slide - 0.10) * 2.2, 0.0, 1.0) * clampf(speed / 18.0, 0.0, 1.0)
		# Locked or spinning wheels scrub just as hard in a straight line.
		squeal = maxf(squeal, clampf((absf(car.worst_slip_ratio()) - 0.20) * 2.0, 0.0, 1.0)
			* clampf(speed / 14.0, 0.0, 1.0))
	_tyre_level = lerpf(_tyre_level, squeal * 0.55, smoothing)
	_tyre.volume_db = linear_to_db(maxf(_tyre_level, 0.0001))
	# Harder work, higher note: the stick-slip frequency really does climb.
	_tyre.pitch_scale = clampf(0.80 + slide * 0.55 + speed / 90.0, 0.6, 1.7)

	var stream: AudioStreamWAV = _surface_streams.get(car.surface)
	if stream != null and _surface.stream != stream:
		_surface.stream = stream
		if _detailed and _audible:
			_surface.play()
	var roll := clampf(speed / 30.0, 0.0, 1.0)
	# Sliding on a loose surface throws far more of it about.
	var scrub := 1.0 + clampf(slide * 1.6, 0.0, 1.4)
	if car.airborne:
		roll = 0.0   # nothing under the wheels to make a noise
	_surface_level = lerpf(_surface_level, roll * scrub * 0.34, smoothing)
	_surface.volume_db = linear_to_db(maxf(_surface_level, 0.0001))
	_surface.pitch_scale = clampf(0.75 + speed / 55.0, 0.6, 1.6)


func _set_voice(player: AudioStreamPlayer2D, level: float, pitch: float,
		delta: float) -> void:
	player.pitch_scale = lerpf(player.pitch_scale, pitch,
		clampf(delta * 22.0, 0.0, 1.0))
	# Below this a voice is inaudible, and holding it at true silence rather
	# than a very small number keeps the mix clean.
	var target := maxf(level, 0.0001)
	player.volume_db = linear_to_db(target)


func _play_one_shot(stream: AudioStreamWAV, volume_db: float) -> void:
	if _one_shot == null or stream == null or not _audible:
		return
	_one_shot.stream = stream
	_one_shot.volume_db = volume_db
	_one_shot.pitch_scale = 1.0
	_one_shot.play()


## A collision. The severity picks which of the three baked impacts plays, so a
## scrape and a shunt are different sounds rather than one at two volumes.
func play_impact(severity: float) -> void:
	if _impacts.is_empty():
		return
	var index := 0
	if severity > 0.66:
		index = 2
	elif severity > 0.28:
		index = 1
	_play_one_shot(_impacts[index], lerpf(-12.0, 0.0, clampf(severity, 0.0, 1.0)))


func _on_landed(car_id: int, impact: float) -> void:
	if car == null or car_id != car.car_id:
		return
	play_impact(clampf(impact / 14.0, 0.05, 1.0) * 0.6)


func _on_gear_changed(car_id: int, _gear: int) -> void:
	if car == null or car_id != car.car_id:
		return
	_play_one_shot(_gear_change, -9.0)


func _on_car_failed(car_id: int, system: String, _description: String) -> void:
	if car == null or car_id != car.car_id:
		return
	match system:
		"TURBO": _play_one_shot(_turbo_failure, -1.0)
		"ENGINE": _play_one_shot(_engine_failure, -1.0)
		"TYRES": _play_one_shot(_puncture, -3.0)
		_: pass
