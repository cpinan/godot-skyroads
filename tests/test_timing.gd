# The simulation must advance with elapsed TIME, not with frames.
#
# This is the failure the whole design guards against: anything that steps once
# per frame, or scales a gameplay quantity by `delta`, runs at a different
# speed on a different device — and it looks like "the game feels off", never
# like a bug. The assertion is the invariant, not a number: the same elapsed
# time at any frame rate must leave the ship in exactly the same place.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var road := RoadData.load_json("res://data/levels/road_01.json")
	check(road != null, "road 1 loads")
	if road == null:
		print("Result: %d checks, %d failures" % [_checks, _failures])
		quit(1)
		return

	# 4 seconds of full throttle at four very different frame rates
	var states := {}
	for fps in [15, 30, 60, 144]:
		states[fps] = _run_for(road, 4.0, fps, 1)
	check(states[60]["running"], "the 4 s comparison runs are still going")

	var ref: Dictionary = states[60]
	for fps in states:
		var s: Dictionary = states[fps]
		check(s["ticks"] == ref["ticks"],
			"%d fps runs the same tick count (%d vs %d)" % [fps, s["ticks"], ref["ticks"]])
		check(s["z"] == ref["z"] and s["speed"] == ref["speed"],
			"%d fps leaves the ship in the same place (z %d vs %d)" % [fps, s["z"], ref["z"]])

	# the rate itself: 4 s must be 4 * 36.0036 ticks, not 4 * the frame rate
	var want := int(4.0 * SkyRoads.TICK_HZ)
	check(absi(ref["ticks"] - want) <= 1,
		"4 s is %d ticks, not a frame count (got %d)" % [want, ref["ticks"]])

	# Drift over a long run. Throttle is off here on purpose: at full throttle
	# the ship reaches road 1's gap and dies around tick 258, and a run that
	# ENDS cannot measure the tick rate — the first version of this test
	# reported that as accumulator drift.
	var long_run := _run_for(road, 10.0, 60, 0)
	check(long_run["running"], "the 10 s run is still going (else it measures nothing)")
	var want_long := int(10.0 * SkyRoads.TICK_HZ)
	check(absi(long_run["ticks"] - want_long) <= 1,
		"no accumulator drift over 10 s (%d vs %d)" % [long_run["ticks"], want_long])

	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _run_for(road: RoadData, seconds: float, fps: int, accel: int) -> Dictionary:
	var loop := GameLoop.new()
	loop.start(road)
	loop.accel = accel
	var dt := 1.0 / float(fps)
	for _i in range(int(seconds * fps)):
		loop._process(dt)
	# Count from the simulation itself, not from a counter closed over by a
	# lambda: GDScript captures locals BY VALUE, so `func(): n += 1` increments
	# a copy and the outer variable stays at zero — which reads as "no ticks
	# ran" and would have been blamed on the loop.
	return {"ticks": loop.play.tick, "z": loop.play.z, "speed": loop.play.speed,
		"running": loop.running}
