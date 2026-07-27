class_name MusicTheory
extends RefCounted
## The notes, and which of them go together.
##
## Music that is generated rather than composed goes wrong in one of two ways:
## it is random, which is noise, or it is a loop, which is wallpaper. What keeps
## it the right side of both is that the notes come from a scale, the chords
## come from the scale, and the bass and the lead are picking from the same
## chord at the same moment. That is all this file is: the rules that make two
## independently generated parts agree with each other.
##
## The sound the game is after is the drift-movie one — a minor key, a heavy
## off-beat bass, and a lead that sits high above it. So the scales here are
## the dark ones, and the default is Phrygian dominant, which is the scale that
## gives that music its particular flavour and is why it does not sound like
## every other minor-key game soundtrack.

## Semitone offsets from the root, one octave.
const SCALES := {
	# The plain minor. Safe, and the fallback for anything that has to be
	# unambiguously readable rather than characterful.
	"minor": [0, 2, 3, 5, 7, 8, 10],
	# A minor scale with a flat second and a major third. It is the sound of
	# the Middle East by way of flamenco, and by way of both, of drift films.
	"phrygian_dominant": [0, 1, 4, 5, 7, 8, 10],
	# Minor with the second missing. Fewer notes means fewer ways to clash,
	# which is what makes it the scale everybody improvises over.
	"minor_pentatonic": [0, 3, 5, 7, 10],
	# Darker still: a flat second and a flat fifth. For the night stages.
	"locrian": [0, 1, 3, 5, 6, 8, 10],
	# The one bright scale here, kept for results screens, where the player has
	# just won something and a minor key would be sarcasm.
	"mixolydian": [0, 2, 4, 5, 7, 9, 10],
}

## Chords as scale degrees rather than semitones, so a progression written once
## works in every scale above. Degree 0 is the root of the scale.
const TRIAD_DEGREES := [0, 2, 4]
## Adding the seventh is most of the difference between a chord that sounds
## like a hymn and one that sounds like a record.
const SEVENTH_DEGREES := [0, 2, 4, 6]

## Progressions, as scale degrees for the root of each chord. Four bars each.
const PROGRESSIONS := {
	# i - VI - VII - i. The engine of essentially all minor-key driving music.
	"drive": [0, 5, 6, 0],
	# i - VII - VI - VII. Circular, so it can run under a menu indefinitely
	# without ever sounding like it is trying to finish.
	"hover": [0, 6, 5, 6],
	# i - iv - VII - III. More movement, for when something is happening.
	"push": [0, 3, 6, 2],
	# i - VI - III - VII. Resolves upward; used where the player has won.
	"lift": [0, 5, 2, 6],
}

## A440, and the octave A0 sits in. Everything else is derived.
const A4_HZ := 440.0
const A4_MIDI := 69


## The frequency of a MIDI note number. Twelve equal steps to an octave, each
## the twelfth root of two — which is the whole of tuning in one line.
static func midi_to_hz(note: float) -> float:
	return A4_HZ * pow(2.0, (note - float(A4_MIDI)) / 12.0)


## The MIDI note for a scale degree, where degree 0 is the root and degrees
## past the end of the scale wrap into the octave above. Negative degrees walk
## downwards, which the bass needs.
static func degree_to_midi(root_midi: int, scale: String, degree: int) -> int:
	var steps: Array = SCALES.get(scale, SCALES["minor"])
	var size := steps.size()
	# floori rather than integer division, because -1 / 7 is 0 in C and that
	# would make the note below the root the root again.
	var octave := floori(float(degree) / float(size))
	var index := degree - octave * size
	return root_midi + octave * 12 + int(steps[index])


## The notes of one chord of a progression, as MIDI numbers.
##
## `bar` indexes the progression and wraps, so a caller can just count bars
## upward forever and never think about the length of the loop.
static func chord_notes(root_midi: int, scale: String, progression: String,
		bar: int, seventh: bool = false) -> Array[int]:
	var roots: Array = PROGRESSIONS.get(progression, PROGRESSIONS["drive"])
	var base := int(roots[posmod(bar, roots.size())])
	var shape: Array = SEVENTH_DEGREES if seventh else TRIAD_DEGREES
	var out: Array[int] = []
	for offset in shape:
		out.append(degree_to_midi(root_midi, scale, base + int(offset)))
	return out


## The root note of the chord in bar `bar`, which is what the bass plays.
static func chord_root(root_midi: int, scale: String, progression: String,
		bar: int) -> int:
	var roots: Array = PROGRESSIONS.get(progression, PROGRESSIONS["drive"])
	return degree_to_midi(root_midi, scale, int(roots[posmod(bar, roots.size())]))


## A note from the scale near a target pitch, for melody lines that want to
## move by a chosen interval without ever leaving the key.
static func nearest_in_scale(root_midi: int, scale: String, midi: int) -> int:
	var steps: Array = SCALES.get(scale, SCALES["minor"])
	var relative := midi - root_midi
	var octave := floori(float(relative) / 12.0)
	var within := relative - octave * 12
	var best := int(steps[0])
	var best_distance := 99
	for step in steps:
		var distance: int = absi(int(step) - within)
		if distance < best_distance:
			best_distance = distance
			best = int(step)
	return root_midi + octave * 12 + best
