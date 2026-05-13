# 목표 문서: Mesh Surface Impact System

## 만들 기능

Godot 4 기준으로, 런타임에 생성되는 캐릭터 `MeshInstance3D` / skinned mesh 표면에 다음 효과를 누적해서 보여준다.

- 총알 피격 위치 주변 약 5 cm 반경에 피, 먼지, 충격 자국 같은 국소 이펙트 표시
- 게임 코드가 "이 위치에서 A 이펙트가 발생했다"는 surface event를 넘기면, material/shader 단에서 effect id, 위치, 반경, 방향, 강도를 받아 아티스트가 원하는 표현을 만들 수 있어야 한다.
- 모래바람 방향에서부터 천천히 모래가 묻는 전역 누적 이펙트 표시
- 표면 normal이 바람 방향과 평행할수록 모래가 덜 묻도록 제어
- 캐릭터가 여러 material slot / surface를 가져도 전체가 하나의 표면처럼 자연스럽게 보이도록 처리

## 핵심 제약

- 의상 교체마다 런타임 mesh가 바뀌므로 초기화 비용이 작아야 한다.
- 캐릭터당 시스템 메모리는 1 MB 미만이어야 한다.
- 전체 mesh를 관통하는 공통 UV 채널이 없다.
- slot별 UV만 있고 UV seam이 임의로 구성되어 있으므로 UV 기반 누적 텍스처를 사용할 수 없다.
- 원본 asset을 수정할 수 없다.
- physics asset hit 위치가 실제 의상 외곽을 정확히 가리키지 않을 수 있다.
- 몸, 상의, 아우터처럼 여러 겹이 있을 때도 관찰 방향 / 탄 방향 기준 가장 바깥쪽 표면에 이펙트가 보여야 한다.

## 선택한 접근

UV나 material slot 좌표계가 아니라 캐릭터 로컬 공간에서 효과를 평가한다.

1. 의상 교체 또는 mesh 재생성 시점에 visual mesh vertex를 희소 샘플링한다.
2. 피격 physics 위치와 탄 방향을 입력받으면, 그 방향의 원통형 탐색 영역 안에서 가장 바깥쪽 visual surface sample을 찾는다.
3. 찾은 로컬 위치, 반경, 방향, 강도, effect id를 작은 ring buffer에 저장한다.
4. 모든 material slot에 같은 surface event uniform 배열을 전달하고, shader가 로컬/월드 위치와 normal로 피격 splat과 모래 누적량을 계산한다.

이 방식은 UV seam, material slot 분리, texture atlas 유무와 무관하게 같은 월드/로컬 공간에서 효과를 계산하므로 seam을 따라 끊기지 않는다.

## 메모리 예산

기본값 기준:

- 외곽 표면 샘플: 최대 8192개
- 위치 `PackedVector3Array`: 약 96 KB
- normal `PackedVector3Array`: 약 96 KB
- surface event 기록 32개: shader uniform 배열 포함 수 KB 수준
- 스크립트/배열 오버헤드를 포함해도 목표는 캐릭터당 1 MB 미만

렌더 타겟을 slot별로 만들지 않는 것이 핵심이다.

## 초기화 비용 목표

의상 교체 시:

- 기존 surface event ring buffer 초기화
- 새 mesh surface를 순회하며 vertex/normal을 일정 stride로 샘플링
- material slot마다 shader material instance를 재바인딩

복잡한 bake, UV unwrap, texture 생성, asset write는 하지 않는다.

## 피격 위치 보정 규칙

입력:

- physics asset에서 얻은 대략적인 hit world position
- 총알 진행 방향 world vector
- 기본 반경 0.05 m

처리:

- hit 위치를 캐릭터 로컬로 변환
- 탄 방향 반대편, 즉 관찰자/총알이 들어온 쪽에 더 가까운 visual sample을 우선한다.
- hit 주변 원통 반경 안의 sample만 후보로 둔다.
- normal이 탄을 마주보는 후보를 가산한다.
- 후보가 없으면 physics hit 위치를 fallback으로 사용한다.

결과적으로 physics asset이 안쪽 몸통을 맞혀도, 같은 방향 선상에서 실제 visual mesh의 가장 바깥 의상 표면에 splat이 올라간다.

## 모래바람 규칙

입력:

- 바람 진행 방향 world vector
- front offset / speed
- 누적 강도

shader 평가:

- 표면 world position을 바람 축에 투영해 front가 지나간 영역부터 천천히 모래가 증가한다.
- `1 - abs(dot(normal, wind_direction))` 계열의 계수로 normal이 바람 방향과 평행할수록 덜 묻도록 한다.
- 피격 splat과 같은 로컬/월드 공간 평가이므로 UV seam과 무관하다.

## Material 데이터 계약

material은 다음 uniform을 통해 누적 surface event를 받는다.

- `impact_count`: 현재 저장된 surface event 수
- `impact_spheres`: xyz는 캐릭터 로컬 이펙트 중심, w는 반경
- `impact_dirs`: xyz는 캐릭터 로컬 방향, w는 강도
- `impact_meta`: x는 effect id, 나머지는 확장용

기본 shader는 `blood_effect_id == 1`인 event만 피격 색상으로 표현한다. 아티스트는 같은 uniform 계약을 유지한 커스텀 shader/material에서 effect id별로 피, 먼지, 스파크, 젖음, 오염 같은 표현을 자유롭게 만들 수 있다.

## 현재 프로토타입 범위

- `SurfaceEffectAccumulator`: 캐릭터 mesh 등록, material slot shader 적용, surface event/sand 상태 관리
- `MeshSurfaceSampler`: visual mesh에서 외곽 후보 sample 수집과 hit 위치 보정
- `surface_effects.gdshader`: UV를 쓰지 않는 surface event/sand 누적 표시
- `demo.tscn`: 여러 겹 mesh를 만들고 주기적으로 피격과 모래 front를 갱신하는 검증용 씬

## 이후 고도화 후보

- CPU sample 대신 GPU depth peel / signed distance field를 써서 더 정확한 외곽 선택
- material 원본 texture와 normal map을 유지하는 material adapter
- network replication용 compact impact record serialization
- 오래된 피격 fade-out, 피/먼지 타입별 색상/roughness/normal perturbation
- animation 후 skinned 위치 기준 외곽 샘플 갱신 또는 bone-space sample 캐시
