# Trace dumper for the three-way differential test.
#
# Mirrors the C harness in analysis/difftest/harness.c byte for byte and field
# for field, so the same randomised roads and input scripts can be driven
# through the C engine, the Python reference model and this GDScript port, and
# every state field compared on every tick.
#
# Processes a whole directory of trials in ONE invocation: Godot takes a few
# hundred milliseconds to start, which would otherwise dominate a 200-trial run.
#
#   godot --headless --path . --script res://tests/harness.gd -- --dir /tmp/trials
#
# Reads  <dir>/trial_NNN_road.bin  u16 gravity, word2, word3, rows, rows*7 u16
#        <dir>/trial_NNN_in.bin    3 bytes per tick: steer+1, accel+1, jump
# Writes <dir>/trial_NNN_gd.csv    same columns as the C harness
extends SceneTree

var max_ticks := 4000


func _init() -> void:
	var dir := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--dir" and i + 1 < args.size():
			dir = args[i + 1]
		if args[i] == "--ticks" and i + 1 < args.size():
			max_ticks = int(args[i + 1])
	if dir.is_empty():
		printerr("usage: --dir <trial directory>")
		quit(2)
		return

	var d := DirAccess.open(dir)
	if d == null:
		printerr("cannot open %s" % dir)
		quit(2)
		return
	var names: Array[String] = []
	for f in d.get_files():
		if f.ends_with("_road.bin"):
			names.append(f.replace("_road.bin", ""))
	names.sort()

	for name in names:
		_run_trial(dir, name)
	print("Result: %d trials traced" % names.size())
	quit(0)


func _run_trial(dir: String, name: String) -> void:
	var rf := FileAccess.open("%s/%s_road.bin" % [dir, name], FileAccess.READ)
	var gravity := rf.get_16()
	var word2 := rf.get_16()
	var word3 := rf.get_16()
	var rows := rf.get_16()
	var cells := PackedInt32Array()
	cells.resize(rows * 7)
	for i in rows * 7:
		cells[i] = rf.get_16()
	rf.close()

	var road := RoadData.new()
	road.index = 0
	road.rows = rows
	road.gravity = gravity
	road.fuel_rows = word2
	road.oxygen_secs = word3
	road.world = 0
	road.cells = cells

	var inf := FileAccess.open("%s/%s_in.bin" % [dir, name], FileAccess.READ)
	var script_bytes := inf.get_buffer(inf.get_length())
	inf.close()
	var n := script_bytes.size() / 3

	var play := SkyRoadsPlay.new(road)
	var out := PackedStringArray()
	out.append("tick,z,x,y,speed,yvel,xvel,side_push,fuel,oxy,on_ground," +
		"jumping,on_ice,on_sticky,over_hole,tile,end_state,expl,end_frames," +
		"ap_delta,ap_light,edge_dist,fly,res,sfx")
	for t in max_ticks:
		var i: int = t if t < n else n - 1
		play.set_input(script_bytes[i * 3] - 1, script_bytes[i * 3 + 1] - 1,
			script_bytes[i * 3 + 2])
		var res := play.step()
		out.append("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d"
			% [play.tick, play.z, play.x, play.y, play.speed, play.yvel,
			play.xvel, play.side_push, play.fuel, play.oxy, play.on_ground,
			play.jumping, play.on_ice, play.on_sticky, play.over_hole,
			play.tile_code, play.end_state, play.expl_ctr, play.end_frames,
			play.ap_delta, play.ap_light, play.edge_dist, play.fly_ticks,
			res, play.pending_sfx])
		if res != SkyRoadsPlay.RUNNING:
			break

	var of := FileAccess.open("%s/%s_gd.csv" % [dir, name], FileAccess.WRITE)
	of.store_string("\n".join(out) + "\n")
	of.close()
