# ERP 배포 플랫폼 PoC

.NET 10 기반 ERP 코어를 GitLab CI로 빌드하고, 온라인/완전 폐쇄망 고객사 양쪽에
배포·업그레이드·롤백할 수 있는지 검증하는 PoC 저장소.

## 이 저장소가 답하려는 것

> 설계한 배포 구조가 실제로 동작하는가, 그리고 사람 손이 얼마나 필요한가.

검증 가설(H1~H8), 범위, 측정 지표는 [`plan.md`](plan.md) 참조.
**PoC 성공은 설계 검증이 아니라 "치명적 결함이 없음"의 확인이다.**

## 저장소 경계 (중요)

| 실행 위치 | 대상 | 이 저장소와의 관계 |
| --- | --- | --- |
| GitHub (여기) | 이슈 · PR · 리뷰 · 머지 | 작업 관리와 산출물 형상관리 |
| GitLab CE (self-managed) | 실제 CI 파이프라인 | `.gitlab-ci.yml`은 여기서 **리뷰만** 받고 실행은 GitLab |
| VM-1 / VM-2 | 설치 · 업그레이드 · 롤백 | 수동 실행. 수치는 [`measurements/metrics.md`](measurements/metrics.md), 원인·설계영향은 [`docs/findings.md`](docs/findings.md), 진행은 `type:env` 이슈 |

GitHub Actions는 `.gitlab-ci.yml`과 셸 스크립트의 **정적 검증만** 수행한다.
PR이 초록불이라고 GitLab 파이프라인이 동작한다는 뜻이 아니다.

## 작업 방식

이슈 → PR → 3개 관점 리뷰 → 머지 → 다음 이슈. 자세한 내용은
[`docs/harness.md`](docs/harness.md).

## 기록

| 파일 | 무엇이 들어가는가 |
| --- | --- |
| [`measurements/metrics.md`](measurements/metrics.md) | 지표 수치. **측정한 자리에서** 채운다 |
| [`docs/findings.md`](docs/findings.md) | 가설 판정, 실패 원인, 설계 영향, 도입 권고 |

보고서(6장 산출물)는 전적으로 이 둘에서 나온다. 4단계에 2~3일뿐이라 그때 재현하려면
VM-2 스냅샷 복구부터 다시 해야 한다.
