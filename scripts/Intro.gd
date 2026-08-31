# The boot intro (fn_4575), in full.
#
# The port used to stop after the ANIM playback and fade to the menu, which is
# where the C reference stops too (game.c tick_intro blits intro.picts[0] and
# the anim records and nothing else). The retail binary keeps going for another
# twenty-odd seconds, and every asset for it was already exported and unused.
# What follows is the whole sequence with the address each timing came from:
#
#   tick   0   title picture, faded in over 36 ticks    fn_4b72 @0x4749
#   tick  24   INTRO.SND voice                          @0x476b
#   tick  61   ANIM playback, 2 ticks per frame         @0x47b1
#   +72        hold on the title                        fn_443d @0x4828
#   +18        the SkyRoads logo wiped in               @0x484a-0x48e3
#   +5/9/70    logo flashes white, then settles         @0x4938-0x4950
#   5 plates   each faded in 50, held 50, faded out 50  @0x49de-0x4a16
#
# Two things make this reproducible without a palette:
#
# * The animation ends ON the title picture — its 221 deltas composite to
#   within 4 pixels of the bare `intro_0` — so nothing needs restoring before
#   the wipe. The original relies on the same thing: fn_4162 @0x4818 points
#   the blitter's "background" at the title and the wipe fills from it.
# * Every fade here is fn_4315 interpolating the DAC between two palettes of
#   the SAME picture, and `lerp(A[v], B[v], t)` per pixel is exactly "draw the
#   A render, then the B render over it at alpha t". So the pictures are two
#   PNGs and the fade is a modulate. `tools/export_intro_palettes.py` writes
#   the A renders; it also verifies that re-rendering B reproduces the shipped
#   `intro_N.png` byte for byte, which is what makes the pairing trustworthy.
#
# Any key or tap skips the whole thing, as it always did.
class_name Intro
extends CanvasLayer

## `skipped` is the original's abort flag as fn_4575 returns it (@0x4aa5):
## false when the sequence ran all the way through untouched, which is what
## sends the shell to the attract demo instead of the menu.
signal done(skipped: bool)

enum Phase { TITLE, ANIM, HOLD, WIPE, FLASH, PLATES, OVER }

const SEQ_PATH := "res://data/gfx/intro_seq.json"

# AudioMgr, deliberately untyped: the parse suite loads scripts one at a time
# with a cold global-class cache, and a typed reference fails there.
var audio

var _t := 0.0
var _ticks := 0
var _phase: int = Phase.TITLE
## tick at which the current phase started, so each phase counts from 0
var _phase_at := 0
var _frames: Array = []
var _declared := 100
var _next := 0                  ## next delta record to blit
var _voiced := false
var _over := false

var _tm := {}                   ## timing, from intro_seq.json
var _picts := []                ## the logo and the plates, in order
var _plate := 0
## Which plate's textures are actually loaded. Tracked separately from
## `_plate` because a phase is entered on the tick that ENDS the previous
## one, so the first `_tick_plates` of a plate already sees `_at() == 1` and
## a setup keyed on `_at() == 0` never runs at all — which is exactly how the
## credits came out blank the first time.
var _plate_shown := -1

var _scene: Control             ## title + anim deltas
var _fade: ColorRect
var _wipe: Control
var _logo_dim: TextureRect
var _logo_white: TextureRect
var _logo_bright: TextureRect
var _plate_dim: TextureRect
var _plate_bright: TextureRect
var _logo_tex: Texture2D


func _ready() -> void:
	_load_seq()
	var ground := ColorRect.new()
	ground.color = Color.BLACK
	ground.position = Vector2.ZERO
	ground.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ground)

	# The animation's deltas go in here, so everything added afterwards draws
	# above them however many records have accumulated.
	_scene = Control.new()
	_scene.position = Vector2.ZERO
	_scene.size = ground.size
	_scene.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scene)
	_place(_scene, "res://data/gfx/intro_0.png", Vector2.ZERO)

	_wipe = Control.new()
	_wipe.position = Vector2.ZERO
	_wipe.size = ground.size
	_wipe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wipe.draw.connect(_draw_wipe)
	_wipe.visible = false
	add_child(_wipe)

	if not _picts.is_empty():
		var logo: Dictionary = _picts[0]
		_logo_tex = _tex("res://data/gfx/%s" % logo["file"])
		_logo_dim = _layer(_tex("res://data/gfx/%s" % logo["dim"]), logo)
		_logo_white = _layer(_white_of(_logo_tex), logo)
		_logo_bright = _layer(_logo_tex, logo)
	_plate_dim = _layer(null, {})
	_plate_bright = _layer(null, {})

	# topmost: the palette fade-in the original opens on
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 1)
	_fade.position = Vector2.ZERO
	_fade.size = ground.size
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)


func _load_seq() -> void:
	var f := FileAccess.open(SEQ_PATH, FileAccess.READ)
	if f != null:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			_tm = d.get("timing", {})
			_picts = d.get("picts", [])
	f = FileAccess.open("res://data/gfx/anim/anim.json", FileAccess.READ)
	if f != null:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			_frames = d.get("frames", [])
			_declared = int(d.get("declared_frames", 100))


## A timing constant from intro_seq.json, with the binary's own value as the
## fallback so the intro still runs if the export is missing.
func _ms(key: String, fallback: int) -> int:
	return int(_tm.get(key, fallback))


func _tex(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null


## The same picture with every opaque pixel white — the middle of the logo's
## flash, where fn_4315 interpolates toward a palette fn_5c92 filled with 0x3f.
func _white_of(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var img := tex.get_image()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.0:
				img.set_pixel(x, y, Color(1, 1, 1, c.a))
	return ImageTexture.create_from_image(img)


## A full-screen-positioned picture layer, hidden and transparent to start.
func _layer(tex: Texture2D, spec: Dictionary) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.visible = false
	if not spec.is_empty():
		_position(tr, spec)
	add_child(tr)
	return tr


func _position(tr: TextureRect, spec: Dictionary) -> void:
	tr.position = Vector2(float(spec["screen_x"]),
		float(spec["screen_y"]) * SkyRoads.PIXEL_ASPECT)
	tr.size = Vector2(float(spec["w"]),
		float(spec["h"]) * SkyRoads.PIXEL_ASPECT)


func _place(parent: Control, path: String, pos: Vector2) -> void:
	var tex := _tex(path)
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.position = Vector2(pos.x, pos.y * SkyRoads.PIXEL_ASPECT)
	tr.size = Vector2(tex.get_width(),
		tex.get_height() * SkyRoads.PIXEL_ASPECT)
	parent.add_child(tr)


func _process(delta: float) -> void:
	if _over:
		return
	_t += delta * SkyRoads.TICK_HZ
	while _ticks < int(_t) and not _over:
		_ticks += 1
		_tick()


func _enter(phase: int) -> void:
	_phase = phase
	_phase_at = _ticks


## Ticks spent in the current phase.
func _at() -> int:
	return _ticks - _phase_at


func _tick() -> void:
	# the title's fade-in runs across the first phases, independently of them
	var fade_ticks := _ms("title_fade", 0x24)
	if _ticks <= fade_ticks and _fade != null:
		_fade.color.a = 1.0 - float(_ticks) / float(maxi(fade_ticks, 1))
	if _ticks == _ms("voice_tick", 0x18) and not _voiced:
		_voiced = true
		if audio != null:
			audio.voice()
	match _phase:
		Phase.TITLE:
			if _ticks >= _ms("anim_start_tick", 0x18 + 0x25):
				_enter(Phase.ANIM)
		Phase.ANIM:
			_tick_anim()
		Phase.HOLD:
			if _at() >= _ms("anim_hold", 0x48):
				_enter(Phase.WIPE)
				_wipe.visible = true
		Phase.WIPE:
			_tick_wipe()
		Phase.FLASH:
			_tick_flash()
		Phase.PLATES:
			_tick_plates()


func _tick_anim() -> void:
	var frame := _at() / maxi(_ms("anim_ticks_per_frame", 2), 1)
	while _next < _frames.size() and int(_frames[_next]["frame"]) <= frame:
		var rec: Dictionary = _frames[_next]
		_place(_scene, "res://data/gfx/anim/%s" % rec["file"],
			Vector2(rec["screen_x"], rec["screen_y"]))
		_next += 1
	# the original's loop ends when the record list does; the declared frame
	# count is how far the playback clock has to run for the last of them
	if _next >= _frames.size() and frame >= _declared - 1:
		_enter(Phase.HOLD)


func _tick_wipe() -> void:
	if _at() >= _ms("wipe_ticks", 0x12):
		_wipe.visible = false
		if _logo_dim != null:
			_logo_dim.visible = true
			_logo_dim.modulate.a = 1.0
		_enter(Phase.FLASH)
		return
	_wipe.queue_redraw()


## Columns still showing the background. fn_4575 @0x484a:
##   L = 319 - (319 * frames / 18), floored at 0.
func _wipe_left() -> int:
	var cols := _ms("wipe_columns", 0x13f)
	var span := maxi(_ms("wipe_ticks", 0x12), 1)
	return maxi(cols - int(cols * _at() / span), 0)


## The curtain. fn_4184 is called twice per iteration with the row pair's
## lead/trail swapped (@0x489b even rows, @0x48ad odd), so even rows slide the
## logo in from the left and odd rows from the right, meeting when L hits 0.
func _draw_wipe() -> void:
	var dim: Texture2D = null
	if _logo_dim != null:
		dim = _logo_dim.texture
	if dim == null or _picts.is_empty():
		return
	var spec: Dictionary = _picts[0]
	var top: float = float(spec["screen_y"]) * SkyRoads.PIXEL_ASPECT
	var w: int = int(spec["w"])
	var h: int = int(spec["h"])
	var left := _wipe_left()
	var shown := w - left
	if shown <= 0:
		return
	for row in h:
		var src_x := 0.0 if row % 2 == 0 else float(left)
		var dst_x := float(left) if row % 2 == 0 else 0.0
		_wipe.draw_texture_rect_region(dim,
			Rect2(dst_x, top + float(row) * SkyRoads.PIXEL_ASPECT,
				float(shown), SkyRoads.PIXEL_ASPECT),
			Rect2(src_x, float(row), float(shown), 1.0))


func _tick_flash() -> void:
	var a := _ms("flash_in", 5)
	var hold := _ms("flash_hold", 9)
	var b := _ms("flash_out", 0x46)
	var t := _at()
	if _logo_white == null or _logo_bright == null:
		_enter(Phase.PLATES)
		return
	if t <= a:
		_logo_white.visible = true
		_logo_white.modulate.a = float(t) / float(maxi(a, 1))
	elif t <= a + hold:
		_logo_white.modulate.a = 1.0
	elif t <= a + hold + b:
		_logo_bright.visible = true
		_logo_bright.modulate.a = float(t - a - hold) / float(maxi(b, 1))
	else:
		_logo_bright.modulate.a = 1.0
		_logo_white.visible = false
		_plate = 0
		_enter(Phase.PLATES)


func _tick_plates() -> void:
	var span_in := _ms("plate_in", 0x32)
	var hold := _ms("plate_hold", 0x32)
	var span_out := _ms("plate_out", 0x32)
	if _plate + 1 >= _picts.size():
		_finish()
		return
	var spec: Dictionary = _picts[_plate + 1]
	if _plate_shown != _plate:
		_plate_shown = _plate
		_plate_dim.texture = _tex("res://data/gfx/%s" % spec["dim"])
		_plate_bright.texture = _tex("res://data/gfx/%s" % spec["file"])
		_position(_plate_dim, spec)
		_position(_plate_bright, spec)
		_plate_dim.visible = true
		_plate_dim.modulate.a = 1.0
		_plate_bright.visible = true
		_plate_bright.modulate.a = 0.0
	var t := _at()
	if t <= span_in:
		_plate_bright.modulate.a = float(t) / float(maxi(span_in, 1))
	elif t <= span_in + hold:
		_plate_bright.modulate.a = 1.0
	elif t <= span_in + hold + span_out:
		_plate_bright.modulate.a = \
			1.0 - float(t - span_in - hold) / float(maxi(span_out, 1))
	else:
		# fn_4aaf's erase: the plate goes back to the background entirely
		_plate_bright.visible = false
		_plate_dim.visible = false
		_plate += 1
		# end on the last plate rather than entering the phase once more with
		# an index that has nothing behind it
		if _plate + 1 >= _picts.size():
			_finish()
		else:
			_enter(Phase.PLATES)


func handle_input(ev: InputEvent) -> void:
	# any key skips the intro (fn_4137 sets the abort flag on any key while
	# the intro has it armed); on a phone, so does any tap
	if ev is InputEventKey and ev.pressed and not ev.echo:
		_finish(true)
	elif ev is InputEventScreenTouch and (ev as InputEventScreenTouch).pressed:
		_finish(true)


func _finish(skipped := false) -> void:
	if _over:
		return
	_over = true
	_phase = Phase.OVER
	done.emit(skipped)
