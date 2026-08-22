#!/usr/bin/env bash
#
# verify-bundle.sh 자체 테스트. 성공 경로 하나로는 아무것도 증명하지 못한다 —
# `gpg --verify || true` 가 한 줄 들어가 있어도 성공 경로는 통과한다.
# 그래서 실패 경로를 전부 돌린다.
#
# 임시 디렉터리에서만 동작하며 시스템 키링을 건드리지 않는다.

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-bundle.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
export ERP_LOG="$WORK/verify.log"

PASS=0
FAIL=0

check() {  # 기대코드 설명 실제코드
    if [ "$1" = "$3" ]; then
        printf '  PASS  %-42s exit=%s\n' "$2" "$3"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-42s 기대=%s 실제=%s\n' "$2" "$1" "$3"
        FAIL=$((FAIL + 1))
    fi
}

run() {    # 종료코드만 뽑는다
    "$VERIFY" "$@" >/dev/null 2>&1 && printf '0' || printf '%s' "$?"
}

sign_bundle() {  # 번들 경로 -> .sha256 + .asc 생성
    local b="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$(dirname "$b")" && sha256sum "$(basename "$b")" > "$b.sha256")
    else
        (cd "$(dirname "$b")" && shasum -a 256 "$(basename "$b")" > "$b.sha256")
    fi
    rm -f "$b.asc"
    gpg --batch --yes --armor --detach-sign --local-user "$1_KEY" -o "$b.asc" "$b" 2>/dev/null ||
        gpg --batch --yes --armor --detach-sign -o "$b.asc" "$b"
}

make_bundle() {  # 경로 [install.sh 생략여부]
    local b="$1" skip="${2:-}"
    local d="$WORK/stage"
    rm -rf "$d"; mkdir -p "$d"
    printf '{"version":"1.0.0","commit":"abc1234","image_digest":"sha256:deadbeef","built_at":"2026-08-22T00:00:00Z","signer":"poc"}\n' > "$d/manifest.json"
    printf 'payload\n' > "$d/images.tar"
    [ "$skip" = "skip-install" ] || printf '#!/bin/sh\necho install\n' > "$d/install.sh"
    tar -cf "$b" -C "$d" .
}

printf '\n=== verify-bundle.sh 자체 테스트 ===\n\n'

printf '준비: 테스트 키쌍 생성\n'
gpg --batch --passphrase '' --quick-generate-key 'ERP PoC Signer <poc@example.invalid>' default default never 2>/dev/null
GOOD_FPR="$(gpg --list-keys --with-colons | awk -F: '/^pub/{p=1} /^fpr/{if(p){print $10; p=0}}' | head -1)"
printf '  서명자 지문: %s\n\n' "$GOOD_FPR"

B="$WORK/bundle.tar"

printf '성공 경로\n'
make_bundle "$B"; sign_bundle "$B"
check 0 "정상 번들 (지문 미지정)" "$(run "$B")"
check 0 "정상 번들 (지문 일치)" "$(export ERP_EXPECTED_FPR="$GOOD_FPR"; run "$B")"

printf '\n실패 경로 — 원인별로 다른 코드가 나와야 한다\n'

# 10: 체크섬 불일치
make_bundle "$B"; sign_bundle "$B"
printf 'tampered' >> "$B"
check 10 "체크섬 불일치" "$(run "$B")"

# 11: 페이로드 변조 후 체크섬만 갱신 = 서명 불일치
make_bundle "$B"; sign_bundle "$B"
printf 'tampered' >> "$B"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$WORK" && sha256sum bundle.tar > bundle.tar.sha256)
else
    (cd "$WORK" && shasum -a 256 bundle.tar > bundle.tar.sha256)
fi
check 11 "서명 불일치 (변조 후 체크섬 갱신)" "$(run "$B")"

# 14: 다른 키로 전체 재서명 — 체크섬·서명 모두 유효하지만 서명자가 다르다
make_bundle "$B"
gpg --batch --passphrase '' --quick-generate-key 'Attacker <bad@example.invalid>' default default never 2>/dev/null
# pub 다음의 첫 fpr 만 primary 다. 서브키 지문을 고르면 gpg 가 primary 로 서명해버려
# '다른 키로 서명' 이라는 테스트 의도가 무력화된다
BAD_FPR="$(gpg --list-keys --with-colons | awk -F: '/^pub/{p=1} /^fpr/{if(p){print $10; p=0}}' | grep -v "^$GOOD_FPR$" | head -1)"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$WORK" && sha256sum bundle.tar > bundle.tar.sha256)
else
    (cd "$WORK" && shasum -a 256 bundle.tar > bundle.tar.sha256)
fi
gpg --batch --yes --armor --detach-sign --local-user "$BAD_FPR" -o "$B.asc" "$B" 2>/dev/null
check 0  "다른 키 재서명 · 지문 미지정 (통과해버린다)" "$(run "$B")"
check 14 "다른 키 재서명 · 지문 지정" "$(export ERP_EXPECTED_FPR="$GOOD_FPR"; run "$B")"

# 전용 서명 서브키로 서명 — 운영자가 등록하는 건 primary 지문이다.
# VALIDSIG 의 3번째 필드(서명키)로 대조하면 여기서 정상 번들이 거짓 거부된다.
printf '\n실도입 형태 — 전용 서명 서브키\n'
gpg --batch --passphrase '' --quick-add-key "$GOOD_FPR" default sign never 2>/dev/null
SUBKEY="$(gpg --list-keys --with-colons "$GOOD_FPR" | awk -F: '/^sub/{c=$12} /^fpr/{if(c ~ /s/){print $10; exit}}')"
make_bundle "$B"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$WORK" && sha256sum bundle.tar > bundle.tar.sha256)
else
    (cd "$WORK" && shasum -a 256 bundle.tar > bundle.tar.sha256)
fi
gpg --batch --yes --armor --detach-sign --local-user "${SUBKEY}!" -o "$B.asc" "$B" 2>/dev/null
check 0 "서명 서브키 서명 + primary 지문 등록" "$(export ERP_EXPECTED_FPR="$GOOD_FPR"; run "$B")"
check 0 "서명 서브키 서명 + 서브키 지문 등록" "$(export ERP_EXPECTED_FPR="$SUBKEY"; run "$B")"
check 14 "서명 서브키 서명 + 엉뚱한 지문" "$(export ERP_EXPECTED_FPR="$BAD_FPR"; run "$B")"

printf '\n나머지 실패 경로\n'
# 12: 공개키 없음
make_bundle "$B"; gpg --batch --yes --armor --detach-sign --local-user "$GOOD_FPR" -o "$B.asc" "$B" 2>/dev/null
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$WORK" && sha256sum bundle.tar > bundle.tar.sha256)
else
    (cd "$WORK" && shasum -a 256 bundle.tar > bundle.tar.sha256)
fi
EMPTY="$WORK/gnupg-empty"; mkdir -p "$EMPTY"; chmod 700 "$EMPTY"
check 12 "공개키 없음 (빈 키링)" "$(export GNUPGHOME="$EMPTY"; run "$B")"

# 15: install.sh 부재
make_bundle "$B" skip-install; sign_bundle "$B"
check 15 "번들에 install.sh 없음" "$(run "$B")"

# 2: 파일 부재
check 2 "번들 파일 없음" "$(run "$WORK/nonexistent.tar")"
make_bundle "$B"; sign_bundle "$B"; rm -f "$B.sha256"
check 2 "체크섬 파일 없음" "$(run "$B")"
make_bundle "$B"; sign_bundle "$B"; rm -f "$B.asc"
check 2 "서명 파일 없음" "$(run "$B")"

printf '\n=== 결과: %s PASS / %s FAIL ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
