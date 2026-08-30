# Golden-trace validation: the GDScript simulation must agree with the
# reference model tick for tick, field for field.
#
# The reference model (analysis/sra/sim.py) is itself proven bit-identical to
# skyroads-port/src/core/play.c over 100k+ ticks, and that C is a
# disassembly-verified reimplementation of the 1993 binary. So a pass here
# chains GDScript -> Python -> C -> DOS.
#
# "The road completed" on its own is a weak assertion — a port can be wrong
# for 400 ticks and right at the end. Every field is compared every tick.
extends SceneTree

const ROUTES := "res://data/routes/"
# Every field the trace carries. Comparing a subset is how a port ships with a
# broken sound gate: it changes no position, so a position-only trace is green.
const FIELDS := ["z", "x", "y", "speed", "yvel", "xvel", "side_push", "fuel",
	"oxy", "on_ground", "jumping", "on_ice", "on_sticky", "over_hole", "tile",
	"end_state", "expl", "end_frames", "ap_delta", "ap_light", "edge_dist",
	"fly", "sfx"]

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	for road_index in [1, 30]:
		_replay(road_index)
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _load_road(i: int) -> RoadData:
	return RoadData.load_json("res://data/levels/road_%02d.json" % i)


## A road either has a winning route or, when the solver could not finish it,
## a deterministic probe. Both are compared tick for tick; only a route is
## expected to complete.
func _load_script_bytes(i: int) -> Array:
	var f := FileAccess.open(ROUTES + "road_%02d.bin" % i, FileAccess.READ)
	if f != null:
		return [f.get_buffer(f.get_length()), true]
	f = FileAccess.open(ROUTES + "road_%02d_probe.bin" % i, FileAccess.READ)
	if f != null:
		return [f.get_buffer(f.get_length()), false]
	return [PackedByteArray(), false]


func _load_trace(i: int) -> Array:
	var f := FileAccess.open(ROUTES + "road_%02d_trace.dat" % i, FileAccess.READ)
	assert(f != null, "missing trace for road %d" % i)
	var header := f.get_line().split(",")
	var rows: Array = []
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parts := line.split(",")
		var row := {}
		for c in header.size():
			row[header[c]] = int(parts[c])
		rows.append(row)
	return rows


func _replay(road_index: int) -> void:
	var road := _load_road(road_index)
	var loaded := _load_script_bytes(road_index)
	var script_bytes: PackedByteArray = loaded[0]
	var is_route: bool = loaded[1]
	var expected := _load_trace(road_index)
	var ticks := script_bytes.size() / 3

	check(road != null, "road %d loads" % road_index)
	check(ticks > 0, "road %d has an input script" % road_index)
	check(expected.size() > 0, "road %d has a golden trace" % road_index)

	var play := SkyRoadsPlay.new(road)
	var result := SkyRoadsPlay.RUNNING
	var diverged_at := -1
	var diverged_field := ""
	var t := 0
	while t < ticks:
		play.set_input(script_bytes[t * 3] - 1, script_bytes[t * 3 + 1] - 1,
			script_bytes[t * 3 + 2])
		result = play.step()
		if t < expected.size():
			var e: Dictionary = expected[t]
			var got := {
				"z": play.z, "x": play.x, "y": play.y, "speed": play.speed,
				"yvel": play.yvel, "xvel": play.xvel,
				"side_push": play.side_push, "fuel": play.fuel,
				"oxy": play.oxy, "on_ground": 1 if play.on_ground else 0,
				"jumping": 1 if play.jumping else 0,
				"on_ice": 1 if play.on_ice else 0,
				"on_sticky": 1 if play.on_sticky else 0,
				"over_hole": 1 if play.over_hole else 0,
				"tile": play.tile_code, "end_state": play.end_state,
				"expl": play.expl_ctr, "end_frames": play.end_frames,
				"ap_delta": play.ap_delta,
				"ap_light": 1 if play.ap_light else 0,
				"edge_dist": play.edge_dist, "fly": play.fly_ticks,
				"sfx": play.pending_sfx,
			}
			for k in FIELDS:
				if got[k] != e[k]:
					diverged_at = t + 1
					diverged_field = "%s: expected %d, got %d" % [k, e[k], got[k]]
					break
		if diverged_at >= 0:
			break
		t += 1
		if result != SkyRoadsPlay.RUNNING:
			break

	check(diverged_at < 0, "road %d matches the reference model tick for tick (%s at tick %d)"
		% [road_index, diverged_field, diverged_at])
	if is_route:
		check(result == SkyRoadsPlay.COMPLETE,
			"road %d completes (got result %d after %d ticks)"
			% [road_index, result, play.tick])
	check(play.tick == expected.size(),
		"road %d takes the expected %d ticks (took %d)"
		% [road_index, expected.size(), play.tick])
	if diverged_at < 0:
		print("road %2d: %d ticks, %d fields x %d ticks all identical%s"
			% [road_index, play.tick, FIELDS.size(), expected.size(),
			"" if is_route else "  (probe — solver found no route)"])
