# The intro sequence, driven tick by tick.
#
# The intro is the one part of the shell that is long, linear and unattended:
# thirty-three seconds during which nobody is pressing anything, so a phase
# that never starts or never ends is invisible until someone sits and watches
# the whole thing. Both failure modes happened while writing it — the credit
# plates drew nothing because their setup was keyed on a tick that never
# arrived, and only a screenshot caught it.
#
# Everything asserted here has an address behind it in `Intro.gd`'s header or
# in `tools/export_intro_palettes.py`; this suite is about whether the port
# reaches those states, in that order, for those durations.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	await _data()
	await _sequence()
	await _skip()
	await _attract_wiring()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## The exported palette pairs. `bright_matches_export` is the exporter's own
## cross-check: it re-renders each picture through the SECOND CMAP of its pair
## and compares against the shipped intro_N.png. If that is ever false the two
## halves of a cross-fade are not the same picture and every fade is wrong.
func _data() -> void:
	var f := FileAccess.open("res://data/gfx/intro_seq.json", FileAccess.READ)
	check(f != null, "intro_seq.json exists (run tools/export_intro_palettes.py)")
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	check(d is Dictionary, "intro_seq.json parses")
	if not (d is Dictionary):
		return
	var picts: Array = d.get("picts", [])
	check(picts.size() == 6,
		"the logo plus five credit plates are exported (%d)" % picts.size())
	for p in picts:
		check(bool(p.get("bright_matches_export", false)),
			"pict %s: the bright render reproduces the shipped export"
			% p.get("index", "?"))
		check(ResourceLoader.exists("res://data/gfx/%s" % p["dim"]),
			"pict %s: the dim render exists" % p.get("index", "?"))
		check(ResourceLoader.exists("res://data/gfx/%s" % p["file"]),
			"pict %s: the bright render exists" % p.get("index", "?"))
	var t: Dictionary = d.get("timing", {})
	# the numbers that came out of the binary; a silent edit to the exporter
	# would otherwise change the pacing of the whole sequence unnoticed
	for pair in [["wipe_ticks", 18], ["wipe_columns", 319], ["flash_in", 5],
			["flash_hold", 9], ["flash_out", 70], ["plate_in", 50],
			["plate_hold", 50], ["plate_out", 50], ["anim_hold", 72],
			["title_fade", 36], ["voice_tick", 24]]:
		check(int(t.get(pair[0], -1)) == pair[1],
			"timing %s is %d" % [pair[0], pair[1]])
	await process_frame


## Step the clock and watch the phases go by.
func _sequence() -> void:
	var intro := Intro.new()
	get_root().add_child(intro)
	await process_frame

	var ran_to_end := [false]
	var was_skipped := [true]
	intro.done.connect(func(sk: bool) -> void:
		ran_to_end[0] = true
		was_skipped[0] = sk)
	var seen: Array[int] = []
	var wipe_left: Array[int] = []
	var plates_seen := {}
	var first_plate_tick_had_texture := true
	var pending_setup := false
	var last_plate := -1
	var finished_at := -1
	for t in range(1, 4000):
		intro._ticks = t
		intro._tick()
		if seen.is_empty() or seen[-1] != intro._phase:
			seen.append(intro._phase)
		if intro._phase == Intro.Phase.WIPE:
			wipe_left.append(intro._wipe_left())
		# The index changes on the tick that ERASES the previous plate, and
		# the next one is set up on the tick after — so the picture has to be
		# looked for one tick later than the change. Checking it on the change
		# tick itself measures the erase, not the setup.
		if pending_setup and intro._phase == Intro.Phase.PLATES:
			pending_setup = false
			if intro._plate_bright == null \
					or intro._plate_bright.texture == null \
					or not intro._plate_bright.visible:
				first_plate_tick_had_texture = false
		if intro._phase == Intro.Phase.PLATES and not intro._over \
				and intro._plate != last_plate:
			last_plate = intro._plate
			plates_seen[intro._plate] = t
			# the bug this suite exists for: a plate whose textures were
			# never assigned draws nothing at all
			pending_setup = true
		if intro._over:
			finished_at = t
			break

	check(seen == [Intro.Phase.TITLE, Intro.Phase.ANIM, Intro.Phase.HOLD,
			Intro.Phase.WIPE, Intro.Phase.FLASH, Intro.Phase.PLATES,
			Intro.Phase.OVER],
		"every phase runs, once, in order (%s)" % [seen])
	check(finished_at > 0, "the intro ends on its own rather than hanging")
	# 33 s at 36 Hz. Loose bounds: this is a "did a phase collapse" check,
	# not a stopwatch — the per-phase durations are asserted above.
	check(finished_at > 1000 and finished_at < 1400,
		"it runs about 33 s (%d ticks)" % finished_at)

	check(wipe_left.size() == 18,
		"the wipe lasts 18 ticks (%d)" % wipe_left.size())
	check(wipe_left.size() > 0 and wipe_left[0] == 319,
		"it starts with all 319 columns still background")
	var monotonic := true
	for i in range(1, wipe_left.size()):
		if wipe_left[i] >= wipe_left[i - 1]:
			monotonic = false
	check(monotonic, "the curtain only ever closes (%s)" % [wipe_left])
	check(wipe_left.size() > 0 and wipe_left[-1] <= 18,
		"and is all but shut on its last tick (%d)"
		% (wipe_left[-1] if wipe_left.size() > 0 else -1))

	check(plates_seen.size() == 5,
		"all five credit plates are shown (%d)" % plates_seen.size())
	check(ran_to_end[0] and not was_skipped[0],
		"an untouched intro reports itself unskipped — which is the only "
		+ "route to the attract demo")
	check(first_plate_tick_had_texture,
		"each plate has its picture on the first tick it is shown")
	var gaps: Array[int] = []
	var keys: Array = plates_seen.keys()
	keys.sort()
	for i in range(1, keys.size()):
		gaps.append(plates_seen[keys[i]] - plates_seen[keys[i - 1]])
	for g in gaps:
		check(g == 151,
			"a plate lasts fade-in 50 + hold 50 + fade-out 50 (%d ticks)" % g)
	intro.queue_free()
	await process_frame


## Any key skips, from any phase — the original arms its abort flag for the
## whole sequence (fn_4575 @0x470d) and clears it at the end (@0x4a6f).
func _skip() -> void:
	for at in [1, 100, 500, 1000]:
		var intro := Intro.new()
		get_root().add_child(intro)
		await process_frame
		var done := [false]
		var skipped := [false]
		intro.done.connect(func(sk: bool) -> void:
			done[0] = true
			skipped[0] = sk)
		for t in range(1, at + 1):
			intro._ticks = t
			intro._tick()
			if intro._over:
				break
		var ev := InputEventKey.new()
		ev.keycode = KEY_SPACE
		ev.pressed = true
		intro.handle_input(ev)
		check(done[0], "a keypress at tick %d ends the intro" % at)
		# fn_4575 returns its abort flag, and a non-zero return is what sends
		# the shell to the menu rather than to the attract demo (BUGS §11.11)
		check(skipped[0], "and reports it as skipped, not as run to the end")
		intro.queue_free()
		await process_frame


## Where the intro hands off, which is the whole point of reporting `skipped`.
##
## main @0x0221: `fn_4575()` returns 0 when untouched and main answers with
## `[0x9602] = 3` and road 0 — the attract demo; non-zero and it opens the
## main menu. Driving Main._end_intro directly is the cheap way to pin that,
## because the honest end-to-end version would have to sit through
## thirty-three seconds of intro twice.
func _attract_wiring() -> void:
	for skipped in [true, false]:
		var main := (load("res://scenes/Main.tscn") as PackedScene).instantiate()
		get_root().add_child(main)
		for _i in 4:
			await process_frame
		main._end_intro(skipped)
		for _i in 4:
			await process_frame
		if skipped:
			check(main._menu != null and not main._in_game,
				"a skipped intro opens the main menu")
			check(not main._replaying, "and does not start a replay")
		else:
			check(main._in_game and main._replaying,
				"an untouched intro runs the attract demo")
			check(main.road_index == 0,
				"and the demo is road 0 (road=%d)" % main.road_index)
		main.queue_free()
		await process_frame
