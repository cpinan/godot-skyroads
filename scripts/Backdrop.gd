# The world backdrop, sized to exactly fill the camera's frustum.
#
# The original composites WORLDn.LZS into the framebuffer first, then draws the
# road spans over it. It never scrolls or parallaxes — the horizon is fixed.
#
# In Godot a CanvasLayer always draws OVER the 3D world, so putting the
# backdrop in the HUD layer hides the entire road. It has to live in 3D,
# parented to the camera at a fixed distance, filling the view.
#
# The frustum here is off-axis, so "filling the view" is not simply centred:
# the visible band at distance d runs from (bottom/near)*d to (top/near)*d,
# and bottom/top already carry the principal-point offset.
class_name Backdrop
extends MeshInstance3D

const DISTANCE := 60.0


## The world picture with its transparency removed, flattened onto black.
##
## WORLDn.LZS has no transparency: the DOS engine memcpy's the whole picture
## into the framebuffer, so its palette index 0 is opaque BLACK. The export
## carries index 0 as alpha 0 anyway, and Godot's importer then runs
## `fix_alpha_border`, which replaces the RGB of every fully transparent pixel
## with a bleed of its opaque neighbours. This material ignores alpha, so what
## reached the screen was that bleed — the night sky's black gaps came out as
## blue-grey blocks, which is what BUGS #30a described as "chunky blue
## rectangles" where the reference has small dim stars. The stars themselves
## were always correct; it was the black around them that was not.
static func flattened(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	var img := texture.get_image()
	if img == null:
		return texture
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(0, 0, 0, 1) if c.a < 0.5
				else Color(c.r, c.g, c.b, 1.0))
	return ImageTexture.create_from_image(img)


func setup(cam: SkyRoadsCamera, texture: Texture2D) -> void:
	# Ask the camera where the screen corners land at DISTANCE rather than
	# recomputing the frustum here. The projection is off-axis and its sign
	# convention is easy to get wrong; there is no reason to encode it twice.
	# WORLDn.LZS is 320x138: it covers the 3D viewport rows only, not the
	# dashboard band below. Stretching it over the whole canvas puts the
	# horizon in the wrong place and leaves the lower half black.
	var view_h: float = SkyRoads.VIEW_H * SkyRoads.PIXEL_ASPECT
	var quad := QuadMesh.new()
	quad.size = cam.screen_size_to_world(Vector2(cam.CANVAS.x, view_h), DISTANCE)
	mesh = quad
	# local to the camera, so it never moves relative to the view
	var centre := cam.screen_to_world(
		Vector2(cam.CANVAS.x * 0.5, view_h * 0.5), DISTANCE)
	position = centre - cam.global_position

	var mat := StandardMaterial3D.new()
	if OS.get_cmdline_user_args().has("--magenta-backdrop"):
		mat.albedo_color = Color.MAGENTA        # diagnostic: gaps show through
	else:
		mat.albedo_texture = flattened(texture)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.render_priority = -100
	material_override = mat
