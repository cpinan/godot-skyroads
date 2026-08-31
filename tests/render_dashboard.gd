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
	# The golden comparison needs a capture run; the two scenarios below build
	# their own dashboard and do not, so they run either way. Skipping the
	# whole suite when the harness has not captured is how a rendering test
	# quietly stops testing.
	var dir := OS.get_environment("SR_DASH_SHOTS")
	if dir.is_empty():
		print("  (no SR_DASH_SHOTS directory — golden parity not checked)")
	else:
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
	await _gravity_readout()
	_cowl_silhouette()
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


## BUGS #41: the GRAV-O-METER's black readout window is two digit slots wide
## and the code draws up to four, in a colour that IS the panel, so in the
## retail game any digit left of x=106 cannot be seen. That is settled — it is
## in SKYROADS.EXE (fn_1067 @0x1091, fn_0fc6 @0xfd6) and in DASHBRD.LZS — so
## what is tested here is not "which is right" but that the port can still do
## both, and that the parity path is the authentic one.
##
## The failure this catches is the deviation leaking into a measured run: if
## Main ever stops passing is_parity_capture() through, the dashboard suite
## above starts comparing a readable gauge against a reference that has an
## unreadable one, and does it 60 rows away from where anyone is looking.
func _gravity_readout() -> void:
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

	# gravity 8 is the typical road: (8-3)*100 = 500, three digits, so the
	# hundreds digit lands on the slot the art does not back
	check(HudModel.gravity_digits(HudModel.gravity_value(8)).size() == 3,
		"gravity 8 asks for three digits")

	var shot: Array[Image] = []
	for authentic in [true, false]:
		dash.authentic_gravity_window = authentic
		var play := SkyRoadsPlay.new(road)
		dash.update(play, road.rows)
		for _i in 3:
			await process_frame
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		shot.append(get_root().get_texture().get_image())
	cl.queue_free()
	await process_frame

	# slot 2 of 4 — the hundreds digit, 4x5 at screen x 101, y 156
	var x0: int = SkyRoads.GRAVITY_POS[0] + 5
	var dark_authentic := _dark_pixels(shot[0], x0, SkyRoads.GRAVITY_POS[1])
	var dark_readable := _dark_pixels(shot[1], x0, SkyRoads.GRAVITY_POS[1])
	print("  grav-o-meter    hundreds slot dark px: authentic %d, readable %d"
		% [dark_authentic, dark_readable])
	check(dark_authentic == 0,
		"authentic: the hundreds digit is painted on bare panel, no window")
	check(dark_readable >= 6,
		"readable: the window is extended under it (%d dark px)"
		% dark_readable)


## Dark pixels inside a 4x5 digit cell, sampled in the frame's own scale.
## "Dark" is the readout window: the dashboard art's index 0, which the DOS
## stamp leaves as the framebuffer's black. The panel around it is
## (207,174,121) and (211,182,85), so the threshold has an enormous margin.
func _dark_pixels(img: Image, sx: int, sy: int) -> int:
	var w := img.get_width()
	var h := img.get_height()
	var n := 0
	for dy in 5:
		var y := int((float(sy + dy) + 0.5) * SkyRoads.PIXEL_ASPECT
			* float(h) / SkyRoads.SQUARE_H)
		for dx in 4:
			var x := int((float(sx + dx) + 0.5) * float(w) / SkyRoads.SCREEN_W)
			var c := img.get_pixel(clampi(x, 0, w - 1), clampi(y, 0, h - 1))
			if c.r8 < 64 and c.g8 < 64 and c.b8 < 64:
				n += 1
	return n


## The dashboard cowl clips the ship, and this port never wrote that code.
##
## The original masks the sprite and its shadow against `ds:0x44a` — 138 half
## widths, zero above row 129, then {89,111,123,133,138,143,148,153,158} — so
## a low-flying ship disappears behind the dashboard's trapezoidal top edge
## (renderer.md §7.2, fn_32a5 @0x32da). The port gets it for free: the
## dashboard art is a CanvasLayer drawn after the 3D world, so the silhouette
## doing the clipping is the art's own opaque pixels.
##
## "For free" is a claim, and this is the check on it: the art's opaque span
## must BE the mask. If a future export ever changes the cowl's shape, or
## something makes those rows transparent, the ship starts showing through a
## dashboard it should be behind and no other test would notice.
func _cowl_silhouette() -> void:
	var tf := FileAccess.open("res://data/tables.json", FileAccess.READ)
	if tf == null:
		check(false, "tables.json loads")
		return
	var cowl: Array = (JSON.parse_string(tf.get_as_text())
		as Dictionary).get("cowl", [])
	check(cowl.size() == 138, "the cowl table is 138 rows (%d)" % cowl.size())
	var tex: Texture2D = load("res://data/gfx/dashbrd_0.png")
	if tex == null or cowl.is_empty():
		check(false, "the dashboard art loads")
		return
	var art := tex.get_image()
	var worst_edge := 0
	var holes := 0
	var rows := 0
	for y in cowl.size():
		var half := int(cowl[y])
		if half == 0:
			continue                       # unobstructed row, nothing to check
		rows += 1
		var ay: int = y - SkyRoads.DASH_PICT_Y
		if ay < 0 or ay >= art.get_height():
			check(false, "cowl row %d is inside the dashboard picture" % y)
			continue
		var lo := -1
		var hi := -1
		for x in SkyRoads.SCREEN_W:
			if art.get_pixel(x, ay).a > 0.5:
				if lo < 0:
					lo = x
				hi = x
		worst_edge = maxi(worst_edge, absi(lo - (160 - half)))
		worst_edge = maxi(worst_edge, absi(hi - (160 + half)))
		for x in range(maxi(0, 160 - half), mini(SkyRoads.SCREEN_W, 160 + half)):
			if art.get_pixel(x, ay).a <= 0.5:
				holes += 1
	print("  cowl            %d masked rows, worst edge %d px, %d interior holes"
		% [rows, worst_edge, holes])
	check(rows == 9, "nine rows are masked, 129..137 (%d)" % rows)
	# the art and the table are two encodings of one trapezoid; they agree to
	# within the edge pixel the mask rounds differently
	check(worst_edge <= 2,
		"the art's opaque span is the mask's band (worst edge %d px)"
		% worst_edge)
	# a hole inside the band is a place the ship would show through the cowl
	check(holes <= 2, "the band is solid (%d transparent pixels)" % holes)


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
