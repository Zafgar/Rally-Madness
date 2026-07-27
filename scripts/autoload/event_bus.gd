extends Node
## Global signal hub. Systems talk through here instead of holding hard
## references to each other, which keeps the split-screen / networked cases
## from needing separate wiring.

# --- Session / lobby ---
signal local_player_joined(slot: int, device_id: int)
signal local_player_left(slot: int)
signal profile_loaded(slot: int, profile: Resource)

# --- Race flow ---
signal race_countdown_started(seconds: float)
signal race_started()
signal race_finished(standings: Array)
signal lap_completed(car_id: int, lap: int, lap_time: float)
signal checkpoint_passed(car_id: int, checkpoint_index: int)

# --- Vehicle ---
signal car_gear_changed(car_id: int, gear: int)
signal car_damaged(car_id: int, part: String, amount: float, total: float)
signal car_wrecked(car_id: int, cause: String)
signal car_caught_fire(car_id: int)
signal car_landed(car_id: int, impact: float)
signal nitro_state_changed(car_id: int, charge: float, active: bool)

# --- Economy / progression ---
signal money_changed(slot: int, amount: int, delta: int)
signal level_changed(slot: int, level: int)
signal event_unlocked(slot: int, event_id: String)
signal sponsor_offer(slot: int, sponsor_id: String)

# --- Networking ---
## A car hit a hazard on the racing surface. Carries the speed at impact so the
## haptics and the HUD can react in proportion.
signal prop_struck(car_id: int, prop_id: String, speed_ms: float)

signal net_state_changed(state: int)
signal net_peer_joined(peer_id: int, display_name: String)
signal net_peer_left(peer_id: int)
