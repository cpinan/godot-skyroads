# The end-of-road screen.
#
# The original has no separate victory or defeat art. On completion it draws
# one string over the FINAL RENDERED FRAME and waits for a key (fn_2b21
# 0x2c62-0x2c8a):
#
#     "Road Completed"  at (0x68, 0x50)   colour 0x63
#     "The End"         at (0x84, 0x50)   after the last road, all 30 done
#
# Defeat has no screen at all. The ship explodes over 14 frames, the wreck
# floats, the state holds for 108 ticks (3.0 s), and then the same road starts
# again — main 0x3b4 sends results 1..5 straight back to the road it came
# from. Reproducing that means NOT inventing a "you died" panel.
class_name RoadEnd
extends CanvasLayer

signal dismissed

const COMPLETED_X := 0x68
const FINAL_X := 0x84
const TEXT_Y := 0x50
## Dashboard palette entry 0x63 = 99 — the index the original passes
## (game.c:350-351). Loaded from the exported palette; fallback only if the
## file is missing.
var _text_colour := Color(0.86, 0.86, 0.86)

var final_road := false
var _overlay: Control


func _ready() -> void:
	var f := FileAccess.open("res://data/game_palette.json", FileAccess.READ)
	if f != null:
		var pal: Array = (JSON.parse_string(f.get_as_text())
			as Dictionary).get("palette", [])
		if pal.size() > 99:
			_text_colour = Color8(pal[99][0], pal[99][1], pal[99][2])
	_overlay = Control.new()
	_overlay.position = Vector2.ZERO
	_overlay.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_text)
	add_child(_overlay)


func _draw_text() -> void:
	var s := "The End" if final_road else "Road Completed"
	var x := FINAL_X if final_road else COMPLETED_X
	Text8x8.draw(_overlay, s, x, TEXT_Y, _text_colour, SkyRoads.PIXEL_ASPECT)


func handle_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		dismissed.emit()
