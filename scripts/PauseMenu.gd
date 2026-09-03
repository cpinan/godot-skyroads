# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# The phone's pause menu: three tappable rows over the frozen road.
#
# The original has no such screen. On a keyboard P pauses and ESC while paused
# quits to the road select (game.c:298-313); a phone has neither key, so those
# two behaviours are reached through one control instead. The pause BUTTON is
# TouchControls' — this is only what the button opens.
#
# Drawn in the original's 320x200 space and scaled by PIXEL_ASPECT, like
# everything else in the HUD, so the rows line up with the dashboard art.
#
# No `class_name`: resolving one needs the global class cache, which only an
# editor scan or `--import` writes, and an editor scan is what un-pins the
# texture `.import` files (docs/STATUS.md). Main preloads it instead.
extends Control

## What the player picked. Main decides what each one means — this only knows
## where the rows are.
signal chose(action: int)

enum { RESUME = 0, RESTART = 1, QUIT = 2 }

const ROWS := ["RESUME", "RESTART", "QUIT"]
const ROW_H := 16
const TOP := 78
const ROW_X := 90.0
const ROW_W := 140.0
## A dim ground so the road behind cannot be mistaken for a live frame.
const SCRIM := Color(0, 0, 0, 0.62)
const INK := Color(0.83, 0.83, 0.72)


func _init() -> void:
	position = Vector2.ZERO
	size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	# the rows are hit-tested by hand from the touch event, so the Control
	# itself must never swallow one
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func show_menu(on: bool) -> void:
	visible = on
	if on:
		queue_redraw()


## One row's rectangle, in the original's 320x200 space.
func row_rect(i: int) -> Rect2:
	var y := float(TOP + i * ROW_H)
	return Rect2(Vector2(ROW_X, y * SkyRoads.PIXEL_ASPECT),
		Vector2(ROW_W, float(ROW_H - 3) * SkyRoads.PIXEL_ASPECT))


## A touch's position in the original's 320x240 canvas space. Same inverse the
## touch layer uses; the menu lives in the same coordinates as the HUD.
func canvas_pos(ev: InputEventScreenTouch) -> Vector2:
	return get_global_transform().affine_inverse() * ev.position


## Returns true when the tap was consumed, which is any tap at all while the
## menu is up: the three rows are the whole interface, and "any tap resumes"
## would make QUIT hard to hit with a thumb.
func handle_tap(ev: InputEventScreenTouch) -> bool:
	if not visible:
		return false
	var p := canvas_pos(ev)
	for i in ROWS.size():
		if row_rect(i).has_point(p):
			chose.emit(i)
			return true
	return true


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,
		Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)), SCRIM, true)
	for i in ROWS.size():
		draw_rect(row_rect(i), INK, false, 1.0)
		var label: String = ROWS[i]
		var x := int((SkyRoads.SCREEN_W - Text8x8.width(label)) / 2)
		Text8x8.draw(self, label, x, TOP + i * ROW_H + 4, INK,
			SkyRoads.PIXEL_ASPECT)
