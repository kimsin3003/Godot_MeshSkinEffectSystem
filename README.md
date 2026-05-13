# Mesh Surface Impact System

Godot 4 prototype for UV-independent accumulated surface effects on runtime-generated skinned characters.

The prototype keeps per-character state below 1 MB by storing compact effect records and sparse exterior mesh samples instead of allocating per-slot render targets.

Materials receive compact surface event uniforms: local position/radius, direction/strength, and effect id. The included shader renders `effect_id == 1` as the default impact mark, while custom artist shaders can use the same data for other effect types.

See `docs/goal.md` for the translated feature goal and implementation constraints.
See `docs/verification.md` for the current requirement-to-test matrix.
See `docs/completion_criteria.md` for the stricter completion gate.

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

- Left click: add the selected surface effect exactly at the clicked visual mesh position.
- Right click: start sand wind from the camera direction toward the clicked character surface.
- `1`-`4`: select effect id.
- Mouse wheel or `[` / `]`: change radius.
- `-` / `=`: change strength.
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
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/test_effect_playtest_scene.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_visual_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_real_asset_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_animated_real_asset_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_sand_mask_smoke.gd
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/render_real_seam_boundary_smoke.gd
```

The render tests compare tracked metrics against `tests/visual_baselines.json`; they are not just nonblank smoke captures.
