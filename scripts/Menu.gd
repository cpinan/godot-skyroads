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
# The main menu does NOT start the attract demo on an idle timer. Sitting
# through the whole intro is the only way to reach it: main @0x021e calls the
# intro and branches on its return, 0 (nobody touched a key) setting the demo
# state and non-zero opening this menu. See Main._end_intro and BUGS §11.11 —
# the ten-second timer was the C reference's invention and this comment was
# the last thing still claiming it.
class_name Menu
extends CanvasLayer

signal start_road(index: int)
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

## Set by Main on a phone. Two effects, both here rather than in the model:
## taps navigate (there is no keyboard to press Enter on), and the settings
## screen's three control-device items are dimmed, because the device is the
## touchscreen and nothing on that row can change it.
var touch_ui: bool:
	get: return model.touch_ui
	set(v): model.touch_ui = v

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
var _sprites: Array[TextureRect] = []
var _bg: TextureRect
var _overlay: Control


## SETMENU ships ten overlays sharing one 3-colour CMAP: picts 1-5 outline
## each item in white, 6-10 in orange. Items 0-2 are the control device, 3-4
## the sound setting.
##
## What is drawn here is the white cursor alone, picts[1 + sel], because that
## is what the C reference does (game.c:257-260) — and it is INCOMPLETE. The
## retail EXE's fn_4ae2 also paints the ORANGE overlay over the item that is
## currently active (control device, sound state) and erases it from the
## others, so the original's screen tells the player what is selected. The
## port does not; that is BUGS §11. Do not "confirm" this against the
## goldens — they came from the same C reference and are missing the same
## thing.
const SET_CURSOR_FIRST := 1
## picts 6..10 — the orange set, one per item, drawn for the setting that is
## currently in force rather than for the cursor.
const SET_STATE_FIRST := 6

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
	# Nothing in a menu is a widget: every screen is a picture and the
	# navigation is the shell's. Letting a TextureRect claim pointer events
	# would make taps land on the art instead of reaching handle_input.
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_overlay = Control.new()
	_overlay.position = Vector2.ZERO
	_overlay.size = canvas
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	# How many help screens there are is NOT the pict count. The C engine
	# pages until HELPMENU.LZS runs out (game.c:268) and the file holds three
	# full screens, but the retail binary shows two: fn_4e12 @0x4e21 calls
	# fn_4dac once and then a second time only if the key was not ESC, and
	# then returns. helpmenu_2 is art the 1993 game never displays, like
	# INTRO.LZS's "Highscore" plate. Take the smaller of the two.
	var pages: int = (_gfx.get("helpmenu", []) as Array).size()
	if pages > 0:
		model.help_pages = mini(pages, MenuModel.HELP_PAGES)
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
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tr)
	_sprites.append(tr)


## Textures are cached because a texture first load()ed INSIDE a draw
## handler renders as a plain white rectangle — its RID is not ready for the
## frame already being built. The road-select completion ticks were drawn
## that way and came out as white blocks instead of the original's small
## amber pips. Anything reached from _draw_overlay must be resolved here
## first, outside the draw pass.
## The hint lines painted into the retail full-screen menus, as (first row,
## last row) in the original's 200-row space. Found by looking for bright-pixel
## spikes in the lower third of each picture and reading the crops.
const TOUCH_HINT_BANDS := {
	"setmenu": [[176, 190]],                          # "Press Esc to exit menu"
	"helpmenu": [[164, 194]],                         # ESC to exit / SPACE for next
}
## Columns to take replacement background from. The retail wording is centred,
## so the left margin of the SAME ROW is always background — which beats
## copying a band from elsewhere in the picture, because the row keeps its own
## lighting and there is no clean band to find anyway (the first attempt tiled
## fragments of the help text back over itself).
const TOUCH_HINT_MARGIN := 40
## What the port draws instead, once the retail wording is covered.
const TOUCH_HINT_TEXT := {
	# was "TAP OUTSIDE TO GO BACK", which stopped being true when a missed
	# tap became inert -- see _keys_for_tap. The X is the way out now, on this
	# screen as on the other two.
	"setmenu": ["TAP THE X TO GO BACK"],
	"helpmenu": ["TAP TO TURN THE PAGE"],
}


func _tex(name: String) -> Texture2D:
	var key := name + ("!touch" if touch_ui else "")
	if _tex_cache.has(key):
		return _tex_cache[key]
	var t: Texture2D = load("res://data/gfx/%s.png" % name)
	if touch_ui and t != null:
		t = _without_key_hints(name, t)
	_tex_cache[key] = t
	return t


## A phone has no Esc and no space bar, so the retail hint lines are simply
## wrong there. They are painted into the 320x200 pictures, so they are covered
## with background copied from a CLEAN BAND OF THE SAME PICTURE — the
## backgrounds are mottled noise, so a copied band tiles invisibly — and the
## port writes its own touch wording over the top in the game's 8x8 font.
##
## Nothing on disk is touched and no art is forked: this builds one derived
## texture in memory, only on Android and iOS, and only for the two pictures
## that carry the wording. The desktop build never reaches it.
func _without_key_hints(name: String, tex: Texture2D) -> Texture2D:
	var family := name.split("_")[0]
	var bands: Array = TOUCH_HINT_BANDS.get(family, [])
	if bands.is_empty():
		return tex
	var img := tex.get_image()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	for band in bands:
		var y0: int = band[0]
		var y1: int = band[1]
		for y in range(y0, mini(y1 + 1, img.get_height())):
			for x in w:
				if x < TOUCH_HINT_MARGIN:
					continue          # already background; leave it alone
				img.set_pixel(x, y, img.get_pixel(x % TOUCH_HINT_MARGIN, y))
	var out := ImageTexture.create_from_image(img)
	var lines: Array = TOUCH_HINT_TEXT.get(family, [])
	if not lines.is_empty():
		_stamp_text(img, lines[0], int(bands[0][0]) + 3)
		out = ImageTexture.create_from_image(img)
	return out


## Draw one line of 8x8 text straight into the picture, centred. Done here
## rather than as a separate node so the replacement lives in exactly the same
## place in the draw order as the wording it replaces.
func _stamp_text(img: Image, text: String, y: int) -> void:
	var x0 := int((SkyRoads.SCREEN_W - Text8x8.width(text)) / 2)
	for i in text.length():
		var g: Array = Text8x8.glyph_rows(text.unicode_at(i))
		for row in g.size():
			var bits: int = g[row]
			for col in 8:
				if bits & (1 << col):
					var px := x0 + i * 8 + col
					var py := y + row
					if px >= 0 and px < img.get_width() \
							and py >= 0 and py < img.get_height():
						img.set_pixel(px, py, Color(0.83, 0.83, 0.72))


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
		# The ORANGE overlays first: fn_4ae2 @0x4ae2 walks all five items and
		# calls fn_4aaf(i + 5, mode) with mode 1 where `i` is the cfg's
		# control device or its sound flag + 3, and 0xff everywhere else.
		# fn_41e5's threshold blit (@0x41cb: below the transparency byte the
		# pixel is skipped, below the threshold it is erased back to the base
		# picture, at or above it it is drawn) makes mode 1 DRAW and mode 0xff
		# ERASE. Objects 5..9 are picts 6..10, the orange set. So the original
		# marks the settings currently in force and this used to show nothing.
		for i in MenuModel.SETTINGS_ITEMS:
			if _state_marked(i):
				_place("setmenu", "setmenu_%d" % (SET_STATE_FIRST + i))
		# then the white outline, the moving cursor, over the top
		# (game.c:259-260)
		_place("setmenu", "setmenu_%d" % (SET_CURSOR_FIRST + set_sel))
	elif screen == Screen.MAIN:
		# The SkyRoads logo. fn_4e36 @0x4f06 blits INTRO.LZS pict 1 (320x54 at
		# y=32) over the title picture before it ever draws an item box, with
		# fn_4162's transparency byte 0 and threshold 1 — a plain
		# index-0-transparent blit, so the whole logo lands. The port drew the
		# title and the boxes and nothing between them, which left the menu
		# with no game name on it at all.
		_place("intro", "intro_1")
		_place("mainmenu", "mainmenu_%d" % main_sel)
	_overlay.queue_redraw()


## Screen offset of road `rd`'s name cell (fn_5064).
static func road_cell(rd: int) -> Vector2i:
	var p := GO_BASE
	p.y += ((rd % 15) / 3) * GO_WORLD_PITCH + (rd % 3) * GO_ROAD_PITCH
	if rd >= 15:
		p.x += GO_COLUMN
	return p


## A phone has no Esc key, so the two screens Esc would leave need a way out on
## screen: the main menu closes the app, the road select goes back to it. Both
## are exactly what Key.ESCAPE already does (MenuModel sets Exit.QUIT on MAIN
## and Screen.MAIN on GO), so the button raises that key rather than inventing
## a second way to navigate.
##
## Top right, clear of everything: the main menu's item box is at (127,128) and
## the road grid's right column ends at x=270.
const TOUCH_CLOSE_RECT := Rect2(298, 3, 18, 14)


func _close_rect() -> Rect2:
	return Rect2(_to_canvas(TOUCH_CLOSE_RECT.position),
		_to_canvas(TOUCH_CLOSE_RECT.size))


func _draw_close_button() -> void:
	if not touch_ui:
		return
	var r := _close_rect()
	var c := Color(0.83, 0.83, 0.72)
	_overlay.draw_rect(r, c, false, 1.0)
	var pad := Vector2(5.0, 5.0)
	_overlay.draw_line(r.position + pad, r.end - pad, c, 1.0)
	_overlay.draw_line(Vector2(r.end.x - pad.x, r.position.y + pad.y),
		Vector2(r.position.x + pad.x, r.end.y - pad.y), c, 1.0)


func _draw_overlay() -> void:
	match screen:
		Screen.MAIN:
			_draw_close_button()          # the box is placed as a node
		Screen.GO:
			_draw_close_button()
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
			# SETTINGS used to be left by tapping anywhere that was not an
			# item, which is the same behaviour that made the road select
			# unusable; now that a miss is inert it needs the same visible way
			# out the other two screens have.
			_draw_close_button()
			# the cursor is the overlay pict; on a phone the three items the
			# cursor can no longer reach are dimmed so the screen says why
			if touch_ui:
				for i in MenuModel.SETTINGS_SOUND_FIRST:
					_overlay.draw_rect(_item_rect(i), Color(0, 0, 0, 0.72),
						true)
		Screen.HELP:
			pass


func _gfx_pos(file: String, name: String) -> Vector2:
	for e in _gfx.get(file, []):
		if e["file"] == name + ".png":
			return Vector2(e["screen_x"], e["screen_y"])
	return Vector2.ZERO


## An overlay pict's rectangle in canvas space. The picts are the original's
## own outlines around each item, so their offsets and sizes ARE the item
## layout — no screen coordinates need inventing for touch or for dimming.
func _gfx_rect(file: String, name: String) -> Rect2:
	for e in _gfx.get(file, []):
		if e["file"] == name + ".png":
			return Rect2(_to_canvas(Vector2(e["screen_x"], e["screen_y"])),
				Vector2(float(e["w"]), float(e["h"]) * SkyRoads.PIXEL_ASPECT))
	return Rect2()


## Is settings item `i` the setting currently in force? fn_4ae2's test,
## verbatim: the control device for items 0-2, the sound flag for 3-4. On a
## phone the control row is dimmed and the device is the touchscreen, so
## marking one of those three would point at something that is not true.
func _state_marked(i: int) -> bool:
	if cfg == null:
		return false
	if i < MenuModel.SETTINGS_SOUND_FIRST:
		return not touch_ui and i == cfg.control
	return i == MenuModel.SETTINGS_SOUND_FIRST + cfg.sound_off


## Settings item `i` (0-2 control device, 3-4 sound), from setmenu pict 1+i.
func _item_rect(i: int) -> Rect2:
	return _gfx_rect("setmenu", "setmenu_%d" % (SET_CURSOR_FIRST + i))


## Main-menu item `i`. The three mainmenu picts share one 68x57 box — they
## highlight a row inside it rather than moving — so the rows are that box
## split three ways.
func _main_item_rect(i: int) -> Rect2:
	var box := _gfx_rect("mainmenu", "mainmenu_0")
	var h := box.size.y / float(MenuModel.MAIN_ITEMS)
	return Rect2(box.position + Vector2(0, h * i), Vector2(box.size.x, h))


## Which shell key a tap at `p` (canvas space) means, plus any selection it
## implies. Returns [] for a tap that means nothing on this screen.
##
## Selecting and confirming are one gesture everywhere except the road list,
## where a tap only moves the cursor and a second tap on the SAME road
## starts it: thirty small cells and an instant launch is a bad combination
## on a phone.
func _keys_for_tap(p: Vector2) -> Array:
	# the close button is the same key Esc raises, and it is checked first so
	# it always wins over whatever it happens to sit above
	if touch_ui and screen != Screen.HELP and _close_rect().has_point(p):
		return [MenuModel.Key.ESCAPE]
	match screen:
		Screen.MAIN:
			for i in MenuModel.MAIN_ITEMS:
				if _main_item_rect(i).has_point(p):
					model.main_sel = i
					return [MenuModel.Key.ENTER]
			return []
		Screen.GO:
			for rd in MenuModel.ROAD_COUNT:
				var c := road_cell(rd)
				# The DRAWN cell is 48 x 9; the TOUCH target is the full row
				# pitch and the full column, so the gaps between rows belong to
				# the nearest road instead of to nothing. A finger is about 40
				# device pixels across and the drawn cell is 22 tall.
				var r := Rect2(_to_canvas(Vector2(c.x, c.y)),
					Vector2(48, 9 * SkyRoads.PIXEL_ASPECT))
				if touch_ui:
					r = Rect2(_to_canvas(Vector2(c.x - 4, c.y - 1)),
						Vector2(GO_COLUMN - 8,
							GO_ROAD_PITCH * SkyRoads.PIXEL_ASPECT))
				if r.has_point(p):
					if rd == go_sel:
						return [MenuModel.Key.ENTER]
					model.go_sel = rd
					_show()
					return []
			# A tap that hits no road does NOTHING. It used to return ESCAPE,
			# which closed the road select — and since a cell is 48x11 canvas
			# pixels, most of this screen is not a cell, so on a phone the
			# common outcome of trying to pick a road was leaving the screen.
			# The close button is how you leave; reported from a Pixel 10 Pro.
			return []
		Screen.SETTINGS:
			for i in MenuModel.SETTINGS_ITEMS:
				if not _item_rect(i).has_point(p):
					continue
				if i < model.settings_first_item():
					return []         # a dimmed item is inert, not a way out
				model.set_sel = i
				return [MenuModel.Key.ENTER]
			return []                     # same rule as GO, same reason
		Screen.HELP:
			return [MenuModel.Key.ENTER]
	return []


func handle_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var key := MenuModel.key_from_event((ev as InputEventKey).keycode)
		if key < 0:
			return                   # a key the shell does not use
		_apply([key])
	elif touch_ui and ev is InputEventScreenTouch \
			and (ev as InputEventScreenTouch).pressed:
		var p: Vector2 = _overlay.get_global_transform().affine_inverse() \
			* (ev as InputEventScreenTouch).position
		var keys := _keys_for_tap(p)
		if not keys.is_empty():
			_apply(keys)


## One shell tick with `keys` pressed, plus everything the view owes the
## model afterwards: persisting settings, acting on an exit, and fading a
## screen change. Shared by the keyboard and the touch paths so a tap and a
## keypress can never diverge.
func _apply(keys: Array) -> void:
	var was := model.screen
	var was_page := model.help_page
	model.step(keys)
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
	if model.screen != was:
		# a screen change is the one transition the original fades through
		var target := model.screen
		model.screen = was
		_change_screen(target)
		return
	if model.screen == Screen.HELP and model.help_page != was_page:
		# Each help page is its own fn_4dac call: fade in over 36 ticks
		# (@0x4dd8), wait for a key, fade out over 36 (@0x4ded). So turning a
		# page fades exactly as entering the screen does — the port used to
		# flip help pages instantly.
		var page := model.help_page
		model.help_page = was_page
		_change_help_page(page)
		return
	_show()


func _change_help_page(page: int) -> void:
	if fader.is_valid():
		fader.call(func() -> void:
			model.help_page = page
			_show())
	else:
		model.help_page = page
		_show()


func _change_screen(s: int) -> void:
	if fader.is_valid():
		fader.call(func() -> void:
			model.screen = s
			_show())
	else:
		model.screen = s
		_show()


# No _process. The retail menus have no clock in them at all: fn_5fad is a
# blocking `int 21h ah=7`, so a menu cannot time out and cannot start the
# attract demo. That is Main's job now, off the end of an unskipped intro —
# BUGS §11.11.
