# Draws what the SIMULATION considers solid, so it can be compared with what
# the renderer draws.
#
# Every "collision is wrong" report so far has turned out to be the drawing
# disagreeing with the physics, not the physics being wrong. Rather than argue
# about it, this overlays the actual collision volumes — sampled from
# SkyRoadsPlay itself, not re-derived — plus the ship's collision extent.
#
# Toggle with C.
#
# Two things it makes visible that surprise people, and are both authentic:
#
#  * The ship is 0x700 (14 px) half-width, but fn_1685 treats the deck as
#    solid if EITHER edge is over floor, so it hovers over a gap with 1 px of
#    support.
#  * A block in the NEXT lane blocks the ship once its centre is 10 px toward
#    that lane (the 0x2f - t neighbour probe), which is about 4 px before the
#    drawn hulls touch. That is what "collides too early with big blocks" is.
class_name CollisionDebug
extends MeshInstance3D

## The same 10-row window the renderer draws (render.c:361-374): base+7 ahead
## down to base-2 behind, so the overlay annotates exactly what is on screen.
const ROWS_AHEAD := 8
const ROWS_BEHIND := 2

var enabled := false
var _play: SkyRoadsPlay
var _last_row := -999
## Rows nearer than the ship, drawn AFTER the sprite like the geometry they
## annotate — so "red where the ship is" means the ship is genuinely inside
## solid, which is the question this overlay exists to answer.
var _behind: MeshInstance3D


func _ready() -> void:
	# The camera's material factory so the overlay is warped by the same DOS
	# horizontal cone as the road it annotates.
	# Rows at or beyond the ship's draw before the sprite (priority -2 < 0),
	# mirroring the DOS band order the road itself uses.
	material_override = SkyRoadsCamera.make_dos_material(true, false, true, -2)
	_behind = MeshInstance3D.new()
	_behind.name = "CollisionDebugBehind"
	# after the ship (0) and after the nearer rows' cover pass (1..2)
	_behind.material_override = SkyRoadsCamera.make_dos_material(true, false, true, 3)
	add_child(_behind)
	visible = false


func toggle() -> void:
	enabled = not enabled
	visible = enabled
	_last_row = -999


func update(play: SkyRoadsPlay) -> void:
	_play = play
	if not enabled:
		return
	var row := int(play.z >> 16)
	if row == _last_row:
		return                      # geometry only changes when the row does
	_last_row = row
	_rebuild(play, row)


func _rebuild(play: SkyRoadsPlay, row: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_behind := SurfaceTool.new()
	st_behind.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w: float = SkyRoadsCamera.COLUMN_WIDTH
	var solid_col := Color(1, 0.25, 0.1, 0.30)
	var deck_col := Color(0.2, 0.9, 1.0, 0.18)

	for r in range(maxi(row - ROWS_BEHIND, 0),
			mini(row + ROWS_AHEAD, play.road.rows)):
		# rows nearer than the ship's go to the late mesh, like the geometry
		var rst := st_behind if r < row else st
		for c in SkyRoads.COLS:
			var code: int = play.road.tile(r, c)
			if code == 0:
				continue
			var x0: float = (float(c) - 3.5) * w
			var x1: float = x0 + w
			var z0 := -float(r)
			var z1 := z0 - 1.0
			# the deck slab: solid for 0x1E80 < y < 0x2800 wherever the
			# surface nibble is set (fn_1685)
			if SkyRoads.tile_surface(code) != 0:
				var lo := (0x1E80 - SkyRoads.Y_DECK) * SkyRoadsCamera.WORLD_PER_GAME_Y
				_box(rst, x0, x1, z0, z1, lo, 0.0, deck_col)
			# the block/tunnel volume, at the heights the profile gives
			var geom := SkyRoads.tile_geometry(code)
			if geom >= 2:
				var top: float = (SkyRoads.BLOCK_TOP[geom] - SkyRoads.Y_DECK) \
					* SkyRoadsCamera.WORLD_PER_GAME_Y
				_box(rst, x0, x1, z0, z1, 0.0, top, solid_col)
			elif geom == 1:
				_tunnel_solid(rst, x0, x1, z0, z1, solid_col)

	# The band the ship's CENTRE is actually forbidden from, sampled from
	# SkyRoadsPlay.solid() itself at the ship's current height. This is wider
	# than the drawn blocks, for two reasons that are both in fn_1685:
	# the ship is tested at x +- 0x700, and a block in the NEXT lane is probed
	# at profile distance 0x2f - t, which bites once the centre is 10px toward
	# it. That gap between the drawn hull and the effective barrier is what
	# "it collides too early with big blocks" is.
	var forbidden := Color(1, 0, 0.6, 0.45)
	for r2 in range(maxi(row, 0), mini(row + 6, play.road.rows)):
		var zz: int = r2 << 16
		var run_start := -1
		for px in range(0, 330, 2):
			var xx: int = (0x5F + px) * 0x80
			var blocked: bool = play.solid(zz, xx, play.y)
			if blocked and run_start < 0:
				run_start = px
			elif not blocked and run_start >= 0:
				_mark(st, run_start, px, r2, forbidden)
				run_start = -1
		if run_start >= 0:
			_mark(st, run_start, 330, r2, forbidden)

	# the ship's own collision extent: +-0x700 about its x, deck-height slab.
	# In the late mesh so it stays readable over the sprite itself.
	var half: float = float(SkyRoads.SHIP_HALF_W) / float(SkyRoads.COL_W) * w
	var lane: float = (float(play.x) - 32768.0) / float(SkyRoads.COL_W)
	var sx: float = lane * w
	var sy: float = (play.y - SkyRoads.Y_DECK) * SkyRoadsCamera.WORLD_PER_GAME_Y
	_box(st_behind, sx - half, sx + half, -float(row) - 0.05, -float(row) + 0.05,
		sy, sy + 0.02, Color(1, 1, 0, 0.55))

	mesh = st.commit()
	_behind.mesh = st_behind.commit()


## The tunnel shell, from the same inner/outer tables collision uses.
func _tunnel_solid(st: SurfaceTool, x0: float, x1: float, z0: float,
		z1: float, col: Color) -> void:
	var px: float = (x1 - x0) / 46.0
	for slice in 46:
		var t: int = absi(23 - slice)
		if t >= SkyRoads.TUN_INNER.size():
			continue
		var lo: int = SkyRoads.TUN_INNER[t]
		var hi: int = SkyRoads.TUN_OUTER[t]
		if hi <= lo:
			continue
		var y_lo := (0x2200 + lo * 0x80 - SkyRoads.Y_DECK) \
			* SkyRoadsCamera.WORLD_PER_GAME_Y
		var y_hi := (0x2200 + hi * 0x80 - SkyRoads.Y_DECK) \
			* SkyRoadsCamera.WORLD_PER_GAME_Y
		_box(st, x0 + slice * px, x0 + (slice + 1) * px, z0, z1,
			y_lo, y_hi, col)


## A thin marker spanning road pixels [px0, px1) on row r, just above the deck.
func _mark(st: SurfaceTool, px0: int, px1: int, r: int, col: Color) -> void:
	var w: float = SkyRoadsCamera.COLUMN_WIDTH
	var x0: float = (float(px0) / 46.0 - 3.5) * w
	var x1: float = (float(px1) / 46.0 - 3.5) * w
	var y: float = 0.02
	_box(st, x0, x1, -float(r) - 0.9, -float(r) - 0.1, y, y + 0.015, col)


func _box(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float,
		y0: float, y1: float, col: Color) -> void:
	var pts := [
		[Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)],
		[Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0), Vector3(x0, y0, z0)],
		[Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3(x0, y0, z0)],
		[Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0)],
	]
	for q in pts:
		for v in [q[0], q[1], q[2], q[0], q[2], q[3]]:
			st.set_color(col)
			st.add_vertex(v)
