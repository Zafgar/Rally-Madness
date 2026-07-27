class_name InterfaceSounds
extends Node
## The noises the menus make.
##
## The front end was completely silent — every button, every purchase, every
## refusal happened without a sound — and a silent menu feels broken in a way
## that is hard to point at. These are deliberately small: a move is a tick, a
## confirm is a tick with a note under it, a refusal is the same note a tone
## lower. Nothing here should be noticeable twice.
##
## Rendered once on first use and then reused, because a menu can easily ask
## for the same click sixty times in a second while somebody holds a direction.

## Everything is baked at this length or shorter. A UI sound longer than this
## is in the way of the next one.
const MAX_SECONDS := 0.55

var _cache: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0
## Set by the options screen.
var volume: float = 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# A small pool, cycled. One player would cut its own tail off every time a
	# player moves quickly down a list, which is exactly when it is noticed.
	for i in 4:
		var player := AudioStreamPlayer.new()
		player.bus = "Interface" if AudioServer.get_bus_index("Interface") >= 0 else "Master"
		add_child(player)
		_players.append(player)


## Plays one of: move, select, back, confirm, deny, purchase, unlock, countdown,
## go. Unknown names are ignored rather than substituted, so a typo is silent
## rather than wrong.
func play(name: String, volume_db: float = 0.0) -> void:
	if not GameConfig.audio_enabled() or _players.is_empty():
		return
	var stream: AudioStreamWAV = _cache.get(name)
	if stream == null:
		stream = _bake(name)
		if stream == null:
			return
		_cache[name] = stream
	var player := _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = stream
	player.volume_db = volume_db + linear_to_db(maxf(clampf(volume, 0.0, 1.0), 0.0001))
	player.play()


func _bake(name: String) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name)
	match name:
		# Moving through a list. Barely there on purpose.
		"move":
			return _blip(1180.0, 0.045, 0.28, 0.0)
		# Choosing something.
		"select":
			return _blip(1560.0, 0.075, 0.42, 620.0)
		# Backing out — the same shape falling instead of rising.
		"back":
			return _blip(880.0, 0.075, 0.34, -300.0)
		# A thing that worked.
		"confirm":
			return _chord([784.0, 1046.5], 0.22, 0.40)
		# A thing that did not. A minor second is the only interval that means
		# "no" without anyone needing to be told.
		"deny":
			return _chord([392.0, 415.3], 0.26, 0.38)
		# Money leaving.
		"purchase":
			return _chord([523.3, 659.3, 784.0], 0.34, 0.34)
		# Something opening up. The one sound here allowed to be pleased.
		"unlock":
			return _arpeggio([523.3, 659.3, 784.0, 1046.5], 0.075, 0.38)
		# Three of these and then a "go", which is the countdown.
		"countdown":
			return _blip(660.0, 0.16, 0.45, 0.0)
		"go":
			return _blip(1320.0, 0.34, 0.55, -220.0)
		_:
			return null


## A sine with an envelope, optionally sliding in pitch. `slide_hz` is where it
## ends up relative to where it started.
func _blip(hz: float, duration: float, gain: float, slide_hz: float) -> AudioStreamWAV:
	var samples := int(minf(duration, MAX_SECONDS) * AudioSynth.MIX_RATE)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)
	var phase := 0.0
	for i in samples:
		var t := float(i) / AudioSynth.MIX_RATE
		var progress := float(i) / maxf(float(samples), 1.0)
		var frequency := hz + slide_hz * progress
		# A short attack rather than none, because a sine starting at full
		# amplitude is a click with a note after it.
		var attack: float = clampf(t / 0.004, 0.0, 1.0)
		var decay: float = exp(-t * (5.0 / maxf(duration, 0.01)))
		# A little second harmonic keeps it from sounding like a test tone.
		buffer[i] = (sin(TAU * phase) + sin(TAU * phase * 2.0) * 0.18) \
			* attack * decay * gain
		phase += frequency / AudioSynth.MIX_RATE
	return AudioSynth.to_stream(buffer, false)


## Several notes at once.
func _chord(notes: Array, duration: float, gain: float) -> AudioStreamWAV:
	var samples := int(minf(duration, MAX_SECONDS) * AudioSynth.MIX_RATE)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)
	var phases := PackedFloat32Array()
	for n in notes:
		phases.append(0.0)
	for i in samples:
		var t := float(i) / AudioSynth.MIX_RATE
		var attack: float = clampf(t / 0.006, 0.0, 1.0)
		var decay: float = exp(-t * (4.2 / maxf(duration, 0.01)))
		var value := 0.0
		for n in notes.size():
			value += sin(TAU * phases[n])
			phases[n] += float(notes[n]) / AudioSynth.MIX_RATE
		buffer[i] = value / float(notes.size()) * attack * decay * gain
	return AudioSynth.to_stream(buffer, false)


## The same notes one after another instead of together.
func _arpeggio(notes: Array, note_seconds: float, gain: float) -> AudioStreamWAV:
	var total := minf(note_seconds * float(notes.size()) + 0.18, MAX_SECONDS)
	var samples := int(total * AudioSynth.MIX_RATE)
	var buffer := PackedFloat32Array()
	buffer.resize(samples)
	buffer.fill(0.0)
	for n in notes.size():
		var start := int(float(n) * note_seconds * AudioSynth.MIX_RATE)
		var phase := 0.0
		var length := int((note_seconds + 0.16) * AudioSynth.MIX_RATE)
		for i in length:
			var index := start + i
			if index >= samples:
				break
			var t := float(i) / AudioSynth.MIX_RATE
			var attack: float = clampf(t / 0.004, 0.0, 1.0)
			var decay: float = exp(-t * 16.0)
			buffer[index] += sin(TAU * phase) * attack * decay * gain
			phase += float(notes[n]) / AudioSynth.MIX_RATE
	return AudioSynth.to_stream(buffer, false)
