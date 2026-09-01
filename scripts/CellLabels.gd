# Puts an ID on every object on screen so a problem can be named.
#
# "the block on the left" is ambiguous; "B14.0" is not. IDs are the tile's own
# grid position, which is the same coordinate the simulation, the level JSON
# and every analysis tool use — so a report maps straight onto a trace.
#
#   B<row>.<col>   a block      (geometry 2/3 = half, 4/5 = full)
#   T<row>.<col>   a tunnel     (geometry 1)
#   F<row>.<col>   a floor cell (track you can stand on)
#   <row>          the row number, at the left edge of the road
#   H<row>         a row with nothing landable at all
#   SHIP r<row> c<col>  where the simulation thinks the ship is
#
# Toggle with L.
class_name CellLabels
extends Node2D

const ROWS_AHEAD := 10
const ROWS_BEHIND := 1
## Anything smaller than this on screen is unreadable and just adds noise.
const MIN_ROWS_APART := 0.35

var enabled := false
var _cam: SkyRoadsCamera
var _play: SkyRoadsPlay


func setup(cam: SkyRoadsCamera) -> void:
	_cam = cam
	visible = false
	z_index = 20


func toggle() -> void:
	enabled = not enabled
	visible = enabled
	queue_redraw()


func update(play: SkyRoadsPlay) -> void:
	_play = play
	if enabled:
		queue_redraw()


func _draw() -> void:
	if _play == null or _cam == null:
		return
	var row := int(_play.z >> 16)
	var w: float = SkyRoadsCamera.COLUMN_WIDTH
	for r in range(maxi(row - ROWS_BEHIND, 0),
			mini(row + ROWS_AHEAD, _play.road.rows)):
		var ahead := float(r) - float(_play.z) / 65536.0
		if ahead < MIN_ROWS_APART - 1.0:
			continue
		# the row number, just off the left edge of the road
		_label("%d" % r, Vector3(-4.2 * w, 0.05, -float(r) - 0.5),
			Color(0.6, 0.9, 1.0))
		var landable := 0
		for c in SkyRoads.COLS:
			var code: int = _play.road.tile(r, c)
			if SkyRoads.tile_geometry(code) != 0 or SkyRoads.tile_surface(code) != 0:
				landable += 1
			var geom := SkyRoads.tile_geometry(code)
			if geom == 0:
				# plain track: labelled only close up, or it is unreadable
				if SkyRoads.tile_surface(code) != 0 and ahead < 4.0:
					_label("F%d.%d" % [r, c],
						Vector3((float(c) - 3.0) * w, 0.03, -float(r) - 0.5),
						Color(0.55, 0.95, 0.6))
				continue
			var top: float = (SkyRoads.BLOCK_TOP[geom] - SkyRoads.Y_DECK) \
				* SkyRoadsCamera.WORLD_PER_GAME_Y
			var tag := "T" if geom == 1 else "B"
			_label("%s%d.%d" % [tag, r, c],
				Vector3((float(c) - 3.0) * w, top + 0.04, -float(r) - 0.5),
				Color(1, 0.85, 0.3) if geom == 1 else Color(1, 0.5, 0.4))
		if landable == 0:
			_label("H%d" % r, Vector3(0.0, 0.06, -float(r) - 0.5),
				Color(1, 0.4, 1.0))

	# and where the simulation says the ship is — its grid cell, not its sprite
	var lane: int = (_play.x / 0x80 - 0x5F) / 0x2E
	var sy: float = (_play.y - SkyRoads.Y_DECK) * SkyRoadsCamera.WORLD_PER_GAME_Y
	var slane: float = (float(_play.x) - 32768.0) / float(SkyRoads.COL_W)
	_label("SHIP r%d c%d y%+d" % [row, lane, _play.y - SkyRoads.Y_DECK],
		Vector3(slane * w, sy + 0.16, -float(row) - 0.5),
		Color(1, 1, 0.4))


func _label(text: String, world: Vector3, col: Color) -> void:
	if _cam.is_position_behind(world):
		return
	# the road meshes are warped to the DOS cone in their vertex shader —
	# horizontally by dos_x_scale and, above the deck, vertically by
	# dos_y_scale (BUGS §12.18) — so warp the label anchor both ways or it
	# drifts off the cell it names
	var depth: float = _cam.global_position.z - world.z
	world.x *= SkyRoadsCamera.dos_x_scale(depth)
	# the deck is y = 0 in world space, so height above it IS world.y
	world.y *= SkyRoadsCamera.dos_y_scale(depth)
	var p := _cam.unproject_position(world)
	# Objects close to the camera project outside the frame; clamp their
	# labels to the edge rather than dropping them, since those are exactly
	# the ones being collided with and most worth naming.
	if p.y < 0.0 or p.y > SkyRoads.VIEW_H * SkyRoads.PIXEL_ASPECT:
		return
	p.x = clampf(p.x, 1.0, SkyRoads.SCREEN_W - Text8x8.width(text) - 1.0)
	# a dark plate so the text stays readable over any road colour
	draw_rect(Rect2(p - Vector2(1, 1),
		Vector2(Text8x8.width(text) + 2, Text8x8.GLYPH_H + 2)),
		Color(0, 0, 0, 0.55), true)
	Text8x8.draw(self, text, int(p.x), int(p.y), col, 1.0)
