# The 8x8 text the original draws for "Road Completed" and "The End".
#
# SKYROADS.EXE renders those two strings with the BIOS ROM font, fetched at
# startup through int 10h ax=1130h. That font cannot be redistributed, so the
# C port substitutes the public-domain font8x8 and this draws from the same
# table (exported to data/font8x8.json), giving identical output to the port.
class_name Text8x8
extends RefCounted

const GLYPH_W := 8
const GLYPH_H := 8

static var _glyphs: Array = []


static func _ensure_loaded() -> void:
	if not _glyphs.is_empty():
		return
	var f := FileAccess.open("res://data/font8x8.json", FileAccess.READ)
	if f == null:
		push_error("font8x8.json missing — run `sra export-godot`")
		return
	_glyphs = (JSON.parse_string(f.get_as_text()) as Dictionary)["glyphs"]


## The exported font is font8x8_basic: ASCII only, 128 glyphs, because the
## original used the BIOS ROM font (int 10h ax=1130h) which is not
## redistributable. The Godot port's own credit line needs an n-tilde, so it is
## built from the `n` the font does have — shifted down a row with a tilde laid
## into the gap — rather than inventing bitmap data or misspelling the name.
## Nothing in the original's own text needs a glyph above 127.
const N_TILDE := 241
const TILDE_ROW := 0x36            ## columns 1,2,4,5; bit 0 is leftmost


static func _glyph_for(code: int) -> Array:
	if code == N_TILDE:
		var n: Array = _glyphs[110]          # 'n'
		var out := [TILDE_ROW, 0]
		for row in range(0, GLYPH_H - 2):
			out.append(n[row])
		return out
	if code < 0 or code >= _glyphs.size():
		code = 63                             # '?'
	return _glyphs[code]


## The raw 8 rows for one codepoint, for callers that need to rasterise into an
## Image rather than a CanvasItem.
static func glyph_rows(code: int) -> Array:
	_ensure_loaded()
	if _glyphs.is_empty():
		return []
	return _glyph_for(code)


static func width(s: String) -> int:
	return s.length() * GLYPH_W


## Draw at original 320x200 coordinates; the caller supplies the vertical
## scale so text lines up with the rest of the 320x240 display space.
static func draw(ci: CanvasItem, s: String, x: int, y: int, colour: Color,
		y_scale: float = 1.0) -> void:
	_ensure_loaded()
	if _glyphs.is_empty():
		return
	for i in s.length():
		var g: Array = _glyph_for(s.unicode_at(i))
		for row in GLYPH_H:
			var bits: int = g[row]
			for col in GLYPH_W:
				# bit 0 is the leftmost pixel in font8x8
				if bits & (1 << col):
					ci.draw_rect(Rect2(
						Vector2(x + i * GLYPH_W + col, (y + row) * y_scale),
						Vector2(1, y_scale)), colour, true)
