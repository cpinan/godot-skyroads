# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# Everything --shots, --surface-ids, --menu-shot and --roadend-shot do.
#
# None of it runs for a player: `LaunchOptions.is_parity_capture()` is false on
# every interactive path, and `dir` stays empty, and every entry point here
# returns immediately. It lived in Main because that is where the nodes are;
# it is here because ~180 lines that only tools/verify.sh executes should not
# sit in the middle of the shell a player runs.
#
# Main hands over the four live handles it needs when a road starts (`bind`)
# and a Callable that re-runs presentation (`present`), because a capture at a
# pinned interpolation fraction has to move the world before it grabs it.
#
# No `class_name`: see scripts/PauseMenu.gd for why.
extends RefCounted

const SurfaceIds = preload("res://scripts/app/SurfaceIds.gd")

## Where to write, and empty when nothing is being captured. Every public entry
## point below tests this first.
var dir := ""
## Ticks named on the command line, and the subset not yet written. A tick that
## never arrives is an error at the end of the run, not a silent short capture.
var at: Array[int] = []
var owed: Array[int] = []
var every := 0
## Pinned interpolation fraction, or < 0 to take the shot wherever the frame
## happens to land. BUGS #29b: without it the same build measured 18.5% and
## 20.0% on road 2 t=640 in consecutive runs.
var alpha := -1.0
var surface_ids := false
var menu_shot := ""
var roadend_shot := false

## Set once a road is running.
var road_index := 0
var present := Callable()
var _loop: GameLoop
var _road_mesh: RoadMesh
var _ship: ShipSprite
var _hud: CanvasLayer
var _backdrop: Backdrop
var _env: Environment

var _pending := -1


func configure(opt: LaunchOptions) -> void:
	dir = opt.shot_dir
	at = opt.shot_ticks.duplicate()
	owed = opt.shot_ticks.duplicate()
	every = opt.shot_every
	alpha = opt.shot_alpha
	surface_ids = opt.surface_ids
	menu_shot = opt.menu_shot
	roadend_shot = opt.roadend_shot


## The scene handles, from _build_world / _build_hud. The loop does not exist
## yet at that point, so it arrives separately.
func bind(index: int, road_mesh: RoadMesh, ship: ShipSprite,
		hud: CanvasLayer, backdrop: Backdrop, env: Environment) -> void:
	road_index = index
	_road_mesh = road_mesh
	_ship = ship
	_hud = hud
	_backdrop = backdrop
	_env = env


func bind_loop(loop: GameLoop) -> void:
	_loop = loop


func active() -> bool:
	return not dir.is_empty()


## The simulation reached a tick. Remember it if it is one that was asked for;
## the shot itself is taken on a drawn frame, never from here.
func note_tick(tick: int) -> void:
	if at.has(tick) or (every > 0 and tick % every == 0):
		_pending = tick


## Called every frame from Main._process, after presentation.
func service(tree: SceneTree) -> void:
	if _pending < 0 or dir.is_empty():
		return
	var tick := _pending
	_pending = -1
	# Taken after the frame's catch-up loop rather than inside it. The two
	# variants were compared on road 2 (8.0% and 8.5% of road pixels differing
	# against 6.5%), but that was measured through the capture bug of BUGS
	# 12.16, when the saved image was the PREVIOUS frame whatever this code
	# did, so those numbers decide nothing and are recorded only so nobody
	# cites them. What holds now: --shot-alpha reaches the image, two runs at
	# the same alpha are byte-identical, and the default 0.0 pins the shot to
	# the tick it is named after.
	if alpha >= 0.0 and _loop != null and _loop.play != null:
		_loop.override_alpha(alpha)
		if present.is_valid():
			present.call()
	_draw_now(tree)
	var img := tree.root.get_texture().get_image()
	var path := "%s/road%02d_t%04d.png" % [dir, road_index, tick]
	if img.save_png(path) == OK:
		owed.erase(tick)
		if every == 0:
			print("shot tick %d -> %s" % [tick, path])
	if surface_ids:
		_capture_surface_ids(tree, tick)


## Deliver every pending 3D transform to the rendering server, then render one
## frame synchronously.
##
## Node3D does not talk to the server when a transform is assigned: it puts
## itself on the SceneTree's pending list, and that list is flushed AFTER the
## idle frame's _process calls, not inside one. A capture calls force_draw()
## from inside _process, so the frame the server draws is built from the
## PREVIOUS flush — the camera and the ship of the frame before. That is why
## --shot-alpha never reached the saved image: the override moved the world
## and the picture was of the world before it moved (BUGS §12.16).
##
## force_update_transform() sends the notification immediately, and it has to
## walk the subtree because the pending flag is per node, not inherited.
##
## force_draw() rather than awaiting frame_post_draw: awaiting deadlocks
## whenever the compositor has suspended the window, which on macOS is any run
## that is not frontmost, i.e. every automated one.
func _draw_now(tree: SceneTree) -> void:
	flush_transforms(tree.root)
	RenderingServer.force_draw()


static func flush_transforms(n: Node) -> void:
	if n is Node3D:
		(n as Node3D).force_update_transform()
	for c in n.get_children():
		flush_transforms(c)


## The same frame again, with every surface painting its identity instead of
## its colour. Taken immediately after the picture and from the same state, so
## the two are of the same tick at the same interpolation fraction.
##
## Everything that is not road geometry is removed rather than left to paint
## an id of its own: the backdrop, the dashboard band and the HUD have no
## record in the reference, whose map simply stays at NONE wherever the
## composer never wrote. The clear colour becomes NONE's encoding for the
## same reason.
func _capture_surface_ids(tree: SceneTree, tick: int) -> void:
	var hud_was := _hud.visible
	var back_was := _backdrop.visible
	_hud.visible = false
	_backdrop.visible = false
	_env.background_color = SurfaceIds.encode(SurfaceIds.NONE)
	_road_mesh.set_sid_mode(true)
	_ship.set_sid_mode(true)
	_resync_ship()
	_draw_now(tree)
	var img := tree.root.get_texture().get_image()
	var path := "%s/road%02d_t%04d.sid.png" % [dir, road_index, tick]
	if img.save_png(path) != OK:
		push_warning("could not write %s" % path)
	_road_mesh.set_sid_mode(false)
	_ship.set_sid_mode(false)
	_resync_ship()
	_env.background_color = Color(0, 0, 0)
	_hud.visible = hud_was
	_backdrop.visible = back_was
	_draw_now(tree)


## Sprite3D binds its texture to its own built-in material, so the surface-ID
## override has to be handed the same texture — which sync() does, but only
## when it runs after the mode has changed.
func _resync_ship() -> void:
	_ship.sync(_loop.play, _loop.play.on_sticky != 0,
		_loop.view_x(), _loop.view_y())


## The end-of-road screen: the text sits over the final rendered frame, so the
## world must still be on screen when this runs.
func capture_roadend(tree: SceneTree, final_road: bool) -> void:
	for _i in 3:
		await tree.process_frame
	RenderingServer.force_draw()
	RenderingServer.force_draw()
	var img := tree.root.get_texture().get_image()
	var tag := "final" if final_road else "completed"
	var path := "%s/roadend_%s.png" % [dir, tag]
	if img.save_png(path) == OK:
		print("roadend shot -> %s" % path)
	tree.quit(0)


## Screens named on the command line are opened in turn and captured.
func capture_menu(tree: SceneTree, menu: Menu) -> void:
	# let the tree settle: capturing straight out of _ready grabs a frame
	# drawn before the menu's children exist, which comes out blank
	for _i in 3:
		await tree.process_frame
	for spec in menu_shot.split(","):
		var parts := spec.split(":")
		menu.screen = int(parts[0])
		if parts.size() > 1:
			match menu.screen:
				Menu.Screen.MAIN: menu.main_sel = int(parts[1])
				Menu.Screen.GO: menu.go_sel = int(parts[1])
				Menu.Screen.SETTINGS: menu.set_sel = int(parts[1])
				Menu.Screen.HELP: menu.help_page = int(parts[1])
		# a little progress so the road-select tick marks are visible
		for r in 30:
			menu.cfg.completions[r] = (r % 4)
		menu._show()
		await tree.process_frame
		RenderingServer.force_draw()
		RenderingServer.force_draw()
		var img := tree.root.get_texture().get_image()
		var path := "%s/menu_%s.png" % [dir, spec.replace(":", "_")]
		if img.save_png(path) == OK:
			print("menu shot -> %s" % path)
	tree.quit(0)
