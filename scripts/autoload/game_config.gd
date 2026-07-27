extends Node
## Tunables that are global to the build rather than to a car. Kept in one
## place so balance passes do not mean hunting through gameplay scripts.

## How many players can share one screen.
const MAX_LOCAL_PLAYERS := 4
## Hard ceiling for a LAN session (host included).
const MAX_NET_PLAYERS := 12
const DEFAULT_PORT := 27015

## World scale: how many pixels represent one metre. All physics maths is done
## in metres and converted at the boundary, so tuning numbers stay readable.
const PIXELS_PER_METRE := 24.0

## Downward acceleration applied to the fake Z axis used for jumps (m/s^2).
const JUMP_GRAVITY := 22.0
## Landing vertical speed above which the car starts taking damage (m/s).
const SAFE_LANDING_SPEED := 9.0

## Impact impulse (kg*m/s) that counts as a real crash rather than a nudge.
## For a 1200 kg car this is about 2.5 m/s of closing speed, so parking into a
## barrier is free and arriving at one is not.
const CRASH_IMPULSE_THRESHOLD := 3000.0

## Integrity below this fraction means the car is out of the race.
const WRECK_THRESHOLD := 0.0
## Chance-per-second of ignition once the engine bay is critically damaged.
const FIRE_IGNITION_RATE := 0.55
## Seconds from ignition to total loss.
const FIRE_BURN_OUT_TIME := 6.0

## Tier 0 cars are always repairable for free so a broke player can keep going.
const STARTER_TIER := 0

var debug_overlay: bool = false


func metres_to_px(m: float) -> float:
	return m * PIXELS_PER_METRE


func px_to_metres(px: float) -> float:
	return px / PIXELS_PER_METRE
