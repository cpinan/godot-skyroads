# UI test: every menu screen, rendered and compared against the C engine.
#
# The goldens under tests/fixtures/golden/ are frames the C reference engine
# itself drew (tools/menu_trace.c, "shot" mode), so this is a parity check
# rather than a snapshot of the port's own past behaviour: if the port drifts,
# it drifts away from the original and the test says so.
#
# It needs a real GPU context — the headless rasterizer draws nothing — so
# verify.sh runs it windowed alongside test_occlusion.gd.
#
# The main menu is deliberately NOT compared: the C reference paints its own
# "Ported by Ammaar and Fable" credit over that screen, which the DOS original
# does not have and this port does not copy.
extends SceneTree

## The port renders the original's 320x200 screen at 320x240 (4:3), so a
## comparison has to resample. Nearest-neighbour row picking leaves a handful
## of boundary rows landing on a neighbour, so a screen counts as matching
## when almost every pixel does, not every last one.
const MAX_DIFF_FRACTION := 0.005
const TOLERANCE := 24          ## per-channel, for the resample boundary rows

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var cases := [
		["menu_go_0", Menu.Screen.GO, 0],
		["menu_go_20", Menu.Screen.GO, 20],
		["menu_settings_0", Menu.Screen.SETTINGS, 0],
		["menu_settings_3", Menu.Screen.SETTINGS, 3],
		["menu_help_0", Menu.Screen.HELP, 0],
		["menu_help_1", Menu.Screen.HELP, 1],
		["menu_help_2", Menu.Screen.HELP, 2],
	]
	for c in cases:
		var frac := await _compare(c[0], c[1], c[2])
		print("  %-18s differing %.3f%%" % [c[0], frac * 100.0])
		check(frac >= 0.0, "%s rendered at all" % c[0])
		check(frac >= 0.0 and frac <= MAX_DIFF_FRACTION,
			"%s matches the C reference (%.3f%% differ)" % [c[0], frac * 100.0])
	await _touch_navigation()
	await _touch_settings_mask()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The settings goldens are C-engine frames, and the C engine does not draw
## the original's orange "this is the current setting" overlays — see BUGS
## §11 and the retraction in §8.3. Rather than compare against a reference
## that is known to be missing something, the missing thing is added here:
## the orange picts are the retail art, blitted at their own PICT offsets the
## way fn_4ae2 does, over an otherwise verified frame. A fresh Config is
## keyboard + sound on, so items 0 and 3 are the marked ones.
##
## This is the honest version of "regenerate the goldens": the pixels come
## from the retail data, not from this port's output, so the test still
## measures the port against the original rather than against itself.
func _add_state_overlays(golden: Image) -> void:
	var gf := FileAccess.open("res://data/gfx/gfx.json", FileAccess.READ)
	if gf == null:
		return
	var files: Dictionary = (JSON.parse_string(gf.get_as_text())
		as Dictionary)["files"]
	# The goldens are RGB8. Blending an RGBA source into them is what the
	# overlay needs — converting the SOURCE down to RGB8 instead throws its
	# alpha away and pastes the whole rectangle opaque, which is an 8% "diff"
	# that looks exactly like a real regression.
	if golden.get_format() != Image.FORMAT_RGBA8:
		golden.convert(Image.FORMAT_RGBA8)
	for item in [0, MenuModel.SETTINGS_SOUND_FIRST]:
		var name := "setmenu_%d.png" % (Menu.SET_STATE_FIRST + item)
		for e in files.get("setmenu", []):
			if e["file"] != name:
				continue
			var src := Image.load_from_file("res://data/gfx/%s" % name)
			if src == null:
				continue
			if src.get_format() != Image.FORMAT_RGBA8:
				src.convert(Image.FORMAT_RGBA8)
			golden.blend_rect(src,
				Rect2i(0, 0, src.get_width(), src.get_height()),
				Vector2i(int(e["screen_x"]), int(e["screen_y"])))


## Returns the fraction of pixels differing from the golden, or -1 if the
## golden is missing or the screen never drew.
func _compare(golden_name: String, screen: int, sel: int) -> float:
	var golden := Image.load_from_file(
		"res://tests/fixtures/golden/%s.png" % golden_name)
	if golden == null:
		return -1.0
	if screen == Menu.Screen.SETTINGS:
		_add_state_overlays(golden)

	var menu := Menu.new()
	menu.cfg = Config.new()
	menu.cfg.path = "user://test_menu_scratch.cfg"
	# the goldens were taken with this completion pattern, which is what puts
	# a varying number of tick marks on the road-select screen
	for r in 30:
		menu.cfg.completions[r] = r % 4
	# Select BEFORE the node enters the tree. Menu holds its state in a plain
	# MenuModel that exists from construction, while its nodes are built in
	# _ready — which, for a child added during SceneTree._init, does not run
	# until the next frame. Setting the screen first means the menu's own
	# first _show() already draws the right one.
	menu.screen = screen
	match screen:
		Menu.Screen.MAIN: menu.main_sel = sel
		Menu.Screen.GO: menu.go_sel = sel
		Menu.Screen.SETTINGS: menu.set_sel = sel
		Menu.Screen.HELP: menu.help_page = sel
	get_root().add_child(menu)
	for _i in 4:
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_draw()
	var shot := get_root().get_texture().get_image()
	menu.queue_free()
	await process_frame

	# resample the capture to the original's 320x200 and compare there
	var w := golden.get_width()
	var h := golden.get_height()
	var diff := 0
	var sw := shot.get_width()
	var sh := shot.get_height()
	if sw == 0 or sh == 0:
		return -1.0
	for y in h:
		# the port's canvas is SQUARE_H tall for the original's SCREEN_H rows
		# sample the CENTRE of each source pixel: at 1.2 rows per row, taking
		# the top edge lands on the neighbouring row for most of them and
		# every one-pixel rule in the art reads as a mismatch
		var sy := int((float(y) + 0.5) * SkyRoads.PIXEL_ASPECT * float(sh)
			/ SkyRoads.SQUARE_H)
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


## A phone has no Enter key, so the menus have to be reachable by tap. The hot
## regions are the original's own overlay picts out of gfx.json rather than
## coordinates typed in by hand, which is the only reason they can be trusted
## not to drift away from the art — but it also means a wrong lookup fails
## silently, as a menu that simply ignores taps. Hence this.
func _touch_navigation() -> void:
	var menu := _fresh_menu()
	menu.touch_ui = true
	get_root().add_child(menu)
	await process_frame

	# MAIN: the three items share one 68x57 box; tapping the middle third
	# must select and confirm item 1, the settings screen
	var started := [-1]
	menu.start_road.connect(func(i: int) -> void: started[0] = i)
	menu.screen = Menu.Screen.MAIN
	menu.handle_input(_tap(menu, menu._main_item_rect(1).get_center()))
	check(menu.screen == Menu.Screen.SETTINGS,
		"tapping the second main-menu item opens the settings screen")

	# SETTINGS with touch_ui: a tap on a control item is out of reach, a tap
	# on the sound row commits, a tap on neither backs out
	menu.set_sel = 3
	menu.handle_input(_tap(menu, menu._item_rect(1).get_center()))
	check(menu.screen == Menu.Screen.SETTINGS and menu.set_sel == 3,
		"a tap on a dimmed control item changes nothing")
	menu.handle_input(_tap(menu, menu._item_rect(4).get_center()))
	check(menu.set_sel == 4 and menu.cfg.sound_off == 1,
		"a tap on sound-off selects it and commits")
	# A tap on no item is INERT, and the close button is the way out. The old
	# contract was "a miss backs out", which reads fine on a desktop with a
	# mouse and is unusable on a phone: reported from a Pixel 10 Pro, where
	# most of the road select is not a road cell, so trying to pick a road
	# mostly left the screen instead. Same rule on both screens.
	menu.handle_input(_tap(menu, Vector2(2, 2)))
	check(menu.screen == Menu.Screen.SETTINGS,
		"a tap on no item at all does nothing, it does not back out")
	menu.handle_input(_tap(menu, menu._close_rect().get_center()))
	check(menu.screen == Menu.Screen.MAIN,
		"the close button backs out of the settings screen")

	# GO: a tap selects, a second tap on the SAME road starts it. One tap
	# starting a road would launch one on nearly every mis-touch.
	menu.screen = Menu.Screen.GO
	menu.go_sel = 0
	var c := Menu.road_cell(12)
	var p := Vector2(float(c.x) + 24.0,
		(float(c.y) + 4.0) * SkyRoads.PIXEL_ASPECT)
	menu.handle_input(_tap(menu, p))
	check(menu.go_sel == 12 and started[0] == -1,
		"the first tap on a road only moves the cursor")
	menu.handle_input(_tap(menu, p))
	check(started[0] == 13, "the second tap starts it (entry = index + 1)")

	# and a tap on no road at all must NOT leave the road select. This is the
	# Pixel 10 Pro report: the drawn cell is 48x9, so most of this screen is
	# not a cell, and a miss used to mean ESCAPE.
	menu.screen = Menu.Screen.GO
	menu.go_sel = 12
	started[0] = -1
	menu.handle_input(_tap(menu, Vector2(2, 2)))
	check(menu.screen == Menu.Screen.GO and started[0] == -1,
		"a tap on no road leaves the road select alone")
	menu.handle_input(_tap(menu, menu._close_rect().get_center()))
	check(menu.screen == Menu.Screen.MAIN,
		"the close button is how the road select is left")

	# and with touch_ui off, taps must do nothing at all — a desktop build
	# must not gain a second, undocumented control scheme
	menu.touch_ui = false
	menu.screen = Menu.Screen.MAIN
	menu.handle_input(_tap(menu, menu._main_item_rect(2).get_center()))
	check(menu.screen == Menu.Screen.MAIN,
		"without touch_ui a tap is ignored")
	menu.queue_free()
	await process_frame


## The three control-device items must actually be covered on a phone, not
## merely unreachable: an item that still looks live is an item players tap.
func _touch_settings_mask() -> void:
	var shots: Array[Image] = []
	for touch in [false, true]:
		var menu := _fresh_menu()
		menu.touch_ui = touch
		menu.screen = Menu.Screen.SETTINGS
		menu.set_sel = 3
		get_root().add_child(menu)
		for _i in 4:
			await process_frame
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		shots.append(get_root().get_texture().get_image())
		menu.queue_free()
		await process_frame

	# inside the first control item, and inside the sound item next to it
	var covered := _mean_luma(shots[1], _rect_of(shots[1], 46, 58, 77, 50))
	var before := _mean_luma(shots[0], _rect_of(shots[0], 46, 58, 77, 50))
	var sound_after := _mean_luma(shots[1], _rect_of(shots[1], 93, 108, 55, 38))
	var sound_before := _mean_luma(shots[0], _rect_of(shots[0], 93, 108, 55, 38))
	print("  settings mask   control item %.1f -> %.1f, sound item %.1f -> %.1f"
		% [before, covered, sound_before, sound_after])
	check(covered < before * 0.6,
		"the control-device items are dimmed on a phone (%.1f -> %.1f)"
		% [before, covered])
	check(absf(sound_after - sound_before) < 2.0,
		"the sound row is left exactly as it was (%.1f -> %.1f)"
		% [sound_before, sound_after])


## A menu whose config is a scratch file. The settings screen commits through
## Config.save_file(), so a suite that taps it must not be pointed at
## user://skyroads.cfg — the player's save is not test scaffolding.
func _fresh_menu() -> Menu:
	var menu := Menu.new()
	menu.cfg = Config.new()
	menu.cfg.path = "user://test_menu_scratch.cfg"
	return menu


## A press event at a point given in the menu's own canvas space.
func _tap(menu: Menu, canvas_pos: Vector2) -> InputEventScreenTouch:
	var ev := InputEventScreenTouch.new()
	ev.pressed = true
	ev.index = 0
	ev.position = menu._overlay.get_global_transform() * canvas_pos
	return ev


## A pict rectangle (original 320x200 coordinates) mapped into a capture.
func _rect_of(img: Image, x: int, y: int, w: int, h: int) -> Rect2i:
	var iw := img.get_width()
	var ih := img.get_height()
	var sx := int(float(x) * iw / SkyRoads.SCREEN_W)
	var sy := int(float(y) * SkyRoads.PIXEL_ASPECT * ih / SkyRoads.SQUARE_H)
	var sw := int(float(w) * iw / SkyRoads.SCREEN_W)
	var sh := int(float(h) * SkyRoads.PIXEL_ASPECT * ih / SkyRoads.SQUARE_H)
	return Rect2i(sx, sy, maxi(sw, 1), maxi(sh, 1))


func _mean_luma(img: Image, r: Rect2i) -> float:
	var total := 0.0
	var n := 0
	for y in range(r.position.y, mini(r.end.y, img.get_height())):
		for x in range(r.position.x, mini(r.end.x, img.get_width())):
			var c := img.get_pixel(x, y)
			total += float(c.r8) * 0.299 + float(c.g8) * 0.587 \
				+ float(c.b8) * 0.114
			n += 1
	return total / maxf(float(n), 1.0)
