#!/usr/bin/env bash
# PoC 하네스가 의존하는 라벨을 생성한다. 멱등 — 여러 번 실행해도 안전.
set -euo pipefail
REPO="${1:-sunm2n/ERP_devOps_Poc}"

label() {  # name color description
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null
  printf '  %s\n' "$1"
}

echo "작업 종류"
label "type:repo"    "1d76db" "PR로 완료되는 저장소 산출물 작업"
label "type:env"     "5319e7" "수동 환경 작업 — PR 없음, 결과를 이슈에 기록"
label "type:measure" "0e8a16" "측정·기록 작업 — 지표를 이슈에 남김"
label "type:docs"    "c5def5" "문서/계획 변경"

echo "실행 단계"
label "phase:0" "ededed" "하네스·부트스트랩"
label "phase:1" "fbca04" "1단계 골격"
label "phase:2" "fbca04" "2단계 폐쇄망"
label "phase:3" "fbca04" "3단계 생애주기"
label "phase:4" "fbca04" "4단계 측정·정리"

echo "검증 가설"
for h in 1 2 3 4 5 6 7 8; do label "H$h" "b60205" "가설 H$h 검증에 기여"; done

echo "진행 상태"
label "status:ready"   "0e8a16" "선행 조건 충족 — 착수 가능"
label "status:blocked" "d93f0b" "선행 이슈 대기 중"

echo "우선순위"
label "prio:must"        "b60205" "필수 — 빠지면 PoC 성립 불가"
label "prio:should"      "fbca04" "권장"
label "prio:conditional" "ededed" "조건부 — 선행 결정에 의존"

echo "완료"
