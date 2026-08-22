#!/usr/bin/env bash
#
# 번들 검증 — 고객사 VM 에 **대역 외로 사전 배치**되는 신뢰 앵커.
#
# 이 스크립트는 번들 안에 들어가지 않는다. 번들과 다른 경로·다른 시점으로 1회 전달되어
# 고객사 VM 에 미리 놓인다. 공개키도 마찬가지다.
#
# 왜 그래야 하는가: 공개키와 검증 코드가 번들과 같은 매체로 이동하면, 운반 구간에 접근한
# 사람이 이미지에 백도어를 넣고 자기 키로 재서명한 뒤 번들 안의 공개키와 install.sh 를
# 함께 바꿔치기하면 그만이다. 검증은 "OK" 를 출력하고, 검출력은 체크섬만 있을 때와 같아진다.
#
# 사용법:
#   verify-bundle.sh <번들.tar>
#     같은 디렉터리에 <번들.tar>.sha256 과 <번들.tar>.asc 가 있어야 한다.
#
# 종료 코드 — 실패 원인을 구분한다. 폐쇄망 고객사 담당자는 "설치가 안 돼요" 라고만
# 말할 수 있으므로, 무엇이 왜 실패했는지가 화면과 로그에 남아야 한다.
#   0  검증 통과
#   2  사용법 오류 / 파일 없음
#  10  체크섬 불일치
#  11  서명 불일치
#  12  공개키 없음 (신뢰 앵커 미배치)
#  13  키 만료 또는 폐기
#  14  기대 지문과 실제 서명자 불일치
#  15  번들 구조 이상 (설치 스크립트 부재 등)
#
# 환경변수:
#   ERP_EXPECTED_FPR  기대 서명자 지문. 없으면 사전 배치 파일에서 읽는다
#   ERP_FPR_FILE      기대 지문 파일 (기본 /etc/erp-deploy/expected-fingerprint)
#   ERP_LOG           로그 파일 (기본 /var/log/erp-verify.log)
#   GNUPGHOME         키링 위치 (기본 시스템 기본값)

set -o errexit
set -o nounset
set -o pipefail

FPR_FILE="${ERP_FPR_FILE:-/etc/erp-deploy/expected-fingerprint}"
LOG="${ERP_LOG:-/var/log/erp-verify.log}"

# 로그를 못 쓰면 조용히 넘어가지 않는다 — 실패 원인이 남지 않으면 원격 지원이 불가능하다.
if ! { mkdir -p "$(dirname "$LOG")" && touch "$LOG"; } 2>/dev/null; then
    printf '오류: 로그 파일을 쓸 수 없습니다: %s\n' "$LOG" >&2
    printf '     ERP_LOG 로 쓰기 가능한 경로를 지정하거나 권한을 확인하십시오.\n' >&2
    exit 2
fi
LOG="$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")"

say() {   # 화면과 로그 양쪽에
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

die() {   # 종료코드, 원인, 조치
    local code="$1"; shift
    {
        printf '\n'
        printf '  검증 실패 (exit %s)\n' "$code"
        printf '  원인: %s\n' "$1"
        printf '  조치: %s\n' "$2"
        printf '  로그: %s\n' "$LOG"
        printf '\n'
        printf '  **설치를 진행하지 마십시오.** 이 번들은 신뢰할 수 없습니다.\n'
        printf '\n'
    } | tee -a "$LOG" >&2
    exit "$code"
}

[ $# -eq 1 ] || {
    printf '사용법: %s <번들.tar>\n' "$0" >&2
    exit 2
}

BUNDLE="$1"
[ -f "$BUNDLE" ] || die 2 "번들 파일이 없습니다: $BUNDLE" "경로를 확인하십시오."

BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
SUMFILE="${BUNDLE}.sha256"
SIGFILE="${BUNDLE}.asc"

say "=== 번들 검증 시작 ==="
say "번들: $BUNDLE"
say "로그: $LOG"

# ---------------------------------------------------------------- 1. 체크섬
# 전송 오류를 잡는다. 변조는 못 막는다 — 그건 서명의 일이다.
[ -f "$SUMFILE" ] || die 2 "체크섬 파일이 없습니다: $SUMFILE" \
    "번들과 함께 전달되어야 합니다. 운반 매체를 확인하십시오."

if command -v sha256sum >/dev/null 2>&1; then
    SUM_CMD=(sha256sum)
else
    SUM_CMD=(shasum -a 256)
fi

EXPECTED_SUM="$(awk 'NR==1{print $1}' "$SUMFILE")"
ACTUAL_SUM="$("${SUM_CMD[@]}" "$BUNDLE" | awk '{print $1}')"

if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
    say "기대 체크섬: $EXPECTED_SUM"
    say "실제 체크섬: $ACTUAL_SUM"
    die 10 "체크섬 불일치 — 번들이 손상되었거나 변조되었습니다" \
        "번들을 다시 운반하십시오. 재전송 후에도 같으면 생성 측에 문의하십시오."
fi
say "[1/4] 체크섬 일치 ($ACTUAL_SUM)"

# ---------------------------------------------------------------- 2. 신뢰 앵커
# 공개키가 여기 없으면 검증 자체가 성립하지 않는다.
[ -f "$SIGFILE" ] || die 2 "서명 파일이 없습니다: $SIGFILE" \
    "번들과 함께 전달되어야 합니다. 운반 매체를 확인하십시오."

if ! gpg --list-keys >/dev/null 2>&1 || [ -z "$(gpg --list-keys --with-colons 2>/dev/null | grep -c '^pub' || true)" ]; then
    die 12 "키링에 공개키가 없습니다" \
        "신뢰 앵커가 배치되지 않았습니다. 번들 안의 키를 임포트하지 마십시오 — 그러면 검증이 무의미해집니다. 공급사에 대역 외 전달을 요청하십시오."
fi

PUBKEY_COUNT="$(gpg --list-keys --with-colons 2>/dev/null | grep -c '^pub' || true)"
[ "$PUBKEY_COUNT" -gt 0 ] || die 12 "키링에 공개키가 없습니다" \
    "신뢰 앵커가 배치되지 않았습니다. 공급사에 대역 외 전달을 요청하십시오."

# 기대 지문. PoC 는 기록만 하고, 실도입에서는 이 값이 하드코딩되어야 한다 —
# gpg --verify 성공 여부가 아니라 "서명자 지문 == 사전 등록 지문" 이 판정이어야 한다.
EXPECTED_FPR="${ERP_EXPECTED_FPR:-}"
if [ -z "$EXPECTED_FPR" ] && [ -f "$FPR_FILE" ]; then
    EXPECTED_FPR="$(tr -d ' \n' < "$FPR_FILE")"
fi

# ---------------------------------------------------------------- 3. 서명
VERIFY_OUT="$(gpg --status-fd 1 --verify "$SIGFILE" "$BUNDLE" 2>>"$LOG" || true)"
printf '%s\n' "$VERIFY_OUT" >> "$LOG"

# VALIDSIG 의 3번째 필드는 '서명에 쓰인 키' 의 지문, 마지막 필드는 primary 키 지문이다.
# 전용 서명 서브키를 쓰면 둘이 다르고, 운영자가 등록하는 값은 primary 다
# (`gpg --fingerprint` 가 보여주는 것). primary 로 대조하지 않으면 정상 번들이 거짓 거부된다.
SIGNING_FPR="$(printf '%s\n' "$VERIFY_OUT" | awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}')"
PRIMARY_FPR="$(printf '%s\n' "$VERIFY_OUT" | awk '/^\[GNUPG:\] VALIDSIG/{print $NF; exit}')"
ACTUAL_FPR="${PRIMARY_FPR:-$SIGNING_FPR}"

if printf '%s\n' "$VERIFY_OUT" | grep -q '^\[GNUPG:\] NO_PUBKEY'; then
    die 12 "이 번들에 서명한 키가 키링에 없습니다" \
        "다른 키로 서명되었거나 신뢰 앵커가 갱신되지 않았습니다. 번들 안의 키를 임포트하지 마십시오. 공급사에 확인하십시오."
fi

if printf '%s\n' "$VERIFY_OUT" | grep -qE '^\[GNUPG:\] (EXPKEYSIG|KEYEXPIRED)'; then
    die 13 "서명 키가 만료되었습니다" \
        "공급사에 키 회전 여부를 확인하고 새 공개키를 대역 외로 받으십시오."
fi

if printf '%s\n' "$VERIFY_OUT" | grep -qE '^\[GNUPG:\] (REVKEYSIG|KEYREVOKED)'; then
    die 13 "서명 키가 폐기되었습니다" \
        "이 키로 서명된 번들은 신뢰할 수 없습니다. 즉시 공급사에 연락하십시오."
fi

if ! printf '%s\n' "$VERIFY_OUT" | grep -q '^\[GNUPG:\] GOODSIG'; then
    say "기대 서명자: ${EXPECTED_FPR:-<미지정>}"
    say "실제 서명자: ${ACTUAL_FPR:-<확인 불가>}"
    die 11 "서명 불일치 — 번들이 변조되었을 수 있습니다" \
        "체크섬은 통과했으나 서명이 맞지 않습니다. 운반 구간에서 내용이 바뀌었을 가능성이 있습니다. 설치하지 말고 공급사에 즉시 연락하십시오."
fi

say "[2/4] 서명 유효"
say "      primary 키 지문: ${PRIMARY_FPR:-<확인 불가>}"
if [ -n "$SIGNING_FPR" ] && [ "$SIGNING_FPR" != "$PRIMARY_FPR" ]; then
    say "      서명 서브키 지문: $SIGNING_FPR"
fi

# ---------------------------------------------------------------- 4. 지문 대조
# gpg --verify 는 키링의 '아무 키로나' 성공한다. 고객사 운영자가 지원 과정에서
# 다른 키를 임포트하는 순간 그 성공은 의미가 없어진다.
if [ -n "$EXPECTED_FPR" ]; then
    say "      기대 서명자 지문: $EXPECTED_FPR"
    # primary 로 대조하되, 등록값이 서명 서브키 지문인 경우도 허용한다
    if [ "$EXPECTED_FPR" != "$ACTUAL_FPR" ] && [ "$EXPECTED_FPR" != "$SIGNING_FPR" ]; then
        die 14 "서명자가 기대 지문과 다릅니다" \
            "유효한 서명이지만 등록된 공급사 키가 아닙니다. 설치하지 말고 공급사에 연락하십시오."
    fi
    say "[3/4] 서명자 지문 일치"
else
    say "[3/4] 기대 지문 미지정 — 지문 대조를 건너뜁니다"
    say "      경고: 키링의 어떤 키로든 서명이 통과합니다."
    say "      실도입에서는 $FPR_FILE 에 기대 지문을 배치하십시오."
fi

# ---------------------------------------------------------------- 5. 번들 구조
# 서명은 tar 전체를 덮으므로 안의 install.sh 도 서명 대상이다. 그 사실을 확인해
# 로그에 남긴다 — 설치 스크립트가 서명 범위 밖에 있으면 검증이 반쪽이 된다.
TAR_LIST="$(tar -tf "$BUNDLE" 2>>"$LOG" || true)"
[ -n "$TAR_LIST" ] || die 15 "번들을 읽을 수 없습니다" \
    "tar 구조가 손상되었습니다. 서명은 통과했으므로 생성 측 문제일 수 있습니다."

INSTALL_PATH="$(printf '%s\n' "$TAR_LIST" | grep -E '(^|/)install\.sh$' | head -1 || true)"
[ -n "$INSTALL_PATH" ] || die 15 "번들에 install.sh 가 없습니다" \
    "번들 생성이 불완전합니다. 공급사에 문의하십시오."

MANIFEST_PATH="$(printf '%s\n' "$TAR_LIST" | grep -E '(^|/)manifest\.(json|yml|yaml)$' | head -1 || true)"

say "[4/4] 번들 구조 확인"
say "      설치 스크립트: $INSTALL_PATH (서명 범위에 포함됨)"

if [ -n "$MANIFEST_PATH" ]; then
    say "      번들 신원:"
    tar -xOf "$BUNDLE" "$MANIFEST_PATH" 2>/dev/null | sed 's/^/        /' | tee -a "$LOG" || true
else
    say "      경고: 매니페스트가 없어 번들 신원(버전·빌드 SHA·이미지 다이제스트)을 확인할 수 없습니다"
fi

{
    printf '\n'
    printf '  검증 통과\n'
    printf '\n'
    printf '  이제 설치를 진행할 수 있습니다:\n'
    printf '    tar -xf %s -C <작업디렉터리>\n' "$BUNDLE"
    printf '    <작업디렉터리>/%s\n' "$INSTALL_PATH"
    printf '\n'
    printf '  로그: %s\n' "$LOG"
    printf '\n'
} | tee -a "$LOG"

exit 0
