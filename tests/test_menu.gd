# The shell's navigation, diffed against the C reference engine.
#
# Every row of tests/fixtures/menu_traces.txt was produced by driving the C
# engine itself (tools/menu_trace.c, "trace" mode) with a scripted key
# sequence. This replays the SAME sequences through MenuModel and asserts the
# state matches at every step, not just at the end — a menu that reaches the
# right screen by the wrong route is still wrong, and only a step-by-step
# comparison catches it.
#
# Regenerate the fixture after any deliberate change:
#   clang -O2 -o /tmp/sr_menu_trace tools/menu_trace.c \
#       skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
#       skyroads-port/src/thirdparty/opl3.c -lm
#   /tmp/sr_menu_trace <retail_dir> trace "DDUUE"
extends SceneTree

const FIXTURE := "res://tests/fixtures/menu_traces.txt"

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	_differential()
	_boundaries()
	_no_attract_in_the_menus()
	_exe_navigation()
	_touch_settings()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The C engine names states; MenuModel numbers them. GAME and QUIT are exits
## rather than screens here, because the shell hands control back to Main.
func _state_name(m: MenuModel) -> String:
	match m.exit:
		MenuModel.Exit.PLAY:
			return "GAME"
		MenuModel.Exit.QUIT:
			return "QUIT"
	return ["MAIN", "GO", "SET", "HELP"][m.screen]


func _differential() -> void:
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	if f == null:
		check(false, "%s missing — regenerate with tools/menu_trace.c" % FIXTURE)
		return
	var rows: Array[PackedStringArray] = []
	f.get_line()                                  # header
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue                 # '#' marks a note, see the fixture header
		rows.append(line.split(","))
	var scripts := {}
	for r in rows:
		if not scripts.has(r[0]):
			scripts[r[0]] = []
		scripts[r[0]].append(r)
	check(scripts.size() >= 10,
		"fixture covers the shell's flows (%d scripts)" % scripts.size())

	for name in scripts:
		var steps: Array = scripts[name]
		var m := MenuModel.new()
		var mismatch := ""
		for row in steps:
			var step := int(row[1])
			if step > 0:
				var key := MenuModel.key_from_letter(row[2])
				m.step([key] if key >= 0 else [])
			var got := [_state_name(m), m.main_sel, m.go_sel, m.set_sel,
				m.help_page, m.road_entry]
			var want := [row[3], int(row[4]), int(row[5]), int(row[6]),
				int(row[7]), int(row[8])]
			if got != want and mismatch.is_empty():
				mismatch = "step %d (key %s): got %s, C says %s" \
					% [step, row[2], got, want]
			# the C trace stops when the shell hands off; so do we
			if m.exit != MenuModel.Exit.NONE:
				break
		check(mismatch.is_empty(), "%s — %s" % [name, mismatch])


## Cases the scripted traces cannot reach, asserted against the rules in
## game.c directly.
func _boundaries() -> void:
	var m := MenuModel.new()
	m.screen = MenuModel.Screen.GO
	m.go_sel = 14
	m.step([MenuModel.Key.RIGHT])
	check(m.go_sel == 29, "road 15 jumps to road 30, the last of its row")
	m.step([MenuModel.Key.RIGHT])
	check(m.go_sel == 29, "the right column cannot jump right again")
	m.step([MenuModel.Key.LEFT])
	check(m.go_sel == 14, "and comes back to where it started")

	# the original applies every pressed key on a tick, not just the first
	m = MenuModel.new()
	m.screen = MenuModel.Screen.GO
	m.step([MenuModel.Key.DOWN, MenuModel.Key.RIGHT])
	check(m.go_sel == 16, "down and right on one tick both apply (1 + 15)")

	# settings: the two rows differ in length, so the hop is asymmetric
	m = MenuModel.new()
	m.screen = MenuModel.Screen.SETTINGS
	m.set_sel = 2
	m.step([MenuModel.Key.DOWN])
	check(m.set_sel == 4, "control item 2 hops down to the sound row's right")
	m.step([MenuModel.Key.UP])
	check(m.set_sel == 1, "and back up to item 1, not to 2")

	m = MenuModel.new()
	m.screen = MenuModel.Screen.SETTINGS
	m.set_sel = 4
	m.step([MenuModel.Key.ENTER])
	check(m.sound_off and m.settings_dirty, "item 4 turns sound off")
	m.set_sel = 3
	m.step([MenuModel.Key.ENTER])
	check(not m.sound_off, "item 3 turns it back on")
	m.set_sel = 1
	m.step([MenuModel.Key.ENTER])
	check(m.control == 1, "items 0-2 pick the control device")

	# help pages come from the data, not from a hardcoded 3
	m = MenuModel.new()
	m.screen = MenuModel.Screen.HELP
	m.help_pages = 5
	for _i in 4:
		m.step([MenuModel.Key.ENTER])
	check(m.screen == MenuModel.Screen.HELP and m.help_page == 4,
		"a five-page help set does not wrap early (page %d)" % m.help_page)
	m.step([MenuModel.Key.ENTER])
	check(m.screen == MenuModel.Screen.MAIN and m.help_page == 0,
		"the last page returns to the main menu")


## There is no attract timer in any menu, and this asserts the absence.
##
## The retail menus read keys with fn_5fad, a blocking `int 21h ah=7`, so they
## cannot time out — the demo is reached by letting the intro finish instead
## (main @0x0221-0x022f, BUGS §11.11). The port used to count ten idle seconds
## on the main menu, from game.c:200. If that ever comes back, a player who
## walks away mid-menu gets dropped into a demo the original would never have
## started.
func _no_attract_in_the_menus() -> void:
	var m := MenuModel.new()
	check(not ("DEMO" in MenuModel.Exit.keys()),
		"there is no DEMO exit for a menu to take")
	# a long idle on every screen, and nothing must happen
	for screen in [MenuModel.Screen.MAIN, MenuModel.Screen.GO,
			MenuModel.Screen.SETTINGS, MenuModel.Screen.HELP]:
		m = MenuModel.new()
		m.screen = screen
		var fingerprint := [m.screen, m.main_sel, m.go_sel, m.set_sel,
			m.help_page]
		var changed := false
		for _i in 36 * 60:                       # a minute of nothing
			if m.step():
				changed = true
		check(not changed and m.exit == MenuModel.Exit.NONE,
			"screen %d does nothing at all when left alone for a minute"
			% screen)
		check(fingerprint == [m.screen, m.main_sel, m.go_sel, m.set_sel,
			m.help_page], "and its state is untouched")


## On a phone the settings screen's first three items pick a control device
## that the hardware has already decided, so the cursor must not be able to
## reach them. The sound row must be exactly as reachable as it always was —
## the failure this guards against is not "the control row is still there",
## it is "the clamp ate the sound setting too".
func _touch_settings() -> void:
	var m := MenuModel.new()
	m.touch_ui = true
	m.screen = MenuModel.Screen.SETTINGS
	check(m.settings_first_item() == MenuModel.SETTINGS_SOUND_FIRST,
		"touch_ui moves the first reachable settings item to the sound row")

	# a cfg carried over from a desktop leaves set_sel on the control row
	m.set_sel = 1
	m.step([])
	check(m.set_sel == 3,
		"entering with a control item selected lands on sound-on")
	m.sound_off = true
	m.set_sel = 0
	m.step([])
	check(m.set_sel == 4, "and on sound-off when that is the current setting")

	# left cannot walk out of the sound row, up cannot hop out of it
	m.set_sel = 3
	for _i in 5:
		m.step([MenuModel.Key.LEFT])
	check(m.set_sel == 3, "left is clamped at the first sound item")
	m.step([MenuModel.Key.UP])
	check(m.set_sel == 3, "up does not hop to the control row")
	m.step([MenuModel.Key.RIGHT])
	check(m.set_sel == 4, "right still moves within the sound row")
	m.step([MenuModel.Key.UP])
	check(m.set_sel == 4, "and up from the second sound item stays put")

	# confirming can only ever change the sound setting
	m.control = 0
	m.step([MenuModel.Key.ENTER])
	check(m.sound_off and m.control == 0,
		"confirm on the sound row turns sound off and leaves control alone")
	m.set_sel = 3
	m.step([MenuModel.Key.ENTER])
	check(not m.sound_off and m.control == 0, "and back on again")
	check(m.screen == MenuModel.Screen.SETTINGS,
		"none of that left the settings screen")

	# ESC must still work, or a phone reaches a screen it cannot leave
	m.step([MenuModel.Key.ESCAPE])
	check(m.screen == MenuModel.Screen.MAIN, "escape still returns to MAIN")

	# and with touch_ui off nothing above applies: this is the same class the
	# C-engine differential above drives, and it must be untouched by it
	var d := MenuModel.new()
	d.screen = MenuModel.Screen.SETTINGS
	d.set_sel = 3
	d.step([MenuModel.Key.UP])
	check(d.set_sel == 0,
		"without touch_ui the sound row still hops up to the control row")
	d.step([MenuModel.Key.ENTER])
	check(d.control == 0 and d.settings_dirty,
		"and the control device is still selectable there")


## The EXE's own navigation rules, at the boundaries the traces do not reach.
func _exe_navigation() -> void:
	# LEFT anywhere in the first column goes to road 1, it does not refuse
	for start in [0, 1, 7, 14]:
		var m := MenuModel.new()
		m.screen = MenuModel.Screen.GO
		m.go_sel = start
		m.step([MenuModel.Key.LEFT])
		check(m.go_sel == 0, "left from road %d lands on road 1" % (start + 1))
	# RIGHT from the second column runs to the end of the list
	for start in [15, 20, 29]:
		var m := MenuModel.new()
		m.screen = MenuModel.Screen.GO
		m.go_sel = start
		m.step([MenuModel.Key.RIGHT])
		check(m.go_sel == 29,
			"right from road %d lands on road 30" % (start + 1))
	# and the pair is not symmetric: right then left does not come home
	var r := MenuModel.new()
	r.screen = MenuModel.Screen.GO
	r.go_sel = 20
	r.step([MenuModel.Key.RIGHT])
	r.step([MenuModel.Key.LEFT])
	check(r.go_sel == 14, "right-then-left from road 21 ends on road 15")

	# space confirms nothing outside the help screen
	for screen in [MenuModel.Screen.MAIN, MenuModel.Screen.GO,
			MenuModel.Screen.SETTINGS]:
		var m := MenuModel.new()
		m.screen = screen
		var before := [m.screen, m.exit, m.control, m.sound_off]
		m.step([MenuModel.Key.JUMP])
		check([m.screen, m.exit, m.control, m.sound_off] == before,
			"space does nothing on screen %d" % screen)

	# but the help screen turns its page on ANY key that is not escape
	for key in [MenuModel.Key.JUMP, MenuModel.Key.UP, MenuModel.Key.LEFT,
			MenuModel.Key.ENTER]:
		var m := MenuModel.new()
		m.screen = MenuModel.Screen.HELP
		m.step([key])
		check(m.help_page == 1, "help pages on key %d" % key)
	var h := MenuModel.new()
	h.screen = MenuModel.Screen.HELP
	h.step([MenuModel.Key.ESCAPE])
	check(h.screen == MenuModel.Screen.MAIN and h.help_page == 0,
		"escape leaves help instead of paging it")
