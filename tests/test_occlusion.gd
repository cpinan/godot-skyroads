# Does a block in front of the ship actually hide it?
#
# The simulation stops the ship at a wall (proven against the C engine), but if
# the sprite is drawn over that wall the player sees themselves inside it —
# which is indistinguishable from "there is no collision".
#
# This builds a road with a wall directly ahead, puts the ship right behind it,
# and counts how many ship pixels survive. It needs a real rendering context,
# so it runs windowed rather than headless.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	# Both directions matter. "0 ship pixels" is also what a ship that fails
	# to render at all looks like — which is exactly how an earlier attempt at
	# this broke — so the open-road case has to prove it IS drawn.
	var hidden := await _count_ship_pixels(true)
	var shown := await _count_ship_pixels(false)
	# Same open road, half a row further along. The ship's row is split at the
	# ship's own depth and its near half paints after the sprite, so this is
	# the case that would break if that half ever covered a grounded ship on
	# open road — the near half there is only deck, which projects BELOW the
	# sprite exactly as the original's post-ship floor records do.
	var shown_mid := await _count_ship_pixels(false, 11.5)
	# The third scenario is the one the old DEPTH_BIAS compromise could never
	# pass: a wall in the single row BEHIND the ship (nearer the camera,
	# 2.535..3.535 out). render.c draws that row in band dr=8, AFTER the ship,
	# so the original covers the sprite with it — the "ship visibly inside a
	# wall it has hit" defect was exactly this geometry. A wall AHEAD of the
	# ship is deliberately not asserted on: the original draws the ship over
	# it (band dr=6 paints before dr=7), see BUGS.md section 8.2 #1.
	var close := await _count_ship_pixels(true, 11.0, 10, 10)
	# Scenarios 4 and 5 are the tunnel, and they have to disagree with each
	# other or neither proves anything. DEEP inside a run of tunnel rows the
	# reference buries the sprite completely: the rows BEHIND the ship are
	# arches too, they paint after it, and above their bore apex they are
	# solid — checked against the C engine on a synthetic five-row tunnel,
	# where the ship is invisible in both engines. At the MOUTH the rows
	# behind are open road, nothing covers the sprite, and it stays visible
	# through the opening exactly as the reference draws road 2's mouth.
	var deep := await _count_ship_pixels(false, 11.0, 0, 0, 9, 12)
	var mouth := await _count_ship_pixels(false, 11.0, 0, 0, 11, 14)
	# Same mouth, half a row further in. The ship's own row is composed as
	# pre-ship geometry, the sprite, then post-ship geometry (render.c:
	# 361-396), and the cut is the ship's own depth — so once it is inside
	# the row, the arch nearer than it paints OVER the sprite. At row 11.0
	# there is no such near half, which is why both rows are asserted: they
	# are the same road and they must disagree.
	var inside := await _count_ship_pixels(false, 11.5, 0, 0, 11, 14)
	print("ship pixels: %d behind a wall, %d/%d on open road, %d against a wall, "
		% [hidden, shown, shown_mid, close]
		+ "%d deep in a tunnel, %d at its mouth, %d half a row in"
		% [deep, mouth, inside])
	check(shown > 50, "the ship is drawn on open road (%d px)" % shown)
	check(shown_mid > 50,
		"the ship is still drawn mid-row on open road (%d px)" % shown_mid)
	check(hidden == 0,
		"a block directly ahead hides the ship (%d px drawn over it)" % hidden)
	check(close == 0,
		"a wall the ship has just stopped against hides it (%d px)" % close)
	check(deep == 0,
		"tunnel rows behind the ship bury it (%d px drawn over them)" % deep)
	check(mouth > 20,
		"at a tunnel mouth the ship is still seen (%d px)" % mouth)
	check(inside < mouth / 2,
		"half a row into the mouth its near half covers the ship (%d px, "
		% inside + "%d on the row boundary)" % mouth)
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _count_ship_pixels(with_wall: bool, ship_row := 11.0,
		wall_lo := 9, wall_hi := 10, tun_lo := -1, tun_hi := -2) -> int:
	var road := RoadData.new()
	road.index = 0
	road.rows = 40
	road.gravity = 8
	road.fuel_rows = 9999
	road.oxygen_secs = 9999
	road.world = 0
	var cells := PackedInt32Array()
	for row in road.rows:
		for col in 7:
			# Flat deck, with a wall of full blocks across rows 9..10 —
			# BETWEEN the camera and the ship. Geometry ahead of the ship is
			# farther away and should NOT hide it; only nearer geometry does.
			# a run of tunnel rows (geometry nibble 1) over that deck,
			# placed either around the ship's row or starting at it
			if row >= tun_lo and row <= tun_hi:
				cells.append(0x0103)
			else:
				cells.append(0x0433 if with_wall and row >= wall_lo
					and row <= wall_hi else 0x0003)
	road.cells = cells
	road.palette = PackedColorArray()
	for i in 72:
		road.palette.append(Color8(i * 3 % 256, 200, 255 - i * 3 % 256))

	var world := Node3D.new()
	get_root().add_child(world)
	var rm := RoadMesh.new()
	world.add_child(rm)
	rm.build(road)
	var cam := SkyRoadsCamera.new()
	world.add_child(cam)
	cam.current = true
	cam.follow(ship_row)                 # ship just short of the wall
	# Main calls these two together every frame; the window also assigns the
	# cover materials that draw the nearer rows over the sprite
	rm.update_window(ship_row)

	var ship := ShipSprite.new()
	world.add_child(ship)
	ship.setup(cam)

	var play := SkyRoadsPlay.new(road)
	play.z = int(ship_row * 65536.0)
	for _i in 4:
		await process_frame
	ship.sync(play, false)
	for _i in 2:
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_draw()
	var img := get_root().get_texture().get_image()
	img.save_png("/tmp/occlusion_%s_%.1f.png"
		% ["tunnel%d" % tun_lo if tun_hi >= tun_lo
			else ("wall" if with_wall else "open"), ship_row])

	# the ship art is red/blue; the road here is green-ish by construction
	var ship_px := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.45 and c.g < 0.35:
				ship_px += 1
	world.queue_free()
	return ship_px
