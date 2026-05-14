# Unreal Implementation Notes

이 문서는 Godot prototype에서 검증한 결론을 Unreal 구현 기준으로 옮긴 것이다.

## 핵심 결론

- Event 배열은 입력/디버그용이고, 장기 상태는 character-local rest-space volume에 누적한다.
- Material의 기본 경로는 event loop가 아니라 volume 1회 샘플이다. Fragment 비용은 event 수와 무관해야 한다.
- Animation/skinning/deformation을 따라가려면 world position이 아니라 pre-skinned/rest local position으로 volume을 샘플해야 한다.
- GameThread에서 40만 vertex visual mesh를 매번 스캔하면 안 된다. 외곽 표면 보정과 splat 계산은 proxy, worker, GPU 경로로 분리해야 한다.

## 현재 Godot Prototype에서 증명한 것

관련 코드:

- `scripts/surface_effect_accumulator.gd`
- `scripts/mesh_surface_sampler.gd`
- `scripts/effect_playtest_controller.gd`
- `shaders/surface_effects.gdshader`

현재 구조:

1. Character rebuild 시 mesh surface를 훑어 sparse exterior sample과 48-layer RGBA8 layered volume을 만든다.
2. Godot에서는 `CUSTOM0.rgb`에 character-local rest position을 주입한다.
3. Material은 `CUSTOM0.rgb`를 volume 좌표로 변환해 `surface_effect_volume`을 샘플한다.
4. Bullet impact와 sand는 같은 volume에 누적된다. RGBA channel은 effect class 1-4다.
5. `MAX_IMPACTS = 32` event ring은 material debug/fallback용이다. 누적 한계가 아니다.

현재 성능 측정:

```text
initial path:       hits=8 raycast_ms=98.746 event_ms=3.583  full_ms=102.329
first optimized:    hits=8 raycast_ms=7.624  event_ms=10.368 full_ms=17.993
latest benchmark:  hits=8 raycast_ms=7.440  event_ms=0.207  full_ms=7.648
```

명령:

```powershell
godot_console --path D:\MeshSurfaceImpactSystem --script res://tests/benchmark_playtest_hit.gd
```

해석:

- 가장 컸던 병목은 playtest용 visual triangle raycast였다.
- 중복 skinning attachment resolve를 제거한 뒤 event/splat path는 약 0.2 ms로 내려갔다.
- 최적화 후에도 click당 약 7.6 ms가 걸리며, 대부분은 exact visual raycast다. 이 수치는 실제 게임 hit path로 받아들이면 안 된다.
- Unreal 게임에서는 physics/collision hit를 입력으로 받고, visual exterior 보정만 별도 proxy에서 수행해야 한다.

## Runtime 데이터 구조

권장 기본 state:

| Data | Purpose | Budget note |
| --- | --- | --- |
| Accumulation volume | Effect 결과의 authoritative state | 48^3 RGBA8 = 442,368 bytes |
| Exterior surface proxy | Physics hit를 visual outer layer로 보정 | mesh rebuild/clothing swap 때 재생성 |
| Debug event ring | 최근 event 확인, artist debug, fallback | 32 records 정도로 제한 |
| Dirty region queue | RenderThread upload 범위 | full upload 회피 |
| Generation id | clothing swap/rebuild invalidation | worker result 폐기 기준 |

48^3 RGBA8은 약 432 KiB다. 64^3 RGBA8은 texture 하나만 1 MiB라서 다른 상태를 담을 여유가 없다. 1 MB/character 제한을 유지하려면 48^3 이하, channel packing, sparse/brick update를 먼저 고려한다.

Godot prototype은 rest position을 `CUSTOM0` float4로 넣는다. 40만 vertex에서는 이것만 약 6.4 MB이므로 Unreal에서는 이 방식을 그대로 쓰면 안 된다.

Unreal material에서는 우선 다음 중 하나를 써야 한다.

- `PreSkinnedLocalPosition` material node
- engine/custom vertex factory가 제공하는 compressed rest position
- 필요한 경우에만 half/quantized custom stream

## Material 계약

Material이 받는 기본 parameter:

| Name | Type | Meaning |
| --- | --- | --- |
| `SurfaceEffectVolume` | Texture3D 또는 Texture2DArray equivalent | RGBA accumulated effect mask |
| `SurfaceEffectSampler` | sampler | linear 또는 point policy 선택 |
| `EffectVolumeOriginLocal` | float3 | character-local volume min |
| `EffectVolumeInvSize` | float3 | local position to UVW |
| `EffectVolumeResolution` | float | debug/min radius 계산용 |
| `RecentEvents` | bounded structured/uniform data | optional debug/fallback only |

Material 해석:

```hlsl
float3 restLocal = PreSkinnedLocalPosition;
float3 uvw = (restLocal - EffectVolumeOriginLocal) * EffectVolumeInvSize;
float4 masks = SurfaceEffectVolume.SampleLevel(SurfaceEffectSampler, uvw, 0);
```

Channel convention:

- R: effect id 1, 현재 bullet/blood
- G: effect id 2, 현재 sand
- B: effect id 3
- A: effect id 4

Artist는 `masks`를 색, roughness, normal/detail overlay, opacity, dissolve 등 원하는 표현에 사용한다. 기본 material path에서는 event 개수만큼 loop를 돌지 않는다.

중요한 손실:

- Volume에는 누적 결과만 남는다.
- 같은 channel의 가까운 event는 합쳐진다.
- 개별 event의 시간, 순서, 원래 반경, 개별 id는 volume만으로 복원할 수 없다.
- 이 정보가 필요한 연출은 짧은 lifetime의 debug/recent event buffer나 별도 high-resolution stamp path를 추가해야 한다.

## Hit Placement

게임에서 들어오는 입력:

- effect id
- approximate physics hit world position
- shot/effect direction
- radius
- strength
- optional bone/component/section hint

처리 목표:

1. Physics asset hit를 시작점으로 삼는다.
2. Shot direction을 기준으로 visual mesh의 가장 바깥 표면을 찾는다.
3. 그 위치의 rest/pre-skinned local position을 volume center로 쓴다.
4. Material debug용으로는 resolved visual position도 보관할 수 있다.

Unreal 구현에서는 40만 vertex visual mesh 전체 scan을 GameThread에서 하면 안 된다. 후보 방법:

- clothing rebuild 때 outer surface sample/BVH/grid를 만든다.
- physics hit 근처와 shot direction corridor만 탐색한다.
- physics/collision proxy가 아니라 최종 visible garment layer 기준 proxy를 따로 둔다.
- body, top, outer가 겹치면 incoming ray 기준 가장 앞에 있는 proxy hit를 선택한다.

Godot의 `MeshSurfaceSampler.find_outer_surface()`는 이 정책의 최소 증명이다. Production에서는 sample count, spatial index, generation invalidation이 필요하다.

## Sand Accumulation

Sand도 bullet과 같은 volume에 쓴다. 방향이 바뀌어도 volume을 clear하지 않는다.

현재 rule:

```text
front_mask = wind front를 지난 표면인지
normal_factor = 1 - abs(dot(surface_normal, wind_direction))
mask = front_mask * normal_factor * amount
```

즉, normal이 wind direction과 평행할수록 덜 묻고, 수직에 가까울수록 더 묻는다.

Unreal에서는 매 frame 40만 vertex나 모든 proxy sample을 GameThread에서 훑으면 안 된다. 권장 방향:

- sand front 진행은 worker job 또는 GPU compute에서 처리한다.
- dirty brick/layer만 RenderThread에 upload한다.
- 방향이 바뀔 때도 기존 channel을 유지하고 새 방향 contribution만 max/additive 방식으로 누적한다.
- 많은 캐릭터가 동시에 sand를 받으면 character별 update budget을 둔다.

## Threading Boundary

권장 흐름:

| Thread | Responsibility |
| --- | --- |
| GameThread | hit 입력 수집, component transform/mesh generation snapshot, job enqueue, 완료 결과 적용 |
| WorkerThread | exterior proxy search, rest-space center 계산, CPU volume buffer splat, dirty region 계산 |
| RenderThread/RHI | transient 3D texture 또는 texture array dirty upload, shader resource swap |

주의점:

- Worker는 live `USkeletalMeshComponent`, `UObject`, render resource를 직접 만지지 않는다.
- Clothing swap/rebuild마다 generation id를 증가시킨다.
- Worker 결과가 돌아왔을 때 generation id가 다르면 폐기한다.
- CPU volume buffer는 double buffer 또는 pending update queue로 보호한다.
- Texture resource 자체를 매 hit마다 rebuild하지 말고 dirty region/layer만 upload한다.

Godot prototype에는 worker job까지 넣지 않았다. Godot의 SceneTree/Skeleton/RenderingServer 접근은 main thread 제약이 강해서, 여기서는 Unreal 구현 경계를 문서화하는 것으로 남긴다.

## Animation, Skinning, Deformation

Volume state는 rest/pre-skinned local position에 묶인다.

따라서:

- 캐릭터가 이동/회전해도 material sample 좌표는 변하지 않는다.
- animation pose가 바뀌어도 같은 vertex의 pre-skinned coordinate로 volume을 샘플하므로 표면을 따라간다.
- morph/cloth/procedural deformation도 같은 topology와 rest coordinate가 유지되면 따라간다.
- topology나 garment set이 바뀌면 proxy와 volume을 rebuild하고 이전 state는 clear한다.

현재 Godot test:

- `tests/test_skinned_surface_attachment.gd`
- `tests/test_deformed_surface_attachment.gd`
- `tests/render_animated_real_asset_smoke.gd`

## Hit Shape와 Resolution 한계

Volume-only 방식은 "3D 공간의 누적 mask와 표면의 교차"를 보여준다. 그래서 아주 작은 hit는 항상 원형 decal처럼 보장되지 않는다.

길쭉하게 보이는 주요 원인:

- 48^3 voxel resolution이 낮다.
- character AABB가 축마다 길이가 달라 voxel의 world/local 크기가 다르다.
- 표면이 volume sphere를 비스듬히 자르면 footprint가 늘어난다.
- radius가 voxel footprint보다 작으면 한두 voxel에 의해 모양이 결정된다.

현재 Godot에는 `minimum_splat_voxel_span = 1.25`가 있어 radius를 최소 voxel footprint 이상으로 올린다. 이것은 aliasing을 줄이지만, 아주 작은 피격 표현을 원하면 반경이 의도보다 커진다.

선택지:

| Goal | Option | Cost |
| --- | --- | --- |
| O(1) material과 1 MB 유지 | 48^3 volume 유지, radius를 voxel 이상으로 제한 | 작은 hit 모양은 coarse |
| 더 작은 bullet mark | local high-resolution impact stamp/brick 추가 | memory와 update 관리 증가 |
| 완전한 원형 decal | recent event buffer에서 tangent-plane decal 계산 | material loop 또는 제한된 event 수 |
| 많은 누적과 작은 hit 모두 필요 | coarse accumulated volume + short-lived high-res decals hybrid | 구현 복잡도 증가 |

Unreal 1차 구현은 volume-only를 기본으로 두고, bullet mark가 실제로 더 작아야 하면 별도 high-res near-hit stamp를 추가하는 것이 현실적이다.

## Unreal 구현 단계 제안

Phase 1:

- `USurfaceEffectComponent` 생성
- 48^3 RGBA8 transient volume state
- material parameter collection 또는 dynamic material instance에 volume/origin/inv size bind
- material에서 `PreSkinnedLocalPosition` 기반 O(1) sample
- physics hit 입력 API와 clear/rebuild API 구현

Phase 2:

- clothing swap/rebuild 시 exterior surface proxy 생성
- shot direction 기준 outer surface resolve
- generation id로 stale worker result 폐기
- automated test character로 body/top/outer 겹침 검증

Phase 3:

- hit/sand splat worker job화
- dirty layer/brick queue
- RenderThread/RHI dirty upload
- GameThread hitch 측정

Phase 4:

- GPU compute sand accumulation
- resolution/clipmap/brick trade-off 검증
- tiny bullet mark가 필요하면 hybrid high-res stamp 추가

## Unreal에서 먼저 검증해야 할 항목

- 40만 vertex character에서 material path가 event 수와 무관하게 O(1)인지
- `PreSkinnedLocalPosition`이 사용하는 mesh pipeline, cloth/morph path에서도 안정적인지
- 48^3 volume으로 5 cm hit가 acceptable한지
- clothing swap 시 rebuild/clear 비용이 frame budget 안에 들어오는지
- worker job 결과가 swap 이후 잘 폐기되는지
- dirty upload가 full texture rebuild 없이 동작하는지
- body/top/outer 3겹에서 항상 incoming direction 기준 outer layer에 묻는지
