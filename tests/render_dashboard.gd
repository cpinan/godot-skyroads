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
	await _jump_o_master()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The JUMP-O-MASTER reads IDLE / IN USE, and the two are a stencil swap in
## the same 26x5 cell — so a break here is silent: the panel keeps showing a
## word, just always the same one. Reported by a player as "it always says
## IDLE", which turned out to be correct behaviour (the landing assist is
## only engaged about 6% of ticks) rather than a fault. This pins the swap so
## that if it ever DOES break, the reason is known.
func _jump_o_master() -> void:
	var road := RoadData.load_json("res://data/levels/road_01.json")
	if road == null:
		check(false, "road 1 loads")
		return
	var cl := CanvasLayer.new()
	get_root().add_child(cl)
	var art := TextureRect.new()
	art.texture = load("res://data/gfx/dashbrd_0.png")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.position = Vector2(0, SkyRoads.DASH_PICT_Y * SkyRoads.PIXEL_ASPECT)
	art.size = Vector2(SkyRoads.SCREEN_W,
		(SkyRoads.SCREEN_H - SkyRoads.DASH_PICT_Y) * SkyRoads.PIXEL_ASPECT)
	cl.add_child(art)
	var dash := Dashboard.new()
	cl.add_child(dash)
	await process_frame

	var shot: Array[Image] = []
	for state in [0, 1]:
		var play := SkyRoadsPlay.new(road)
		play.ap_light = state
		dash.update(play, road.rows)
		for _i in 3:
			await process_frame
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		shot.append(get_root().get_texture().get_image())
	cl.queue_free()
	await process_frame

	var differ := 0
	var a := shot[0]
	var b := shot[1]
	for y in a.get_height():
		for x in a.get_width():
			if not a.get_pixel(x, y).is_equal_approx(b.get_pixel(x, y)):
				differ += 1
	print("  jump-o-master   IDLE vs IN USE differ by %d px" % differ)
	check(differ > 50,
		"the landing-assist readout changes with ap_light (%d px)" % differ)


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
