class_name RaceEntrant
extends RefCounted
## One car in a race, player or AI, with everything needed to order the field
## and pay out at the end.

var car: RallyCar
var display_name: String = ""
## -1 for AI, otherwise the local seat index.
var seat_slot: int = -1
var profile: PlayerProfile
var ai: AIDriver

var next_checkpoint: int = 0
var lap: int = 0
var laps_target: int = 1
## Total distance along the centreline including completed laps, which is what
## the standings sort on.
var total_progress: float = 0.0
var last_checkpoint_time: float = 0.0

var finished: bool = false
var finish_time: float = 0.0
var eliminated: bool = false
var dnf: bool = false
var dnf_reason: String = ""
var position: int = 0

var best_lap: float = INF
var _lap_start_time: float = 0.0

## False until the car has crossed the start line for the first time. The grid
## sits *behind* the line, so without this a car on the grid measures as almost
## a full lap ahead of one that has just started.
var started: bool = false

## Where the car was, and when, the last time it was seen moving. The director
## uses the pair to retire cars that have stopped for good. Deliberately based
## on world position rather than track progress: a car wedged against a barrier
## may still be creeping along the centreline measure.
var stall_reference_position := Vector2.ZERO
var stall_reference_time: float = 0.0


func is_player() -> bool:
	return seat_slot >= 0


func is_racing() -> bool:
	return not finished and not eliminated and not dnf


func start_lap(now: float) -> void:
	_lap_start_time = now


func complete_lap(now: float) -> float:
	var lap_time := now - _lap_start_time
	_lap_start_time = now
	if lap_time < best_lap:
		best_lap = lap_time
	lap += 1
	return lap_time


func mark_dnf(reason: String) -> void:
	if finished:
		return
	dnf = true
	dnf_reason = reason


## Sort key for the live standings. Finished cars always outrank running ones,
## and running cars outrank anyone who is out.
func standing_key() -> Array:
	if finished:
		return [0, finish_time, 0.0]
	if is_racing():
		return [1, 0.0, -total_progress]
	return [2, 0.0, -total_progress]
