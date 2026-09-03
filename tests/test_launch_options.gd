# The command line, including the ways it can be malformed.
#
# Every automated check in this repo — the parity captures, the menu shots,
# verify.sh's own replay pass — reaches the game through these flags, so a
# silent parsing change breaks the harness rather than the game, and does it
# quietly. These run headless because LaunchOptions is pure.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _p(argv: Array) -> LaunchOptions:
	var a := PackedStringArray()
	for s in argv:
		a.append(str(s))
	return LaunchOptions.parse(a)


func _init() -> void:
	var o := _p([])
	check(o.mode == LaunchOptions.Mode.MENU, "no arguments boots the menu")
	check(not o.is_automated(), "and that is not an automated run")
	check(o.road_index == 1, "road 1 is the default")

	o = _p(["--road", "7"])
	check(o.mode == LaunchOptions.Mode.PLAY and o.road_index == 7,
		"--road 7 plays road 7")
	check(o.is_automated(), "--road is an automated run: no intro, no fades")

	o = _p(["--replay", "12"])
	check(o.mode == LaunchOptions.Mode.REPLAY and o.road_index == 12,
		"--replay 12 replays road 12")

	# capture flags
	o = _p(["--replay", "2", "--shots", "/tmp/x", "--shot-ticks", "10,20,30"])
	check(o.shot_dir == "/tmp/x", "--shots takes a directory")
	check(Array(o.shot_ticks) == [10, 20, 30],
		"--shot-ticks parses a comma list (got %s)" % [o.shot_ticks])
	o = _p(["--shot-every", "24"])
	check(o.shot_every == 24, "--shot-every takes an interval")
	o = _p(["--final-shot"])
	check(o.roadend_shot and o.force_final,
		"--final-shot implies --roadend-shot")

	o = _p(["--menu-shot", "1:0,2:3"])
	check(o.mode == LaunchOptions.Mode.MENU_SHOT and o.menu_shot == "1:0,2:3",
		"--menu-shot captures menus")

	# route resolution: explicit file wins, otherwise the road's own route
	o = _p(["--replay", "3"])
	check(o.route_for(3) == "res://data/routes/road_03.bin",
		"a road replays its own route by default (%s)" % o.route_for(3))
	o = _p(["--replay", "3", "--route", "crash"])
	check(o.route_for(3) == "res://data/routes/road_03_crash.bin",
		"--route names a variant (%s)" % o.route_for(3))
	o = _p(["--replay", "3", "--route-file", "/tmp/mine.bin"])
	check(o.route_for(3) == "/tmp/mine.bin",
		"--route-file overrides both (%s)" % o.route_for(3))

	# flags with no value must not consume the next argument or crash
	o = _p(["--road"])
	check(o.mode == LaunchOptions.Mode.MENU,
		"a trailing --road with no number does not start a road")
	o = _p(["--shots"])
	check(o.shot_dir.is_empty(), "a trailing --shots is ignored")
	o = _p(["--shot-ticks", "--labels"])
	check(o.want_labels,
		"a flag following a valueless one is still seen")

	# a value must not be mistaken for a flag
	o = _p(["--collision-overlay", "--labels", "--record"])
	check(o.want_overlay and o.want_labels and o.autodump,
		"valueless flags combine")

	o = _p(["--nonsense", "--road", "4"])
	check(Array(o.unknown) == ["--nonsense"],
		"an unknown option is reported, not swallowed (%s)" % [o.unknown])
	check(o.road_index == 4, "and the rest of the line still parses")

	# Deviations from the original are switched off whenever frames are being
	# measured. Getting this wrong is invisible: the pixel suites would carry
	# on passing right up to the moment they compare a deviation against a
	# reference that does not have one.
	check(not _p(["--road", "2"]).is_parity_capture(),
		"an ordinary run is not a parity capture")
	check(_p(["--replay", "1", "--shots", "/tmp/x"]).is_parity_capture(),
		"--shots makes a run a parity capture")
	check(_p(["--menu-shot", "go:0"]).is_parity_capture(),
		"--menu-shot does too")
	check(_p(["--authentic"]).is_parity_capture(),
		"--authentic forces it without capturing anything")
	check(_p(["--road", "2", "--touch"]).force_touch,
		"--touch asks for the on-screen controls")
	check(not _p(["--road", "2"]).force_touch,
		"and is off by default, so a desktop build has no touch layer")
	check(_p(["--touch", "--fixed-stick"]).fixed_stick,
		"--fixed-stick anchors the thumbstick to its drawn circle")
	check(not _p(["--touch"]).fixed_stick,
		"and the stick floats by default, which is what shipped")

	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
