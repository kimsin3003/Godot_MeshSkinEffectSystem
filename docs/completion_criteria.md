# Completion Criteria

This project is not complete just because the current prototype imports and renders.

The work can only be treated as complete when every item below has direct evidence.

## Required Evidence

| Area | Completion Gate |
| --- | --- |
| Real multi-slot character | At least one real skinned character with multiple material slots is tested end-to-end. |
| Runtime generated / clothing swap path | A test rebuilds or swaps runtime mesh content and proves impact state resets without expensive bake or asset writes. |
| Memory budget | Real-character tests prove persistent per-character state stays below 1 MB for the intended production character scale, not only for small sample assets. |
| No shared UV dependency | The effect placement must remain correct when UVs are discontinuous or arbitrary; UV may only be used to sample existing base textures. |
| UV seam visual quality | A rendered real-asset test must show the effect crossing or approaching material/UV boundaries without obvious discontinuity. |
| Physics hit to visual exterior | A real-character test must start from an approximate inner physics hit and resolve to the visible outer surface using shot direction. |
| Multiple garment layers | A test must cover overlapping visible layers and prove the outer visible layer receives the effect. |
| Artist material event contract | A test must prove material slots receive enough data for custom material expressions: effect id, resolved/debug position, radius, direction, strength, and/or accumulated effect masks. |
| More than debug-ring accumulation | A test must prove accumulation is not limited by the raw event uniform ring. |
| Sand direction persistence | A test must prove sand remains when wind direction changes and new-direction sand is added. |
| Sand direction front | A rendered or numeric test must prove sand appears from the configured wind/front direction over time. |
| Normal-angle sand attenuation | A test must prove surfaces parallel to wind receive less sand than perpendicular surfaces. |
| Material O(1) evaluation | The default material path must not loop over event count per fragment. |
| Material preservation | The adapter must preserve at least albedo, normal, roughness/ORM, and alpha behavior needed by the source material set. |
| Animation/skinning/deformation | Triangle-attached effects must remain on skinned/deformed surfaces. |
| Visual regression | Rendered smoke tests must include real characters and should fail if impact/sand masks disappear. |
| Documentation | `README.md`, `docs/goal.md`, `docs/verification.md`, and asset/license documentation must match implemented behavior and known gaps. |

## Current Status

The current state is a working Godot prototype, not final production completion.

Already covered:

- Godot 4.6.2 import and runtime execution.
- Synthetic layered mesh exterior selection.
- Synthetic multi-material-slot state propagation.
- Artist material event contract is covered by `tests/test_surface_effects.gd`.
- The 32-event debug uniform ring is no longer the accumulation limit: `tests/test_surface_effects.gd` adds 80 events and verifies the first event remains in the shared volume.
- Sand and impact accumulation share the same 3D volume: `tests/test_surface_effects.gd` changes wind direction and verifies old and new sand regions both remain.
- Real Sophia skinned character import: 4 slots, 93 bones, 8 animations.
- Real Kenney FBX model and animation FBX import.
- Real Quaternius Adventurer layered garment import: 4 skinned mesh parts, 17 material surfaces, 79 bones.
- Real multi-layer garment exterior resolution is covered by `tests/test_real_layered_garment_asset.gd`: `hit_z=0.029` resolves to `resolved_z=-0.189`, with memory at `981632` bytes.
- Real UV seam/boundary visual quality is covered by `tests/render_real_seam_boundary_smoke.gd`.
- Real Sophia render smoke with visible impact shader.
- Runtime clothing swap is covered by `tests/test_runtime_clothing_swap.gd`.
- Sand front progression and normal-angle attenuation are covered by rendered pixel sampling in `tests/render_sand_mask_smoke.gd`.
- Material preservation for albedo, normal, roughness, ORM, metallic, emission, and alpha scissor is covered by `tests/test_surface_effects.gd`.
- Animated/skinned deformation is covered by `tests/test_skinned_surface_attachment.gd`: a real Sophia triangle moves while the rest-space volume sample persists.
- Runtime vertex deformation is covered by `tests/test_deformed_surface_attachment.gd`: provider-resolved visual hit and mutated mesh vertices keep the same rest-space sampling coordinate.
- Visual regression is covered by `tests/visual_baseline.gd` and `tests/visual_baselines.json`.

Still incomplete for production:

- The current Godot rest-coordinate implementation uses float4 `CUSTOM0`, which is valid for the included validation assets but exceeds the 1 MB budget for a 400k-vertex character.
- Production-scale Unreal implementation should use `PreSkinnedLocalPosition` or an equivalent compressed/rest-position path instead of adding 16 bytes per vertex.
- CPU sample-based sand accumulation should be replaced or optimized for many high-density characters.
