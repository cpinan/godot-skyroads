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
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## Returns the fraction of pixels differing from the golden, or -1 if the
## golden is missing or the screen never drew.
func _compare(golden_name: String, screen: int, sel: int) -> float:
	var golden := Image.load_from_file(
		"res://tests/fixtures/golden/%s.png" % golden_name)
	if golden == null:
		return -1.0

	var menu := Menu.new()
	menu.cfg = Config.new()
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
