# The boot intro (fn_4575), previously never played although every asset for
# it was already exported:
#
#   tick  0   title pict (intro_0) under a 36-tick fade-in
#   tick 24   INTRO.SND voice
#   tick 61   ANIM.LZS playback at 2 ticks per frame (18 fps)
#   ...       any key skips; after the last delta + 72 ticks, on to the menu
#
# ANIM is 100 declared frames delivered as 221 delta rectangles, each blitted
# over the previous image at its own screen offset (anim.json). Painter's
# order == child order, so every delta is simply appended as a TextureRect.
class_name Intro
extends CanvasLayer

signal done

const VOICE_TICK := 24
const ANIM_START_TICK := 24 + 37
const TICKS_PER_FRAME := 2
const END_SLACK_TICKS := 72

# AudioMgr, deliberately untyped: the parse suite loads scripts one at a time
# with a cold global-class cache, and a typed reference fails there.
var audio

var _t := 0.0
var _ticks := 0
var _frames: Array = []
var _declared := 100
var _next := 0                  ## next delta record to blit
var _voiced := false
var _over := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.position = Vector2.ZERO
	bg.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	add_child(bg)
	_place("res://data/gfx/intro_0.png", Vector2.ZERO)
	var f := FileAccess.open("res://data/gfx/anim/anim.json", FileAccess.READ)
	if f != null:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			_frames = d.get("frames", [])
			_declared = int(d.get("declared_frames", 100))


func _place(path: String, pos: Vector2) -> void:
	if not ResourceLoader.exists(path):
		return
	var tex: Texture2D = load(path)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.position = Vector2(pos.x, pos.y * SkyRoads.PIXEL_ASPECT)
	tr.size = Vector2(tex.get_width(),
		tex.get_height() * SkyRoads.PIXEL_ASPECT)
	add_child(tr)


func _process(delta: float) -> void:
	if _over:
		return
	_t += delta * SkyRoads.TICK_HZ
	while _ticks < int(_t) and not _over:
		_ticks += 1
		_tick()


func _tick() -> void:
	if _ticks == VOICE_TICK and not _voiced:
		_voiced = true
		if audio != null:
			audio.voice()
	var at := _ticks - ANIM_START_TICK
	if at < 0:
		return
	var frame := at / TICKS_PER_FRAME
	while _next < _frames.size() and int(_frames[_next]["frame"]) <= frame:
		var rec: Dictionary = _frames[_next]
		_place("res://data/gfx/anim/%s" % rec["file"],
			Vector2(rec["screen_x"], rec["screen_y"]))
		_next += 1
	if _next >= _frames.size() \
			and at > TICKS_PER_FRAME * _declared + END_SLACK_TICKS:
		_finish()


func handle_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		_finish()


func _finish() -> void:
	if _over:
		return
	_over = true
	done.emit()
