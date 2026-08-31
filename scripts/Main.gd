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
var _shot_alpha := -1.0

## The phone's pause menu: three tappable rows in the original's 320x200 space,
## centred. Only ever built when the touch UI is on.
const PAUSE_MENU_ROWS := ["RESUME", "RESTART", "QUIT"]
const PAUSE_ROW_H := 16
const PAUSE_MENU_TOP := 78
var _pause_menu: Control
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
## The running fade, kept only so a skippable one can be run to its end.
var _fade_tween: Tween
## What that fade is on its way to doing, so a skip can still do it.
var _fade_cb := Callable()
var _fade_skippable := false
var _fade_rect: ColorRect
var _menu_state := {}
var _last_menu_screen := -1
## The on-screen thumbstick and jump button, alive only while a road is
## being played. Null on desktop.
var _touch: TouchControls
## Whether this run drives itself by finger: a phone, or `--touch` on a
## desktop so the mobile layout can be looked at without one. Decided once,
## at boot, because a control scheme that changes under the player is worse
## than either scheme.
var _touch_ui := false

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
	_shot_alpha = opt.shot_alpha
	_roadend_shot = opt.roadend_shot
	_force_final = opt.force_final
	_autodump = opt.autodump
	_want_overlay = opt.want_overlay
	_want_labels = opt.want_labels
	_menu_shot = opt.menu_shot
	# A parity capture must render the reference screen and nothing else, so
	# the touch layer stays off there even on a phone.
	# SkyRoads.is_mobile() is Android/iOS specifically, not
	# OS.has_feature("mobile") — that is also true of a web export on a touch
	# device, and the mobile UI changes (no CONTROLS item, a pause menu instead
	# of the P key) are for phones. --touch still forces it on a desktop, which
	# is how the layout is testable at all.
	_touch_ui = opt.force_touch \
		or (SkyRoads.is_mobile() and not opt.is_parity_capture())
	# Godot quits on Android's back gesture unless told otherwise, which would
	# end a run rather than back out of it. _notification handles it instead.
	get_tree().set_quit_on_go_back(false)
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
	_menu.touch_ui = _touch_ui
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
	_menu.quit_game.connect(func() -> void: get_tree().quit())
	add_child(_menu)
	_last_menu_screen = -1


func _start_intro() -> void:
	_intro = Intro.new()
	_intro.audio = _audio
	_intro.done.connect(func(skipped: bool) -> void:
		_fade_transition(_end_intro.bind(skipped), true))
	add_child(_intro)


## What the intro leads to, and it is not always the menu.
##
## main @0x021e-0x022f: `fn_4575()` returns the value of its abort flag, so it
## returns 0 when nobody touched a key and non-zero when somebody did. On 0
## main sets `[0x9602] = 3` and loads road 0 — the DEMO.REC attract run. On
## non-zero it opens the main menu. Sitting through the whole intro is the
## ONLY way to reach the attract demo in the retail game; the port used to
## start it after ten idle seconds on the main menu, which is the C
## reference's invention (BUGS §11.11).
func _end_intro(skipped: bool) -> void:
	if _intro != null and is_instance_valid(_intro):
		_intro.queue_free()
	_intro = null
	if skipped:
		_open_menu(Menu.Screen.MAIN)
	else:
		_replaying = true
		_begin(0)


func _teardown() -> void:
	if _menu != null and is_instance_valid(_menu):
		_menu_state = {
			"screen": _menu.screen, "main_sel": _menu.main_sel,
			"go_sel": _menu.go_sel, "set_sel": _menu.set_sel,
			"help_page": _menu.help_page,
		}
	_paused = false
	# a child of _hud, so it dies with it — but the reference must not dangle
	_pause_menu = null
	for n in [_menu, _world, _hud, _loop, _roadend, _touch]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_menu = null
	_roadend = null
	_world = null
	_hud = null
	_loop = null
	_touch = null
	_in_game = false


## Every interactive transition goes through here (fade_to, game.c:86-92):
## fade to black, switch, fade back. Automated paths (--road/--replay/
## --shots/--menu-shot) call their targets directly and never fade.
##
## `skippable` reproduces the original's abort flag. fn_4315 forces its
## interpolation straight to t=100 when `[0x54ac]` is set, and fn_4137 sets
## that on any keypress — but ONLY while armed by `[0xaf42]`, which fn_4575
## raises at 0x470d for the intro and clears at 0x4a6f when it ends. So the
## intro can be skipped through and nothing else can, which is why this is a
## parameter rather than a blanket rule.
func _fade_transition(cb: Callable, skippable := false) -> void:
	if _fading:
		return
	_fading = true
	_fade_skippable = skippable
	_fade_cb = cb
	if _loop != null and is_instance_valid(_loop):
		_loop.paused = true          # nothing ticks during the fade-out
	if _menu != null and is_instance_valid(_menu):
		_menu.set_process(false)
	var tw := create_tween()
	_fade_tween = tw
	tw.tween_property(_fade_rect, "color:a", 1.0, FADE_SECS)
	tw.tween_callback(func() -> void:
		# through _fade_cb, so a skip and a normal run perform the same call
		# exactly once whichever gets there first
		var pending := _fade_cb
		_fade_cb = Callable()
		if pending.is_valid():
			pending.call())
	tw.tween_property(_fade_rect, "color:a", 0.0, FADE_SECS)
	tw.tween_callback(func() -> void:
		_fading = false
		_fade_skippable = false
		_fade_tween = null
		_fade_cb = Callable()
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

	# Nothing is drawn over the top 32 rows any more. The world used to be
	# clipped there by painting the backdrop's own rows back over the 3D — but
	# that painted over the SHIP too, and the original draws the ship
	# unclipped: draw_ship bounds x and the cowl mask, never y, so a high jump
	# legitimately puts it in the sky band. Measured on road 17 t=150, the
	# reference draws 290 ship pixels from row 31 down where the port drew 145
	# from row 35 — the top of the ship simply sheared off.
	# The geometry is clipped in its own shader instead
	# (SkyRoadsCamera.make_dos_material), which is what the original's baked
	# span records amount to, and the backdrop already fills those rows.

	var dash := TextureRect.new()
	dash.texture = load("res://data/gfx/dashbrd_0.png")
	dash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dash.stretch_mode = TextureRect.STRETCH_SCALE
	dash.position = Vector2(0, SkyRoads.DASH_PICT_Y * SkyRoads.PIXEL_ASPECT)
	dash.size = Vector2(SkyRoads.SCREEN_W,
		(SkyRoads.SCREEN_H - SkyRoads.DASH_PICT_Y) * SkyRoads.PIXEL_ASPECT)
	_hud.add_child(dash)
	_dash = Dashboard.new()
	# A parity capture must reproduce the reference exactly, so the one
	# documented dashboard deviation (BUGS #41's readable GRAV-O-METER) is
	# off whenever frames are being measured.
	_dash.authentic_gravity_window = _opt.is_parity_capture()
	_hud.add_child(_dash)
	if _touch_ui:
		_touch = TouchControls.new()
		_touch.mouse_fallback = _opt.force_touch
		_touch.on_pause = _touch_pause
		_pause_menu = Control.new()
		_pause_menu.position = Vector2.ZERO
		_pause_menu.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
		_pause_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pause_menu.visible = false
		_pause_menu.draw.connect(_draw_pause_menu)
		_hud.add_child(_pause_menu)
		add_child(_touch)
	_labels = CellLabels.new()
	_hud.add_child(_labels)
	_labels.setup(_camera)
	if _want_labels:
		_labels.toggle()

	_loop = GameLoop.new()
	add_child(_loop)
	_loop.finished.connect(_on_finished)
	_loop.ticked.connect(_on_tick)
	# A capture must be of the tick it is named after, so the catch-up loop
	# stops on those ticks instead of running past them.
	if not _shot_dir.is_empty():
		_loop.halt_ticks = _shot_at.duplicate()
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
	# Take the shot at a REPRODUCIBLE moment inside the tick. Without this the
	# fraction is whatever the frame that noticed the tick happened to be at,
	# which is why the same build measured 18.5% and 20.0% on road 2 t=640 in
	# consecutive runs — see BUGS #29b and §12.3 for the sweep that chose the
	# default.
	if _shot_alpha >= 0.0 and _loop != null and _loop.play != null:
		_loop.override_alpha(_shot_alpha)
		_present()
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
		# Menus are frozen during fades (game.c:398-402) — except the
		# intro's, which the original lets the player cut short.
		if _fade_skippable and _is_confirm(ev):
			_skip_fade()
		return
	if _intro != null:
		_intro.handle_input(ev)
	elif _roadend != null:
		_roadend.handle_input(ev)
	elif _menu != null:
		_menu.handle_input(ev)
	elif _in_game and _touch_ui and ev is InputEventScreenTouch \
			and (ev as InputEventScreenTouch).pressed:
		# The pause box has already claimed its own taps (TouchControls marks
		# them handled), so anything reaching here is a tap on the playfield.
		# A tap leaves the demo: a phone has no ESC, and the pause box is the
		# documented stand-in for it.
		if _replaying and road_index == 0:
			_replaying = false
			_fade_transition(_open_menu.bind(Menu.Screen.MAIN))
		elif _paused:
			# the phone gets a real pause menu rather than "any tap resumes"
			_pause_menu_tap(_touch_canvas_pos(ev as InputEventScreenTouch))
	elif _in_game and ev is InputEventKey and ev.pressed and not ev.echo:
		var key := (ev as InputEventKey).keycode
		if _replaying and road_index == 0:
			# The attract demo is a road like any other, so only ESC leaves
			# it — that is the play loop's result 7, and main @0x037a sends
			# result 7 to the main menu. Every other key does nothing, here
			# as in the game (BUGS §11.11).
			if key != KEY_ESCAPE:
				return
			_replaying = false
			_fade_transition(_open_menu.bind(Menu.Screen.MAIN))
			return
		if _paused:
			# any key resumes; ESC resumes AND quits to the road select
			# (game.c:298-307)
			_set_paused(false)
			if key == KEY_ESCAPE:
				_fade_transition(_open_menu.bind(Menu.Screen.GO))
			return
		# The developer keys are inert while frames are being captured. Every
		# one of them either paints over the picture being measured or stalls
		# the loop, so a single stray keystroke into a focused capture window
		# invalidates the run — which is exactly what happened on 2026-08-31:
		# an `r` typed while the gate had focus dumped a recording at tick 15
		# and left its toast across road 5's sky, and `render_backdrop.gd`
		# reported 571 wrong pixels in a band the renderer had not touched.
		if not _shot_dir.is_empty() and key != KEY_ESCAPE:
			return
		match key:
			KEY_ESCAPE:
				# result 7: back to the road select, cursor kept
				# (game.c:312-313)
				_replaying = false
				_fade_transition(_open_menu.bind(Menu.Screen.GO))
			KEY_P:
				if not _replaying:   # the original cannot pause the demo
					_set_paused(true)
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
			# BOTH menus are song 1 in the retail binary: fn_4e36 @0x4e3f
			# (main menu) and fn_5164 @0x5172 (road select) each call
			# music_start(1). Song 0 belongs to the intro alone
			# (fn_4575 @0x4586) — the port used to leave it playing over the
			# main menu, so song 1 was only ever heard on the road select.
			if ms == Menu.Screen.MAIN or ms == Menu.Screen.GO:
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
			Input.get_connected_joypads().size(), _touch_ui):
		PlayerInput.Device.TOUCH:
			# the on-screen stick has already done the thresholding, in
			# PlayerInput.from_axes, exactly as the joystick does
			return _touch.sample() if _touch != null else [0, 0, 0]
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


## Android's back gesture and the application losing focus. Both are phone
## facts with no DOS equivalent, and both are damaging if ignored: by default
## Godot QUITS on a back press, so the system gesture would end a run outright,
## and a phone call arriving mid-road would otherwise keep the simulation
## running behind the lock screen.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_go_back()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			# Mobile only, deliberately. On a desktop this fires whenever the
			# window goes to the background, and an automated `--replay
			# --shots` run that pauses there never terminates — it would hang
			# verify.sh instead of failing it.
			if OS.has_feature("mobile") and _in_game and not _paused \
					and not _replaying \
					and _loop != null and is_instance_valid(_loop):
				_set_paused(true)


## One screen back, wherever we are. This is Escape's job on a keyboard, so it
## does Escape's job here rather than inventing a second navigation model.
func _go_back() -> void:
	if _fading:
		return
	if _intro != null:
		_intro.handle_input(_escape_event())
	elif _roadend != null:
		_roadend.handle_input(_escape_event())
	elif _menu != null:
		_menu.handle_input(_escape_event())
	elif _in_game:
		_set_paused(false)
		_replaying = false
		_fade_transition(_open_menu.bind(Menu.Screen.GO))


## Any key or tap, which is what the original's fn_4137 watches for.
static func _is_confirm(ev: InputEvent) -> bool:
	if ev is InputEventKey:
		return ev.pressed and not (ev as InputEventKey).echo
	if ev is InputEventScreenTouch:
		return (ev as InputEventScreenTouch).pressed
	return false


## Run the fade to its end immediately, the way fn_4315 does when its abort
## flag is raised mid-interpolation.
##
## Done by hand rather than with `Tween.custom_step()`: stepping a tween that
## the tree is also processing is documented as unreliable, and it showed —
## the tween finished, its LAST callback ran and its middle one did not, so
## the shell cleared `_fading` while the transition it was supposed to perform
## never happened. The intro then sat on screen forever.
func _skip_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null
	var cb := _fade_cb
	_fade_cb = Callable()
	_fade_rect.color.a = 0.0
	_fading = false
	_fade_skippable = false
	if cb.is_valid():
		cb.call()
	if _menu != null and is_instance_valid(_menu):
		_menu.set_process(true)


func _escape_event() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev


## The touch pause box, which is also the only "back" a phone has: tap once
## to pause, tap it again to leave the road. That is the original's own pair
## of behaviours (P pauses, ESC while paused quits to the road select,
## game.c:298-313) reached with one control instead of two keys.
## A touch's position in the original's 320x240 canvas space. Same inverse the
## touch layer uses; the pause menu lives in the same coordinates as everything
## else drawn in the HUD.
func _touch_canvas_pos(ev: InputEventScreenTouch) -> Vector2:
	if _pause_menu == null:
		return Vector2.ZERO
	return _pause_menu.get_global_transform().affine_inverse() * ev.position


## One row of the phone's pause menu, in the original's 320x200 space.
func _pause_row_rect(i: int) -> Rect2:
	var y := float(PAUSE_MENU_TOP + i * PAUSE_ROW_H)
	return Rect2(Vector2(90.0, y * SkyRoads.PIXEL_ASPECT),
		Vector2(140.0, float(PAUSE_ROW_H - 3) * SkyRoads.PIXEL_ASPECT))


func _draw_pause_menu() -> void:
	# a dim ground so the road behind cannot be mistaken for a live frame
	_pause_menu.draw_rect(Rect2(Vector2.ZERO,
		Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)), Color(0, 0, 0, 0.62), true)
	for i in PAUSE_MENU_ROWS.size():
		var r := _pause_row_rect(i)
		_pause_menu.draw_rect(r, Color(0.83, 0.83, 0.72), false, 1.0)
		var label: String = PAUSE_MENU_ROWS[i]
		var x := int((SkyRoads.SCREEN_W - Text8x8.width(label)) / 2)
		Text8x8.draw(_pause_menu, label, x, PAUSE_MENU_TOP + i * PAUSE_ROW_H + 4,
			Color(0.83, 0.83, 0.72), SkyRoads.PIXEL_ASPECT)


## Returns true when the tap was consumed by the pause menu.
func _pause_menu_tap(p: Vector2) -> bool:
	if _pause_menu == null or not _pause_menu.visible:
		return false
	for i in PAUSE_MENU_ROWS.size():
		if not _pause_row_rect(i).has_point(p):
			continue
		match i:
			0:
				_set_paused(false)
			1:
				_set_paused(false)
				_fade_transition(_begin.bind(road_index))
			2:
				_set_paused(false)
				_fade_transition(_open_menu.bind(Menu.Screen.GO))
		return true
	# a tap anywhere else on the overlay does nothing: the three rows are the
	# whole interface, and "any tap resumes" would make QUIT hard to hit
	return true


func _set_paused(on: bool) -> void:
	_paused = on
	if _loop != null and is_instance_valid(_loop):
		_loop.paused = on
	if _pause_menu != null:
		_pause_menu.visible = on
		if on:
			_pause_menu.queue_redraw()


func _touch_pause() -> void:
	if not _in_game or _loop == null or _fading:
		return
	if _replaying:
		# the original cannot pause the demo; a tap leaves it instead
		_replaying = false
		_fade_transition(_open_menu.bind(
			Menu.Screen.MAIN if road_index == 0 else Menu.Screen.GO))
		return
	# The button opens the menu; the menu decides what happens next. Tapping it
	# again just closes it, which is what a pause button should do.
	_set_paused(not _paused)


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
			# A demo that ran to its end goes back to the INTRO, not to the
			# menu: main @0x0385 jumps to 0x219, which is the `fn_4575()`
			# call. Intro, demo, intro, demo — an arcade attract loop, and
			# the answer to whether the intro ever replays. It does, here and
			# only here.
			_replaying = false
			_fade_transition(func() -> void:
				_teardown()
				_audio.want_song(0)
				_start_intro())
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
