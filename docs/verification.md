# Verification

## Commands

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

## Real Asset Sources

| Asset | Local Path | License Evidence |
| --- | --- | --- |
| GDQuest Sophia | `addons/gdquest_sophia` | `docs/licenses/GDQuest_3D_Characters_LICENSE.txt` says art assets are CC-BY 4.0 and require GDQuest credit. |
| Kenney Animated Characters 3 | `external/kenney_animated_characters_3/src` | `docs/licenses/Kenney_Animated_Characters_3_LICENSE.txt` says the pack is Creative Commons Zero, CC0. |
| Quaternius Ultimate Modular Women | `external/quaternius_modular_women_glb` | The Quaternius pack page lists the asset as CC0. The local GLBs were converted from the downloaded FBX files with `tools/convert_fbx_to_glb.py`. |

## Requirement Matrix

| Requirement | Current Evidence |
| --- | --- |
| Runtime character mesh can be rebuilt cheaply | `SurfaceEffectAccumulator.rebuild_for_character()` clears impact state, rebuilds sparse samples, and rebinds per-surface shader materials only. |
| Runtime generated / clothing swap path | `tests/test_runtime_clothing_swap.gd` creates runtime `ArrayMesh` body/outerwear, records an impact, replaces the outerwear with a newly generated mesh, rebuilds, and asserts sample/material counts update while old impacts are cleared. Latest passing values: `first_samples=48`, `swapped_samples=64`, `first_x=-0.550`, `second_x=-0.720`, `materials=4`, `memory=2560`. |
| Per-character memory stays below 1 MB | `tests/test_surface_effects.gd` asserts `estimate_memory_bytes() < 1024 * 1024` for layered and multi-slot cases. |
| No shared UV channel is required | `surface_effects.gdshader` computes impact masks from local position and sand from world position/normal; UV is only used to preserve an optional base texture sample. |
| Multiple material slots are supported | `tests/test_surface_effects.gd` builds a two-surface `ArrayMesh`, then asserts two shader material instances and shared impact state across both slots. |
| Artist material event contract | `tests/test_surface_effects.gd` calls `add_surface_effect(7, ...)` and asserts every material slot receives `impact_spheres`, `impact_dirs`, and `impact_meta.x == 7`, so a custom material can render effect id A at the resolved surface position. |
| In-game effect playtest | `scenes/effect_playtest.tscn` loads the real Quaternius character, raycasts left-clicks against visual mesh triangles, and calls `add_surface_effect_at_visual_surface()` so the material event center matches the clicked visual position exactly. Right-click starts sand wind from the camera direction toward the clicked surface, while `T`/`F`/`Q`/`E` control sand playback and direction. `tests/test_effect_playtest_scene.gd` verifies the scene builds `13456` samples, stays at `323968` bytes, a center-screen click adds one event with `click_error=0.0000`, and `start_sandstorm(Vector3(1,0,0))` pushes the sand direction to materials. |
| Real multi-slot skinned character is supported | `tests/test_real_character_assets.gd` loads GDQuest Sophia: 1 skinned mesh, 4 material slots, 93 bones, 8 animations. It asserts every slot receives shared impact/sand state. |
| Material preservation | `tests/test_surface_effects.gd` creates a `StandardMaterial3D` with albedo, normal, roughness, ORM, metallic, emission, and alpha scissor data and asserts the generated `ShaderMaterial` receives matching uniforms. `tests/test_real_character_assets.gd` also proves Sophia forwards `textured=4`, `normal=4`, `roughness=1`. |
| UV seams should not break the effect | The split-slot test gives each surface arbitrary UVs; hit placement and shader state are independent of those UVs. `tests/render_real_seam_boundary_smoke.gd` renders a real Quaternius multi-surface boundary and asserts impact pixels on both sides of the boundary. Latest passing values: `impact_samples=173`, `left=13`, `right=83`, `vertical=96`. |
| Physics hit can be moved to the visible outer layer | The layered capsule test sends a hit from the inside and asserts the resolved local X moves to the incoming outer shell. |
| Real multi-layer garment asset | `tests/test_real_layered_garment_asset.gd` loads Quaternius Adventurer from GLB: 4 skinned mesh parts, 17 material surfaces, 79 bones. It finds a real torso column with 2 overlapping source surfaces and depth `0.365`, starts from an inner physics hit (`hit_z=0.029`), and resolves to the incoming outer surface (`outer_z=-0.172`, `resolved_z=-0.189`) while memory stays at `323968` bytes. |
| Real skinned FBX import path is supported | `tests/test_real_character_assets.gd` loads Kenney's skinned FBX model plus three separate animation FBXs. |
| Sand comes from a direction and respects normal angle | `tests/render_sand_mask_smoke.gd` renders the real shader twice and samples pixels. Latest passing values: `left_early=0.084`, `left_late=0.669`, `right_late=0.084`, `parallel_late=0.084`. |
| Demo renders nonblank with the effect shader | `tests/render_visual_smoke.gd` captures `artifacts/demo_snapshot.png` and asserts enough pixels differ from the background. |
| Real character renders with visible impact shader | `tests/render_real_asset_smoke.gd` renders Sophia through Vulkan, captures `artifacts/sophia_surface_effects.png`, asserts visible magenta impact pixels, and checks `non_background`/`impact_samples` against `tests/visual_baselines.json`. |
| Animated/skinned deformation approximation | `tests/render_animated_real_asset_smoke.gd` disables Sophia's animation tree, seeks the imported `Run` animation, asserts the skeleton pose changed (`pose_delta=4.658`), then renders the effect and checks visible magenta impact metrics against `tests/visual_baselines.json` (`impact_samples=73`). This proves the current root-local approximation is acceptable for that animated real-character case; it is not a CPU-skinned exterior sampler. |
| Visual regression | `tests/visual_baseline.gd` and `tests/visual_baselines.json` define metric ranges for synthetic impact, real Sophia impact, animated Sophia impact, sand front/normal attenuation, and real seam-boundary renders. The render tests fail if those metrics leave the expected ranges. |

## Known Gaps

- See `docs/completion_criteria.md` for the full "complete only when all evidence exists" gate.
- The demo is still a shader/prototype path, not a production Godot rendering module.
- Animated/skinned vertex deformation is not resampled per animation frame; `render_animated_real_asset_smoke.gd` covers the current approximation on Sophia's Run pose.
- Material preservation covers common `StandardMaterial3D` texture/value channels, but exact parity with every Godot material feature is not claimed.
- The artist event contract is uniform-level data delivery; authored visual style remains shader/material content.
- Visual regression uses metric baselines, not exact pixel-for-pixel golden image comparison.
