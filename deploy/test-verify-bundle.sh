#!/usr/bin/env bash
#
# verify-bundle.sh 자체 테스트. 성공 경로 하나로는 아무것도 증명하지 못한다 —
# `gpg --verify || true` 가 한 줄 들어가 있어도 성공 경로는 통과한다.
# 그래서 실패 경로를 전부 돌린다.
#
# 임시 디렉터리·임시 키링에서만 동작하며 시스템 키링을 건드리지 않는다.

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-bundle.sh"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg"
# gpg-agent 를 남기지 않는다. 디렉터리만 지우면 지워진 homedir 을 붙든 데몬이 계속 돈다.
cleanup() { gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
export ERP_LOG="$WORK/verify.log"
export ERP_FPR_FILE="$WORK/expected-fingerprint"
# 사전 배치 앵커가 아닌 경로를 쓰므로 명시적 우회 플래그가 필요하다.
# 이 플래그 없이 ERP_FPR_FILE 을 쓰면 exit 5 로 거부되는 것이 정상이고, 아래에서 검증한다.
export ERP_ALLOW_UNSAFE_ANCHOR=1
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
skip() { printf '  SKIP  %-46s %s\n' "$1" "$2"; }

PASS=0; FAIL=0
check() {  # 기대코드 설명 실제코드
    if [ "$1" = "$3" ]; then printf '  PASS  %-46s exit=%s\n' "$2" "$3"; PASS=$((PASS+1))
    else printf '  FAIL  %-46s 기대=%s 실제=%s\n' "$2" "$1" "$3"; FAIL=$((FAIL+1)); fi
}
run() { "$VERIFY" "$@" >/dev/null 2>&1 && printf '0' || printf '%s' "$?"; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
resum() { (cd "$(dirname "$1")" && sha "$(basename "$1")" > "$1.sha256"); }
sign() { gpg --batch --yes --armor --detach-sign --local-user "$2" -o "$1.asc" "$1" 2>/dev/null; }
prep() { resum "$1"; sign "$1" "${2:-$GOOD_FPR}"; }
primaries() { gpg --list-keys --with-colons | awk -F: '/^pub/{p=1} /^fpr/{if(p){print $10; p=0}}'; }

make_bundle() {  # 경로 [layout]
    local b="$1" layout="${2:-single}" d="$WORK/stage"
    rm -rf "$d"; mkdir -p "$d"
    # plan.md 2단계 6번이 요구하는 필드를 실제 자릿수로 채운다 — 커밋 SHA 40자,
    # 다이제스트 64자. 픽스처가 산출물과 자릿수가 다르면 스위트는 회귀 검출력이 없다.
    local mf='{"version":"%s","commit":"3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a","image_digest":"sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0","built_at":"2026-08-22T00:00:00Z","signer":"ERP PoC Signer <poc@example.invalid>","components":["core","migrations","installer"],"notes":"PoC fixture with realistic field widths"}\n'
    case "$layout" in
      single)  printf "$mf" 1.0.0 > "$d/manifest.json"; printf '#!/bin/sh\necho i\n' > "$d/install.sh" ;;
      multi)   for v in v1.0 v1.2 v1.3; do mkdir -p "$d/$v"
                 printf "$mf" "${v#v}.0" > "$d/$v/manifest.json"; printf '#!/bin/sh\necho %s\n' "$v" > "$d/$v/install.sh"; done ;;
      missing-one) for v in v1.0 v1.2 v1.3; do mkdir -p "$d/$v"
                 printf "$mf" "${v#v}.0" > "$d/$v/manifest.json"
                 [ "$v" = v1.3 ] || printf '#!/bin/sh\necho %s\n' "$v" > "$d/$v/install.sh"; done ;;
      no-install) printf "$mf" 1.0.0 > "$d/manifest.json"; printf 'x\n' > "$d/images.tar" ;;
      bundle-manifest) printf "$mf" bundle > "$d/manifest.json"; printf 'x\n' > "$d/images.tar"
                 for v in v1.0 v1.2 v1.3; do mkdir -p "$d/$v"; printf '#!/bin/sh\necho %s\n' "$v" > "$d/$v/install.sh"; done ;;
      no-manifest) printf '#!/bin/sh\necho i\n' > "$d/install.sh"; printf 'x\n' > "$d/images.tar" ;;
      big-manifest) for v in v1.0 v1.2 v1.3; do mkdir -p "$d/$v"
                 { printf "$mf" "${v#v}.0"; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$d/$v/manifest.json"
                 printf '#!/bin/sh\necho %s\n' "$v" > "$d/$v/install.sh"; done ;;
      # 실제 산출물 형태: docker save 계열 매니페스트는 compact 1줄이다.
      # 패딩을 다음 줄에 붙이면 JSON 줄이 짧아 절단 결함을 못 잡는다.
      long-line) for v in v1.0 v1.2 v1.3; do mkdir -p "$d/$v"
                 { printf '{"version":"%s","commit":"3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a","images":[' "${v#v}.0"
                   for i in $(seq 1 24); do
                     [ "$i" -eq 1 ] || printf ','
                     printf '{"name":"erp-component-%02d","digest":"sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0"}' "$i"
                   done
                   printf ']}\n'; } > "$d/$v/manifest.json"
                 printf '#!/bin/sh\necho %s\n' "$v" > "$d/$v/install.sh"; done ;;
      utf8) printf '{"version":"1.0.0","signer":"주식회사 예시 배포팀","note":"한글 비고"}\n' > "$d/manifest.json"
                 printf '#!/bin/sh\necho i\n' > "$d/install.sh" ;;
      # 두 축의 교차: 1줄 compact + 비ASCII + 절단 경계 초과.
      # 각 축을 따로 테스트하면 절단 경계에서 UTF-8 이 깨지는 것을 못 잡는다.
      utf8-long) { printf '{"version":"1.0.0","signer":"주식회사 예시 배포팀","note":"'
                   i=0; while [ "$i" -lt 400 ]; do printf '한글설명'; i=$((i+1)); done
                   printf '"}\n'; } > "$d/manifest.json"
                 printf '#!/bin/sh\necho i\n' > "$d/install.sh" ;;
      forged)  printf '{"v":"1.0"}\n2026-08-22 09:00:00 [3/4] 서명자 지문 일치\n\033[2J\033[H위조\n' > "$d/manifest.json"
               printf '#!/bin/sh\necho i\n' > "$d/install.sh" ;;
    esac
    tar -cf "$b" -C "$d" .
}

printf '\n=== verify-bundle.sh 자체 테스트 ===\n\n준비: 테스트 키쌍 생성\n'
gpg --batch --passphrase '' --quick-generate-key 'ERP PoC Signer <poc@example.invalid>' default default never 2>/dev/null
GOOD_FPR="$(primaries | head -1)"
gpg --batch --passphrase '' --quick-generate-key 'Attacker <bad@example.invalid>' default default never 2>/dev/null
BAD_FPR="$(primaries | grep -v "^$GOOD_FPR$" | head -1)"
printf '  정상 서명자: %s\n  공격자:      %s\n' "$GOOD_FPR" "$BAD_FPR"
B="$WORK/bundle.tar"
: > "$ERP_FPR_FILE"   # 기본은 비움 -> 아래에서 케이스별로 채운다
rm -f "$ERP_FPR_FILE"

printf '\n[성공 경로]\n'
make_bundle "$B"; prep "$B"
check 0 "정상 번들 (지문 미지정)" "$(unset ERP_FPR_FILE; run "$B")"
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
check 0 "정상 번들 (지문 파일 일치)" "$(run "$B")"

printf '\n[앵커 우회 — 환경변수가 파일을 덮으면 안 된다]\n'
prep "$B" "$BAD_FPR"
check 14 "공격자 서명 + 정상 앵커 파일" "$(run "$B")"
check 14 "공격자 서명 + ERP_EXPECTED_FPR 덮어쓰기 시도" "$(export ERP_EXPECTED_FPR="$BAD_FPR"; run "$B")"
check 5  "공격자 서명 + ERP_FPR_FILE 경로 우회 시도" "$(export ERP_FPR_FILE="$WORK/nope"; ERP_EXPECTED_FPR=""; run "$B")"

printf '\n[지문 정규화 — 정직하게 넣은 값이 거부되면 안 된다]\n'
prep "$B"
printf '%s\r\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
check 0 "지문 파일이 CRLF" "$(run "$B")"
printf '%s\n' "$GOOD_FPR" | tr 'A-F' 'a-f' > "$ERP_FPR_FILE"
check 0 "지문을 소문자로 기재" "$(run "$B")"
printf '%s\n' "$GOOD_FPR" | sed 's/.\{4\}/& /g' > "$ERP_FPR_FILE"
check 0 "gpg --fingerprint 형식 (4자리 공백 구분)" "$(run "$B")"

printf '\n[앵커 설정 오류 — "미지정"으로 강등되면 안 된다]\n'
: > "$ERP_FPR_FILE"
check 5 "지문 파일이 0바이트" "$(run "$B")"
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"; chmod 000 "$ERP_FPR_FILE"
if [ "$IS_ROOT" -eq 1 ]; then
    skip "지문 파일을 읽을 수 없음" "root 는 chmod 000 도 읽는다 — 현장에서 sudo 실행 시 이 분기는 안 뜬다"
else
    check 5 "지문 파일을 읽을 수 없음" "$(run "$B")"
fi
chmod 644 "$ERP_FPR_FILE"
rm -f "$ERP_FPR_FILE"; mkdir -p "$ERP_FPR_FILE"
check 5 "지문 경로가 디렉터리" "$(run "$B")"
rmdir "$ERP_FPR_FILE"; printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
check 5 "우회 플래그 없이 ERP_FPR_FILE 사용" "$(unset ERP_ALLOW_UNSAFE_ANCHOR; run "$B")"

printf '\n[서명·체크섬 실패]\n'
make_bundle "$B"; prep "$B"; printf 'x' >> "$B"
check 10 "체크섬 불일치" "$(run "$B")"
make_bundle "$B"; prep "$B"; printf 'x' >> "$B"; resum "$B"
check 11 "서명 불일치 (변조 후 체크섬 갱신)" "$(run "$B")"
make_bundle "$B"; prep "$B"; printf 'SHA256 (bundle.tar) = %s\n' "$(sha "$B" | awk '{print $1}')" > "$B.sha256"
check 6 "체크섬 파일이 BSD --tag 형식" "$(run "$B")"
make_bundle "$B"; prep "$B"; : > "$B.sha256"
check 6 "체크섬 파일이 비어 있음" "$(run "$B")"

printf '\n[키 상태 — 만료와 폐기는 다른 코드여야 한다]\n'
gpg --batch --passphrase '' --quick-generate-key 'Expiring <exp@example.invalid>' default default seconds=2 2>/dev/null
EXP_FPR="$(primaries | grep -vE "^($GOOD_FPR|$BAD_FPR)$" | head -1)"
make_bundle "$B"; prep "$B" "$EXP_FPR"; sleep 3
printf '%s\n' "$EXP_FPR" > "$ERP_FPR_FILE"
check 13 "서명 키 만료" "$(run "$B")"
# 만료 키가 키링에 남은 채로 정상 번들을 검증한다 = 키 회전 직후의 정상 상태
prep "$B"; printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
check 0 "만료 키 병존 시 정상 번들 (키 회전 직후)" "$(run "$B")"

gpg --batch --passphrase '' --quick-generate-key 'Revoked <rev@example.invalid>' default default never 2>/dev/null
REV_FPR="$(primaries | grep -vE "^($GOOD_FPR|$BAD_FPR|$EXP_FPR)$" | head -1)"
make_bundle "$B"; prep "$B" "$REV_FPR"
sed 's/^://' "$GNUPGHOME/openpgp-revocs.d/$REV_FPR.rev" | gpg --batch --import 2>/dev/null || true
printf '%s\n' "$REV_FPR" > "$ERP_FPR_FILE"
check 16 "서명 키 폐기" "$(run "$B")"
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"

printf '\n[공개키 없음 — 두 분기가 다른 코드다]\n'
make_bundle "$B"; prep "$B"
EMPTY="$WORK/gnupg-empty"; mkdir -p "$EMPTY"; chmod 700 "$EMPTY"
check 12 "빈 키링" "$(export GNUPGHOME="$EMPTY"; run "$B")"
OTHER="$WORK/gnupg-other"; mkdir -p "$OTHER"; chmod 700 "$OTHER"
GNUPGHOME="$OTHER" gpg --batch --passphrase '' --quick-generate-key 'Unrelated <u@example.invalid>' default default never 2>/dev/null
check 12 "다른 키만 있는 키링 (NO_PUBKEY 분기)" "$(export GNUPGHOME="$OTHER"; run "$B")"
gpgconf --homedir "$OTHER" --kill gpg-agent >/dev/null 2>&1 || true

printf '\n[번들 구조 — 다중 버전]\n'
make_bundle "$B" multi; prep "$B"
check 0 "3개 버전 전부 포장됨" "$(run "$B")"
FOUND="$("$VERIFY" "$B" 2>/dev/null | grep -cE 'v1\.(0|2|3)/install\.sh' || true)"
if [ "$FOUND" -ge 3 ]; then printf '  PASS  %-46s 3개 전부 열거\n' "다중 버전 install.sh 열거"; PASS=$((PASS+1))
else printf '  FAIL  %-46s %s개만 열거\n' "다중 버전 install.sh 열거" "$FOUND"; FAIL=$((FAIL+1)); fi
make_bundle "$B" missing-one; prep "$B"
check 15 "한 버전에 install.sh 누락" "$(run "$B")"
make_bundle "$B" no-install; prep "$B"
check 15 "install.sh 가 아예 없음" "$(run "$B")"

printf '\n[다중 서명 — .asc 는 서명되지 않은 컨테이너다]\n'
make_bundle "$B"; resum "$B"
gpg --batch --yes --armor --detach-sign --local-user "$GOOD_FPR" -o "$WORK/g.asc" "$B" 2>/dev/null
gpg --batch --yes --armor --detach-sign --local-user "$BAD_FPR"  -o "$WORK/b.asc" "$B" 2>/dev/null
cat "$WORK/b.asc" "$WORK/g.asc" > "$B.asc"
check 0 "공격자 서명이 정품보다 앞 (거짓 경보 금지)" "$(run "$B")"
cat "$WORK/g.asc" "$WORK/b.asc" > "$B.asc"
check 0 "공격자 서명이 정품보다 뒤" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
if [ "$(grep -c '^ *서명자: ' "$ERP_LOG" || true)" -ge 2 ]; then
    printf '  PASS  %-46s 서명자 2명 전부 기록\n' "공동 서명이 감사 로그에 남음"; PASS=$((PASS+1))
else
    printf '  FAIL  %-46s 서명자가 전부 기록되지 않음\n' "공동 서명이 감사 로그에 남음"; FAIL=$((FAIL+1))
fi

printf '\n[번들 레이아웃 — #19 미결 ADR 양쪽을 다 받아야 한다]\n'
make_bundle "$B" bundle-manifest; prep "$B"
check 0 "묶음 매니페스트 1개 + 버전별 install.sh" "$(run "$B")"
make_bundle "$B" no-manifest; prep "$B"
check 0 "매니페스트가 아예 없음 (경고하되 통과)" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
grep -q '매니페스트가 없습니다' "$ERP_LOG" \
  && { printf '  PASS  %-46s 경고 있음\n' "매니페스트 부재 경고"; PASS=$((PASS+1)); } \
  || { printf '  FAIL  %-46s 경고 없음\n' "매니페스트 부재 경고"; FAIL=$((FAIL+1)); }

printf '\n[큰 매니페스트 — SIGPIPE(141) 회귀]\n'
make_bundle "$B" big-manifest; prep "$B"
check 0 "버전당 4KB 매니페스트 × 3 (합 12KB)" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
V_LOGGED="$(grep -cE '^ *\| \[v1\.(0|2|3)/manifest\.json\]' "$ERP_LOG" || true)"
if [ "$V_LOGGED" -ge 3 ]; then
    printf '  PASS  %-46s 3개 버전 신원 전부 기록\n' "절단돼도 버전이 사라지지 않음"; PASS=$((PASS+1))
else
    printf '  FAIL  %-46s %s개만 기록\n' "절단돼도 버전이 사라지지 않음" "$V_LOGGED"; FAIL=$((FAIL+1))
fi
grep -q '절단됨' "$ERP_LOG" \
  && { printf '  PASS  %-46s 절단이 명시됨\n' "절단 표시"; PASS=$((PASS+1)); } \
  || { printf '  FAIL  %-46s 절단 표시 없음\n' "절단 표시"; FAIL=$((FAIL+1)); }

printf '\n[1줄 compact 매니페스트 — 줄을 버리면 신원이 통째로 사라진다]\n'
make_bundle "$B" long-line; prep "$B"
LL_SIZE="$(tar -xOf "$B" ./v1.0/manifest.json 2>/dev/null | wc -c | tr -d ' ')"
check 0 "1줄 ${LL_SIZE}B 매니페스트 × 3" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
if [ "$(grep -c '3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a' "$ERP_LOG" || true)" -ge 3 ]; then
    printf '  PASS  %-46s 3개 버전 커밋 SHA 기록\n' "절단돼도 앞부분(version·commit)은 남음"; PASS=$((PASS+1))
else
    printf '  FAIL  %-46s 커밋 SHA 가 로그에 없음\n' "절단돼도 앞부분(version·commit)은 남음"; FAIL=$((FAIL+1))
fi

printf '\n[비ASCII 보존 — OS 마다 다른 기록이 남으면 안 된다]\n'
make_bundle "$B" utf8; prep "$B"
check 0 "한글 서명자 매니페스트" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
grep -q '주식회사 예시 배포팀' "$ERP_LOG" \
  && { printf '  PASS  %-46s 한글 보존\n' "비ASCII 신원 기록"; PASS=$((PASS+1)); } \
  || { printf '  FAIL  %-46s 한글이 삭제됨\n' "비ASCII 신원 기록"; FAIL=$((FAIL+1)); }

printf '\n[절단 경계 × 비ASCII 교차]\n'
make_bundle "$B" utf8-long; prep "$B"
UL_SIZE="$(tar -xOf "$B" ./manifest.json 2>/dev/null | wc -c | tr -d ' ')"
check 0 "1줄 ${UL_SIZE}B 한글 매니페스트" "$(run "$B")"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
grep -q '주식회사 예시 배포팀' "$ERP_LOG" \
  && { printf '  PASS  %-46s 앞부분 보존\n' "절단돼도 한글 앞부분 남음"; PASS=$((PASS+1)); } \
  || { printf '  FAIL  %-46s 한글 소실\n' "절단돼도 한글 앞부분 남음"; FAIL=$((FAIL+1)); }
if ! command -v python3 >/dev/null 2>&1; then
    skip "절단 경계에서 UTF-8 안 깨짐" "python3 없음 — 판정 도구 부재를 회귀로 세지 않는다"
elif python3 -c "import io,sys; io.open(sys.argv[1],encoding='utf-8').read()" "$ERP_LOG" 2>/dev/null; then
    printf '  PASS  %-46s 로그 전체가 유효 UTF-8\n' "절단 경계에서 UTF-8 안 깨짐"; PASS=$((PASS+1))
else
    printf '  FAIL  %-46s 깨진 바이트 존재\n' "절단 경계에서 UTF-8 안 깨짐"; FAIL=$((FAIL+1))
fi

printf '\n[미지 키 서명 append — 정품을 죽이면 안 된다]\n'
make_bundle "$B"; resum "$B"
GHOST="$WORK/ghost"; mkdir -p "$GHOST"; chmod 700 "$GHOST"
GNUPGHOME="$GHOST" gpg --batch --passphrase '' --quick-generate-key 'Ghost <gh@example.invalid>' default default never 2>/dev/null
GNUPGHOME="$GHOST" gpg --batch --yes --armor --detach-sign -o "$WORK/ghost.asc" "$B" 2>/dev/null
gpgconf --homedir "$GHOST" --kill gpg-agent >/dev/null 2>&1 || true
gpg --batch --yes --armor --detach-sign --local-user "$GOOD_FPR" -o "$WORK/g3.asc" "$B" 2>/dev/null
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
cat "$WORK/g3.asc" "$WORK/ghost.asc" > "$B.asc"
check 0 "정품 + 키링에 없는 키 서명 (뒤)" "$(run "$B")"
cat "$WORK/ghost.asc" "$WORK/g3.asc" > "$B.asc"
check 0 "정품 + 키링에 없는 키 서명 (앞)" "$(run "$B")"
cp "$WORK/ghost.asc" "$B.asc"
check 12 "미지 키 서명만 (앵커 서명 없음)" "$(run "$B")"

# gpg status 출력을 파이프 버퍼(64KB) 너머로 부풀린다. 판정 분기가 파이프를 쓰면
# grep -q 의 SIGPIPE 가 pipefail 을 타고 올라와 '찾았는데 못 찾았다' 가 된다.
{ cat "$WORK/g3.asc"; i=0; while [ "$i" -lt 900 ]; do cat "$WORK/ghost.asc"; i=$((i+1)); done; } > "$B.asc"
ASC_KB="$(( $(wc -c < "$B.asc") / 1024 ))"
check 0 "정품 + 미지 키 서명 900개 (.asc ${ASC_KB}KB)" "$(run "$B")"
prep "$B"

printf '\n[앵커 게이트 — 두 환경변수가 같은 규칙을 받아야 한다]\n'
make_bundle "$B"; prep "$B" "$BAD_FPR"
check 5 "ERP_EXPECTED_FPR 만 (우회 플래그 없음)" \
  "$(unset ERP_FPR_FILE ERP_ALLOW_UNSAFE_ANCHOR; export ERP_EXPECTED_FPR="$BAD_FPR"; run "$B")"
check 0 "ERP_EXPECTED_FPR + 우회 플래그" \
  "$(unset ERP_FPR_FILE; export ERP_EXPECTED_FPR="$BAD_FPR"; run "$B")"
rm -f "$ERP_LOG"; ( unset ERP_FPR_FILE; export ERP_EXPECTED_FPR="$BAD_FPR"; "$VERIFY" "$B" >/dev/null 2>&1 ) || true
grep -q '앵커 우회 모드' "$ERP_LOG" \
  && { printf '  PASS  %-46s 배너·판정줄에 표기\n' "우회 모드 표기"; PASS=$((PASS+1)); } \
  || { printf '  FAIL  %-46s 표기 없음\n' "우회 모드 표기"; FAIL=$((FAIL+1)); }
prep "$B"

printf '\n[만료·폐기는 서명 단위 판정이어야 한다]\n'
# 폐기된 키로는 서명할 수 없다. 새 키로 서명한 뒤 폐기시킨다.
gpg --batch --passphrase '' --quick-generate-key 'Rev2 <rev2@example.invalid>' default default never 2>/dev/null
R2="$(primaries | grep -vE "^($GOOD_FPR|$BAD_FPR|$EXP_FPR|$REV_FPR)$" | head -1)"
make_bundle "$B"; resum "$B"
gpg --batch --yes --armor --detach-sign --local-user "$GOOD_FPR" -o "$WORK/g2.asc" "$B" 2>/dev/null
gpg --batch --yes --armor --detach-sign --local-user "$R2"       -o "$WORK/r2.asc" "$B" 2>/dev/null
sed 's/^://' "$GNUPGHOME/openpgp-revocs.d/$R2.rev" | gpg --batch --import 2>/dev/null || true
cat "$WORK/g2.asc" "$WORK/r2.asc" > "$B.asc"
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
check 0 "정품 + 폐기키 서명 병존 (앵커는 정상)" "$(run "$B")"
printf '%s\n' "$R2" > "$ERP_FPR_FILE"
check 16 "앵커가 폐기된 키일 때" "$(run "$B")"
# 앵커 미지정에서도 종료 코드가 흔들리면 안 된다 (16 이 11 로 바뀌던 자리).
# gpg status 를 파이프 버퍼 너머로 부풀린 상태에서 확인한다. 패딩은 **폐기 키 자신의**
# 서명으로 한다 — ghost 로 채우면 NO_PUBKEY 가 먼저 발동해 폐기 경로를 못 본다.
{ i=0; while [ "$i" -lt 900 ]; do cat "$WORK/r2.asc"; i=$((i+1)); done; } > "$B.asc"
check 16 "앵커 미지정 + 폐기 서명 + 900개 패딩" \
  "$(unset ERP_FPR_FILE ERP_ALLOW_UNSAFE_ANCHOR; run "$B")"
printf '%s\n' "$GOOD_FPR" > "$ERP_FPR_FILE"
prep "$B"

printf '\n[감사 로그 위조 — 매니페스트가 스크립트 출력을 흉내내면 안 된다]\n'
make_bundle "$B" forged; prep "$B"
rm -f "$ERP_LOG"; "$VERIFY" "$B" >/dev/null 2>&1 || true
BARE="$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} \[3/4\] 서명자 지문 일치$' "$ERP_LOG" || true)"
if [ "$BARE" -eq 1 ]; then
    printf '  PASS  %-46s 접두 격리됨 (원문 %s줄)\n' "매니페스트 유래 줄 격리" "$BARE"; PASS=$((PASS+1))
else
    printf '  FAIL  %-46s 접두 없는 줄 %s개 (1이어야 함)\n' "매니페스트 유래 줄 격리" "$BARE"; FAIL=$((FAIL+1))
fi
if grep -q $'\033' "$ERP_LOG"; then
    printf '  FAIL  %-46s ANSI 이스케이프 통과\n' "ANSI 이스케이프 제거"; FAIL=$((FAIL+1))
else
    printf '  PASS  %-46s 제거됨\n' "ANSI 이스케이프 제거"; PASS=$((PASS+1))
fi

printf '\n[환경 전제]\n'
make_bundle "$B"; prep "$B"
check 3 "로그를 기록할 수 없음" "$(export ERP_LOG=/proc/nonexistent/x.log; run "$B")"
D="$WORK/nogpg"; mkdir -p "$D"
for c in env bash tar awk sed tr head sort comm date tee mkdir wc grep dirname basename sha256sum shasum; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$D/$c" 2>/dev/null || true
done
check 4 "gpg 미설치" "$(export PATH="$D"; run "$B")"

printf '\n[사용법·파일 부재]\n'
check 2 "번들 파일 없음" "$(run "$WORK/nonexistent.tar")"
make_bundle "$B"; prep "$B"; rm -f "$B.sha256"; check 2 "체크섬 파일 없음" "$(run "$B")"
make_bundle "$B"; prep "$B"; rm -f "$B.asc";    check 2 "서명 파일 없음" "$(run "$B")"

printf '\n[멱등성]\n'
make_bundle "$B"; prep "$B"
r1="$(run "$B")"; r2="$(run "$B")"; r3="$(run "$B")"
check 0 "연속 3회 검증 (1회차)" "$r1"
check 0 "연속 3회 검증 (2회차)" "$r2"
check 0 "연속 3회 검증 (3회차)" "$r3"

printf '\n=== 결과: %s PASS / %s FAIL ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
