# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# The menu's ART: where each retail picture goes, and what has to be done to it.
#
# Split out of Menu.gd, which was 629 lines holding this, the screen state, the
# hit testing, the drawing and the input. None of what is here decides
# anything — it answers "what does this picture look like and where does it
# belong", and everything it returns is a Texture2D or a Rect2.
#
# Two things in here are not simple loads and are the reason it is worth its
# own file:
#
#   * the road-select highlight, which reproduces the original's brighten by
#     re-indexing a cell of GOMENU.LZS rather than by tinting it, and
#   * the touch build's removal of the retail key hints, which repaints a band
#     of two pictures in memory because a phone has no Esc and no space bar.
#
# No `class_name`: see scripts/PauseMenu.gd for why.
extends RefCounted

const GO_BASE := Vector2i(62, 12)
const GO_ROAD_PITCH := 9
const GO_WORLD_PITCH := 39
const GO_COLUMN := 160


## Android/iOS, or --touch. Decides whether the key hints are painted out.
var touch_ui := false

## `gfx.json`: where every retail picture sits on the 320x200 screen.
var _gfx: Dictionary = {}
var _tex_cache := {}
## GOMENU.LZS as palette indices, for the road-select highlight.
var _go_idx: PackedByteArray = PackedByteArray()
var _go_pal: Array = []
var _go_w := 0
var _go_h := 0
var _go_hi := {}                ## go_sel -> brightened 48x9 ImageTexture


func load_index() -> void:
	var gf := FileAccess.open("res://data/gfx/gfx.json", FileAccess.READ)
	if gf != null:
		_gfx = (JSON.parse_string(gf.get_as_text()) as Dictionary)["files"]
	_load_gomenu_index()


## How many help pages the retail art actually has.
func help_pages() -> int:
	return (_gfx.get("helpmenu", []) as Array).size()


## The original's 320x200 screen is displayed at 4:3. Everything here is placed
## in those original coordinates and scaled by the same 1.2 the camera uses, so
## menu overlays and gameplay share one coordinate system.
func to_canvas(p: Vector2) -> Vector2:
	return Vector2(p.x, p.y * SkyRoads.PIXEL_ASPECT)


## Optional: without it the selection falls back to an outline rectangle.
## True once GOMENU.LZS decoded; without it the selection falls back to an
## outline rectangle rather than the original's brighten.
func has_highlight() -> bool:
	return not _go_idx.is_empty()


## Screen offset of road `rd`'s name cell (fn_5064).
static func road_cell(rd: int) -> Vector2i:
	var p := GO_BASE
	p.y += ((rd % 15) / 3) * GO_WORLD_PITCH + (rd % 3) * GO_ROAD_PITCH
	if rd >= 15:
		p.x += GO_COLUMN
	return p


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
func highlight_tex(sel: int) -> ImageTexture:
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


func tex(name: String) -> Texture2D:
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


func gfx_pos(file: String, name: String) -> Vector2:
	for e in _gfx.get(file, []):
		if e["file"] == name + ".png":
			return Vector2(e["screen_x"], e["screen_y"])
	return Vector2.ZERO


## An overlay pict's rectangle in canvas space. The picts are the original's
## own outlines around each item, so their offsets and sizes ARE the item
## layout — no screen coordinates need inventing for touch or for dimming.
func gfx_rect(file: String, name: String) -> Rect2:
	for e in _gfx.get(file, []):
		if e["file"] == name + ".png":
			return Rect2(to_canvas(Vector2(e["screen_x"], e["screen_y"])),
				Vector2(float(e["w"]), float(e["h"]) * SkyRoads.PIXEL_ASPECT))
	return Rect2()
