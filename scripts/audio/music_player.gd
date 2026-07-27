class_name MusicPlayer
extends Node
## Plays one track at a time, and changes between them without a gap.
##
## Two players rather than one, because cutting from one loop to another is a
## click and a jolt, and every screen change in the game would have one. With
## two, the outgoing track fades down while the incoming one fades up, and the
## player hears a change of mood rather than an edit.
##
## Tracks are rendered on first use and then kept: rendering ten seconds of
## music costs a noticeable fraction of a second, which is fine once and not
## fine every time somebody opens the garage.

## How long a change of track takes. Long enough not to be a cut, short enough
## that the new screen and its music arrive together.
const CROSSFADE_SECONDS := 0.9
## Silence, in dB. Below this nothing is audible and the maths stays simple.
const SILENT_DB := -60.0

var _players: Array[AudioStreamPlayer] = []
var _active: int = 0
var _current: String = ""
## Rendered streams, by preset name.
var _cache: Dictionary = {}
## The render running on a worker thread, if any, and what it is for.
var _task_id: int = -1
var _rendering: String = ""
var _rendered: AudioStreamWAV = null
## What was asked for while a render was in flight. Only the last one matters —
## somebody clicking quickly through three screens should end up with the third
## screen's music, not all three in turn.
var _queued: String = ""
## 0..1 per player, faded each frame and converted to dB on the way out.
var _levels := PackedFloat32Array([0.0, 0.0])
var _targets := PackedFloat32Array([0.0, 0.0])
## Set by the options screen; scales everything this node plays.
var volume: float = 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
		player.volume_db = SILENT_DB
		add_child(player)
		_players.append(player)


## Starts `preset`, fading out whatever is playing. Asking for the track that
## is already playing does nothing, so a screen can call this in _ready without
## restarting the music every time the player steps back into it.
func play(preset: String) -> void:
	if not GameConfig.audio_enabled():
		return
	if preset == _current:
		return
	_current = preset
	if preset.is_empty():
		_targets[0] = 0.0
		_targets[1] = 0.0
		return

	var stream: AudioStreamWAV = _cache.get(preset)
	if stream == null:
		# Rendering twenty seconds of music takes about a second and a half,
		# and a screen that freezes for a second and a half when you open it is
		# worse than one that is quiet for a moment. So it happens on a worker
		# thread and fades in when it is ready — which reads as deliberate.
		if _task_id >= 0:
			_queued = preset
			return
		_rendering = preset
		_rendered = null
		_task_id = WorkerThreadPool.add_task(_render_pending)
		# Fade out what is playing now regardless, so the old screen's music
		# does not hang over the new screen waiting for its replacement.
		_targets[_active] = 0.0
		return

	_begin(stream)


## Runs on a worker thread. It touches nothing but its own locals and the two
## fields the main thread only reads once the task reports itself finished.
func _render_pending() -> void:
	_rendered = MusicTrack.make(_rendering).render()


func _begin(stream: AudioStreamWAV) -> void:
	var next := 1 - _active
	_players[next].stream = stream
	_players[next].play()
	_targets[next] = 1.0
	_targets[_active] = 0.0
	_active = next


func stop() -> void:
	_current = ""
	_targets[0] = 0.0
	_targets[1] = 0.0


func current() -> String:
	return _current


## Picks up a finished render. Deliberately not a signal: the worker cannot
## touch the scene tree, and a per-frame check on one integer costs nothing.
func _collect_render() -> void:
	if _task_id < 0 or not WorkerThreadPool.is_task_completed(_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	var finished := _rendering
	var stream := _rendered
	_rendering = ""
	_rendered = null
	if stream != null:
		_cache[finished] = stream
		# Only play it if it is still what is wanted. A player who has moved on
		# gets the music of the screen they are actually looking at.
		if finished == _current:
			_begin(stream)
	if not _queued.is_empty():
		var next := _queued
		_queued = ""
		# _current already equals next if it was asked for; clear so play()
		# does not treat it as a no-op.
		if next == _current:
			_current = ""
		play(next)


## Renders a track now, on this thread. For the bench, which wants the result
## rather than the behaviour.
func render_now(preset: String) -> AudioStreamWAV:
	if not _cache.has(preset):
		_cache[preset] = MusicTrack.make(preset).render()
	return _cache[preset]


func _process(delta: float) -> void:
	_collect_render()
	var step := delta / CROSSFADE_SECONDS
	for i in _players.size():
		var was := _levels[i]
		_levels[i] = move_toward(_levels[i], _targets[i], step)
		if is_equal_approx(was, _levels[i]):
			continue
		if _levels[i] <= 0.001:
			# Stopped rather than left running at silence: a player holding a
			# loop it is not using is a voice nobody gets back.
			_players[i].stop()
			_players[i].volume_db = SILENT_DB
			continue
		if not _players[i].playing and _targets[i] > 0.0:
			_players[i].play()
		_players[i].volume_db = linear_to_db(
			maxf(_levels[i] * clampf(volume, 0.0, 1.0), 0.0001))
