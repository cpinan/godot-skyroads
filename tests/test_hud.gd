# Does the dashboard actually report the simulation?
#
# A dashboard that is a static image looks fine in a screenshot and tells the
# player nothing — which is how this port shipped until now. These assert the
# gauges move with the values they represent.
#
# Everything here calls HudModel, the class the Dashboard itself calls. An
# earlier version of this suite kept its own copy of the arithmetic, which
# meant it went on passing no matter what the dashboard actually did; the
# boundary cases below are transcribed from hud.c instead, so they pin the
# shipped code to the reference rather than to a second implementation of it.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var f := FileAccess.open("res://data/hud/shapes.json", FileAccess.READ)
	check(f != null, "hud/shapes.json exists")
	if f == null:
		_done()
		return
	var g: Dictionary = (JSON.parse_string(f.get_as_text()) as Dictionary)["gauges"]
	check(g["speedometer"].size() == SkyRoads.SPEEDO_SEGMENTS,
		"speedometer has %d segments" % SkyRoads.SPEEDO_SEGMENTS)
	check(g["fuel"].size() == SkyRoads.GAUGE_SEGMENTS, "fuel has 10 bars")
	check(g["oxygen"].size() == SkyRoads.GAUGE_SEGMENTS, "oxygen has 10 bars")

	# the segment counts fn_124b would light, at known values
	check(_speedo(0) == 0, "stationary lights no speedometer segment")
	check(_speedo(SkyRoads.SPEED_MAX) == SkyRoads.SPEEDO_SEGMENTS,
		"maximum speed lights all %d" % SkyRoads.SPEEDO_SEGMENTS)
	check(_speedo(SkyRoads.SPEED_MAX / 2) == SkyRoads.SPEEDO_SEGMENTS / 2,
		"half speed lights about half (%d)" % _speedo(SkyRoads.SPEED_MAX / 2))
	# the wall-kill threshold should sit around a third of the dial
	var kill := _speedo(SkyRoads.SPEED_KILL)
	check(kill > 10 and kill < 13,
		"the fatal-collision speed reads ~11 segments (got %d)" % kill)

	check(_tank(SkyRoads.TANK_FULL) == SkyRoads.GAUGE_SEGMENTS, "full tank = 10 bars")
	check(_tank(0) == 0, "empty tank = 0 bars")
	check(_tank(1) == 1, "a sliver of fuel still shows one bar")

	# the autopilot's speed correction must NOT reach the speedometer
	var road := RoadData.load_json("res://data/levels/road_01.json")
	if road != null:
		var play := SkyRoadsPlay.new(road)
		play.speed = 6000
		play.ap_delta = 1200
		# ask the model to do the subtraction; doing it here instead would
		# test this file's arithmetic and pass however the dashboard behaves
		check(HudModel.speed_segments(play.speed, play.ap_delta)
			< HudModel.speed_segments(play.speed, 0),
			"the landing assist is hidden from the speedometer")
		check(HudModel.speed_segments(play.speed, play.ap_delta)
			== HudModel.speed_segments(play.speed - play.ap_delta, 0),
			"and the dial reads exactly the corrected speed")

	var t := FileAccess.open("res://data/tables.json", FileAccess.READ)
	if t != null:
		var d: Dictionary = JSON.parse_string(t.get_as_text())
		check(d["digits"].size() == 10, "10 digit stencils for the GRAV-O-METER")
		check(d["aplight"].size() == 2, "jump-o-master lamp has two states")
	_boundaries()
	_done()


## The cases where an off-by-one is invisible on screen but wrong, taken from
## hud.c rather than from how the port happens to behave.
func _boundaries() -> void:
	# hud.c:70 — a segment lights only once its full quantum is reached
	var q := HudModel.SPEEDO_UNITS_PER_SEG
	check(_speedo(q - 1) == 0, "one unit short of a segment lights none")
	check(_speedo(q) == 1, "exactly one quantum lights exactly one segment")
	check(_speedo(q * HudModel.SPEEDO_SEGMENTS * 2)
		== HudModel.SPEEDO_SEGMENTS, "the dial cannot overflow past full")
	check(HudModel.speed_segments(100, 5000) == 0,
		"an assist bigger than the speed reads zero, never negative")

	# hud.c:78 — the tanks round UP, so the last drop still shows a bar
	var t := HudModel.GAUGE_UNITS_PER_SEG
	check(_tank(t) == 1, "exactly one tank quantum is one bar")
	check(_tank(t + 1) == 2, "one unit into the second quantum is two bars")
	check(_tank(t * HudModel.GAUGE_SEGMENTS * 3) == HudModel.GAUGE_SEGMENTS,
		"the tanks cannot overflow past full")
	check(_tank(-5) == 0, "a negative tank reads empty, not full")

	# hud.c:92 — the bar spans spawn row to last row, and cannot run off
	check(HudModel.progress_steps(HudModel.Z_START_ROW << 16, 100) == 0,
		"the bar is empty at the spawn row")
	check(HudModel.progress_steps(100 << 16, 100)
		== HudModel.PROGRESS_STEPS - 1, "and full at the finish")
	check(HudModel.progress_steps(500 << 16, 100)
		== HudModel.PROGRESS_STEPS - 1, "overrunning the finish does not wrap")
	check(HudModel.progress_steps(0, 100) == 0,
		"a ship behind the spawn row shows no progress")
	for rows in [0, 1, 3]:
		check(HudModel.progress_steps(10 << 16, rows) == 0,
			"a %d-row road cannot divide by zero" % rows)

	# hud.c:120 — (gravity - 3) * 100, leading zeros suppressed
	check(HudModel.gravity_value(3) == 0, "gravity 3 reads 0")
	check(HudModel.gravity_value(8) == 500, "gravity 8 reads 500")
	check(HudModel.gravity_value(0) == 0, "gravity below 3 clamps at 0")
	check(Array(HudModel.gravity_digits(0)) == [0],
		"a zero readout still prints one digit")
	check(Array(HudModel.gravity_digits(500)) == [0, 0, 5],
		"500 prints three digits, not four")
	check(HudModel.gravity_digits(1200).size() == 4,
		"a four-digit readout prints all four")

	# the empty-tank lamp blinks rather than sitting lit
	var lit := 0
	for tick in HudModel.WARN_PERIOD:
		if HudModel.warn_lit(tick):
			lit += 1
	check(lit > 0 and lit < HudModel.WARN_PERIOD,
		"the warning lamp blinks (%d of %d ticks lit)"
		% [lit, HudModel.WARN_PERIOD])


func _speedo(speed: int) -> int:
	return HudModel.speed_segments(speed, 0)


func _tank(qty: int) -> int:
	return HudModel.gauge_segments(qty)


func _done() -> void:
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
