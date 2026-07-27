# Adding content

Cars, parts, events, sponsors and tracks are all JSON. None of them need code.
After editing any of these, run the smoke test — it cross-checks every reference
between the files, so a typo fails there rather than in front of a player:

```bash
godot --headless --fixed-fps 60 --path . res://tests/smoke_test.tscn
```

---

## A car — `data/cars.json`

```json
{
  "id": "escort_rs1800",
  "manufacturer": "Ford",
  "model": "Escort RS1800",
  "year": 1975,
  "tier": 2,
  "price": 38000,
  "drivetrain": "RWD",
  "category": "rally",
  "description": "One line the showroom shows the player.",
  "gears": [3.36, 1.81, 1.26, 1.00],
  "reverse": 3.32,
  "stats": {
    "mass_kg": 900, "weight_bias_front": 0.52, "cg_height_m": 0.50,
    "wheelbase_m": 2.40, "track_width_m": 1.40,
    "engine_torque_nm": 200, "redline_rpm": 8000, "final_drive": 3.54,
    "grip_lat": 1.02, "grip_long": 1.06, "dirt_grip": 1.10,
    "max_steer_deg": 36, "brake_force": 0.92, "shift_time": 0.30
  }
}
```

Any key in `VehicleStats.STAT_KEYS` is valid under `stats`; anything omitted
takes the default. Units are SI throughout — kg, metres, Nm, rpm.

The three that decide how a car *feels*, in order:

- **`weight_bias_front`** — fraction of static mass on the front axle. Front
  transverse ≈ 0.62, front-engine RWD ≈ 0.53, mid-engine ≈ 0.42, rear-engine
  911 ≈ 0.38. Get this roughly right and the car behaves like itself.
- **`slip_forgiveness`** — widens the grip peak. High is arcade-forgiving, low
  snaps away at the limit.
- **`drift_release`** — how fast grip decays past the peak. Low drifts
  progressively, high bites.

`tier` drives pricing bands, event eligibility and the AI field. Tier 0 is the
free-to-repair starter fleet — the safety net that keeps a broke player racing —
so only put genuinely slow, cheap cars there.

## A part — `data/parts.json`

```json
{
  "id": "turbo_big", "name": "Big Single Turbo", "slot": "turbo",
  "tier": 3, "price": 58000,
  "description": "Enormous top end. Nothing happens until it wakes up.",
  "mods": {
    "turbo_boost": { "add": 0.62 },
    "turbo_lag": { "add": 1.05 },
    "torque_curve_bias": { "add": 0.30 },
    "durability_engine": 0.88
  }
}
```

A bare number is a multiplier; `{"add": n}` is an absolute offset. Additive
terms are summed first, then multipliers applied, so two +10% parts stack to
+21% rather than depending on dictionary order.

**Give every part a downside.** The interesting decision is the trade, not the
upgrade. Optional gates: `drivetrain_filter` (`["AWD"]`) and `min_car_tier`.

## An event — `data/events.json`

```json
{
  "id": "coastal_night", "name": "Coastal Night Stage",
  "track": "tarmac_circuit", "format": "circuit", "laps": 4,
  "min_level": 5, "max_car_tier": 2,
  "entry_fee": 3000,
  "payouts": [28000, 16000, 9000, 5000, 2000, 0],
  "xp": 480, "ai_opponents": 5, "ai_skill": 0.6,
  "requires_events": ["club_night"],
  "unlocks": ["regional_rally"],
  "sponsor_offers": ["helix_tyres"]
}
```

Formats: `sprint`, `stage`, `circuit`, `elimination`, `derby`.

`requires_events` gates visibility and `unlocks` opens the next node, so the
calendar is a graph. An event with neither and `min_level: 1` is a starting
point. The smoke test rejects an event whose tier and drivetrain limits leave no
eligible car in the catalogue, which is the easy way to create a dead end.

## A track — `data/tracks.json`

A centreline and a width, in metres. The builder derives the road, the barriers,
the checkpoints, the start grid and the surface patches from it.

```json
{
  "id": "coast_run", "name": "Coast Run",
  "surface": "tarmac", "closed": false, "width": 14.0,
  "checkpoint_spacing": 120.0,
  "waypoints": [[0, 0], [150, -40], [300, -30], [450, -90]],
  "ramps": [{ "at": 2, "launch": 7.0, "length": 10.0 }],
  "surface_overrides": [{ "from": 1, "to": 2, "surface": "gravel" }]
}
```

`closed: true` joins the last waypoint back to the first (a circuit); `false`
leaves it as a point-to-point stage, and the grid then forms up at the start
rather than behind the line.

Two things learned the hard way:

- **Keep waypoints flowing.** Alternating the offset sharply between successive
  points turns into a slalom once the curve is smoothed, and a narrow slalom is
  brutal on a centreline-following AI. Spacing of 130–170 m with gentle
  direction changes reads well.
- **Width under ~12 m gets punishing** for anything quick. The club loop is 15 m
  for a reason.

`ramps` and `surface_overrides` index into the waypoint list. Surfaces:
`tarmac`, `dirt`, `gravel`, `grass`, `snow`, `ice`, `mud`.

## A sponsor — `data/sponsors.json`

Objectives are `finish_top` (with `objective_value` as the position),
`win_count`, or `no_wrecks`. The payoff should be worth the risk: a contract the
player is certain to complete is not a decision.
