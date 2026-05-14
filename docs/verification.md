# Verification

## Commands

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
```

## Real Asset Sources

| Asset | Local Path | License Evidence |
| --- | --- | --- |
| GDQuest Sophia | `addons/gdquest_sophia` | `docs/licenses/GDQuest_3D_Characters_LICENSE.txt` says art assets are CC-BY 4.0 and require GDQuest credit. |
| Kenney Animated Characters 3 | `external/kenney_animated_characters_3/src` | `docs/licenses/Kenney_Animated_Characters_3_LICENSE.txt` says the pack is Creative Commons Zero, CC0. |
| Quaternius Ultimate Modular Women | `external/quaternius_modular_women_glb` | The Quaternius pack page lists the asset as CC0. The local GLBs were converted from downloaded FBX files with `tools/convert_fbx_to_glb.py`. |

## Requirement Matrix

| Requirement | Current Evidence |
| --- | --- |
| Runtime character mesh can be rebuilt cheaply | `SurfaceEffectAccumulator.rebuild_for_character()` clears accumulated volume/event state, rebuilds sparse samples, injects rest `CUSTOM0`, and rebinds per-surface shader materials without asset writes. |
| Runtime generated / clothing swap path | `tests/test_runtime_clothing_swap.gd` creates runtime `ArrayMesh` body/outerwear, records an impact, replaces outerwear, rebuilds, and asserts old impacts clear. Latest passing values: `first_samples=48`, `swapped_samples=64`, `first_x=-0.550`, `second_x=-0.720`, `materials=4`, `memory=445952`. |
| Current validation assets stay below 1 MB | Synthetic and real tests assert `estimate_memory_bytes() < 1024 * 1024`. Latest real values: Sophia `776688`, Kenney `484552`, Quaternius layered/playtest `981632`. |
| 400k-vertex production memory caveat is explicit | `README.md` and `docs/goal.md` document that Godot float4 `CUSTOM0` costs 16 bytes/vertex and would exceed 1 MB at 400k vertices; Unreal should use pre-skinned/rest position from the engine or a compressed stream. |
| No shared UV channel is required | `surface_effects.gdshader` samples the effect volume from character-local/rest-space position, not UV. UV is only used to preserve optional source textures. |
| Multiple material slots are supported | `tests/test_surface_effects.gd` builds a two-surface `ArrayMesh`, then asserts two shader material instances and shared impact state across slots. |
| Artist material event contract | `tests/test_surface_effects.gd` calls `add_surface_effect(7, ...)` and asserts every material slot receives recent debug uniforms: `impact_spheres`, `impact_dirs`, and `impact_meta.x == 7`; it also verifies accumulation into the fourth O(1) volume channel. |
| More than 32 effects can accumulate | `tests/test_surface_effects.gd` adds 80 events, asserts total count `80`, debug uniform count `32`, and verifies the first event remains in the volume after the debug ring wraps (`first_g=1.000`). |
| Sand and impacts share the same accumulation structure | `tests/test_surface_effects.gd` changes wind direction and proves prior sand remains in the shared volume while new-direction sand is added (`left=1.000`, `right=1.000`). |
| In-game effect playtest | `scenes/effect_playtest.tscn` loads the real Quaternius character. Left-click raycasts current visual mesh triangles and calls `add_surface_effect_at_triangle()`. Right-click starts sand wind from camera direction. Latest passing `tests/test_effect_playtest_scene.gd`: `samples=13456`, `memory=981632`, `events=1`, `click_error=0.0000`. |
| Real multi-slot skinned character is supported | `tests/test_real_character_assets.gd` loads GDQuest Sophia: 1 skinned mesh, 4 material slots, 93 bones, 8 animations. It asserts every slot receives shared impact/sand state. |
| Material preservation | `tests/test_surface_effects.gd` verifies albedo, normal, roughness, ORM, metallic, emission, and alpha scissor forwarding. `tests/test_real_character_assets.gd` also proves Sophia forwards `textured=4`, `normal=4`, `roughness=1`. |
| UV seams should not break the effect | The split-slot test uses arbitrary UVs; hit placement and shader state are independent of UV. `tests/render_real_seam_boundary_smoke.gd` renders a real Quaternius multi-surface boundary and asserts impact pixels on both sides. Latest values: `impact_samples=202`, `left=33`, `right=92`, `vertical=110`. |
| Physics hit can be moved to the visible outer layer | The layered capsule test sends a hit from inside and asserts the resolved local X moves to the incoming outer shell (`resolved_x=-0.480`). |
| Real multi-layer garment asset | `tests/test_real_layered_garment_asset.gd` loads Quaternius Adventurer: 4 skinned mesh parts, 17 material surfaces, 79 bones. It resolves from inner `hit_z=0.029` to outer `resolved_z=-0.189`, with `memory=981632`. |
| Real skinned FBX import path is supported | `tests/test_real_character_assets.gd` loads Kenney's skinned FBX model plus three separate animation FBXs. |
| Sand comes from a direction and respects normal angle | `tests/render_sand_mask_smoke.gd` renders the shader twice and samples pixels. Latest values: `left_early=0.084`, `left_late=0.669`, `right_late=0.084`, `parallel_late=0.084`. |
| Demo renders nonblank with the effect shader | `tests/render_visual_smoke.gd` captures `artifacts/demo_snapshot.png` and asserts enough pixels differ from the background. |
| Real character renders with visible impact shader | `tests/render_real_asset_smoke.gd` renders Sophia through Vulkan, captures `artifacts/sophia_surface_effects.png`, and checks `non_background=1561`, `impact_samples=432` against `tests/visual_baselines.json`. |
| Material O(1) impact evaluation | `surface_effects.gdshader` uses `surface_effect_volume` as the default impact path, so fragment cost is fixed layered-volume sampling instead of an event loop. The old array loop remains only behind `use_surface_effect_volume == false`. |
| Playtest hit performance baseline | `tests/benchmark_playtest_hit.gd` measures the current Godot playtest path. Latest run: `hits=8`, `raycast_ms=7.624`, `event_ms=10.368`, `full_ms=17.993`. This is still a prototype/editor-style exact visual raycast path, not the intended Unreal GameThread path. |
| Animated/skinned deformation attachment | `tests/test_skinned_surface_attachment.gd` attaches an event to a real Sophia triangle, seeks `Run`, and proves the visual triangle moves (`attachment_delta=0.592`) while the rest-space volume sample persists (`rest_alpha=1.000`). `tests/render_animated_real_asset_smoke.gd` checks visible animated impact metrics: `pose_delta=4.658`, `impact_samples=246`. |
| Runtime vertex deformation attachment | `tests/test_deformed_surface_attachment.gd` uses a deformation provider to resolve a visual hit at `visual_z=0.200`, then mutates the mesh while preserving rest `CUSTOM0`. It proves the visual triangle moved away from rest (`visual_rest_delta=0.200`) while the rest-space volume sample remains (`volume_g=1.000`). |
| Visual regression | `tests/visual_baseline.gd` and `tests/visual_baselines.json` define metric ranges for synthetic impact, real Sophia impact, animated Sophia impact, sand renders, and real seam-boundary renders. |

## Known Gaps

- The demo is a Godot prototype, not a production rendering module.
- The rest-space `CUSTOM0` path is too expensive for a 400k-vertex character under a 1 MB budget. Unreal should use an engine-provided pre-skinned/rest-position semantic or a compressed custom stream.
- CPU sample-based sand accumulation is suitable for validating the data model; production should move this to a GPU/compute or tighter update path for many characters.
- Godot currently does not implement the production worker/render-thread split. `docs/unreal_implementation_notes.md` defines the intended Unreal boundary: GameThread captures input/snapshot, WorkerThread resolves/splats CPU state, RenderThread/RHI uploads dirty texture regions.
- The O(1) volume path currently exposes four accumulated effect classes through RGBA. More independently styled effect classes need more volume channels/textures or a packed representation.
- Tiny bullet marks can alias or stretch at 48^3 resolution. The current prototype clamps the radius by `minimum_splat_voxel_span`; production may need higher-resolution local stamps or a hybrid decal path for very small circular marks.
- Material preservation covers common `StandardMaterial3D` texture/value channels, but exact parity with every Godot material feature is not claimed.
- Visual regression uses metric baselines, not exact pixel-for-pixel golden image comparison.
