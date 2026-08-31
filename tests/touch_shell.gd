# End-to-end: does a tap actually reach the shell?
#
# Every other touch test drives `Menu.handle_input` or `PlayerInput` directly,
# which proves the mapping and proves nothing about delivery. The failure this
# exists for is the one that cannot be seen from a unit test: a Control
# somewhere in the menu claiming pointer events, so the phone build boots,
# draws perfectly, and ignores every tap.
#
# So this instantiates the REAL Main.tscn and pushes synthetic touches through
# Godot's own input pipeline with `Input.parse_input_event`, which is the same
# path a finger takes. It needs a window (the headless rasterizer draws
# nothing and the shell never advances) and it needs `-- --touch`, so
# verify.sh runs it on its own rather than in the render_* loop.
#
# It waits on `_fading` rather than counting frames: the original freezes input
# during its palette fades (game.c:398-402) and this port copies that, so a
# tap sent mid-fade is CORRECTLY ignored and a frame-counting test would blame
# the touch layer for it.
extends SceneTree

## Seconds, not frames. A fade is 1 s out plus 1 s in of WALL CLOCK, and this
## harness renders as fast as it can — measured at ~1400 fps, where a
## frame-counted wait of 900 covers 0.6 s and times out mid-fade for reasons
## that have nothing to do with the code under test. The cap only exists so a
## hung shell fails instead of hanging the suite.
const SETTLE_SECONDS := 12.0

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var main := (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in 6:
		await process_frame

	check(main._touch_ui, "--touch turns the touch UI on")
	check(main._intro != null, "an interactive boot runs the intro")

	# the intro: any tap skips it, exactly as any key does
	await _tap(main, Vector2(160, 120))
	await _settle(main)
	check(main._intro == null and main._menu != null,
		"a tap skips the intro and lands on the main menu")

	var menu: Menu = main._menu
	check(menu.touch_ui, "the menu was told this is a touch build")

	# the main menu's third item is HELP; tapping it must open that screen.
	# This is the check that catches an input path blocked by a Control: the
	# same tap works in render_menu.gd, so a failure here is delivery.
	menu.screen = Menu.Screen.MAIN
	await process_frame
	await _tap(main, menu._main_item_rect(2).get_center())
	await _settle(main)
	check(menu.screen == Menu.Screen.HELP,
		"a tap on the main menu's third item opens HELP (screen=%d)"
		% menu.screen)

	# and paging out of help by tap, which is the only way off that screen
	# on a phone
	for _i in menu.model.help_pages:
		await _tap(main, Vector2(160, 100))
		await _settle(main)
	check(menu.screen == Menu.Screen.MAIN,
		"tapping through every help page returns to the main menu")

	main.queue_free()
	await process_frame
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## One press/release at a point in the game's 320x240 canvas space.
func _tap(main: Node, canvas_pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = 0
		ev.pressed = pressed
		# Events pushed through Input arrive as if from the window, so they
		# are divided by the root viewport's stretch on the way in. At the
		# default 320x240 that transform is the identity and getting this
		# wrong is invisible; verify.sh runs this suite at 640x480, where it
		# is a factor of two and every tap lands somewhere else.
		ev.position = get_root().get_final_transform() * canvas_pos
		Input.parse_input_event(ev)
		await process_frame
	await process_frame


func _settle(main: Node) -> void:
	var deadline := Time.get_ticks_msec() + int(SETTLE_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if not main._fading:
			return
