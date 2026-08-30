# The ship and its shadow, drawn the way the original draws them: 2D blits in
# screen space, over the composed road.
#
#     sprite left = x / 0x80 + pan[tilt] - 0x6e     (fn_0be3, pan ds:0x38)
#     sprite top  = 0x9d - y / 0x80                 (1 px lower on sticky)
#     shadow y    = top + 0x10 + clearance          (renderer.md §7.3)
#
# Occlusion is the reason this lives in 3D rather than in a CanvasLayer. A
# CanvasLayer always draws over the whole 3D world, so a block the ship has
# stopped against would not hide it — the player sees themselves inside a wall
# the simulation has already stopped them against, which reads as "there is no
# collision".
#
# The sprite is NOT depth-tested. The DOS order (render.c:361-396) blits the
# ship inside its own row's band: everything from its row outward is already
# painted, and only the one-or-two rows nearer the camera paint after it.
# Measured on the C engine, the grounded sprite sits entirely inside the
# screen strips of those nearer rows, so a depth-tested sprite at its true
# depth is swallowed by nearer FLOOR — which the original never lets happen.
# So the sprite draws over everything opaque (floor, backdrop, rows at or
# beyond its own), and RoadMesh moves the nearer rows' raised geometry into
# the transparent pass at a higher render_priority so exactly that geometry —
# and nothing else — paints over the ship.
class_name ShipSprite
extends Node3D

const SPRITE_W := 29
const SPRITE_H := 24
const ORIGIN_X := 0x6E
const SCREEN_Y_BASE := 0x9D
const SHADOW_W := 29
const SHADOW_H := 9
const SHADOW_Y_OFFSET := 0x10
## True depth: the sprite is placed at the ship's own distance and never
## depth-tested, so this constant only exists to say so. Occlusion comes from
## draw order — RoadMesh paints the rows nearer than the ship after the
## sprite, exactly as the DOS band order does (render.c:361-396). The old
## bias compromise and its measurements are in BUGS.md section 8.2 #1.
const DEPTH_BIAS := 0.0

var _ship: Array[Texture2D] = []
var _explosion: Array[Texture2D] = []
var _shadow_tex: Array[Texture2D] = []
var _ship_rect: Sprite3D
var _shadow_rect: Sprite3D
var _cam: SkyRoadsCamera


func setup(cam: SkyRoadsCamera) -> void:
	_cam = cam
	for i in SkyRoads.CARS_SHIP_FRAMES:
		_ship.append(load("res://data/sprites/ship/ship_t%d_p%d_f%d.png"
			% [i / 9, (i / 3) % 3, i % 3]))
	for i in SkyRoads.CARS_EXPLOSION_FRAMES:
		_explosion.append(load("res://data/sprites/ship/explosion_%02d.png" % i))
	_build_shadow_textures()

	_shadow_rect = _make_sprite()
	# The original does not blit a shadow: it DARKENS what is under it,
	# shifting floor colours by +0x2D. Measured across the retail road
	# palettes that is a consistent 0.586x multiply, and the unset stencil
	# pixels are white so they leave the road alone.
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	smat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	# under the ship (priority -1 < 0) and under the nearer rows' cover pass,
	# so a block the ship is passing covers the shadow along with the ship
	smat.no_depth_test = true
	smat.render_priority = -1
	_shadow_rect.material_override = smat
	add_child(_shadow_rect)

	_ship_rect = _make_sprite()
	add_child(_ship_rect)


func _make_sprite() -> Sprite3D:
	var s := Sprite3D.new()
	s.centered = true
	s.billboard = BaseMaterial3D.BILLBOARD_DISABLED   # the camera never turns
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	# Plain alpha blending, no depth test: the sprite must paint over every
	# opaque row (the DOS blit ignores what is already there) and be painted
	# over only by the nearer rows' cover pass, which RoadMesh orders after
	# priority 0 in the transparent queue.
	s.no_depth_test = true
	s.render_priority = 0
	s.visible = false
	return s


func _build_shadow_textures() -> void:
	var f := FileAccess.open("res://data/tables.json", FileAccess.READ)
	if f == null:
		push_error("tables.json missing — run `sra export-godot`")
		return
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	var darken: float = d.get("shadow_darken", 0.586)
	for stencil in d["shadow"]:
		var img := Image.create(SHADOW_W, SHADOW_H, false, Image.FORMAT_RGBA8)
		for col in SHADOW_W:
			for row in SHADOW_H:
				# stored column-major, exactly like the ship cells
				var on: bool = int(stencil[col * SHADOW_H + row]) != 0
				img.set_pixel(col, row, Color(darken, darken, darken, 1.0)
					if on else Color.WHITE)
		_shadow_tex.append(ImageTexture.create_from_image(img))


static func _tilt(x: int) -> int:
	return clampi((x / 0x80 - 95) / 46, 0, 6)


## `tilt` comes from the caller so the frame agrees with the interpolated
## position the sprite is drawn at — deriving it from the simulated play.x
## here made the art lag the placement by a frame during fast steering.
func _index(play: SkyRoadsPlay, tilt: int) -> int:
	var pitch := 0
	if not play.in_tunnel(play.z, play.x, play.y):
		if play.yvel <= -SkyRoads.PITCH_VEL_THRESHOLD or play.y < SkyRoads.Y_DECK:
			pitch = 2
		elif play.yvel >= SkyRoads.PITCH_VEL_THRESHOLD:
			pitch = 1
	var flame: int = 0 if play.end_state == SkyRoadsPlay.NO_FUEL \
		else SkyRoads.FLAME_TABLE[(play.tick / 2) % 4]
	return 9 * tilt + 3 * pitch + flame


## Put a sprite where the original's screen coordinates say, at the ship's own
## depth so the depth buffer can sort it.
##
## pixel_size converts texture pixels to world units: one canvas pixel spans
## depth / FOCAL_PX at this distance. The extra 1.2 on Y is mode 13h's
## non-square pixel, applied as scale rather than baked into pixel_size so the
## sprite stays pixel-exact horizontally.
func _place(s: Sprite3D, left: float, top: float, w: float, h: float) -> void:
	if _cam == null:
		return
	var depth: float = _cam.BEHIND_ROWS - DEPTH_BIAS
	s.pixel_size = depth / _cam.FOCAL_PX
	s.scale = Vector3(1.0, SkyRoads.PIXEL_ASPECT, 1.0)
	var centre := Vector2(left + w * 0.5,
		(top + h * 0.5) * SkyRoads.PIXEL_ASPECT)
	s.global_position = _cam.screen_to_world(centre, depth)


## Ground height under the ship, sampled either side of it (fn_0b71).
func _support(play: SkyRoadsPlay, x: int, in_tun: bool) -> int:
	var t := play.tile_at(play.z, x)
	var sh := (t >> 8) & 0xF
	if sh >= 2 and sh <= 5:
		return SkyRoads.BLOCK_TOP[sh]
	if sh == 1 and not in_tun:
		return 0                       # a plain tunnel casts onto the floor
	return SkyRoads.Y_DECK if (t & 0xF) else 0


## `view_x` / `view_y` are the interpolated position to draw at; they default
## to the simulated one. Only presentation uses them — the simulation is never
## fed an interpolated value.
func sync(play: SkyRoadsPlay, on_sticky: bool, view_x: int = -1,
		view_y: int = -1) -> void:
	if _ship_rect == null:
		return
	var px: int = view_x if view_x >= 0 else play.x
	var py: int = view_y if view_y >= 0 else play.y
	var tilt := _tilt(px)
	var alt: int = (py - 0x80 if on_sticky else py) / 0x80
	var left := float(px / 0x80 + SkyRoads.SHIP_PAN[tilt] - ORIGIN_X)
	var top := float(SCREEN_Y_BASE - alt)

	var tex: Texture2D = null
	if play.expl_ctr != 0:
		var e := play.expl_ctr / 3
		if e < SkyRoads.CARS_EXPLOSION_FRAMES:
			tex = _explosion[e]
	else:
		tex = _ship[_index(play, tilt)]
	_ship_rect.visible = tex != null
	if tex != null:
		_ship_rect.texture = tex
		_place(_ship_rect, left, top, SPRITE_W, SPRITE_H)

	# shadow: none while exploding, none with nothing underneath, and none
	# once the ship is high enough that the stencils run out
	_shadow_rect.visible = false
	if play.expl_ctr != 0 or _shadow_tex.is_empty():
		return
	var in_tun := play.in_tunnel(play.z, px, py)
	var g: int = maxi(_support(play, (px - 0x380) & 0xFFFF, in_tun),
		_support(play, (px + 0x380) & 0xFFFF, in_tun))
	if g == 0:
		return
	# the DOS remap (render.c draw_shadow:292-311) only darkens floor colours
	# 1..15 and the block side — a shadow cast onto a block TOP never shows,
	# and drawing one misleads about height while judging a jump
	var sh_l := (play.tile_at(play.z, (px - 0x380) & 0xFFFF) >> 8) & 0xF
	var sh_r := (play.tile_at(play.z, (px + 0x380) & 0xFFFF) >> 8) & 0xF
	if (sh_l >= 2 and sh_l <= 5) or (sh_r >= 2 and sh_r <= 5):
		return
	var clearance := (py - g) / 0x80
	if clearance < 0:
		return
	var map_index := clearance / 5
	if map_index >= _shadow_tex.size():
		return
	_shadow_rect.visible = true
	_shadow_rect.texture = _shadow_tex[map_index]
	_place(_shadow_rect, left, top + SHADOW_Y_OFFSET + clearance,
		SHADOW_W, SHADOW_H)
