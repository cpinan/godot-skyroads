# The shell: menu, gameplay, replay, and optional frame capture.
#
#   godot --path .                          the menu
#   godot --path . -- --road 7              straight into a road
#   godot --path . -- --replay 1            feed road 1's solved route
#
# Deliberately thin. Everything that decides gameplay lives in SkyRoadsPlay,
# everything that decides where the camera goes lives in SkyRoadsCamera, and
# this only wires them together.
extends Node

var road_index := 1
var _loop: GameLoop
var _road: RoadData
var _road_mesh: RoadMesh
var _camera: SkyRoadsCamera
var _ship: ShipSprite
var _hud: CanvasLayer
var _dash: Dashboard
var _coldbg: CollisionDebug
var _labels: CellLabels
var _world: Node3D
var _menu: Menu
var _replay: PackedByteArray
var _replaying := false
var _in_game := false

# frame capture
var _shot_dir := ""
var _shot_at: Array[int] = []
var _shot_every := 0
var _pending_shot := -1
var _owed: Array[int] = []
var _menu_shot := ""
var _cfg := Config.new()
## the parsed command line, kept so the replay path can ask it for a route
var _opt := LaunchOptions.new()
var _roadend: RoadEnd
var _hold := 0
var _roadend_shot := false
var _force_final := false
## --record dumps the input automatically on every death, so a session can be
## played normally and every failure comes out as a replayable file.
var _autodump := false
var _next_road := 0
var _want_overlay := false
var _want_labels := false
## DEMO.REC, the 1993 attract recording. Indexed by ship Z rather than by tick
## (sample = z / 0x666, roughly 40 per row), which is what makes playback
## independent of how fast the ship happens to be going.
var _demo_rec: PackedByteArray
var _audio: AudioMgr
var _intro: Intro
var _paused := false
var _fading := false
var _fade_rect: ColorRect
var _menu_state := {}
var _last_menu_screen := -1

## fade_to pacing (game.c:86-92): 36 ticks out, switch, 36 ticks in.
const FADE_SECS := 1.0


func _ready() -> void:
	Controls.install()
	_cfg.load_file()
	_audio = AudioMgr.new()
	_audio.cfg = _cfg
	add_child(_audio)
	_opt = LaunchOptions.parse(OS.get_cmdline_user_args())
	var opt := _opt
	for u in opt.unknown:
		push_warning("unrecognised option %s — ignored" % u)
	road_index = opt.road_index
	_replaying = opt.mode == LaunchOptions.Mode.REPLAY
	_shot_dir = opt.shot_dir
	_shot_at = opt.shot_ticks.duplicate()
	_owed = opt.shot_ticks.duplicate()
	_shot_every = opt.shot_every
	_roadend_shot = opt.roadend_shot
	_force_final = opt.force_final
	_autodump = opt.autodump
	_want_overlay = opt.want_overlay
	_want_labels = opt.want_labels
	_menu_shot = opt.menu_shot
	var start_now := opt.mode == LaunchOptions.Mode.PLAY \
		or opt.mode == LaunchOptions.Mode.REPLAY

	if start_now:
		_begin(road_index)
	elif not _menu_shot.is_empty():
		_open_menu()
		_capture_menu.call_deferred()
	else:
		# interactive boot runs the original intro (game.c:17-29); every
		# automated path above skips it
		_audio.want_song(0)
		_start_intro()

	# the fade layer sits over everything; created last so it is on top
	var fl := CanvasLayer.new()
	fl.layer = 100
	add_child(fl)
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.position = Vector2.ZERO
	_fade_rect.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fl.add_child(_fade_rect)


func _open_menu(screen: int = -1) -> void:
	_teardown()
	_menu = Menu.new()
	_menu.cfg = _cfg
	# selections survive reopening — the original keeps them in sr_game for
	# the whole session (game.h:33-36)
	for k in _menu_state:
		_menu.set(k, _menu_state[k])
	if _next_road > 0:
		# a completed road advances the cursor and returns to the road
		# select screen (game.c:347-348, 359-363)
		_menu.go_sel = clampi(_next_road, 0, 29)
		_menu.screen = Menu.Screen.GO
		_next_road = 0
	if screen >= 0:
		_menu.screen = screen
	_menu.fader = _fade_transition
	_menu.start_road.connect(func(i: int) -> void:
		_fade_transition(_begin.bind(i)))
	_menu.start_demo.connect(func() -> void:
		_fade_transition(func() -> void:
			_replaying = true
			_begin(0)))
	_menu.quit_game.connect(func() -> void: get_tree().quit())
	add_child(_menu)
	_last_menu_screen = -1


func _start_intro() -> void:
	_intro = Intro.new()
	_intro.audio = _audio
	_intro.done.connect(func() -> void: _fade_transition(_end_intro))
	add_child(_intro)


func _end_intro() -> void:
	if _intro != null and is_instance_valid(_intro):
		_intro.queue_free()
	_intro = null
	_open_menu(Menu.Screen.MAIN)


func _teardown() -> void:
	if _menu != null and is_instance_valid(_menu):
		_menu_state = {
			"screen": _menu.screen, "main_sel": _menu.main_sel,
			"go_sel": _menu.go_sel, "set_sel": _menu.set_sel,
			"help_page": _menu.help_page,
		}
	_paused = false
	for n in [_menu, _world, _hud, _loop, _roadend]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_menu = null
	_roadend = null
	_world = null
	_hud = null
	_loop = null
	_in_game = false


## Every interactive transition goes through here (fade_to, game.c:86-92):
## fade to black, switch, fade back. Automated paths (--road/--replay/
## --shots/--menu-shot) call their targets directly and never fade.
func _fade_transition(cb: Callable) -> void:
	if _fading:
		return
	_fading = true
	if _loop != null and is_instance_valid(_loop):
		_loop.paused = true          # nothing ticks during the fade-out
	if _menu != null and is_instance_valid(_menu):
		_menu.set_process(false)     # freeze the attract-idle timer
	var tw := create_tween()
	tw.tween_property(_fade_rect, "color:a", 1.0, FADE_SECS)
	tw.tween_callback(cb)
	tw.tween_property(_fade_rect, "color:a", 0.0, FADE_SECS)
	tw.tween_callback(func() -> void:
		_fading = false
		if _menu != null and is_instance_valid(_menu):
			_menu.set_process(true))


func _begin(index: int) -> void:
	_teardown()
	road_index = index
	_road = RoadData.load_json("res://data/levels/road_%02d.json" % index)
	if _road == null:
		push_error("no level data for road %d" % index)
		get_tree().quit(1)
		return

	if not _replaying:
		# a random song 2..13 per road start, never repeating the current
		# one; the attract demo keeps whatever is playing (game.c:52-58)
		_audio.gameplay_song(index)

	_replay = PackedByteArray()
	_demo_rec = PackedByteArray()
	if _replaying:
		if index == 0:
			# the attract demo is the original's own recording, not a route
			_demo_rec = _load_demo_rec()
			if _demo_rec.is_empty():
				push_warning("DEMO.REC unavailable; returning to the menu")
				_replaying = false
				_open_menu()
				return
		else:
			var route := _opt.route_for(index)
			var f := FileAccess.open(route, FileAccess.READ)
			if f == null:
				# never take the whole game down for a missing replay: a route
				# is an optional artefact, the menu is always reachable
				push_warning("no route recorded for road %d — back to the menu"
					% index)
				_replaying = false
				_open_menu()
				return
			_replay = f.get_buffer(f.get_length())

	_world = Node3D.new()
	add_child(_world)
	var road_mesh := RoadMesh.new()
	road_mesh.name = "RoadMesh"
	_world.add_child(road_mesh)
	road_mesh.build(_road)
	_road_mesh = road_mesh
	# the world backdrop is a fixed image behind the road; it never scrolls
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0)
	env.environment = e
	_world.add_child(env)
	_camera = SkyRoadsCamera.new()
	_world.add_child(_camera)
	_camera.current = true
	# the backdrop must be IN the 3D world: a CanvasLayer draws over the road
	var back := Backdrop.new()
	_camera.add_child(back)
	back.setup(_camera, load("res://data/gfx/world%d_0.png" % _road.world))
	# In the 3D world so blocks can occlude it; the dashboard CanvasLayer is
	# still drawn afterwards, which reproduces the cowl clipping for free.
	_ship = ShipSprite.new()
	_world.add_child(_ship)
	_ship.setup(_camera)
	_coldbg = CollisionDebug.new()
	_world.add_child(_coldbg)
	if _want_overlay:
		_coldbg.toggle()

	_hud = CanvasLayer.new()
	add_child(_hud)

	# Below the dashboard art, and behind it. The DOS screen is a single
	# framebuffer: the world picture fills rows 0..137, the dashboard is
	# STAMPED over rows 129..199 skipping its index-0 pixels, and the road is
	# composed into rows 32..137 only. So every transparent pixel of the
	# dashboard below row 137 shows palette index 0 — black — because nothing
	# ever wrote there. Here the 3D viewport covers the whole window, so
	# without this those pixels showed the live road instead: the road's
	# colour bled through the GRAV-O-METER digits, the JUMP-O-MASTER panel,
	# the unlit side of the speedometer and the dashboard's bottom corners,
	# and changed hue as the player drove between worlds (BUGS #30b, which
	# was recorded as "corner speckle" but is the whole band).
	var below := ColorRect.new()
	below.name = "BelowViewport"
	below.color = Color(0, 0, 0, 1)
	below.position = Vector2(0, SkyRoads.VIEW_H * SkyRoads.PIXEL_ASPECT)
	below.size = Vector2(SkyRoads.SCREEN_W,
		(SkyRoads.SCREEN_H - SkyRoads.VIEW_H) * SkyRoads.PIXEL_ASPECT)
	below.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(below)

	# ...and the same again above it. The DOS composer writes into
	# `fb->px + 32*320` and its band records are baked to stay inside the
	# viewport, so rows 0..31 are the world picture and NOTHING else, at every
	# tick, on every road (checked against the C engine: zero differing
	# pixels). Here the camera's frustum covers the whole window, so a tall
	# block close to the ship projected up into the sky — road 5's teal
	# platforms showed above the horizon where the original has only stars.
	# Redrawing the picture's own top rows over the 3D restores the bound.
	var sky := TextureRect.new()
	sky.name = "AboveViewport"
	var atlas := AtlasTexture.new()
	atlas.atlas = Backdrop.flattened(
		load("res://data/gfx/world%d_0.png" % _road.world))
	atlas.region = Rect2(0, 0, SkyRoads.SCREEN_W, SkyRoads.VIEW_TOP)
	sky.texture = atlas
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	sky.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sky.position = Vector2.ZERO
	sky.size = Vector2(SkyRoads.SCREEN_W,
		SkyRoads.VIEW_TOP * SkyRoads.PIXEL_ASPECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(sky)

	var dash := TextureRect.new()
	dash.texture = load("res://data/gfx/dashbrd_0.png")
	dash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dash.stretch_mode = TextureRect.STRETCH_SCALE
	dash.position = Vector2(0, SkyRoads.DASH_PICT_Y * SkyRoads.PIXEL_ASPECT)
	dash.size = Vector2(SkyRoads.SCREEN_W,
		(SkyRoads.SCREEN_H - SkyRoads.DASH_PICT_Y) * SkyRoads.PIXEL_ASPECT)
	_hud.add_child(dash)
	_dash = Dashboard.new()
	_hud.add_child(_dash)
	_labels = CellLabels.new()
	_hud.add_child(_labels)
	_labels.setup(_camera)
	if _want_labels:
		_labels.toggle()

	_loop = GameLoop.new()
	add_child(_loop)
	_loop.finished.connect(_on_finished)
	_loop.ticked.connect(_on_tick)
	_loop.start(_road)
	if _replaying:
		_apply_replay_input(_loop.play)
	_in_game = true
	print("road %d: %d rows, gravity %d (dash shows %d), fuel %d rows, "
		% [index, _road.rows, _road.gravity, SkyRoads.dash_gravity(_road.gravity),
		_road.fuel_rows] + "oxygen %d s%s"
		% [_road.oxygen_secs, "  [replay]" if _replaying else ""])


func _on_tick(play: SkyRoadsPlay, _result: int) -> void:
	if play.pending_sfx != 0:
		# fn_03c2: one voice, id+1 encoded, shell consumes and clears
		# (game.c:320-323)
		_audio.sfx(play.pending_sfx - 1)
		play.pending_sfx = 0
	_audio.warn_tick(play)
	if _replaying:
		_apply_replay_input(play)
	if _shot_at.has(play.tick) or (_shot_every > 0 and play.tick % _shot_every == 0):
		_pending_shot = play.tick


func _load_demo_rec() -> PackedByteArray:
	var f := FileAccess.open("res://data/demo.json", FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	var out := PackedByteArray()
	for s in d["samples"]:
		out.append(int(s["steer"]) + 1)
		out.append(int(s["accel"]) + 1)
		out.append(int(s["jump"]))
	return out


## Feed the next input. A solved route is indexed by tick; DEMO.REC is indexed
## by position, so the attract demo stays in step whatever the speed.
func _apply_replay_input(play: SkyRoadsPlay) -> void:
	var src := _demo_rec if not _demo_rec.is_empty() else _replay
	var i: int = (play.z / SkyRoads.DEMO_BYTES_PER_SAMPLE
		if not _demo_rec.is_empty() else play.tick)
	if i * 3 + 2 < src.size():
		_loop.steer = src[i * 3] - 1
		_loop.accel = src[i * 3 + 1] - 1
		_loop.jump = src[i * 3 + 2]


## Capture happens on a drawn frame, never from the tick signal: ticks come
## from the fixed-step accumulator and there is no image to grab between them.
## Put the world where the simulation actually is, plus however far into the
## current tick real time has already run. Called every frame, and again with
## the interpolation removed just before a capture.
func _present() -> void:
	var row := _loop.view_row()
	_camera.follow(row)
	# The visibility window is decided from the SIMULATED row, not the
	# presented one. render.c:356-363 takes `baserow = (z / 0x2000) >> 3`,
	# which is z >> 16 — the integer row the simulation is on — and draws
	# baserow+7 down to baserow-2 from it. Passing the interpolated row
	# instead let floori() cross into the next row up to a whole tick early,
	# so a row of geometry appeared (and the near-row cover materials
	# flipped) before the original does either: things arriving out of
	# nowhere at the horizon. The camera still follows the interpolated row —
	# that is what keeps motion smooth between ticks.
	_road_mesh.update_window(float(_loop.play.z >> 16))
	_ship.sync(_loop.play, _loop.play.on_sticky != 0,
		_loop.view_x(), _loop.view_y())
	_dash.update(_loop.play, _road.rows)
	_coldbg.update(_loop.play)
	_labels.update(_loop.play)


func _capture_pending() -> void:
	var tick := _pending_shot
	_pending_shot = -1
	# Deliberately NOT rewound to the exact simulated tick, and deliberately
	# taken after the frame's catch-up loop rather than inside it. Both were
	# tried and both measured WORSE against the C engine on road 2 (8.0% and
	# 8.5% of road pixels differing, against 6.5% as it stands): the
	# reference's frame for a tick corresponds to a moment this engine
	# reaches part-way through its own, so the interpolated, end-of-frame
	# state is the closer match. Left here because it is the kind of thing
	# that looks obviously wrong and is not.
	# force_draw() renders a frame synchronously instead of waiting for one.
	# Awaiting frame_post_draw deadlocks whenever the compositor has suspended
	# the window — which on macOS is any run that is not frontmost, i.e. every
	# automated one.
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	var path := "%s/road%02d_t%04d.png" % [_shot_dir, road_index, tick]
	if img.save_png(path) == OK:
		_owed.erase(tick)
		if _shot_every == 0:
			print("shot tick %d -> %s" % [tick, path])


## Screens named on the command line are opened in turn and captured.
## Capture the end-of-road screen: the text sits over the final rendered
## frame, so the world must still be on screen when this runs.
func _capture_roadend() -> void:
	for _i in 3:
		await get_tree().process_frame
	RenderingServer.force_draw()
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	var tag := "final" if _roadend.final_road else "completed"
	var path := "%s/roadend_%s.png" % [_shot_dir, tag]
	if img.save_png(path) == OK:
		print("roadend shot -> %s" % path)
	get_tree().quit(0)


func _capture_menu() -> void:
	# let the tree settle: capturing straight out of _ready grabs a frame
	# drawn before the menu's children exist, which comes out blank
	for _i in 3:
		await get_tree().process_frame
	for spec in _menu_shot.split(","):
		var parts := spec.split(":")
		_menu.screen = int(parts[0])
		if parts.size() > 1:
			match _menu.screen:
				Menu.Screen.MAIN: _menu.main_sel = int(parts[1])
				Menu.Screen.GO: _menu.go_sel = int(parts[1])
				Menu.Screen.SETTINGS: _menu.set_sel = int(parts[1])
				Menu.Screen.HELP: _menu.help_page = int(parts[1])
		# a little progress so the road-select tick marks are visible
		for r in 30:
			_menu.cfg.completions[r] = (r % 4)
		_menu._show()
		await get_tree().process_frame
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		var img := get_viewport().get_texture().get_image()
		var path := "%s/menu_%s.png" % [_shot_dir, spec.replace(":", "_")]
		if img.save_png(path) == OK:
			print("menu shot -> %s" % path)
	get_tree().quit(0)


func _unhandled_input(ev: InputEvent) -> void:
	if _fading:
		return                       # menus frozen during fades (game.c:398-402)
	if _intro != null:
		_intro.handle_input(ev)
	elif _roadend != null:
		_roadend.handle_input(ev)
	elif _menu != null:
		_menu.handle_input(ev)
	elif _in_game and ev is InputEventKey and ev.pressed and not ev.echo:
		var key := (ev as InputEventKey).keycode
		if _replaying and road_index == 0:
			# attract demo: ANY key returns to the main menu (game.c:293-296)
			_replaying = false
			_fade_transition(_open_menu.bind(Menu.Screen.MAIN))
			return
		if _paused:
			# any key resumes; ESC resumes AND quits to the road select
			# (game.c:298-307)
			_paused = false
			if key == KEY_ESCAPE:
				_fade_transition(_open_menu.bind(Menu.Screen.GO))
			else:
				_loop.paused = false
			return
		match key:
			KEY_ESCAPE:
				# result 7: back to the road select, cursor kept
				# (game.c:312-313)
				_replaying = false
				_fade_transition(_open_menu.bind(Menu.Screen.GO))
			KEY_P:
				if not _replaying:   # the original cannot pause the demo
					_paused = true
					_loop.paused = true
			KEY_L:
				_labels.toggle()
				_toast("object IDs %s\nB=block T=tunnel H=empty row"
					% ("ON" if _labels.enabled else "off"))
			KEY_C:
				_coldbg.toggle()
				_toast("collision overlay %s\ncyan = deck slab, red = solid, "
					% ("ON" if _coldbg.enabled else "off")
					+ "yellow = ship extent")
			KEY_F2, KEY_R:
				# R as well as F2: on macOS the function keys are brightness
				# and media unless "Use F1, F2 as standard function keys" is on
				_dump_recording()


func _process(_delta: float) -> void:
	if _menu != null and is_instance_valid(_menu) and not _fading:
		# song 0 on the main menu, 1 on road select; SETMENU/HELP keep the
		# current song (game.c enter_state, 73-80)
		var ms: int = _menu.screen
		if ms != _last_menu_screen:
			if ms == Menu.Screen.MAIN:
				_audio.want_song(0)
			elif ms == Menu.Screen.GO:
				_audio.want_song(1)
			_last_menu_screen = ms
	# Presentation runs every frame and interpolates between ticks. Without
	# this the camera and ship only move 36 times a second while the screen
	# redraws 60 or 120 times, so every second or third frame is a repeat and
	# the whole scene judders.
	if _in_game and _loop != null and _loop.play != null:
		_present()
	if _pending_shot >= 0 and not _shot_dir.is_empty():
		_capture_pending()
	if not _in_game or _loop == null or not _loop.running or _replaying:
		return
	var inp := _read_device()
	_loop.steer = inp[0]
	_loop.accel = inp[1]
	_loop.jump = inp[2]


## Sample whichever device skyroads.cfg selects (0 keyboard, 1 joystick,
## 2 mouse). The mapping itself lives in PlayerInput, which is pure and
## tested; this only reads the hardware.
func _read_device() -> Array:
	match PlayerInput.effective_device(_cfg.control,
			Input.get_connected_joypads().size()):
		PlayerInput.Device.JOYSTICK:
			var pad: int = Input.get_connected_joypads()[0]
			# stick or d-pad, whichever the player uses
			var jx := Input.get_joy_axis(pad, JOY_AXIS_LEFT_X)
			var jy := Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y)
			if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_LEFT):
				jx = -1.0
			elif Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_RIGHT):
				jx = 1.0
			if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_UP):
				jy = -1.0
			elif Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_DOWN):
				jy = 1.0
			var jb := Input.is_joy_button_pressed(pad, JOY_BUTTON_A) \
				or Input.is_joy_button_pressed(pad, JOY_BUTTON_B)
			return PlayerInput.from_axes(jx, jy, jb)
		PlayerInput.Device.MOUSE:
			# Offset from the centre of the view, normalised — the DOS driver
			# read an absolute position in a calibrated box, and this is the
			# same idea without a sensitivity constant to invent: the ship
			# goes where the pointer is relative to the middle of the screen.
			var vp := get_viewport().get_visible_rect().size
			var half := vp * 0.5
			var off := get_viewport().get_mouse_position() - half
			var mb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			return PlayerInput.from_axes(
				off.x / maxf(half.x, 1.0), off.y / maxf(half.y, 1.0), mb)
		_:
			return PlayerInput.from_keys(
				Input.is_action_pressed("sr_left"),
				Input.is_action_pressed("sr_right"),
				Input.is_action_pressed("sr_up"),
				Input.is_action_pressed("sr_down"),
				Input.is_action_pressed("sr_home"),
				Input.is_action_pressed("sr_pgup"),
				Input.is_action_pressed("sr_end"),
				Input.is_action_pressed("sr_pgdn"),
				Input.is_action_pressed("sr_jump"))


## A short-lived on-screen message. The recording filename is useless if the
## only place it appears is a console the player cannot see.
func _toast(msg: String) -> void:
	if _hud == null:
		return
	var label := Label.new()
	label.text = msg
	label.position = Vector2(6, 6)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(1, 1, 0.6))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	_hud.add_child(label)
	var tree := get_tree()
	await tree.create_timer(4.0).timeout
	if is_instance_valid(label):
		label.queue_free()


## Write everything played so far as a replayable input script.
##
## The point is to make a complaint reproducible: the file feeds straight back
## through --route, and through the C engine and the Python model, so
## "collision felt wrong around there" becomes a trace three engines can be
## compared on.
func _dump_recording() -> void:
	if _loop == null or _loop.recording.is_empty():
		return
	var dir := "user://recordings"
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/road%02d_%s.bin" % [dir, road_index, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("could not write %s" % path)
		return
	f.store_buffer(_loop.recording)
	f.close()
	var full := ProjectSettings.globalize_path(path)
	print("recorded %d ticks -> %s" % [_loop.recording.size() / 3, full])
	print("  replay it:  godot --path . -- --replay %d --route-file %s"
		% [road_index, full])
	# ...and on screen, because stdout is not visible when the game is
	# launched from a shortcut or with its output redirected
	_toast("recorded %d ticks\n%s" % [_loop.recording.size() / 3,
		path.get_file()])


func _on_finished(result: int) -> void:
	print("finished: %s after %d ticks (%.2f s), row %d/%d, fuel %d, oxygen %d"
		% [SkyRoads.RESULT.get(result, result), _loop.play.tick,
		_loop.play.tick / SkyRoads.TICK_HZ, _loop.play.z >> 16, _road.rows,
		_loop.play.fuel, _loop.play.oxy])
	if not _shot_dir.is_empty() and not _owed.is_empty():
		push_error("%d screenshot(s) never taken: %s — the window was starved "
			% [_owed.size(), _owed] + "of frames (occluded on macOS)")
	if _replaying and not _roadend_shot:
		if _shot_dir.is_empty() and road_index == 0:
			_replaying = false          # attract demo over: back to the menu
			_fade_transition(_open_menu.bind(Menu.Screen.MAIN))
			return
		get_tree().quit(0 if result == SkyRoadsPlay.COMPLETE else 1)
		return

	if result == SkyRoadsPlay.COMPLETE:
		var rd := road_index - 1
		if rd >= 0 and rd < 30 and _cfg.completions[rd] < 0xFFFF:
			_cfg.completions[rd] += 1
		_cfg.save_file()
		# the original moves the road-select cursor on to the next road
		# (game.c: `if (g->go_sel < 29) g->go_sel++`), so finishing one road
		# leaves you pointed at the next
		_next_road = mini(road_index, 30)
		# the final frame stays on screen with the text drawn over it
		_roadend = RoadEnd.new()
		_roadend.final_road = _force_final or (rd == 29
			and _cfg.completed_count() == 30)
		# any key: road select next, main menu only after "The End"
		# (game.c:359-363)
		_roadend.dismissed.connect(func() -> void:
			var final := _roadend.final_road
			_fade_transition(_open_menu.bind(
				Menu.Screen.MAIN if final else Menu.Screen.GO)))
		add_child(_roadend)
		if _roadend_shot:
			_capture_roadend.call_deferred()
	else:
		if not _loop.recording.is_empty() and _autodump:
			_dump_recording()
		# Every death sends the player straight back to the same road — the
		# original has no defeat screen, but it does fade out and in around
		# the restart (game.c:356). Screenshot runs skip the fade so capture
		# ticks stay deterministic.
		if _shot_dir.is_empty():
			_fade_transition(_begin.bind(road_index))
		else:
			_begin(road_index)
