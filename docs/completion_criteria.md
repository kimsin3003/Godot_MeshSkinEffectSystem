# Completion Criteria

This project is not complete just because the current prototype imports and renders.

The work can only be treated as complete when every item below has direct evidence.

## Required Evidence

| Area | Completion Gate |
| --- | --- |
| Real multi-slot character | At least one real skinned character with multiple material slots is tested end-to-end. |
| Runtime generated / clothing swap path | A test rebuilds or swaps runtime mesh content and proves impact state resets without expensive bake or asset writes. |
| Memory budget | Real-character tests prove persistent per-character state stays below 1 MB, with the estimate tied to actual sample and impact data. |
| No shared UV dependency | The effect placement must remain correct when UVs are discontinuous or arbitrary; UV may only be used to sample existing base textures. |
| UV seam visual quality | A rendered real-asset test must show the effect crossing or approaching material/UV boundaries without obvious discontinuity. |
| Physics hit to visual exterior | A real-character test must start from an approximate inner physics hit and resolve to the visible outer surface using shot direction. |
| Multiple garment layers | A test must cover overlapping visible layers and prove the outer visible layer receives the effect. |
| Artist material event contract | A test must prove material slots receive enough data for custom material expressions: effect id, resolved position, radius, direction, and strength. |
| Sand direction front | A rendered or numeric test must prove sand appears from the configured wind/front direction over time. |
| Normal-angle sand attenuation | A test must prove surfaces parallel to wind receive less sand than perpendicular surfaces. |
| Material preservation | The adapter must preserve at least albedo, normal, roughness/ORM, and alpha behavior needed by the source material set. |
| Animation/skinning/deformation | Triangle-attached events must follow skinned deformation, and runtime deformation must have a tested provider path for current deformed vertex positions. |
| Visual regression | Rendered smoke tests must include real characters and should fail if impact/sand masks disappear. |
| Documentation | `docs/goal.md`, `docs/verification.md`, and asset/license documentation must match the implemented behavior and known gaps. |

## Current Status

The current state is a working prototype, not final completion.

Already covered:

- Godot 4.6.2 import and runtime execution.
- Synthetic layered mesh exterior selection.
- Synthetic multi-material-slot state propagation.
- Artist material event contract is covered by `tests/test_surface_effects.gd`: `add_surface_effect(7, ...)` pushes resolved position/radius, direction/strength, and `effect_id` metadata to every material slot.
- Real Sophia skinned character import: 4 slots, 93 bones, 8 animations.
- Real Kenney FBX model and animation FBX import.
- Real Quaternius Adventurer layered garment import: 4 skinned mesh parts, 17 material surfaces, 79 bones.
- Real multi-layer garment exterior resolution is covered by `tests/test_real_layered_garment_asset.gd`: a real column with 2 overlapping source surfaces resolves from inner `hit_z=0.029` to outer `resolved_z=-0.189`, with memory at `323968` bytes.
- Real UV seam/boundary visual quality is covered by `tests/render_real_seam_boundary_smoke.gd`: it captures `artifacts/quaternius_layered_seam_effects.png` and asserts impact coverage on both sides of a real multi-surface boundary.
- Real Sophia render smoke with visible impact shader.
- Runtime clothing swap is covered by `tests/test_runtime_clothing_swap.gd`: generated `ArrayMesh` outerwear is replaced, sampler/material counts update, stale impacts clear, and memory remains below 1 MB.
- Sand front progression and normal-angle attenuation are covered by rendered pixel sampling in `tests/render_sand_mask_smoke.gd`.
- Material preservation for albedo, normal, roughness, ORM, metallic, emission, and alpha scissor is covered by `tests/test_surface_effects.gd`; real Sophia also proves albedo/normal/roughness forwarding.
- Animated/skinned deformation is covered by `tests/test_skinned_surface_attachment.gd`: a real Sophia triangle-attached event follows the `Run` pose change (`movement=0.592`, `attachment_delta=0.592`). `tests/render_animated_real_asset_smoke.gd` also verifies visible impact pixels on an animated Sophia pose.
- Runtime vertex deformation is covered by `tests/test_deformed_surface_attachment.gd`: a custom deformation provider moves a recorded triangle vertex and the material event center follows it (`delta=0.200`).
- Visual regression is covered by `tests/visual_baseline.gd` and `tests/visual_baselines.json`; synthetic impact, real Sophia impact, animated Sophia impact, sand renders, and real seam-boundary renders now fail when tracked metrics leave expected ranges.
- Memory estimates under 1 MB for current tests.

Still incomplete:

- None against the Required Evidence table above. The full command suite listed in `docs/verification.md` passed after the latest documentation updates.
