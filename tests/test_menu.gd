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
	_attract_demo()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The C engine names states; MenuModel numbers them. GAME and QUIT are exits
## rather than screens here, because the shell hands control back to Main.
func _state_name(m: MenuModel) -> String:
	match m.exit:
		MenuModel.Exit.PLAY, MenuModel.Exit.DEMO:
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
		if line.is_empty():
			continue
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


func _attract_demo() -> void:
	var m := MenuModel.new()
	check(m.advance(MenuModel.ATTRACT_IDLE_TICKS) == false
		or m.exit == MenuModel.Exit.NONE,
		"the attract demo has not started one tick early")
	check(m.exit == MenuModel.Exit.NONE,
		"idle for exactly 10 s does not start the demo yet")
	m.advance(2)
	check(m.exit == MenuModel.Exit.DEMO,
		"idle past 10 s starts the attract demo")

	# any key resets the countdown
	m = MenuModel.new()
	m.advance(MenuModel.ATTRACT_IDLE_TICKS)
	m.step([MenuModel.Key.DOWN])
	m.advance(10)
	check(m.exit == MenuModel.Exit.NONE,
		"a keypress resets the attract countdown")

	# and it only runs on the main menu
	m = MenuModel.new()
	m.screen = MenuModel.Screen.GO
	m.advance(MenuModel.ATTRACT_IDLE_TICKS * 2)
	check(m.exit == MenuModel.Exit.NONE,
		"the road-select screen never starts the attract demo")
