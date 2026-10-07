# test_theme_resource_fresh.gd
# Fails when assets/Sonara_Theme.tres no longer matches what ThemeBuilder builds from the default
# settings (REQ-023). Regenerate with:
#   godot --headless --path Godot -s core/theme/build_theme_resource.gd
# Run: godot --headless --path Godot -s tests/test_theme_resource_fresh.gd -- --test
extends TestBase

const DATA_TYPES := [
	[Theme.DATA_TYPE_COLOR, "color"],
	[Theme.DATA_TYPE_CONSTANT, "constant"],
	[Theme.DATA_TYPE_FONT, "font"],
	[Theme.DATA_TYPE_FONT_SIZE, "font_size"],
	[Theme.DATA_TYPE_ICON, "icon"],
	[Theme.DATA_TYPE_STYLEBOX, "style"],
]


func suite_name() -> String:
	return "Sonara_Theme.tres freshness"


func run_tests() -> void:
	var built := ThemeBuilder.build(ThemePalette.from_settings({}))
	var saved := ResourceLoader.load("res://assets/Sonara_Theme.tres", "Theme", ResourceLoader.CACHE_MODE_IGNORE) as Theme
	_assert(saved != null, "Sonara_Theme.tres loads as a Theme")
	if saved == null:
		return
	_assert(ResourceUID.id_to_text(ResourceLoader.get_resource_uid("res://assets/Sonara_Theme.tres")) == "uid://c77m063o570pp",
		"the theme keeps its UID")
	var diffs: Array[String] = _differences(built, saved)
	for d in diffs.slice(0, 10):
		print("  differs: ", d)
	_assert(diffs.is_empty(), "the committed theme matches the builder (%d differences; regenerate with build_theme_resource.gd)" % diffs.size())


func _differences(a: Theme, b: Theme) -> Array[String]:
	var out: Array[String] = []
	if a.default_font_size != b.default_font_size:
		out.append("default_font_size")
	if (a.default_font == null) != (b.default_font == null) or (a.default_font != null and a.default_font.resource_path != b.default_font.resource_path):
		out.append("default_font")
	var types := {}
	for t in a.get_type_list() + b.get_type_list():
		types[t] = true
	for type in types:
		if a.get_type_variation_base(type) != b.get_type_variation_base(type):
			out.append("variation base of %s" % type)
		for entry in DATA_TYPES:
			var kind: int = entry[0]
			var names := {}
			for n in a.get_theme_item_list(kind, type) + b.get_theme_item_list(kind, type):
				names[n] = true
			for name in names:
				if not a.has_theme_item(kind, name, type) or not b.has_theme_item(kind, name, type):
					out.append("%s/%s/%s missing on one side" % [type, entry[1], name])
				elif not _same(a.get_theme_item(kind, name, type), b.get_theme_item(kind, name, type)):
					out.append("%s/%s/%s" % [type, entry[1], name])
	return out


func _same(x, y) -> bool:
	if x is Resource and y is Resource:
		if x.get_class() != y.get_class():
			return false
		if x is Font:
			return _font_same(x, y)
		for prop in x.get_property_list():
			if not (prop.usage & PROPERTY_USAGE_STORAGE) or prop.name in ["resource_path", "resource_name", "script"]:
				continue
			if not _same(x.get(prop.name), y.get(prop.name)):
				return false
		return true
	if x is float and y is float:
		return is_equal_approx(x, y)
	if x is Color and y is Color:
		return x.is_equal_approx(y)
	return x == y


func _font_same(x: Font, y: Font) -> bool:
	if x is FontVariation and y is FontVariation:
		return x.variation_embolden == y.variation_embolden and x.variation_transform == y.variation_transform \
			and x.base_font.resource_path == y.base_font.resource_path
	return x.resource_path == y.resource_path and x.get_font_name() == y.get_font_name()
