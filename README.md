# Rally Madness

Top-down rally combat racer for Godot 4.4. Up to **4 players on one screen**,
up to **12 over a LAN**. Built for PC with PS5 pads.

This repository is the playable foundation: the driving model, the tuning
system, the car catalogue, the career economy, split-screen, the AI field and
the LAN layer are all in and working end to end. What is deliberately thin so
far is the front end — see [Current state](#current-state).

---

## Running it

Needs [Godot 4.4](https://godotengine.org/download) (standard build, no C#).

```bash
godot --path .                 # editor
godot --path . scenes/boot.tscn  # straight into the game
```

From the menu: press **Options** on a pad (or **Enter** on the keyboard) to
take a seat, pick an event, hit **START RACE**.

### Tests

```bash
# Full check: data integrity, physics model, damage, economy, and a live race.
godot --headless --fixed-fps 60 --path . res://tests/smoke_test.tscn

# Watch one AI car drive one track, for tuning the driver model.
godot --headless --fixed-fps 60 --path . res://tests/ai_probe.tscn \
      -- gravel_loop impreza_gc8 0.6 tires_gravel
```

The smoke test exits non-zero on failure, so it drops straight into CI. It runs
in about 25 seconds.

---

## Controls (DualSense)

| Input | Action |
|---|---|
| Left stick | Steer |
| R2 / L2 | Throttle / brake |
| Cross | Handbrake |
| Circle | Nitro |
| R1 / L1 | Shift up / down |
| Triangle | Toggle automatic ↔ manual gearbox |
| Options | Join a seat / respawn |

Keyboard (player 1 fallback): `WASD`, `Space` handbrake, `Shift` nitro,
`Q`/`E` shift, `T` gearbox mode, `R` respawn.

Split-screen deliberately bypasses Godot's InputMap and polls each device id
directly. InputMap actions are global, so four pads bound to the same action all
fire for every player — reading the device is the only way to keep four seats
independent.

---

## How the driving works

A two-axle (bicycle) model with load transfer, per-axle tire forces and a real
drivetrain split, integrated on a `RigidBody2D`. All maths is in SI units and
converted to pixels only at the point force is applied, so the numbers in
`data/cars.json` mean what a spec sheet says they mean.

What actually reaches the road each tick:

1. **Load transfer** — longitudinal acceleration shifts weight between axles via
   the CoG height and wheelbase. Braking loads the front, power loads the rear.
2. **Slip angles** — computed per axle from lateral velocity and yaw rate, with
   the front axle offset by the current steering angle.
3. **Tire forces** — a Pacejka-shaped curve that rises to a peak and then falls
   away to a lower sliding value. How far it falls, and how fast, is the entire
   difference between a car that snaps into a spin and one that holds a
   controllable drift.
4. **Drive and brake forces** — engine torque through the gearbox, split
   front/rear by the drivetrain layout, plus brakes split by bias.
5. **Friction ellipse** — a tire has one budget of grip; spending it all
   longitudinally leaves nothing for cornering.

Jumps use a fake Z axis: height and vertical speed integrated separately, with
tire forces switched off while airborne, and landing speed feeding straight into
suspension damage. It is the classic top-down trick and it keeps the whole game
in 2D, which is what makes 4-way split-screen and 12-car LAN cheap.

**Weight distribution is the biggest character knob.** A front-transverse hot
hatch sits near 0.62, a mid-engine Group B car near 0.42, a 911 near 0.38 — and
they drive completely differently as a result, without a line of special-case
code.

---

## Tuning

21 slots: engine, intake, exhaust, turbo, ECU, cooling, gearbox, clutch,
differential, suspension, springs, dampers, anti-roll, brakes, tires, wheels,
chassis, weight, aero, armour, nitro.

Parts are pure data — a slot, a price, and modifiers against `VehicleStats`. No
part has bespoke code, which is what makes it cheap to add hundreds. **Every
part costs something as well as giving something**: a big turbo brings lag,
sticky tires wear out, a stripped interior gives up crash protection. A part
with only upside is a balance bug, not a reward.

On top of parts sits a free setup sheet — brake bias, diff preload, ride height,
anti-roll balance, gear length, AWD split, boost pressure — that needs no
purchase and is where a player fine-tunes a car they already own.

Tire compound is the rally decision: gravel, mud, studded snow, semi-slicks and
slicks each have per-surface multipliers, so turning up to the winter trial on
the wrong rubber genuinely ends your event.

---

## Progression

Each seat loads **its own profile from the local machine**, so four people on
one couch keep four separate careers. Saves are written to a temp file and
renamed over the real one, so a crash mid-save cannot corrupt a career.

- **Money** from prize funds and sponsor contracts; some events charge an entry
  fee up front, which is the risk half of the risk/reward.
- **Levels** from XP gate which events appear.
- **Unlock graph** — every event lists what completing it opens, so the whole
  calendar is data in `data/events.json`.
- **Sponsors** pay per race plus a win bonus, against an objective (podium every
  race / three wins / no write-offs). Fail one and you pay the penalty.
- **Rating** — Elo against the field average, used for online matchmaking, with
  K falling off as a driver builds a record.

### The safety net

Crash damage persists between events, and repairs cost money. A player can
therefore end a race with a bent car and no cash — so **tier-0 cars are always
free to repair**, and a player with no working car and no money is issued a
fresh starter. There is no way to get permanently stuck.

---

## Damage

Tracked per component (body / engine / suspension / tires) rather than as one
health bar, because where you hit something should change how the car drives
afterwards: a nose-first impact hurts the engine, a kerb strike ruins the
suspension. Damage feeds back through the same tuning calculator as parts do, so
a bent car is genuinely slower — less power, less grip, vaguer steering.

Damage is priced from **arriving** at a collision, not resting against one. The
per-step contact impulse is the obvious input and is wrong: a car leaning on a
barrier reports one every tick, which destroys it in seconds. Instead the tick a
contact first appears is priced from the speed carried into it, so a sustained
scrape costs speed but not integrity.

Wreck the engine badly enough and the car catches fire; from ignition there are
six seconds before it is a write-off and you are out of the race.

---

## Networking

Host-authoritative over ENet. Clients send a 4-byte encoded `VehicleCommand`
each tick and receive car transforms back at 20 Hz; the host simulates every
car. That is the right trade for a game where collisions decide races — two
peers must never disagree about who hit whom.

A hosting machine can still run up to four local split-screen seats, so a
twelve-car field might be three couches of four. The host clamps what a client
can claim, so a modified client cannot ask for eight seats.

---

## Layout

```
data/           cars, parts, events, sponsors, tracks — all JSON
scripts/
  autoload/     EventBus, GameConfig, SaveSystem, databases, PlayerManager, NetManager
  vehicle/      the driving model: stats, tires, engine, transmission, nitro, damage
  tuning/       parts, loadouts, and the calculator that folds them together
  career/       profiles, owned cars, events, sponsors
  track/        track spec and the builder that turns a centreline into a scene
  race/         race director, entrants, race scene
  ai/           the AI driver
  ui/           split screen and HUD
  input/        device polling and the command struct
tests/          headless smoke test and the AI probe
```

**Adding content needs no code.** A new car is an entry in `data/cars.json`, a
new part in `data/parts.json`, a new track is a list of waypoints plus a width.
The smoke test cross-checks every reference between those files, so a typo fails
at test time rather than when a player picks it from a menu.

---

## Current state

Working: driving model, tuning, damage and fire, career economy, sponsors,
rating, split-screen for 1–4, AI field, track generation, LAN host/join,
per-player local saves.

Thin or missing, roughly in the order they matter:

1. **Garage and showroom UI.** Buying cars, fitting parts and adjusting the
   setup sheet all work through `PlayerProfile` and `TuningCalculator`, but the
   only front end is a placeholder menu. This is the biggest gap.
2. **AI racing line.** The AI follows the track centreline, which is the
   tightest way through any corner, and it cannot see other cars. It drives
   cleanly alone — about one crash per 90 seconds at low skill on the club loop
   — but a full field still trades paint. The fix is a proper curvature-
   minimising line within the track width, plus opponent avoidance; the driver
   already brakes on a real braking-distance scan and reads the surface ahead,
   so the line is the missing piece.
3. **Art.** Cars and tracks are coloured polygons. The rendering is deliberately
   separated from the physics, so replacing `Visual` in `rally_car.tscn` with
   sprites changes nothing else.
4. **Audio.** None yet.
5. **Online race flow.** Host/join, the lobby and in-race replication work; the
   results and rating hand-off across peers still needs wiring.

## Note on car names

The catalogue uses real manufacturers and models because they are the clearest
reference for how each car should drive. Names, manufacturers and every stat are
data in `data/cars.json` with nothing hard-coded, so if this ever ships
commercially the whole catalogue can be renamed without touching a line of code.
Worth settling before art is commissioned around any particular car.
