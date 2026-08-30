# UI test: the world backdrop must render its own art, pixel for pixel.
#
# The exported world pictures were verified byte-identical to what the C
# engine puts in its framebuffer, so "the port draws its art unchanged" is
# the whole requirement — no C golden is needed, and the invariant holds for
# every world rather than the one a golden would cover.
#
# This exists because the art was faithful and the screen still was not.
# WORLDn.LZS has no transparency, but the export carries palette index 0 as
# alpha 0; Godot's importer then ran `fix_alpha_border`, which replaces the
# RGB of transparent pixels with a bleed of their opaque neighbours, and the
# backdrop material ignores alpha — so the night sky's black came out as
# blue-grey blocks (BUGS #30a). Nothing about the art or the star pixels was
# wrong, which is why only a comparison against the source art finds it.
#
# Rows 0..VIEW_TOP-1 are checked: the DOS composer writes into fb + 32*320 and
# its band records are baked to stay inside the viewport, so those rows are the
# world picture and nothing else, on every road and at every tick — verified
# against the C engine, which differs from the picture there by zero pixels.
extends SceneTree

const BAND_ROWS := SkyRoads.VIEW_TOP
const TOLERANCE := 30
## Exact. These rows are drawn by the 2D path, straight from the picture, so
## there is nothing left to allow for.
const MAX_BAD := 0

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var dir := OS.get_environment("SR_SKY_SHOTS")
	if dir.is_empty():
		print("  (no SR_SKY_SHOTS directory — backdrop parity not checked)")
		print("Result: %d checks, %d failures" % [_checks, _failures])
		quit(0)
		return
	# Two worlds, chosen for what each one catches: world 8's sky is mostly
	# palette index 0, which is what the transparent-pixel bleed showed up
	# on; world 1 has tall roadside blocks near the ship, which is what
	# projected up out of the viewport into the sky.
	var cases := [[26, 8], [5, 1]]
	var live := false
	for c in cases:
		var art := Image.load_from_file("res://data/gfx/world%d_0.png" % c[1])
		check(art != null, "world%d_0.png loads" % c[1])
		if art == null:
			continue
		if _transparent_pixels(art) > 0:
			live = true
		for tick in [61, 241] if c[0] == 26 else [61, 121]:
			var bad := _compare(dir, c[0], tick, art)
			if bad < 0:
				check(false, "road %d tick %d: capture missing" % [c[0], tick])
				continue
			print("  sky road%02d t%04d   wrong px %d" % [c[0], tick, bad])
			check(bad <= MAX_BAD,
				"road %d's backdrop at tick %d is the picture, unaltered "
				% [c[0], tick] + "(%d px wrong)" % bad)
	check(live, "at least one world still carries transparent pixels, "
		+ "so the flattening is still being exercised")
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _transparent_pixels(img: Image) -> int:
	var n := 0
	for y in BAND_ROWS:
		for x in img.get_width():
			if img.get_pixel(x, y).a < 0.5:
				n += 1
	return n


## Pixels differing from the art by more than TOLERANCE, or -1 if the capture
## is missing.
func _compare(dir: String, road: int, tick: int, art: Image) -> int:
	var shot := Image.load_from_file("%s/road%02d_t%04d.png" % [dir, road, tick])
	if shot == null:
		return -1
	var sw := shot.get_width()
	var sh := shot.get_height()
	if sw == 0 or sh == 0:
		return -1
	var bad := 0
	for y in BAND_ROWS:
		var sy := int((float(y) + 0.5) * SkyRoads.PIXEL_ASPECT * float(sh)
			/ SkyRoads.SQUARE_H)
		sy = clampi(sy, 0, sh - 1)
		for x in art.get_width():
			var sx := clampi(int((float(x) + 0.5) * float(sw)
				/ float(art.get_width())), 0, sw - 1)
			var a := art.get_pixel(x, y)
			var b := shot.get_pixel(sx, sy)
			# transparent art pixels are opaque BLACK on the DOS screen
			var ar := 0 if a.a < 0.5 else a.r8
			var ag := 0 if a.a < 0.5 else a.g8
			var ab := 0 if a.a < 0.5 else a.b8
			if absi(int(ar) - int(b.r8)) > TOLERANCE \
					or absi(int(ag) - int(b.g8)) > TOLERANCE \
					or absi(int(ab) - int(b.b8)) > TOLERANCE:
				bad += 1
	return bad
