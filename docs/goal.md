# 목표 문서: Mesh Surface Impact System

## 목표

Godot 4 기준으로, 런타임에 생성되거나 교체되는 캐릭터 `MeshInstance3D` / skinned mesh 표면에 UV와 material slot 구성에 의존하지 않는 누적 표면 효과를 표시한다.

- 게임 코드는 "이 위치에서 A 이펙트가 발생했다"는 surface event를 넘긴다.
- material/shader는 effect id, 위치, 반경, 방향, 강도 또는 누적 mask를 받아 아티스트가 원하는 표현을 만든다.
- 총알 피격은 physics hit를 시작점으로 삼되, shot direction 기준 가장 바깥쪽 visual surface에 표시한다.
- 모래바람은 방향/front/normal angle에 따라 표면에 누적되고, 방향이 바뀌어도 기존 누적 결과가 유지된다.
- 여러 material slot, 끊어진 UV, UV seam, 여러 겹 의상에서도 하나의 캐릭터 표면처럼 보이게 한다.

## 제약

- 의상 교체나 runtime mesh 재생성 시 초기화 비용이 작아야 한다.
- 현재 검증 asset 기준 persistent per-character memory는 1 MB 미만이어야 한다.
- 전체 mesh를 관통하는 공통 UV 채널은 없다고 가정한다.
- 원본 asset은 수정하지 않는다.
- physics asset은 실제 의상 부피를 완전히 반영하지 못할 수 있으므로, 표시 위치는 실제 visual mesh 기준으로 보정한다.

## 현재 Godot 접근

UV 대신 character-local/rest-space 좌표에서 효과를 관리한다.

1. `SurfaceEffectAccumulator.rebuild_for_character()`가 캐릭터 mesh를 훑어 sparse surface sample, shared 3D effect volume, material override를 구성한다.
2. runtime에서 각 mesh surface를 복제해 `CUSTOM0.rgb`에 character-local rest position을 넣는다.
3. shader는 skinned/deformed 뒤의 world position이 아니라 `CUSTOM0.rgb`를 사용해 3D volume을 샘플링한다.
4. 피격 event는 triangle/barycentric 정보를 받을 수 있으면 visual hit는 현재 변형된 triangle에서 계산하고, 누적 splat은 rest-space center에 기록한다.
5. 모래바람도 surface sample을 따라 같은 volume의 sand channel에 누적한다. 방향이 바뀌어도 volume은 clear하지 않으므로 이전 모래가 유지된다.

## Material 데이터 계약

기본 path는 material fragment에서 O(1)이다.

- `use_surface_effect_volume`: true이면 shared 3D volume path 사용
- `surface_effect_volume`: RGBA8 layered volume texture. R/G/B/A는 effect class 1/2/3/4 누적 mask
- `effect_volume_origin_local`: volume 시작점, character local
- `effect_volume_inv_size`: character local 위치를 volume UVW로 바꾸는 inverse size
- `use_rest_volume_position`: true이면 shader가 `CUSTOM0.rgb` rest position으로 volume sample

호환/디버그용 raw event uniform도 유지한다.

- `impact_count`: 최근 debug ring에 남아 있는 event 수, 최대 `MAX_IMPACTS`
- `impact_spheres`: xyz는 현재 visual/debug center, w는 radius
- `impact_dirs`: xyz는 local direction, w는 strength
- `impact_meta`: x는 effect id

중요한 구분:

- `MAX_IMPACTS = 32`는 debug/fallback uniform ring 제한이다.
- 실제 누적 결과는 event가 들어올 때 shared 3D volume에 바로 기록되므로, volume을 clear하거나 character rebuild를 하지 않는 한 32개로 제한되지 않는다.

## 메모리 예산

현재 prototype의 주요 persistent memory:

- sparse surface samples: position/normal 배열
- debug event ring: 32개 record에 해당하는 uniform 배열
- shared 48-layer RGBA8 volume: 약 432 KB
- Godot rest-space attribute: `CUSTOM0` RGBA float, vertex당 16 bytes

현재 검증 asset은 1 MB 아래에 있다.

- Sophia: `776688` bytes
- Kenney: `484552` bytes
- Quaternius layered garment validation asset: `981632` bytes
- Quaternius playtest asset with sampler cap: `820160` bytes

단, 40만 vertex 캐릭터에서 Godot의 float4 `CUSTOM0`를 그대로 쓰면 rest attribute만 약 6.4 MB가 되어 원래 1 MB 제약을 넘는다. 이 prototype은 동작 원리 검증용이고, Unreal 최종 구현은 `PreSkinnedLocalPosition` 같은 엔진 제공 rest/pre-skinned 좌표를 쓰거나 half/quantized/custom vertex stream, GDExtension/engine-level 압축 경로가 필요하다.

## 모래바람 규칙

`set_sand_state(direction_world, front, amount)` 호출 시:

- surface sample의 world projection이 wind front 뒤에 있으면 sand 후보가 된다.
- `1 - abs(dot(normal, wind_direction))`로 wind와 normal이 평행할수록 덜 묻게 한다.
- 계산된 mask는 effect volume의 sand channel(effect id 2)에 누적된다.
- direction이 바뀌어도 기존 volume channel은 유지된다.

현재 shader에는 standalone sand render test를 위한 procedural sand 계산도 남아 있다. `use_surface_effect_volume`이 true인 게임 누적 path에서는 procedural sand를 섞지 않고 shared effect volume만 사용한다.

## 현재 한계

- Godot prototype은 production renderer module이 아니라 구조 검증용이다.
- sand accumulation은 CPU surface sample 기반이므로 대규모 캐릭터/다수 캐릭터에서는 GPU compute나 더 압축된 update path가 필요하다.
- RGBA volume은 독립 effect class 4개만 직접 표현한다. 더 많은 독립 스타일은 추가 volume, channel packing, indirection table이 필요하다.
- material preservation은 현재 사용하는 `StandardMaterial3D` 주요 채널을 대상으로 검증했다.

## Unreal 구현으로 가져갈 결론

- Event list는 장기 상태가 아니라 입력/디버그 buffer다. 누적 결과는 rest/pre-skinned local volume에 저장한다.
- Material 기본 경로는 `PreSkinnedLocalPosition` 기반 volume sample이어야 하며, event 개수만큼 loop를 돌면 안 된다.
- 40만 vertex 캐릭터에서는 Godot처럼 float4 `CUSTOM0`를 추가하면 memory budget을 크게 넘는다.
- Physics hit는 shot direction 기준 visual outer layer로 보정해야 하지만, GameThread에서 전체 visual mesh를 매번 스캔하면 안 된다.
- Clothing swap/runtime mesh rebuild는 event-driven으로 요청하고, proxy/volume/generation id를 다시 만들며 이전 worker 결과는 폐기해야 한다. 매 frame mesh 변경을 찾기 위해 전체 component tree나 vertex buffer를 훑으면 안 된다.
- Tiny bullet mark가 반드시 원형이어야 하면 coarse volume만으로는 부족할 수 있다. 이 경우 short-lived high-resolution stamp나 제한된 recent event decal path를 volume과 함께 쓴다.

자세한 Unreal 포팅 기준은 `docs/unreal_implementation_notes.md`에 정리했다.
