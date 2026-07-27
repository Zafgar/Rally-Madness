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

# Watch one AI car drive one track, for tuning the driver model. The third
# argument is a driver archetype from data/drivers.json, or a bare skill number.
godot --headless --fixed-fps 60 --path . res://tests/ai_probe.tscn \
      -- gravel_loop impreza_gc8 works_driver tires_gravel
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
4. **Wheel dynamics** — each axle's wheels have their own rotational speed,
   so slip ratio is a consequence rather than an input. This is what makes
   lock-up and wheelspin exist at all.
5. **Combined slip** — longitudinal and lateral are solved together from one
   slip vector, because a tyre opposes the direction it is actually sliding.

Jumps use a fake Z axis: height and vertical speed integrated separately, with
tire forces switched off while airborne, and landing speed feeding straight into
suspension damage. It is the classic top-down trick and it keeps the whole game
in 2D, which is what makes 4-way split-screen and 12-car LAN cheap.

### Mass, torque, power, grip

Those four decide almost everything, and only three of them are authored. Power
is torque times crank speed, so a car defined by a torque curve, a redline and
a set of ratios already has a power output whether anyone checked it or not —
and top speed is simply where drive force finally loses to drag.

That makes both of them a free honesty check, and the catalogue failed it
badly until one existed. `engine_torque_nm` holds the peak torque a spec sheet
quotes, which for a turbo car already includes boost — and boost was being
multiplied on top of it. The Group B cars were making 800 hp instead of 480.
Boost now describes the *hole below it* rather than a multiplier on the rated
figure, and every one of the 33 cars lands within 12% of its real power and 15%
of its real top speed:

```bash
godot --headless --path . res://tests/spec_bench.tscn        # the whole table
godot --headless --path . res://tests/spec_bench.tscn -- tuned   # + build costs
```

The same pass caught `downforce` being authored on a scale ~50x too large — a
GT2 RS was generating fifty tonnes of it at speed. The smoke test now holds all
of this in place.

**Weight distribution is the biggest character knob.** A front-transverse hot
hatch sits near 0.62, a mid-engine Group B car near 0.42, a 911 near 0.38 — and
they drive completely differently as a result, without a line of special-case
code.

### Lock-up, ABS and why the brakes "fail"

Stand on the brakes in a car with no ABS and the wheels stop turning. The
brakes have not failed — the tyre has stopped doing two jobs at once. A locked
wheel slides almost straight backwards relative to the road, so nearly all of
its friction goes into fighting that slide and there is almost nothing left to
turn the car with. It also stops *worse*, because sliding friction is lower
than the peak at around 10–15% slip.

Both of those fall out of the model rather than being special-cased, and the
smoke test measures them:

| From 30 m/s on tarmac | No ABS | ABS |
|---|---|---|
| Stopping distance | 60.1 m | **46.9 m** |
| Grip still available to steer, with 10° of lock held on | 14% | **35%** |

ABS is a PI controller with a feed-forward term that holds the wheel just past
its grip peak. Three things were tried and rejected on the way, all of which
looked correct and stopped *worse than no ABS at all*: bang-bang control (lets
the wheel spin back to zero slip, where a tyre makes no force), proportional
only (output is zero at the setpoint, so it overshoots every cycle), and high
gains (drives the loop into oscillation, and the force curve is not symmetric
about its peak).

The handbrake deliberately bypasses ABS — it is a cable to the rear calipers —
which is why it still breaks the tail loose on a car whose brake pedal never
could.

Traction control works the same way in reverse, trimming torque when the driven
wheels light up. Neither is universal: tier 0–1 cars have no ABS, and **Group B
cars have nothing at all**, which is most of what makes them frightening. Both
can be retrofitted, or deleted, in the `electronics` tuning slot.

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

### What a chassis will accept

A Lada can be usefully improved — better tyres, a rebuild, a cage — but no
amount of money turns it into a Group B car, and being able to bolt a
sequential race gearbox and WRC dampers to one would make the whole progression
pointless. Each chassis has an **upgrade ceiling**: the highest part tier it
will accept, one tier above the car itself. Parts also gate the other way, so a
WRC compound refuses to fit anything below tier 3.

| Chassis | Ceiling | Stock → fully built |
|---|---|---|
| Lada 2101 (tier 0) | tier 1 | 56 → 76 hp |
| Golf GTI (tier 1) | tier 2 | 138 → 274 hp |
| Sierra Cosworth (tier 2) | tier 3 | 209 → 648 hp |
| Skyline R34 (tier 3) | tier 4 | 343 → 972 hp |

A saved loadout naming a part the chassis cannot take is ignored rather than
honoured, so an old save or a hand-edited file cannot smuggle one in.

The economics carry the rest of the message: building that Cosworth to 648 hp
costs about 590,000 in parts on a 38,000 car — more than simply buying a
factory Group B machine. You *can* build an old car to be fast. It costs more
than the real thing, and it is still worse everywhere except in a straight line.

On top of parts sits a free setup sheet — brake bias, diff preload, ride height,
anti-roll balance, gear length, AWD split, boost pressure — that needs no
purchase and is where a player fine-tunes a car they already own.

Tire compound is the rally decision: gravel, mud, studded snow, semi-slicks and
slicks each have per-surface multipliers, so turning up to the winter trial on
the wrong rubber genuinely ends your event.

---

## Controller feedback

Every effect corresponds to something real. A driver should be able to tell,
without looking, whether the wheels have locked, whether ABS is working,
whether the rears are spinning, and what the road surface is — because each of
those is a distinct physical event.

**Rumble** works today on any pad Godot recognises. Engine note spread across
the two motors by revs, surface texture scaled by speed, distinct signatures
for wheelspin, lock-up and a slide, and transient jolts for impacts and
landings. Mid-air is conspicuously smooth, which is what sells a jump.

**Adaptive triggers** are the PS5-specific half:

| Situation | Brake (L2) |
|---|---|
| Normal | Progressive resistance, softer as the tyres wear |
| ABS working | Pulses at 14 Hz, following the real pressure-release signal |
| Locked, no ABS | **Goes light** — there is no more braking to be had, and the resistance vanishing is the cue to release |

| Situation | Throttle (R2) |
|---|---|
| Normal | Resistance rising with engine load, so boost arriving is felt |
| Wheelspin | Buzzes at 24 Hz |
| Traction control cutting in | Slower, softer flutter |
| On the limiter | A wall at the top of the travel |

> **Adaptive triggers need a native extension.** Godot has no API for them —
> the L2/R2 resistance motors are driven by DualSense-specific HID output
> reports. `DualSenseBackend` detects such an extension at runtime and drives
> it; with none installed it logs a warning once and everything except trigger
> resistance still works. The feel logic itself is hardware-free and unit
> tested, so it can be verified without a pad in the room — but it has **not
> been validated against real hardware in this repository**.

## Starting a career

New game asks for three things: a name, a profile picture, and one of five
starter cars. The picture is drawn from polygons rather than loaded, so a
profile has a face without the project carrying image assets.

The car is the real decision. All five are free to repair forever, but they do
not drive alike — the Škoda is rear-engined and will swap ends if you lift
mid-corner, the Wartburg is nose-heavy front-drive that simply pushes, the
Trabant weighs six hundred kilos. The picker shows mass, power, torque, top
speed and where the weight sits, plus a sentence on what that means, because
"40% front" tells a first-time player nothing on its own.

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

## AI drivers

A single "skill" number makes every rival the same driver turned up or down.
Instead, each has a **DriverProfile** of traits that pull in different
directions — commitment, consistency, line quality, braking, throttle
discipline, recovery, aggression, mechanical sympathy — so a field contains
people rather than difficulty settings.

The important one is **`pace_ceiling`**: a hard cap on how fast a driver goes
*regardless of the car*. Without it, handing a nervous club driver a Group B car
turns them into a works driver, which is exactly backwards. They drive at the
pace they always did, in something far more frightening.

Eight archetypes ship in `data/drivers.json`, weighted by event difficulty so a
club night still gets the occasional quick driver and a works event still gets
someone out of their depth. Same car, same track, 90 seconds each:

| Archetype | Distance covered | Crashes | Car condition |
|---|---|---|---|
| Nervous Novice | 2032 m | 6 | 0.49 |
| Sunday Driver | 2033 m | 1 | 0.89 |
| Steady Privateer | 2078 m | 1 | 0.94 |
| Old Hand | 2122 m | 2 | 0.76 |
| Works Driver | 2279 m | 1 | 0.97 |
| Reckless Local | 2301 m | 1 | 0.90 |
| Young Charger | 2345 m | 3 | 0.90 |

Slow-and-safe, slow-and-messy, fast-and-clean and fast-and-crashy are all
distinct outcomes, which is the point. Weak drivers also leave the car in
automatic and never use the rev range, brake far too early, and sit near the
middle of the road instead of apexing — they are not simply a scaled-down works
driver.

---

## Layout

```
data/           cars, parts, events, sponsors, tracks — all JSON
scripts/
  autoload/     EventBus, GameConfig, SaveSystem, databases, PlayerManager, NetManager
  vehicle/      the driving model: stats, axles, tires, engine, transmission, nitro, damage
  haptics/      rumble and adaptive-trigger feel, and the backends behind it
  tuning/       parts, loadouts, and the calculator that folds them together
  career/       profiles, owned cars, events, sponsors
  track/        track spec and the builder that turns a centreline into a scene
  race/         race director, entrants, race scene
  ai/           the AI driver and its personality archetypes
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
   setup sheet all work through `PlayerProfile` and `TuningCalculator`, and
   `PartDatabase.catalogue_for()` already returns each part with the reason it
   will not fit — but the only front end is a placeholder menu plus the
   new-career screen. This is the biggest gap.
2. **AI opponent awareness.** Rivals cannot see each other, so a full field
   still trades paint. Everything else is in place — braking-distance scanning,
   surface look-ahead, pure-pursuit steering and apexing — so this is the
   remaining piece, along with a properly optimised racing line rather than an
   apex offset from the centreline.
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
