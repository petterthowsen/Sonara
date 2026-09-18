# Godot Code Guidelines

## GDScript

- Use two blank lines between functions.
- Add a brief `##` comment above each class and function describing its purpose.
- Prefer < 600 lines, avoid > 1000 lines. Use composition, signals, reusable components.
- Make tweakable values into configurable properties.
- Avoid manually editing `.tscn`, `.uid`.
- Use `a if cond else b` for ternaries.
- Avoid building scene trees in code, instead use Godot MCP tools and ensure scene components aren't blank/empty but contain sensible default values, making it more comfortable to adjust and style in-editor.

## Scenes

Always use Godot MCP tools for scene/resource edits—never hand-edit text. Scene paths must be relative to their scene.
