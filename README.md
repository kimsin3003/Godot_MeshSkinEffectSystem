# Mesh Surface Impact System

Godot 4 prototype for UV-independent accumulated surface effects on runtime-generated skinned characters.

The prototype keeps the included validation characters below 1 MB by storing sparse exterior mesh samples, one shared 48^3 RGBA8 effect volume, and a small debug event ring instead of allocating per-slot render targets.

The default material path is O(1) per fragment: it samples a shared layered RGBA8 effect volume, where RGBA channels represent effect classes 1-4. Bullet impacts and sand accumulation both write into this volume. The compact event uniforms are still provided for debugging and custom materials that need recent raw position/radius/direction/effect-id records; the 32-event ring is not the accumulation limit.

For animation/deformation, the Godot prototype injects character-local rest position into `CUSTOM0` at runtime and samples the volume with that coordinate. This proves the data model, but a 400k-vertex production character cannot afford float4 `CUSTOM0` under a 1 MB budget; the Unreal version should use engine-provided pre-skinned/rest position or a compressed vertex stream.

See `docs/goal.md` for the translated feature goal and implementation constraints.
See `docs/verification.md` for the current requirement-to-test matrix.
See `docs/completion_criteria.md` for the stricter completion gate.
See `docs/unreal_implementation_notes.md` for the Unreal port architecture, threading boundaries, and production caveats.

## Real Character Assets

- `addons/gdquest_sophia`: Sophia character from GDQuest 3D Characters, copied into the project path expected by its Godot resources.
- `external/kenney_animated_characters_3`: Kenney Animated Characters 3 FBX model and animation files.
- `external/quaternius_modular_women_glb`: Quaternius Ultimate Modular Women GLBs converted from FBX for real layered garment and seam-boundary tests.

GDQuest art assets are CC-BY 4.0 and require attribution. Kenney Animated Characters 3 and Quaternius Ultimate Modular Women are CC0.

## Local Setup

Godot 4.6.2 is installed through WinGet as `GodotEngine.GodotEngine`.

Open the in-game effect playtest:

```powershell
godot --path D:\MeshSurfaceImpactSystem
```

Controls:

- Left click: add the selected surface effect at the clicked visual mesh triangle.
- Right click: start sand wind from the camera direction toward the clicked character surface.
- `1`-`4`: select effect id.
- Mouse wheel or `[` / `]`: change radius.
- `-` / `=`: change strength.
- `W` / `A` / `S` / `D`: move the camera orbit focus.
- Arrow keys: orbit the camera around the character.
- Middle mouse drag: orbit the camera around the character.
- `Z` / `X`: move the camera down/up.
- `P`: toggle character animation playback.
- `T`: toggle sand wind.
- `F`: restart the sand front from the current direction.
- `Q` / `E`: rotate the sand wind direction.
- `C`: clear accumulated effects.
- `R`: rebuild the current character surface cache.
- `Tab`: swap between the Quaternius Adventurer and Soldier character assets.

Run headless validation:

```powershell
godot_console --headless --path D:\MeshSurfaceImpactSystem --editor --quit
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_surface_effects.gd
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_runtime_clothing_swap.gd
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_real_character_assets.gd
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_real_layered_garment_asset.gd
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_skinned_surface_attachment.gd
godot_console --headless --path D:\MeshSurfaceImpactSystem --script res://tests/test_deformed_surface_attachment.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/test_effect_playtest_scene.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_visual_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_real_asset_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_animated_real_asset_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_sand_mask_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_real_seam_boundary_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/benchmark_playtest_hit.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/benchmark_accumulation_scaling.gd
```

The render tests compare tracked metrics against `tests/visual_baselines.json`; they are not just nonblank smoke captures.
