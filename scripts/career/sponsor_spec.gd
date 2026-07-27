class_name SponsorSpec
extends RefCounted
## A sponsorship contract: guaranteed money per race plus a win bonus, in
## exchange for meeting an objective over a number of races.
##
## Contracts are the counterweight to entry fees. A player who has committed to
## an expensive championship can cover the fees with a contract, but a contract
## they fail costs them the penalty, so it is a real decision.

var id: String = ""
var display_name: String = ""
var description: String = ""
var min_level: int = 1
var min_rating: int = 0
## Races the contract runs for.
var duration_races: int = 5
var per_race: int = 1500
var win_bonus: int = 4000
## Paid out only if the objective is met across the whole contract.
var completion_bonus: int = 10000
## Charged if the contract lapses unfulfilled.
var failure_penalty: int = 5000

## Objective: "finish_top" with a value, "no_wrecks", "win_count".
var objective: String = "finish_top"
var objective_value: int = 3


static func from_dict(d: Dictionary) -> SponsorSpec:
	var s := SponsorSpec.new()
	s.id = String(d.get("id", ""))
	s.display_name = String(d.get("name", s.id))
	s.description = String(d.get("description", ""))
	s.min_level = int(d.get("min_level", 1))
	s.min_rating = int(d.get("min_rating", 0))
	s.duration_races = int(d.get("duration_races", 5))
	s.per_race = int(d.get("per_race", 1500))
	s.win_bonus = int(d.get("win_bonus", 4000))
	s.completion_bonus = int(d.get("completion_bonus", 10000))
	s.failure_penalty = int(d.get("failure_penalty", 5000))
	s.objective = String(d.get("objective", "finish_top"))
	s.objective_value = int(d.get("objective_value", 3))
	return s


func objective_text() -> String:
	match objective:
		"finish_top":
			return "Finish in the top %d in every race" % objective_value
		"no_wrecks":
			return "Complete the contract without writing a car off"
		"win_count":
			return "Win %d races" % objective_value
	return objective


## Fresh contract state to store on the profile.
func new_contract_state() -> Dictionary:
	return {
		"sponsor_id": id,
		"races_remaining": duration_races,
		"per_race": per_race,
		"win_bonus": win_bonus,
		"objective": objective,
		"objective_value": objective_value,
		"objective_progress": 0,
		"failed": false,
	}


## Applies one race result to a contract, returning the money earned this race.
## Mutates `state` in place; the caller checks `races_remaining` afterwards.
static func apply_result(state: Dictionary, placing: int, wrecked: bool) -> int:
	if state.get("failed", false):
		return 0
	var earned := int(state.get("per_race", 0))
	if placing == 1:
		earned += int(state.get("win_bonus", 0))

	match String(state.get("objective", "")):
		"finish_top":
			if placing > int(state.get("objective_value", 3)):
				state["failed"] = true
		"no_wrecks":
			if wrecked:
				state["failed"] = true
		"win_count":
			if placing == 1:
				state["objective_progress"] = int(state.get("objective_progress", 0)) + 1

	state["races_remaining"] = int(state.get("races_remaining", 0)) - 1
	return earned


## Whether a completed contract met its objective.
static func objective_met(state: Dictionary) -> bool:
	if state.get("failed", false):
		return false
	if String(state.get("objective", "")) == "win_count":
		return int(state.get("objective_progress", 0)) >= int(state.get("objective_value", 0))
	return true
