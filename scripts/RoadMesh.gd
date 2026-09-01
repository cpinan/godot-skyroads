# Builds the road as 3D geometry from the tile grid.
#
# The DOS original had no 3D: every scanline of every tile shape was a span
# list baked into TREKDAT.LZS, eight of them, one per eighth of a grid row.
# There is nothing to port directly, so this rebuilds the same shapes as real
# geometry and relies on the camera recovered from those tables
# (data/camera.json) to frame them the way the original did.
#
# World scale comes from that same fit and lives in SkyRoadsCamera:
#   one grid row deep = 1.0 unit, a column is COLUMN_WIDTH wide, and block
#   tops sit at HALF_BLOCK_Y / FULL_BLOCK_Y above the deck.
class_name RoadMesh
extends MeshInstance3D

## Palette layout implied by the original's span composers (renderer.md §5.1):
## 1..14 floor colours, +15 front edges, +30 side edges.
const FRONT_EDGE_OFFSET := 15
const SIDE_EDGE_OFFSET := 30
## The block's FRONT is the fixed record colour 62; its TOP is the face the
## tile's colour nibble patches, with 0x3d = 61 standing in when the nibble is
## 0. render.c names kinds 2 and 3 the other way round, but the decoded
## records settle it (tools/dump_bands.c "kindlines"): at dr7 kind 2's first
## record spans y[64,81] — the band ABOVE the deck strip, i.e. the top seen
## from above — while kind 3's spans y[82,101], the deck strip itself, and
## blockcolor() patches kind 2. Painting them the other way round is what made
## blocks read inside-out, and is BUGS #24's "tiers": the reference puts the
## patched colour on the upper band and 62 below.
const BLOCK_FRONT_COLOUR := 62
## sr_quad[63] = {63, 64}: the block side is 63 on the left screen half, 64
## on the right. Add _half(col).
const BLOCK_SIDE_COLOUR := 63
const BLOCK_TOP_DEFAULT := 61
const TUNNEL_WALL_COLOUR := 65
## One original screen pixel of height, in world units (0x80 game Y units).
const PIXEL_Y := SkyRoadsCamera.WORLD_PER_GAME_Y * 128.0

## The tunnel arch as the original DRAWS it: height above the deck, in
## original pixels, at each pixel of distance from the lane centre. Measured
## off the TREKDAT span records with `tools/dump_bands.c archlines` (phase 0,
## band dr7, centre column — the head-on band where one game pixel is one
## screen pixel). ARCH_OUTER_PX is where the mouth's kind-66 rim records
## stop; ARCH_BORE_PX is where the hole they leave begins. A coordinate
## descent that re-fits both against the decoded mask lands back on these
## numbers, so they are the profile, not a guess at it.
##
## These are NOT SkyRoads.TUN_INNER / TUN_OUTER. Those are the COLLISION
## profile and the two disagree wildly: collision leaves a 13x4 px slot at
## deck level under a nearly flat-topped slab, while the artist's arch is a
## 47x19 px vault over a 41x16 px bore. Building the collision profile is
## what made the port's tunnels read as stepped slabs where the reference
## draws a smooth cone (BUGS #31) — a flat-topped slab has no silhouette to
## taper. Physics keeps its own tables; nothing here feeds collision.
const ARCH_OUTER_PX := [19, 19, 19, 19, 18, 18, 18, 18, 18, 17, 17, 16,
	16, 15, 15, 14, 13, 12, 11, 10, 9, 7, 5, 1]
const ARCH_BORE_PX := [16, 16, 16, 16, 16, 15, 15, 15, 15, 14, 14, 13,
	12, 12, 11, 10, 9, 8, 6, 4, 0, 0, 0, 0]

## The six kind-4 arch records resolve through sr_quad to FOUR bands across
## each lane, and the sequence runs ACROSS the lane rather than out from its
## centre — a fixed light direction, not a symmetric gradient. Columns 0..2
## take records k70..k73 through the left sr_quad entry, columns 4..6 the
## same records through the right one, and the centre column takes k69/k70 on
## its left half mirrored onto its right.
const TUNNEL_ARCH_LEFT := [69, 68, 69, 70]
const TUNNEL_ARCH_MID := [70, 69, 68, 69]
const TUNNEL_ARCH_RIGHT := [71, 70, 69, 68]
## Slice boundaries between those bands. The records are not equal slices of
## the lane — decoded at dr7 they cover 5/24/35/36 % of an outer column's
## drawn arch and 21/30/30/19 % of an inner one — so these edges are the ones
## that reproduce the measured AREAS through this camera (the sector geometry
## the original used to get there is not recovered; see BUGS #31). The centre
## column's own split is near-symmetric, so it keeps quarters.
const TUNNEL_BAND_EDGES_LEFT := [4, 29, 41]
const TUNNEL_BAND_EDGES_MID := [11, 23, 34]
const TUNNEL_BAND_EDGES_RIGHT := [5, 17, 42]

## The surface identities both engines write into their parity buffers.
const SurfaceIds = preload("res://scripts/app/SurfaceIds.gd")

## Per-geometry record ids, in the order _block emits its quads:
## [top, front, side, front-right-of-bore, bore interior]. A -1 means the port
## draws nothing for that surface.
const LOWBLOCK_SIDS := [SurfaceIds.LOWBLOCK_K2_0, SurfaceIds.LOWBLOCK_K3_0,
	SurfaceIds.LOWBLOCK_K2_1, SurfaceIds.LOWBLOCK_K3_0, -1]
const TUNLOW_SIDS := [SurfaceIds.TUNLOW_K2_0, SurfaceIds.TUNLOW_K3_1,
	SurfaceIds.TUNLOW_K2_1, SurfaceIds.TUNLOW_K3_2, SurfaceIds.TUNLOW_K1_0]
const HIBLOCK_SIDS := [SurfaceIds.HIBLOCK_K5_0, SurfaceIds.HIBLOCK_K5_2,
	SurfaceIds.HIBLOCK_K5_1, SurfaceIds.HIBLOCK_K5_2, -1]
const TUNHIGH_SIDS := [SurfaceIds.TUNHIGH_K5_0, SurfaceIds.TUNHIGH_K3_1,
	SurfaceIds.TUNHIGH_K5_1, SurfaceIds.TUNHIGH_K3_2, SurfaceIds.TUNHIGH_K1_0]

var _road: RoadData
var _floors: Array[MeshInstance3D] = []      ## per grid row; null = nothing
var _solids: Array[MeshInstance3D] = []      ## per grid row; null = nothing
var _floor_mat: ShaderMaterial
var _solid_mat: ShaderMaterial
var _cover_mats: Array[ShaderMaterial] = []
## the ship's own row is drawn twice: its far half through _split_far_mat on
## the row's own instances, its near half through these two extra instances,
## which share the very same meshes and paint after the sprite
var _split_far_mat: ShaderMaterial
var _split_near_mat: ShaderMaterial
var _split_floor: MeshInstance3D
var _split_solid: MeshInstance3D
var _last_base := -0x7FFFFFFF


## The road is built as one mesh PAIR per grid row (floor + raised geometry),
## which is what lets the draw order reproduce the original's.
##
## render.c:361-396 paints 10 grid rows far-to-near and blits the ship inside
## its own row's band, so raised geometry in the rows NEARER than the ship is
## painted after the sprite and covers it, while the floor's spans stay in
## their own screen strips and never touch it. Measured on the C engine
## (sr_render_test): the grounded ship sits entirely inside the screen strips
## of the rows behind it, so a depth-tested sprite at its true depth is
## swallowed by nearer floor — the order, not the depth, is what decides.
##
## Reproduced here as: floor and rows at or beyond the ship's stay opaque, the
## ship draws over them without depth-testing, and the one-or-two nearer rows'
## solids are moved to the transparent pass with a higher render_priority so
## they paint over the sprite. update_window() keeps that classification and
## the original's 10-row visibility window (T18) current as the ship advances.
func build(road: RoadData) -> void:
	_road = road
	# all road materials come from the camera so they carry the DOS
	# horizontal cone warp (SkyRoadsCamera.make_dos_material)
	_floor_mat = SkyRoadsCamera.make_dos_material()
	_solid_mat = SkyRoadsCamera.make_dos_material()
	_cover_mats.clear()
	# The ship's own row straddles the sprite: render.c composes it as
	# pre-ship geometry, the ship, then post-ship geometry, and the cut is at
	# the ship's own depth (SkyRoadsCamera.SHIP_SPLIT_DEPTH). Without this the
	# arch of the tunnel row the ship has just entered paints entirely BEFORE
	# the sprite and the player is drawn on top of the tunnel.
	_split_far_mat = SkyRoadsCamera.make_dos_material(false, false, false, 0,
		SkyRoadsCamera.CLIP_FAR)
	_split_near_mat = SkyRoadsCamera.make_dos_material(true, true, false, 1,
		SkyRoadsCamera.CLIP_NEAR)
	for i in 2:
		# rows nearer than the ship: drawn in the transparent pass AFTER the
		# sprite (ShipSprite render_priority 0) and after the ship row's own
		# near half, nearest last. Depth is still written and tested so the
		# rows sort against each other and against their own hidden faces.
		_cover_mats.append(SkyRoadsCamera.make_dos_material(true, true, false, 2 + i))
	for n in get_children():
		n.queue_free()
	_floors.clear()
	_solids.clear()
	_floors.resize(road.rows)
	_solids.resize(road.rows)
	for row in road.rows:
		var floor_st := SurfaceTool.new()
		var solid_st := SurfaceTool.new()
		floor_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		solid_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for col in SkyRoads.COLS:
			_emit_cell(floor_st, solid_st, row, col)
		_floors[row] = _commit_row(floor_st, _floor_mat, "Floor%d" % row)
		_solids[row] = _commit_row(solid_st, _solid_mat, "Solid%d" % row)
	# two instances, reassigned to whichever row the ship is in
	_split_floor = MeshInstance3D.new()
	_split_floor.name = "ShipRowFloorNear"
	_split_floor.material_override = _split_near_mat
	_split_floor.visible = false
	add_child(_split_floor)
	_split_solid = MeshInstance3D.new()
	_split_solid.name = "ShipRowSolidNear"
	_split_solid.material_override = _split_near_mat
	_split_solid.visible = false
	add_child(_split_solid)
	_last_base = -0x7FFFFFFF


func _commit_row(st: SurfaceTool, mat: Material, nm: String) -> MeshInstance3D:
	var m := st.commit()
	if m == null or m.get_surface_count() == 0:
		return null
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)
	return mi


## The original composes only grid rows base+7 down to base-2 (render.c:
## 361-374), so the road pops in at the horizon instead of shrinking into the
## sky. Rows nearer than the ship's own get the cover material so their raised
## geometry paints over the sprite, exactly as bands dr=8,9 do in the DOS
## order. Call every frame with the presented (interpolated) row; it is a
## no-op until the ship crosses into a new grid row.
func update_window(view_row: float) -> void:
	var base := floori(view_row)
	if base == _last_base:
		return
	var lo := base - 2
	var hi := base + 7
	# only rows whose state can have changed are touched — the union of the
	# old and new windows, or every row on the first call
	var span_lo := 0 if _last_base == -0x7FFFFFFF else mini(lo, _last_base - 2)
	var span_hi := _floors.size() - 1 if _last_base == -0x7FFFFFFF \
		else maxi(hi, _last_base + 7)
	_last_base = base
	for row in range(maxi(span_lo, 0), mini(span_hi, _floors.size() - 1) + 1):
		var vis := row >= lo and row <= hi
		if _floors[row] != null:
			_floors[row].visible = vis
			if vis:
				# only the ship's own row is cut; every other row lies wholly
				# on one side of the split, so clipping it would cost a
				# discard per fragment for nothing
				_floors[row].material_override = _split_far_mat \
					if row == base else _floor_mat
		if _solids[row] != null:
			_solids[row].visible = vis
			if vis:
				if row == base:
					_solids[row].material_override = _split_far_mat
				else:
					_solids[row].material_override = _solid_mat if row > base \
						else _cover_mats[mini(base - 1 - row, 1)]
	# the near half of the ship's row, painted after the sprite
	var f: MeshInstance3D = _floors[base] if base >= 0 \
		and base < _floors.size() else null
	var so: MeshInstance3D = _solids[base] if base >= 0 \
		and base < _solids.size() else null
	_split_floor.mesh = f.mesh if f != null else null
	_split_floor.visible = f != null
	_split_solid.mesh = so.mesh if so != null else null
	_split_solid.visible = so != null


## Screen half for per-half palette variants (render.c sr_quad): columns
## left of centre use the left entry, right of centre the right. The
## centre column (3) uses left — its own records are split mid-column in
## the original, which a per-cell colour cannot express.
func _half(col: int) -> int:
	return 1 if col > 3 else 0


func _colour(index: int) -> Color:
	if index >= 0 and index < _road.palette.size():
		return _road.palette[index]
	return Color(1, 0, 1)          # magenta: a palette index that should exist


func _emit_cell(floor_st: SurfaceTool, solid_st: SurfaceTool,
		row: int, col: int) -> void:
	var st := floor_st
	var code := _road.tile(row, col)
	var nearer_tile: int = _road.tile(row - 1, col) if row > 0 else 0
	if code == 0:
		return                      # a hole: nothing at all is drawn
	var surface := SkyRoads.tile_surface(code)
	var geom := SkyRoads.tile_geometry(code)
	if geom > 5:
		return                      # composer jump table sends 6..15 to ret
	var w := SkyRoadsCamera.COLUMN_WIDTH
	var x0 := (col - 3.5) * w
	var x1 := x0 + w
	var z0 := -float(row)
	var z1 := z0 - 1.0

	if surface != 0:
		var top := _colour(surface)
		var front := _colour(surface + FRONT_EDGE_OFFSET)
		# sr_quad[31..45] = {c+30, c+45}: side edges are 31..45 on the left
		# screen half and 46..60 on the right
		var side := _colour(surface + SIDE_EDGE_OFFSET + 15 * _half(col))
		_quad(st, Vector3(x0, 0, z0), Vector3(x1, 0, z0),
			Vector3(x1, 0, z1), Vector3(x0, 0, z1), top,
			SurfaceIds.FLOOR_K0_0)
		# The front lip is what makes the road read as solid rather than as a
		# painted plane, so it is drawn whenever the nearer row is empty.
		# render.c:150 tests the nearer tile's floor NIBBLE, not the whole
		# code: a block with no floor under it still gets a front lip
		if row == 0 or (_road.tile(row - 1, col) & 0xF) == 0:
			_quad(st, Vector3(x0, 0, z0), Vector3(x1, 0, z0),
				Vector3(x1, -0.08, z0), Vector3(x0, -0.08, z0), front,
				SurfaceIds.FLOOR_K0_2)
		# side edge only toward the screen centre (render.c:146-149); the DOS
		# renderer never emits the outward-facing edge. Column 3 is composed
		# in BOTH halves and so can carry either edge there — a per-cell
		# colour cannot express that, so it carries neither.
		if col < 3 and (_road.tile(row, col + 1) & 0xF) == 0:
			_quad(st, Vector3(x1, 0, z0), Vector3(x1, 0, z1),
				Vector3(x1, -0.08, z1), Vector3(x1, -0.08, z0), side,
				SurfaceIds.FLOOR_K0_1)
		elif col > 3 and (_road.tile(row, col - 1) & 0xF) == 0:
			_quad(st, Vector3(x0, 0, z0), Vector3(x0, 0, z1),
				Vector3(x0, -0.08, z1), Vector3(x0, -0.08, z0), side,
				SurfaceIds.FLOOR_K0_1)

	# anything that stands up off the deck goes in the depth-writing mesh
	# Which reference records each of these quads claims to be. The port
	# emits ONE front quad and one side quad per block where the reference
	# splits both across a deck-strip band and a tier band, so the ids below
	# name the tier's records and the comparison reports the lower band as
	# the mismatch it is (BUGS §12.14's method, not a labelling convenience).
	match geom:
		2:
			_block(solid_st, x0, x1, z0, z1, SkyRoadsCamera.HALF_BLOCK_Y,
				code, false, col, 0.0, LOWBLOCK_SIDS)
		3:
			_block(solid_st, x0, x1, z0, z1, SkyRoadsCamera.HALF_BLOCK_Y,
				code, true, col, 0.0, TUNLOW_SIDS)
		4:
			_block(solid_st, x0, x1, z0, z1, SkyRoadsCamera.FULL_BLOCK_Y,
				code, false, col, 0.0, HIBLOCK_SIDS)
		5:
			# A tun_high is a FULL-HEIGHT BLOCK WITH A BORE, not a tunnel
			# with a tier on top. The retail composer at 0x2fb0 is the kind-4
			# full block with one substitution: where kind 4 draws the plain
			# lower front (kind-3 record 0), this draws the kind-3 PAIR that
			# splits that front around the bore, plus the bore's interior
			# from kind 1 at colour 0x41. It never seeks kind 4, so none of
			# the six arch-gradient records a plain tunnel paints appear on
			# it — which is what the C reference (render.c compose_tun_high)
			# had wrong, and what put a band of vault under this tier.
			# The bore is the same ARCH_BORE_PX the geom-3 blocks use:
			# decoded at phase 0 / dr7 / ci1 the kind-3 pair carves 16 px of
			# height at the lane centre and 20 px of half-width at the deck.
			_block(solid_st, x0, x1, z0, z1, SkyRoadsCamera.FULL_BLOCK_Y,
				code, true, col, 0.0, TUNHIGH_SIDS)
		1:
			# the front wall is only drawn at the MOUTH — the original tests
			# "nearer row's shape < 1" (composer 0x303d). Drawing it for every
			# cell stacks a striped wall across consecutive tunnel rows.
			_tunnel(solid_st, x0, x1, z0, z1,
				SkyRoads.tile_geometry(nearer_tile) < 1, col)


## `front_base_y` is where the front face stops: 0 for a block standing on
## the deck, HALF_BLOCK_Y for the upper tier of a tun_high, whose lower half
## is the tunnel arch rather than masonry.
func _block(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float,
		top_y: float, code: int, bored: bool, col: int,
		front_base_y := 0.0, sids := LOWBLOCK_SIDS) -> void:
	# render.c:154-171 — the colour nibble patches the TOP (default 61); the
	# front is always the baked 62; sides are 63 left half / 64 right half
	var nib := SkyRoads.tile_blocktop(code)
	var top_c := _colour(nib if nib != 0 else BLOCK_TOP_DEFAULT)
	var front_c := _colour(BLOCK_FRONT_COLOUR)
	var side_c := _colour(BLOCK_SIDE_COLOUR + _half(col))
	_quad(st, Vector3(x0, top_y, z0), Vector3(x1, top_y, z0),
		Vector3(x1, top_y, z1), Vector3(x0, top_y, z1), top_c, sids[0])
	if bored:
		# The bore through a block is the same one the tunnels draw
		# (ARCH_BORE_PX), so compose_tun_low can split the block's front
		# record around it: the front runs from the bore's arch up to the
		# top, and the arch's inner surface — the kind-1 "entrance", colour
		# 0x41 = 65 — carries on through the cell behind it. The bore never
		# reaches the cell edge, so the side faces stay full height.
		var px := (x1 - x0) / 46.0
		var interior := _colour(TUNNEL_WALL_COLOUR)
		var bore := PackedFloat32Array()
		bore.resize(47)
		for b in 47:
			bore[b] = ARCH_BORE_PX[absi(b - 23)] * PIXEL_Y
		for slice in 46:
			var i0 := bore[slice]
			var i1 := bore[slice + 1]
			var sx0 := x0 + slice * px
			var sx1 := sx0 + px
			# the reference splits this front into a pair of records, one
			# each side of the bore; slice 23 is the lane centre
			var front_sid: int = sids[1] if slice < 23 else sids[3]
			if i0 < top_y or i1 < top_y:
				_quad(st, Vector3(sx0, top_y, z0), Vector3(sx1, top_y, z0),
					Vector3(sx1, i1, z0), Vector3(sx0, i0, z0), front_c,
					front_sid)
			if i0 > 0.0 or i1 > 0.0:
				_quad(st, Vector3(sx0, i0, z1), Vector3(sx1, i1, z1),
					Vector3(sx1, i1, z0), Vector3(sx0, i0, z0), interior,
					sids[4])
		_quad(st, Vector3(x0, top_y, z0), Vector3(x0, top_y, z1),
			Vector3(x0, 0, z1), Vector3(x0, 0, z0), side_c, sids[2])
		_quad(st, Vector3(x1, top_y, z0), Vector3(x1, top_y, z1),
			Vector3(x1, 0, z1), Vector3(x1, 0, z0), side_c, sids[2])
	else:
		_face(st, x0, x1, z0, z1, top_y, front_c, side_c, front_base_y,
			sids[1], sids[2])


## The front quad and the two side quads are separate palette entries in the
## original, so neither is a shaded variant of the other.
func _face(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float,
		top_y: float, front_c: Color, side_c: Color,
		front_base_y := 0.0, front_sid := SurfaceIds.LOWBLOCK_K3_0,
		side_sid := SurfaceIds.LOWBLOCK_K2_1) -> void:
	_quad(st, Vector3(x0, top_y, z0), Vector3(x1, top_y, z0),
		Vector3(x1, front_base_y, z0), Vector3(x0, front_base_y, z0), front_c,
		front_sid)
	# The sides stop where the front does. compose_tun_high still emits the
	# LOWER side record, but it paints the six arch records over it
	# afterwards, so what the reference actually shows below the tier is the
	# arch. Here the side is a plane standing between the camera and the
	# arch, so drawing it would win on depth and hide the tunnel — which is
	# what made road 2's roadside tunnels look like solid grey walls.
	_quad(st, Vector3(x0, top_y, z0), Vector3(x0, top_y, z1),
		Vector3(x0, front_base_y, z1), Vector3(x0, front_base_y, z0), side_c,
		side_sid)
	_quad(st, Vector3(x1, top_y, z0), Vector3(x1, top_y, z1),
		Vector3(x1, front_base_y, z1), Vector3(x1, front_base_y, z0), side_c,
		side_sid)


## A tunnel, built from the profile the original DRAWS (ARCH_OUTER_PX /
## ARCH_BORE_PX), not the one collision tests.
##
## The DOS tunnel is a real 3D vault and compose_tunnel paints its surfaces:
## six kind-4 band records that are the vault's outer surface seen from
## ABOVE, at a mouth two kind-66 rim records that are the ring face closing
## the shell, and a kind-1 record (0x43 = 67) that is the bore's inner
## surface seen obliquely from an off-centre column. Each record covers its
## whole band — from the row's far edge to its near one — which is why
## consecutive rows abut into a smooth cone instead of stacking as steps.
##
## So each tunnel row emits those surfaces, swept from its far edge to its
## near one:
##   * the vault's outer surface. It is a roof, but a CURVED one, so its
##     silhouette is the arch and it hides only what the reference's arch
##     hides — unlike the flat roof tried earlier, which had no silhouette
##     and buried the road beyond.
##   * the bore's inner surface, always: inside a run of tunnel rows it is
##     continuous, which is why the original only needs its record at a
##     mouth.
##   * the ring face closing the shell, ONLY at a mouth. Inside a run there
##     is no opening to close and compose_tunnel draws no rim.
## Nothing here is a horizontal plane and nothing is a closed tube, so from
## above the camera sees the vault, never a box top.
##
## Emitting each row's ring at its near edge ALONE — no swept surface — was
## tried and is wrong: an off-centre column's rings shift toward the
## vanishing point row by row, so they render as a row of separate arches
## with gaps, not as one wedge (parity IoU 0.41 against the C frames, vs
## 0.91 for the swept surfaces).
func _tunnel(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float,
		mouth: bool, col: int, wall := TUNNEL_WALL_COLOUR + 2) -> void:
	var rim_c := _colour(TUNNEL_WALL_COLOUR + 1)        # 66 (render.c:223-226)
	# compose_tunnel patches the bore's wall with 0x43 = 67, but the block
	# variants (compose_tun_low / _high) use 0x41 = 65 for the same surface
	var wall_c := _colour(wall)
	var bands: Array = TUNNEL_ARCH_MID if col == 3 \
		else (TUNNEL_ARCH_RIGHT if col > 3 else TUNNEL_ARCH_LEFT)
	var edges: Array = TUNNEL_BAND_EDGES_MID if col == 3 \
		else (TUNNEL_BAND_EDGES_RIGHT if col > 3 else TUNNEL_BAND_EDGES_LEFT)
	var px := (x1 - x0) / 46.0
	# heights at the 47 slice BOUNDARIES, so the surfaces slope with the arch
	# instead of leaving vertical steps between slices
	var outer := PackedFloat32Array()
	var bore := PackedFloat32Array()
	outer.resize(47)
	bore.resize(47)
	for b in 47:
		var u: int = absi(b - 23)
		outer[b] = ARCH_OUTER_PX[u] * PIXEL_Y
		bore[b] = ARCH_BORE_PX[u] * PIXEL_Y
	for slice in 46:
		var sx0 := x0 + slice * px
		var sx1 := sx0 + px
		var o0 := outer[slice]
		var o1 := outer[slice + 1]
		var i0 := bore[slice]
		var i1 := bore[slice + 1]
		var band := 0
		while band < 3 and slice >= int(edges[band]):
			band += 1
		var c: Color = _colour(bands[band])
		# the reference paints SIX kind-4 records across the vault where this
		# emits four bands; the ids follow its paint order, so the two the
		# port never emits show up as absent rather than as a colour argument
		_quad(st, Vector3(sx0, o0, z1), Vector3(sx1, o1, z1),
			Vector3(sx1, o1, z0), Vector3(sx0, o0, z0), c,
			SurfaceIds.TUNNEL_K4_0 + band)
		if i0 > 0.0 or i1 > 0.0:
			_quad(st, Vector3(sx0, i0, z1), Vector3(sx1, i1, z1),
				Vector3(sx1, i1, z0), Vector3(sx0, i0, z0), wall_c,
				SurfaceIds.TUNNEL_K1_0)
		if mouth:
			_quad(st, Vector3(sx0, o0, z0), Vector3(sx1, o1, z0),
				Vector3(sx1, i1, z0), Vector3(sx0, i0, z0), rim_c,
				SurfaceIds.TUNNEL_K4_6)


## `sid` is the reference record this quad claims to be
## (scripts/app/SurfaceIds.gd). It rides in UV2.x, which nothing else uses, so
## the surface map costs the normal render nothing: the shader reads it only
## when sid_mode is on.
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		col: Color, sid: int) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_color(col)
		st.set_uv2(Vector2(float(sid), 0.0))
		st.add_vertex(v)


## Paint the surface-ID map instead of the picture. Every road material is
## switched together — a half-switched frame would be neither.
func set_sid_mode(on: bool) -> void:
	var v := 1.0 if on else 0.0
	for m in [_floor_mat, _solid_mat, _split_far_mat, _split_near_mat]:
		if m != null:
			m.set_shader_parameter("sid_mode", v)
	for m in _cover_mats:
		m.set_shader_parameter("sid_mode", v)
