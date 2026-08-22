#!/usr/bin/env bash
#
# 번들 검증 — 고객사 VM 에 **대역 외로 사전 배치**되는 신뢰 앵커.
#
# 이 스크립트는 번들 안에 들어가지 않는다. 번들과 다른 경로·다른 시점으로 1회 전달되어
# 고객사 VM 에 미리 놓인다. 공개키와 기대 지문 파일도 마찬가지다 — 앵커는 3종이다.
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
#   2  사용법 오류 / 번들·체크섬·서명 파일 없음
#   3  로그를 기록할 수 없음
#   4  필수 도구 없음 (gpg, tar)
#   5  앵커 설정 오류 (기대 지문 파일이 비었거나 읽을 수 없음)
#   6  체크섬 파일 형식을 인식할 수 없음
#  10  체크섬 불일치
#  11  서명 불일치
#  12  공개키 없음 (신뢰 앵커 미배치)
#  13  서명 키 만료
#  14  기대 지문과 서명자 불일치
#  15  번들 구조 이상
#  16  서명 키 폐기
#
# 만료(13)와 폐기(16)를 나눈다. 만료는 일정이고 폐기는 사고다. 자동화가 읽는 것은
# 종료 코드지 한국어 문장이 아니다.
#
# 환경변수 — **기대 지문 파일이 있으면 그것이 최종 판정값이고 환경변수는 무시된다.**
# 앵커 값은 앵커 쪽에서만 온다. 환경변수로 덮을 수 있으면, 운반 구간에 안내서를 한 장
# 끼워 넣는 것만으로 공격자 서명 번들이 "지문 일치" 를 화면과 감사 로그에 남기며 통과한다.
#   ERP_EXPECTED_FPR  기대 지문. 파일이 없을 때만 쓰인다
#   ERP_FPR_FILE      기대 지문 파일 (기본 /etc/erp-deploy/expected-fingerprint)
#   ERP_LOG           로그 파일 (기본 /var/log/erp-verify.log)

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_VERSION='1.1.0'

# 종료 코드는 닫힌 집합이어야 한다. README 표가 자동화의 인터페이스이고, 폐쇄망에서
# 표에 없는 코드는 담당자에게 '원인 불명' 과 같다. errexit 나 SIGPIPE 로 die() 를
# 건너뛴 종료를 전부 1 로 정규화한다.
KNOWN_EXITS=' 0 2 3 4 5 6 10 11 12 13 14 15 16 130 '
on_signal() {   # 128+N. 수백 MB 해싱 구간에서 세션 끊김·타임아웃은 현실적인 종료 사유다
    # 이 핸들러가 존재하는 이유가 '세션 끊김' 인데, 세션이 끊기면 화면이 바로 그
    # 사라지는 매체다. 담당자에게 남는 건 로그뿐이므로 로그에도 반드시 쓴다.
    {
        printf '\n  중단됨 (exit 130, 신호 %s)\n' "$1"
        printf '  조치: 검증이 끝나기 전에 중단되었습니다. **재운반이 아니라 재실행**이 정답입니다.\n'
        printf '        수백 MB 해싱에 시간이 걸립니다. 세션이 끊기지 않는 환경에서 다시 실행하십시오.\n'
        printf '  로그: %s\n\n' "${LOG:-<미설정>}"
    } | { if [ -w "${LOG:-/nonexistent}" ]; then tee -a "$LOG"; else cat; fi; } >&2
    trap - EXIT
    exit 130
}
on_exit() {
    local c=$?
    case "$KNOWN_EXITS" in
        *" $c "*) exit "$c" ;;
    esac
    printf '\n  내부 오류 (exit 1, 원래 코드 %s)\n' "$c" >&2
    printf '  조치: 재운반으로 해결되지 않습니다. 로그 전문과 함께 공급사에 문의하십시오.\n' >&2
    printf '  로그: %s\n\n' "${LOG:-<미설정>}" >&2
    exit 1
}
trap on_exit EXIT
trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP'  HUP

DEFAULT_FPR_FILE='/etc/erp-deploy/expected-fingerprint'
FPR_FILE="$DEFAULT_FPR_FILE"
FPR_OVERRIDE=''
# 앵커 값을 밖에서 넣으려는 시도는 **한 곳에서** 처리한다. 경로(ERP_FPR_FILE)와
# 값(ERP_EXPECTED_FPR)을 따로 다루면 한쪽만 막히고, 공격자는 안 막힌 쪽을 안내서에
# 적으면 그만이다. 입력이 하나 늘어도 여기만 고치면 되게 둔다.
ANCHOR_ENV=''
[ -z "${ERP_FPR_FILE:-}" ] || [ "$ERP_FPR_FILE" = "$DEFAULT_FPR_FILE" ] || ANCHOR_ENV='ERP_FPR_FILE'
[ -z "${ERP_EXPECTED_FPR:-}" ] || ANCHOR_ENV="${ANCHOR_ENV:+$ANCHOR_ENV, }ERP_EXPECTED_FPR"
if [ -n "$ANCHOR_ENV" ]; then
    if [ -e "$DEFAULT_FPR_FILE" ]; then
        FPR_OVERRIDE='ignored'          # 사전 배치 앵커가 있으면 그것이 이긴다
    elif [ "${ERP_ALLOW_UNSAFE_ANCHOR:-}" = '1' ]; then
        FPR_OVERRIDE='unsafe'           # 개발·테스트용. 판정 줄과 배너에 그렇게 찍는다
        [ -z "${ERP_FPR_FILE:-}" ] || FPR_FILE="$ERP_FPR_FILE"
    else
        FPR_OVERRIDE='refused'
    fi
fi
LOG="${ERP_LOG:-/var/log/erp-verify.log}"

# --- 로그 ---------------------------------------------------------------
# append 권한을 실제로 본다. touch 는 0444 파일에서도 성공하고, 그러면 첫 tee 가
# EACCES 로 죽어 원인·조치 블록이 한 줄도 안 나온 채 exit 1 이 된다.
if ! { mkdir -p "$(dirname "$LOG")" && : >> "$LOG"; } 2>/dev/null; then
    printf '\n  로그를 기록할 수 없습니다 (exit 3)\n' >&2
    printf '  경로: %s\n' "$LOG" >&2
    printf '  조치: 아래 중 하나를 수행한 뒤 다시 실행하십시오.\n' >&2
    printf '        sudo install -d -m 755 "%s" && sudo touch "%s" && sudo chmod 666 "%s"\n' \
        "$(dirname "$LOG")" "$LOG" "$LOG" >&2
    printf '        또는 쓰기 가능한 경로로:  ERP_LOG=./erp-verify.log %s <번들.tar>\n\n' "$0" >&2
    exit 3
fi
LOG="$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")"

say() {   # 화면과 로그 양쪽에
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

die() {   # 종료코드, 원인, 조치
    local code="$1"
    {
        printf '\n'
        printf '  검증 실패 (exit %s)\n' "$code"
        printf '  원인: %s\n' "$2"
        printf '  조치: %s\n' "$3"
        printf '  로그: %s\n' "$LOG"
        printf '\n'
        printf '  **설치를 진행하지 마십시오.** 이 번들은 신뢰할 수 없습니다.\n'
        printf '\n'
    } | tee -a "$LOG" >&2
    exit "$code"
}

# 번들에서 나온 문자열은 그대로 찍지 않는다. 매니페스트에 스크립트 자기 출력과 똑같이
# 생긴 줄을 넣으면 감사 로그가 위조되고, ANSI 이스케이프는 화면을 지운다.
untrusted() {
    # 제어문자만 지운다. `tr -cd '[:print:]'` 는 GNU tr 이 바이트 기반이라 로케일과
    # 무관하게 비ASCII 를 전부 삭제하고, 같은 번들의 한글 서명자가 Linux 에서만
    # 사라진다 — OS 마다 다른 기록이 남는다.
    # LC_ALL=C 로 고정한다. awk 의 length()/substr() 는 gawk + UTF-8 로케일에서
    # '문자' 단위라, 같은 한글 1줄이 환경에 따라 2048B 로도 6144B 로도 잘린다.
    # 종료 코드에서 없앤 'OS 마다 다른 결과' 가 절단 경계로 자리를 옮기는 것을 막는다.
    tr -d '\000-\010\013\014\016-\037\177' | LC_ALL=C awk -v max=2048 '
        BEGIN { n = 0; cut = 0; dropped = 0 }
        {
            if (n >= max) { dropped++; next }
            room = max - n
            if (length($0) <= room) { n += length($0) + 1; print "      | " $0 }
            else {
                # 줄을 버리지 않는다. 매니페스트는 흔히 1줄(compact JSON)이라
                # 버리면 version·commit·digest 가 통째로 사라진다.
                s = substr($0, 1, room)
                # 바이트 절단이 UTF-8 시퀀스를 중간에서 자르면 로그가 깨진 바이트로
                # 끝나고, 엄격한 UTF-8 소비자(로그 수집기 등)가 그 줄에서 실패한다.
                sub(/[\200-\277]*$/, "", s); sub(/[\302-\364]$/, "", s)
                print "      | " s "…"
                n = max; cut = 1
            }
        }
        END {
            if (cut || dropped > 0)
                printf "      | ... (%d바이트에서 절단됨%s)\n", max,
                       (dropped > 0 ? sprintf(", 이후 %d줄 생략", dropped) : "")
        }'
}

# 지문 정규화. 대역 외 지문은 메일·Windows PC 를 거쳐 오므로 CRLF·탭·4자리 공백
# 구분(`gpg --fingerprint` 출력 형식)·소문자가 전부 현실이다. 정규화하지 않으면
# 운영자가 정직하게 넣은 값이 exit 14 "설치 금지, 즉시 연락" 을 만든다 —
# 오타 하나가 실제 공격과 구분 불가능한 신호가 된다.
normalize_fpr() {
    tr -d '[:space:]' | tr 'a-f' 'A-F'
}

# --- 필수 도구 ----------------------------------------------------------
# gpg 가 없는 것을 "앵커 미배치" 로 오진하면 고객사는 멀쩡한 키를 다시 받으러 연락하고,
# 임포트할 수단이 없어 또 실패한다. VM-2 는 망이 끊겨 apt install 도 안 된다.
for tool in gpg tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '\n  필수 도구가 없습니다 (exit 4): %s\n' "$tool" >&2
        printf '  조치: 폐쇄망에서는 설치할 수 없습니다. VM 이미지 준비 단계에서\n' >&2
        printf '        누락된 것이므로 공급사에 VM 사전 요구사항을 확인하십시오.\n\n' >&2
        exit 4
    }
done

[ $# -eq 1 ] || {
    printf '사용법: %s <번들.tar>\n' "$0" >&2
    exit 2
}

BUNDLE="$1"
[ -f "$BUNDLE" ] || {
    printf '번들 파일이 없습니다: %s\n' "$BUNDLE" >&2
    exit 2
}

BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
SUMFILE="${BUNDLE}.sha256"
SIGFILE="${BUNDLE}.asc"

say "=== 번들 검증 시작 (verify-bundle.sh $SCRIPT_VERSION) ==="
say "번들: $BUNDLE"
say "로그: $LOG"

# --- 1. 체크섬 ----------------------------------------------------------
# 전송 오류를 잡는다. 변조는 못 막는다 — 그건 서명의 일이다.
[ -f "$SUMFILE" ] || die 2 "체크섬 파일이 없습니다: $SUMFILE" \
    "번들과 함께 전달되어야 합니다. 운반 매체를 확인하십시오."
[ -f "$SIGFILE" ] || die 2 "서명 파일이 없습니다: $SIGFILE" \
    "번들과 함께 전달되어야 합니다. 운반 매체를 확인하십시오."

if command -v sha256sum >/dev/null 2>&1; then
    SUM_CMD=(sha256sum)
else
    SUM_CMD=(shasum -a 256)
fi

EXPECTED_SUM="$(awk 'NR==1{print $1}' "$SUMFILE" | normalize_fpr)"
# 형식을 먼저 본다. BSD --tag 형식(`SHA256 (f) = <hash>`)이나 빈 파일을
# "체크섬 불일치" 로 떨어뜨리면 재운반 안내가 나가고, 재운반은 그걸 못 고친다.
case "$EXPECTED_SUM" in
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]*)
        [ "${#EXPECTED_SUM}" -eq 64 ] || die 6 "체크섬 파일 형식을 인식할 수 없습니다" \
            "SHA256 은 64자리 16진수여야 합니다. 생성 측에 문의하십시오." ;;
    *)
        die 6 "체크섬 파일 형식을 인식할 수 없습니다" \
            "첫 줄 첫 칸이 SHA256 해시여야 합니다 (sha256sum 형식). 생성 측에 문의하십시오." ;;
esac

ACTUAL_SUM="$("${SUM_CMD[@]}" "$BUNDLE" | awk '{print $1}' | normalize_fpr)"
if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
    say "기대 체크섬: $EXPECTED_SUM"
    say "실제 체크섬: $ACTUAL_SUM"
    die 10 "체크섬 불일치 — 번들이 손상되었거나 변조되었습니다" \
        "번들을 다시 운반하십시오. 재전송 후에도 같으면 생성 측에 문의하십시오."
fi
say "[1/4] 체크섬 일치 ($ACTUAL_SUM)"

# --- 2. 기대 지문 (앵커) ------------------------------------------------
# 파일이 있으면 그것이 최종 판정값이다. 환경변수는 파일이 없을 때만 쓰인다.
EXPECTED_FPR=""
FPR_SOURCE=""
case "$FPR_OVERRIDE" in
    refused)
        die 5 "환경변수로 앵커 값을 넣으려 했습니다 ($ANCHOR_ENV)" \
            "앵커 값은 사전 배치된 위치에서만 옵니다. 번들에 딸려온 안내서를 따르지 마십시오 — 그 안내서는 검증 대상과 같은 경로로 왔습니다. 환경변수를 지우고 다시 실행하십시오." ;;
    unsafe)
        # 우회 모드에서도 지정한 경로가 없으면 '미지정' 으로 강등되면 안 된다.
        [ -z "${ERP_FPR_FILE:-}" ] || [ -e "$FPR_FILE" ] || die 5 "지정한 기대 지문 파일이 없습니다: $FPR_FILE" \
            "ERP_FPR_FILE 로 경로를 지정했으나 그 파일이 없습니다. 앵커가 없는 상태로 검증이 통과하는 것을 막기 위해 거부합니다." ;;
    ignored)
        say "      알림: $ANCHOR_ENV 이(가) 설정되어 있으나 무시합니다 — 사전 배치 앵커가 우선입니다" ;;
esac
if [ -e "$FPR_FILE" ]; then
    [ -f "$FPR_FILE" ] || die 5 "기대 지문 경로가 일반 파일이 아닙니다: $FPR_FILE" \
        "디렉터리이거나 특수 파일입니다. 프로비저닝을 확인하십시오 (mkdir -p 를 파일 경로에 실행한 경우가 흔합니다)."
    [ -r "$FPR_FILE" ] || die 5 "기대 지문 파일을 읽을 수 없습니다: $FPR_FILE" \
        "권한을 확인하십시오. 이 파일은 설치 가부를 결정하는 값입니다."
    EXPECTED_FPR="$(normalize_fpr < "$FPR_FILE")"
    [ -n "$EXPECTED_FPR" ] || die 5 "기대 지문 파일이 비어 있습니다: $FPR_FILE" \
        "앵커가 배치된 것처럼 보이지만 값이 없습니다. 공급사에 지문을 재요청하십시오."
    FPR_SOURCE="$FPR_FILE"
    [ "$FPR_OVERRIDE" != 'unsafe' ] || FPR_SOURCE="$FPR_FILE (앵커 우회 모드)"
    if [ -n "${ERP_EXPECTED_FPR:-}" ]; then
        say "      알림: ERP_EXPECTED_FPR 이 설정되어 있으나 무시합니다 — 앵커 파일이 우선입니다"
    fi
elif [ "$FPR_OVERRIDE" = 'unsafe' ] && [ -n "${ERP_EXPECTED_FPR:-}" ]; then
    EXPECTED_FPR="$(printf '%s' "$ERP_EXPECTED_FPR" | normalize_fpr)"
    # 파일 쪽과 같은 규칙이다. 공백만 든 값이 '미지정' 으로 강등되면 로그만 봐서는
    # 지문 대조를 아예 안 한 것과 구분이 안 된다.
    [ -n "$EXPECTED_FPR" ] || die 5 "ERP_EXPECTED_FPR 에 지문 값이 없습니다" \
        "공백·개행만 들어 있습니다. 값이 치환되지 않았을 수 있습니다. 확인 후 다시 실행하십시오."
    FPR_SOURCE="환경변수 ERP_EXPECTED_FPR (앵커 우회 모드)"
fi

# --- 3. 서명 -----------------------------------------------------------
PUBKEY_COUNT="$(gpg --list-keys --with-colons 2>/dev/null | grep -c '^pub' || true)"
[ "$PUBKEY_COUNT" -gt 0 ] || die 12 "키링에 공개키가 없습니다" \
    "신뢰 앵커가 배치되지 않았습니다. 번들 안의 키를 임포트하지 마십시오 — 그러면 검증이 무의미해집니다. 공급사에 대역 외 전달을 요청하십시오."

VERIFY_OUT="$(gpg --status-fd 1 --verify "$SIGFILE" "$BUNDLE" 2>>"$LOG" || true)"
printf '%s\n' "$VERIFY_OUT" >> "$LOG"

status() { printf '%s\n' "$VERIFY_OUT" | grep -q "^\[GNUPG:\] $1"; }

# 앵커와 일치하는 유효 서명이 있으면 미지 키 서명은 경고로 강등한다.
# .asc 는 서명되지 않은 컨테이너라, 키링에 없는 아무 키로 만든 블록 하나를 붙이는
# 것만으로 모든 정품 번들이 exit 12 로 죽고 — 그 조치문이 운영자를 앵커 재배포
# 경로(가장 비싼 지원 경로)로 보낸다. 만료·폐기와 같은 처리다.
# 서명 목록을 먼저 뽑는다. 아래 NO_PUBKEY·만료·폐기 판정이 전부 '앵커에 해당하는
# 서명이 있는가' 를 기준으로 하므로, 그 판정보다 앞에 있어야 한다.
# VALIDSIG 의 3번째 필드는 '서명에 쓰인 키' 지문, 마지막 필드는 primary 지문이다.
ALL_SIGNING="$(printf '%s\n' "$VERIFY_OUT" | awk '/^\[GNUPG:\] VALIDSIG/{print $3}')"
ALL_PRIMARY="$(printf '%s\n' "$VERIFY_OUT" | awk '/^\[GNUPG:\] VALIDSIG/{print $NF}')"
BAD_IDS="$(printf '%s\n' "$VERIFY_OUT" | awk '/^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG)/{print $3}')"
# grep 을 끼우지 않는다. 빈 입력에서 grep 이 1 을 반환하면 pipefail 이 스크립트를 죽인다.
SIG_COUNT="$(printf '%s\n' "$ALL_SIGNING" | awk -v b="$BAD_IDS" '
    BEGIN { n = split(b, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") bad[a[i]] = 1 }
    NF && !(substr($0, length($0) - 15) in bad) { c++ }
    END { print c + 0 }')"
SIGNING_FPR="$(printf '%s\n' "$ALL_SIGNING" | head -1)"
PRIMARY_FPR="$(printf '%s\n' "$ALL_PRIMARY" | head -1)"
ACTUAL_FPR="${PRIMARY_FPR:-$SIGNING_FPR}"

ANCHOR_SIGNED=''
if [ -n "$EXPECTED_FPR" ] &&
   printf '%s\n%s\n' "$ALL_PRIMARY" "$ALL_SIGNING" | grep -qxF "$EXPECTED_FPR"; then
    ANCHOR_SIGNED='yes'
fi
if status NO_PUBKEY; then
    if [ -n "$ANCHOR_SIGNED" ]; then
        say "      경고: 키링에 없는 키의 서명이 .asc 에 포함되어 있습니다 (판정에는 쓰지 않습니다)"
    else
        die 12 "이 번들에 서명한 키가 키링에 없습니다" \
            "다른 키로 서명되었거나 신뢰 앵커가 갱신되지 않았습니다. 번들 안의 키를 임포트하지 마십시오. 공급사에 확인하십시오."
    fi
fi

# EXPKEYSIG/REVKEYSIG 만 본다. 맨 KEYEXPIRED/KEYREVOKED 는 **이 서명과 무관한**
# 키링 전역 통지라서, 구 키 만료 + 신 키 병존(= 키 회전 직후의 정상 상태)에서
# 정상 번들을 거짓 거부한다.
# 만료·폐기 서명도 VALIDSIG 를 낸다(확인함). 따라서 키 ID 로 앵커와 대조해야 한다.
# 전역 판정이면, 공격자가 일회용 키를 만들어 스스로 폐기한 뒤 .asc 에 서명 블록 하나만
# 붙여서 — 번들은 손도 안 대고 — 모든 정품 번들에 exit 16 을 내게 할 수 있다.
# 거짓 경보가 반복되면 그 경로가 안 믿긴다. exit 14 를 고친 이유와 같다.
ANCHOR_KEY_STATUS="$(printf '%s\n' "$VERIFY_OUT" | awk -v a="$EXPECTED_FPR" '
    /^\[GNUPG:\] VALIDSIG/  { sf[$3] = $3; pf[$3] = $NF }
    /^\[GNUPG:\] EXPKEYSIG/ { expid[$3] = 1 }
    /^\[GNUPG:\] REVKEYSIG/ { revid[$3] = 1 }
    END {
        if (a == "") exit
        for (x in sf) {
            if (x != a && pf[x] != a) continue
            kid = substr(x, length(x) - 15)
            if (kid in revid) { print "revoked"; exit }
            if (kid in expid) { print "expired"; exit }
        }
    }')"

if [ -n "$EXPECTED_FPR" ]; then
    case "$ANCHOR_KEY_STATUS" in
        expired) die 13 "등록된 공급사 키가 만료되었습니다" \
            "공급사에 키 회전 여부를 확인하고 새 공개키와 지문을 대역 외로 받으십시오." ;;
        revoked) die 16 "등록된 공급사 키가 폐기되었습니다" \
            "이 키로 서명된 번들은 신뢰할 수 없습니다. 즉시 공급사에 연락하십시오." ;;
    esac
    if status EXPKEYSIG || status REVKEYSIG; then
        say "      경고: 앵커와 무관한 만료·폐기 서명이 .asc 에 포함되어 있습니다 (판정에는 쓰지 않습니다)"
    fi
else
    # 앵커 미지정이면 대조할 기준이 없다. 안전 측으로 기운다.
    if status EXPKEYSIG; then
        die 13 "이 번들에 서명한 키가 만료되었습니다" \
            "공급사에 키 회전 여부를 확인하고 새 공개키와 지문을 대역 외로 받으십시오."
    fi
    if status REVKEYSIG; then
        die 16 "이 번들에 서명한 키가 폐기되었습니다" \
            "이 키로 서명된 번들은 신뢰할 수 없습니다. 즉시 공급사에 연락하십시오."
    fi
fi


if ! status GOODSIG; then
    say "기대 서명자: ${EXPECTED_FPR:-<미지정>}"
    say "실제 서명자: ${ACTUAL_FPR:-<확인 불가>}"
    die 11 "서명 불일치 — 번들이 변조되었을 수 있습니다" \
        "체크섬은 통과했으나 서명이 맞지 않습니다. 운반 구간에서 내용이 바뀌었을 가능성이 있습니다. 설치하지 말고 공급사에 즉시 연락하십시오."
fi

say "[2/4] 서명 유효 — 유효 서명 ${SIG_COUNT}개"
# .asc 는 서명되지 않은 컨테이너다. 운반 구간에서 서명 블록을 덧붙일 수 있으므로
# 개수와 서명자 전부를 남긴다. 하나만 찍으면 공동 서명이 기록에서 사라진다.
printf '%s\n' "$ALL_PRIMARY" | grep . | sed 's/^/      서명자: /' | tee -a "$LOG" || true
if [ "$SIG_COUNT" -gt 1 ]; then
    say "      경고: 서명이 여러 개입니다. 정품 서명에 다른 서명이 덧붙었을 수 있습니다."
fi

# --- 4. 지문 대조 -------------------------------------------------------
# gpg --verify 는 키링의 '아무 키로나' 성공한다. 고객사 운영자가 지원 과정에서
# 다른 키를 임포트하는 순간 그 성공은 의미가 없어진다.
if [ -n "$EXPECTED_FPR" ]; then
    say "      기대 서명자 지문: $EXPECTED_FPR ($FPR_SOURCE)"
    # 서명 중 **하나라도** 앵커와 맞으면 통과한다. 첫 번째만 보면 공격자가 번들을
    # 건드리지 않고 자기 서명을 앞에 덧붙이는 것만으로 거짓 exit 14 를 반복 생성할 수
    # 있고, exit 14 는 '즉시 연락' 경로다 — 거짓 경보가 반복되면 그 경로가 안 믿긴다.
    if ! printf '%s\n%s\n' "$ALL_PRIMARY" "$ALL_SIGNING" | grep -qxF "$EXPECTED_FPR"; then
        die 14 "서명자가 기대 지문과 다릅니다 (서명 불일치)" \
            "유효한 서명이지만 등록된 공급사 키가 아닙니다. 설치하지 말고 공급사에 연락하십시오."
    fi
    say "[3/4] 서명자 지문 일치"
else
    say "[3/4] 기대 지문 미지정 — 지문 대조를 건너뜁니다"
    say "      경고: 키링의 어떤 키로든 서명이 통과합니다. 앵커가 반쪽입니다."
    say "      $FPR_FILE 에 기대 지문을 배치하십시오. PoC 에서도 배치해야 합니다 —"
    say "      배치하지 않으면 '다른 키로 전체 재서명' 변조가 검출되지 않습니다."
fi

# --- 5. 번들 구조 -------------------------------------------------------
# 서명은 tar 전체를 덮으므로 안의 install.sh 도 서명 대상이다. 그 사실을 확인해
# 로그에 남긴다. 버전이 여럿이면 **전부** 열거한다 — head -1 로 하나만 고르면
# tar 항목 순서(readdir 순서)에 따라 OS 마다 다른 버전이 뽑히고, 빠진 버전도 못 잡는다.
TAR_LIST="$(tar -tf "$BUNDLE" 2>>"$LOG" || true)"
[ -n "$TAR_LIST" ] || die 15 "번들이 비어 있거나 읽을 수 없습니다" \
    "서명은 통과했으므로 생성 측 문제일 수 있습니다. 공급사에 문의하십시오."

norm_path() { sed 's#^\./##'; }
INSTALLS="$(printf '%s\n' "$TAR_LIST" | grep -E '(^|/)install\.sh$' | norm_path | sort || true)"
MANIFESTS="$(printf '%s\n' "$TAR_LIST" | grep -E '(^|/)manifest\.(json|ya?ml)$' | norm_path | sort || true)"

[ -n "$INSTALLS" ] || die 15 "번들에 install.sh 가 없습니다" \
    "번들 생성이 불완전합니다. 공급사에 문의하십시오."

# 빈 입력을 '.' 로 접지 않는다. 접으면 실재하지 않는 디렉터리가 집합에 들어간다.
dirs_of() { grep . | sed 's#[^/]*$##; s#/$##; s#^$#.#' | sort -u || true; }
INSTALL_DIRS="$(printf '%s\n' "$INSTALLS" | dirs_of)"
MANIFEST_DIRS="$(printf '%s\n' "$MANIFESTS" | dirs_of)"

# **최상위(`.`) 매니페스트는 묶음 신원이지 버전이 아니다.** 버전 디렉터리는
# install.sh 가 있는 하위 디렉터리로만 센다. 묶음 매니페스트 1개 + 버전별
# install.sh 구조와 버전별 매니페스트 구조를 둘 다 받는다 — 어느 쪽을 쓸지는
# #19 의 미결 ADR 이고, 검증 스크립트가 그 결정을 대신 내려서는 안 된다.
VERSION_DIRS="$(printf '%s\n' "$INSTALL_DIRS" | grep -v '^\.$' || true)"
MANIFEST_VDIRS="$(printf '%s\n' "$MANIFEST_DIRS" | grep -v '^\.$' || true)"

MISSING_INSTALL="$(comm -13 <(printf '%s\n' "$VERSION_DIRS") <(printf '%s\n' "$MANIFEST_VDIRS") || true)"
# 최상위 묶음 매니페스트가 있으면 레이아웃 A 다. 버전별 매니페스트 부재는 결함이 아니다.
# 최상위 매니페스트가 있고 **버전별 매니페스트가 하나도 없을 때만** 레이아웃 A 로 본다.
# 무조건 억제하면 레이아웃 B 에서 일부 버전 매니페스트가 빠진 것을 조용히 덮는다.
if printf '%s\n' "$MANIFEST_DIRS" | grep -qx '\.' &&
   [ -z "$(printf '%s' "$MANIFEST_VDIRS" | tr -d '[:space:]')" ]; then
    MISSING_MANIFEST=''
else
    MISSING_MANIFEST="$(comm -23 <(printf '%s\n' "$VERSION_DIRS") <(printf '%s\n' "$MANIFEST_VDIRS") || true)"
fi

if [ -n "$(printf '%s' "$MISSING_INSTALL" | tr -d '[:space:]')" ]; then
    say "      버전 매니페스트는 있으나 install.sh 가 없는 위치:"
    printf '%s\n' "$MISSING_INSTALL" | grep . | sed 's/^/        /' | tee -a "$LOG" || true
    die 15 "일부 버전에 install.sh 가 없습니다" \
        "번들 생성이 불완전합니다. 공급사에 문의하십시오. 이 상태로 설치하면 해당 버전을 적용할 수 없습니다."
fi

say "[4/4] 번들 구조 확인 — 설치 스크립트 $(printf '%s\n' "$INSTALLS" | wc -l | tr -d ' ')개 (모두 서명 범위에 포함됨)"
printf '%s\n' "$INSTALLS" | sed 's/^/        /' | tee -a "$LOG"

if [ -n "$(printf '%s' "$MISSING_MANIFEST" | tr -d '[:space:]')" ]; then
    say "      경고: 매니페스트가 없는 위치 — 그 위치의 신원을 확인할 수 없습니다:"
    printf '%s\n' "$MISSING_MANIFEST" | grep . | sed 's/^/        /' | tee -a "$LOG" || true
fi

if [ -z "$MANIFESTS" ]; then
    say "      경고: 번들에 매니페스트가 없습니다 — 신원(버전·빌드 SHA·이미지 다이제스트)이 감사 로그에 남지 않습니다"
else
    say "      번들 신원:"
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        # 경로도 번들에서 온 문자열이다. 격리 없이 로그에 쓰면 tar 의 escape quoting
        # 에만 기대게 된다 — 구현·옵션이 바뀌면 감사 로그 위조가 경로명으로 되살아난다.
        printf '%s\n' "[$m]" | untrusted | tee -a "$LOG"
        if MANIFEST_BODY="$(tar -xOf "$BUNDLE" "./$m" 2>/dev/null)" ||
           MANIFEST_BODY="$(tar -xOf "$BUNDLE" "$m" 2>/dev/null)"; then
            # 파일마다 상한을 건다. 전체 합산으로 걸면 뒤 버전이 조용히 사라진다.
            printf '%s\n' "$MANIFEST_BODY" | untrusted | tee -a "$LOG"
        else
            say "      경고: $m 을 읽을 수 없습니다 — 이 위치의 신원이 기록되지 않습니다"
        fi
    done <<< "$MANIFESTS"
fi

{
    printf '\n'
    if [ "$FPR_OVERRIDE" = 'unsafe' ]; then
        printf '  검증 통과 (verify-bundle.sh %s) — **앵커 우회 모드**\n' "$SCRIPT_VERSION"
        printf '  경고: 앵커 값이 사전 배치본이 아니라 환경변수에서 왔습니다. 운영에 쓰지 마십시오.\n'
    else
        printf '  검증 통과 (verify-bundle.sh %s)\n' "$SCRIPT_VERSION"
    fi
    printf '\n'
    printf '  이제 설치를 진행할 수 있습니다. 적용할 버전의 스크립트를 고르십시오:\n'
    printf "    tar -xf '%s' -C <작업디렉터리>\n" "$BUNDLE"
    printf '%s\n' "$INSTALLS" | sed "s#^#    '<작업디렉터리>/#; s#\$#'#"
    printf '\n'
    printf '  로그: %s\n' "$LOG"
    printf '\n'
} | tee -a "$LOG"

exit 0
