# The menu system, following the screen graph recovered from SKYROADS.EXE.
#
#   intro -> mainmenu -> gomenu -> game -> roadend -> gomenu
#                     -> setmenu
#                     -> help
#
# Every screen is a full-frame image from the original with small overlays
# blitted at the offsets the EXE used, so the layout is the game's own rather
# than a reconstruction. Navigation matches the original exactly:
#
#   main menu   up/down over 3 boxes, Enter selects, Esc quits
#   road select up/down +-1 clamped 0..29, left/right +-15 (column swap)
#   settings    left/right over 5 items, up/down hops control row <-> sound row
#   help        Enter pages through 3 screens, then back to the main menu
#
# Idle on the main menu for 10 seconds and the attract demo starts, exactly as
# the original does.
class_name Menu
extends CanvasLayer

signal start_road(index: int)
signal start_demo
signal quit_game

## Kept as an alias so callers (Main, the capture paths, the tests) keep
## naming screens the same way after the state machine moved to MenuModel.
const Screen := MenuModel.Screen

## fn_5064: the road-name cell is 48x9 at 0xF3E = (62,12), +9 rows per road,
## +39 rows per world, and the right-hand column is +0xA0 = 160 px across.
const GO_BASE := Vector2i(62, 12)
const GO_ROAD_PITCH := 9
const GO_WORLD_PITCH := 39
const GO_COLUMN := 160
## fn_5164: completion ticks start at 0x11F0 = (112,14), 7 px apart, max 7.
const TICK_BASE := Vector2i(112, 14)
const TICK_PITCH := 7
const TICK_MAX := 7

## Every navigation decision lives in MenuModel, which is a transcription of
## game.c and is diffed against the C engine by test_menu.gd. This class only
## draws what the model holds, and the properties below forward to it so the
## rest of the shell keeps its existing vocabulary.
var model := MenuModel.new()
var cfg: Config

var screen: int:
	get: return model.screen
	set(v): model.screen = v
var main_sel: int:
	get: return model.main_sel
	set(v): model.main_sel = v
var go_sel: int:
	get: return model.go_sel
	set(v): model.go_sel = v
var set_sel: int:
	get: return model.set_sel
	set(v): model.set_sel = v
var help_page: int:
	get: return model.help_page
	set(v): model.help_page = v

## Set by Main: wraps a screen switch in the palette fade the original does
## on every state change (game.c fade_to). Unset (e.g. menu screenshots),
## switches are instant.
var fader: Callable

var _tex_cache := {}
## fractional ticks carried between frames, so the attract countdown does not
## drift with the frame rate
var _idle := 0.0
var _sprites: Array[TextureRect] = []
var _bg: TextureRect
var _overlay: Control


## SETMENU ships ten overlays sharing one 3-colour CMAP: picts 1-5 outline
## each item in white, 6-10 in orange. game.c:257-260 blits the base pict
## plus EXACTLY ONE of them, picts[1 + sel] — so the white outline is the
## cursor and the orange set is never used. Items 0-2 are the control device,
## 3-4 the sound setting; the screen shows no current-state feedback at all,
## which is the original's own behaviour, not an omission here.
const SET_CURSOR_FIRST := 1

var _gfx: Dictionary = {}

## GOMENU pict 0 as palette INDICES plus the 256-entry palette the original
## builds for it. The road-select highlight is a palette remap, not an
## overlay (game.c:147-155), and an RGB png cannot express it.
var _go_idx: PackedByteArray = PackedByteArray()
var _go_pal: Array = []
var _go_w := 0
var _go_h := 0
var _go_hi := {}                ## go_sel -> brightened 48x9 ImageTexture


func _ready() -> void:
	if cfg == null:
		cfg = Config.new()
	var gf := FileAccess.open("res://data/gfx/gfx.json", FileAccess.READ)
	if gf != null:
		_gfx = (JSON.parse_string(gf.get_as_text()) as Dictionary)["files"]
	# A CanvasLayer is not a Control, so anchor presets inside it resolve
	# against nothing and every child collapses. Size everything explicitly in
	# the original's 320x240 display space instead.
	var canvas := Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	# Every DOS menu starts with sr_fb_clear(fb, 0), so index 0 is BLACK, not
	# see-through. The exports carry index 0 as alpha 0 (INTRO.LZS alone has
	# 15109 such pixels), and without something opaque behind them Godot's
	# own grey clear colour showed through — the main menu's night sky came
	# out mottled grey.
	var ground := ColorRect.new()
	ground.name = "Ground"
	ground.color = Color(0, 0, 0, 1)
	ground.position = Vector2.ZERO
	ground.size = canvas
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ground)
	_bg = TextureRect.new()
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bg.position = Vector2.ZERO
	_bg.size = canvas
	add_child(_bg)
	_overlay = Control.new()
	_overlay.position = Vector2.ZERO
	_overlay.size = canvas
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	# how many help screens there are is data, not a constant: the C engine
	# pages until it runs out of HELPMENU picts (game.c:268)
	var pages: int = (_gfx.get("helpmenu", []) as Array).size()
	if pages > 0:
		model.help_pages = pages
	_load_gomenu_index()
	_show()


## Optional: without it the selection falls back to an outline rectangle.
func _load_gomenu_index() -> void:
	var f := FileAccess.open("res://data/gfx/gomenu_index.json", FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary):
		return
	_go_w = int(d.get("width", 0))
	_go_h = int(d.get("height", 0))
	_go_pal = d.get("palette", [])
	_go_idx = Marshalls.base64_to_raw(str(d.get("pixels", "")))
	if _go_idx.size() < _go_w * _go_h or _go_pal.size() < 256:
		_go_idx = PackedByteArray()          # unusable; keep the fallback


## The selected road's name cell with the original's brighten applied:
## every pixel of index >= 0x63 becomes 240 + (p & 7) (game.c:147-155).
func _highlight_tex(sel: int) -> ImageTexture:
	if _go_hi.has(sel):
		return _go_hi[sel]
	var c := road_cell(sel)
	var img := Image.create(48, 9, false, Image.FORMAT_RGBA8)
	for y in 9:
		for x in 48:
			var sx: int = c.x + x
			var sy: int = c.y + y
			if sx < 0 or sy < 0 or sx >= _go_w or sy >= _go_h:
				continue
			var p: int = _go_idx[sy * _go_w + sx]
			if p == 0:
				continue                      # index 0 is transparent
			if p >= 0x63:
				p = 240 + (p & 7)
			var e: Array = _go_pal[p]
			img.set_pixel(x, y, Color8(e[0], e[1], e[2]))
	var tex := ImageTexture.create_from_image(img)
	_go_hi[sel] = tex
	return tex


## The original's 320x200 screen is displayed at 4:3. Everything here is placed
## in those original coordinates and scaled by the same 1.2 the camera uses, so
## menu overlays and gameplay share one coordinate system.
func _to_canvas(p: Vector2) -> Vector2:
	return Vector2(p.x, p.y * SkyRoads.PIXEL_ASPECT)


## Put an image where its PICT says it belongs, in display space.
func _place(file: String, name: String) -> void:
	var tex := _tex(name)
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.position = _to_canvas(_gfx_pos(file, name))
	tr.size = Vector2(tex.get_width(),
		tex.get_height() * SkyRoads.PIXEL_ASPECT)
	add_child(tr)
	_sprites.append(tr)


## Textures are cached because a texture first load()ed INSIDE a draw
## handler renders as a plain white rectangle — its RID is not ready for the
## frame already being built. The road-select completion ticks were drawn
## that way and came out as white blocks instead of the original's small
## amber pips. Anything reached from _draw_overlay must be resolved here
## first, outside the draw pass.
func _tex(name: String) -> Texture2D:
	if _tex_cache.has(name):
		return _tex_cache[name]
	var t: Texture2D = load("res://data/gfx/%s.png" % name)
	_tex_cache[name] = t
	return t


func _show() -> void:
	match screen:
		Screen.MAIN:
			_bg.texture = _tex("intro_0")
		Screen.GO:
			_bg.texture = _tex("gomenu_0")
		Screen.SETTINGS:
			_bg.texture = _tex("setmenu_0")
		Screen.HELP:
			_bg.texture = _tex("helpmenu_%d" % help_page)
	for c in _sprites:
		c.queue_free()
	_sprites.clear()
	if screen == Screen.GO:
		_tex("gomenu_1")             # the tick pip, drawn from _draw_overlay
	if screen == Screen.SETTINGS:
		# exactly one overlay, the outline round the selected item
		# (game.c:259-260)
		_place("setmenu", "setmenu_%d" % (SET_CURSOR_FIRST + set_sel))
	elif screen == Screen.MAIN:
		_place("mainmenu", "mainmenu_%d" % main_sel)
	_overlay.queue_redraw()


## Screen offset of road `rd`'s name cell (fn_5064).
static func road_cell(rd: int) -> Vector2i:
	var p := GO_BASE
	p.y += ((rd % 15) / 3) * GO_WORLD_PITCH + (rd % 3) * GO_ROAD_PITCH
	if rd >= 15:
		p.x += GO_COLUMN
	return p


func _draw_overlay() -> void:
	match screen:
		Screen.MAIN:
			pass                          # the box is placed as a node
		Screen.GO:
			var tick := _tex("gomenu_1")
			for rd in 30:
				var n: int = mini(cfg.completions[rd], TICK_MAX)
				var base := TICK_BASE
				base.y += ((rd % 15) / 3) * GO_WORLD_PITCH + (rd % 3) * GO_ROAD_PITCH
				if rd >= 15:
					base.x += GO_COLUMN
				for t in n:
					_overlay.draw_texture_rect(tick, Rect2(
						_to_canvas(Vector2(base.x + t * TICK_PITCH, base.y)),
						Vector2(6, 5 * SkyRoads.PIXEL_ASPECT)), false)
			# selection: the name cell redrawn through the brightening
			# remap, exactly where it already sits (game.c:147-155)
			var c := road_cell(go_sel)
			if not _go_idx.is_empty():
				_overlay.draw_texture_rect(_highlight_tex(go_sel),
					Rect2(_to_canvas(Vector2(c.x, c.y)),
					Vector2(48, 9 * SkyRoads.PIXEL_ASPECT)), false)
			else:
				_overlay.draw_rect(Rect2(_to_canvas(Vector2(c.x - 1, c.y - 1)),
					Vector2(50, 11 * SkyRoads.PIXEL_ASPECT)),
					Color(1, 1, 1, 0.35), false, 1.0)
		Screen.SETTINGS:
			pass                          # the cursor is the overlay pict
		Screen.HELP:
			pass


func _gfx_pos(file: String, name: String) -> Vector2:
	for e in _gfx.get(file, []):
		if e["file"] == name + ".png":
			return Vector2(e["screen_x"], e["screen_y"])
	return Vector2.ZERO


func handle_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo):
		return
	var key := MenuModel.key_from_event((ev as InputEventKey).keycode)
	if key < 0:
		return                       # a key the shell does not use
	var was := model.screen
	model.step([key])
	if model.settings_dirty:
		# the model never touches the filesystem; persisting is the view's job
		cfg.control = model.control
		cfg.sound_off = 1 if model.sound_off else 0
		cfg.save_file()
		model.settings_dirty = false
	match model.exit:
		MenuModel.Exit.QUIT:
			model.clear_exit()
			quit_game.emit()
			return
		MenuModel.Exit.PLAY:
			var road := model.road_entry
			model.clear_exit()
			start_road.emit(road)
			return
		MenuModel.Exit.DEMO:
			model.clear_exit()
			start_demo.emit()
			return
	if model.screen != was:
		# a screen change is the one transition the original fades through
		var target := model.screen
		model.screen = was
		_change_screen(target)
		return
	_show()


func _change_screen(s: int) -> void:
	if fader.is_valid():
		fader.call(func() -> void:
			model.screen = s
			_show())
	else:
		model.screen = s
		_show()


## The attract demo is counted in TICKS by the original (game.c:200), so real
## time is converted rather than compared against a float deadline — a frame
## rate change must not move when the demo starts.
func _process(delta: float) -> void:
	if model.screen != Screen.MAIN or model.exit != MenuModel.Exit.NONE:
		return
	_idle += delta * SkyRoads.TICK_HZ
	var due := int(_idle)
	if due <= 0:
		return
	_idle -= float(due)
	model.advance(due)
	if model.exit == MenuModel.Exit.DEMO:
		model.clear_exit()
		start_demo.emit()
