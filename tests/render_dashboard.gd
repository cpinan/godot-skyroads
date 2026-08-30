# UI test: the dashboard, rendered mid-game and compared against the C engine.
#
# The goldens are the dashboard band (rows 138..199) of frames the C reference
# engine drew while replaying the user's own road-2 recording. Reaching them
# means driving the real stack — Main's scene, GameLoop's fixed-step
# accumulator, the simulation — to the same tick and capturing what is on
# screen, which is what tools/verify.sh does for this suite.
#
# It exists because the dashboard is the one part of the screen a unit test
# cannot reach: the readouts are correct arithmetic (test_hud.gd proves that)
# and were still drawn wrong, because the 3D viewport was showing through the
# dashboard art's transparent pixels. Only a pixel comparison catches that.
extends SceneTree

const GOLDEN_DIR := "res://tests/fixtures/golden"
## The band below the 3D viewport, in the original's 200-line screen space.
const BAND_TOP := 138
const TOLERANCE := 24
const MAX_DIFF_FRACTION := 0.002

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	# A capture run needs the same replay Main performs, so this test asserts
	# on frames the capture harness produced rather than re-implementing the
	# loop. verify.sh passes the directory; without it the test self-skips
	# rather than silently passing.
	var dir := OS.get_environment("SR_DASH_SHOTS")
	if dir.is_empty():
		print("  (no SR_DASH_SHOTS directory — dashboard parity not checked)")
		print("Result: %d checks, %d failures" % [_checks, _failures])
		quit(0)
		return
	for tick in [100, 240, 420, 640]:
		var frac := _compare(dir, tick)
		if frac < 0.0:
			check(false, "tick %d: capture or golden missing" % tick)
			continue
		print("  dash t%04d       differing %.3f%%" % [tick, frac * 100.0])
		check(frac <= MAX_DIFF_FRACTION,
			"dashboard at tick %d matches the C reference (%.3f%% differ)"
			% [tick, frac * 100.0])
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _compare(dir: String, tick: int) -> float:
	var golden := Image.load_from_file(
		"%s/dash_road02_t%04d.png" % [GOLDEN_DIR, tick])
	# the harness captures the tick AFTER the C one: presentation carries the
	# ship forward into the tick being simulated, so the port's frame for C's
	# tick N lines up with tick N+1 (measured; see BUGS #29b)
	var shot := Image.load_from_file("%s/road02_t%04d.png" % [dir, tick + 1])
	if golden == null or shot == null:
		return -1.0
	var w := golden.get_width()
	var h := golden.get_height()
	var sw := shot.get_width()
	var sh := shot.get_height()
	if sw == 0 or sh == 0:
		return -1.0
	var diff := 0
	for y in h:
		# golden row y is screen row BAND_TOP + y of a 200-line frame
		var sy := int((float(BAND_TOP + y) + 0.5) * SkyRoads.PIXEL_ASPECT
			* float(sh) / SkyRoads.SQUARE_H)
		sy = clampi(sy, 0, sh - 1)
		for x in w:
			var sx := clampi(int((float(x) + 0.5) * float(sw) / float(w)),
				0, sw - 1)
			var a := golden.get_pixel(x, y)
			var b := shot.get_pixel(sx, sy)
			if absi(int(a.r8) - int(b.r8)) > TOLERANCE \
					or absi(int(a.g8) - int(b.g8)) > TOLERANCE \
					or absi(int(a.b8) - int(b.b8)) > TOLERANCE:
				diff += 1
	return float(diff) / float(w * h)
