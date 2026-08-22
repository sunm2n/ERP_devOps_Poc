#!/usr/bin/env bash
#
# 적용 완료 판정 — 설치 스크립트(#20)가 호출한다.
#
# **이 파일이 계약의 정본이다.** 문서 코드블록에 두면 shellcheck 도 테스트도 닿지 않는다 —
# 실제로 그 상태에서 조용히 틀리는 경로가 두 개 있었다(빈 SHA 무증상 통과, code=000 의
# 낡은 본문). `verify-bundle.sh` 와 같은 규율로 둔다.
#
# 사용법:
#   wait-for-health.sh <헬스URL> [기대커밋SHA] [최대대기초]
#
# 종료 코드 — `verify-bundle.sh` 의 0~16·130 과 겹치지 않게 20번대를 쓴다.
#   0   적용 완료 (/health 200 + build 일치)
#  20   대기 상한 초과
#  21   200 이지만 build 불일치 — 컨테이너가 교체되지 않았다. 재적용으로 고쳐질 수 있다
#  22   buildIdentity 가 missing-commit-sha, 또는 build 에서 SHA 를 뽑지 못함 —
#       대조 자체가 무의미하다. **재적용으로 안 고쳐진다** (번들 생성 측 문제)
#  23   curl/wget 없음, 또는 응답 코드 000 (포트 매핑 -p 8080:8080 누락 포함)
#
# 21 과 22 를 나눈 이유: 21 은 재적용으로 고쳐질 수 있고 22 는 절대 안 고쳐진다.
# 같은 코드로 묶으면 담당자가 고쳐지지 않을 것을 반복한다.

set -o nounset
set -o pipefail

URL="${1:?사용법: $0 <헬스URL> [기대커밋SHA] [최대대기초]}"
EXPECTED_SHA="${2:-}"
DEADLINE_SECONDS="${3:-600}"
LOG="${ERP_HEALTH_LOG:-/var/log/erp-install-health.json}"
INTERVAL="${ERP_POLL_INTERVAL:-2}"

command -v curl >/dev/null 2>&1 || {
    printf 'curl 이 없습니다. VM 사전 요구사항을 확인하십시오.\n' >&2
    exit 23
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

deadline=$(( $(date +%s) + DEADLINE_SECONDS ))
last=''
code=000

while :; do
    # **매 폴링마다 비운다.** curl 은 연결 실패 시 -o 파일을 건드리지 않으므로,
    # 비우지 않으면 code=000 화면에 직전 폴링의 낡은 본문이 함께 찍힌다 —
    # 담당자는 포트 매핑 문제를 DB 문제로 쫓게 된다.
    : > "$LOG" 2>/dev/null || true

    code="$(curl -s -o "$LOG" -w '%{http_code}' "$URL")" || code=000

    [ "$code" = 200 ] && break

    if [ "$code" != "$last" ]; then
        printf '[%s] 대기 중\n' "$code"
        [ "$code" = 000 ] || { cat "$LOG" 2>/dev/null; printf '\n'; }
        last="$code"
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '대기 상한 %s초 초과 (마지막 응답 코드 %s)\n' "$DEADLINE_SECONDS" "$code" >&2
        if [ "$code" = 000 ]; then
            printf '응답이 없습니다. 포트 매핑(-p 8080:8080)과 컨테이너 기동을 확인하십시오.\n' >&2
            exit 23
        fi
        cat "$LOG" 2>/dev/null >&2
        exit 20
    fi
    sleep "$INTERVAL"
done

# --- build 대조 -------------------------------------------------------
# 인코더가 relaxed 라 `+` 와 한글이 원문으로 나온다 — jq 없이 셸만으로 뽑힌다.
if grep -q '"buildIdentity":"missing-commit-sha"' "$LOG"; then
    printf '빌드 신원에 커밋 SHA 가 없습니다 — build 대조가 무의미합니다.\n' >&2
    printf '번들 생성 측에서 -p:SourceRevisionId 주입이 빠졌습니다. 재적용으로 고쳐지지 않습니다.\n' >&2
    exit 22
fi

if [ -z "$EXPECTED_SHA" ]; then
    printf '적용 완료 (기대 SHA 미지정 — build 대조를 건너뜁니다)\n'
    exit 0
fi

build="$(sed -n 's/.*"build":"\([^"]*\)".*/\1/p' "$LOG")"
actual="${build#*+}"

# **빈 값을 통과시키지 않는다.** `case "$EXPECTED" in "$actual"*)` 는 actual 이 비면
# 빈 패턴이 되어 무엇에나 일치한다 — `git describe --always --dirty` 처럼 SHA 뒤에
# 접미어가 붙는 흔한 스탬핑에서 대조가 조용히 통과하던 자리다.
if [ -z "$build" ] || [ "$actual" = "$build" ]; then
    printf 'build 에서 SHA 를 뽑지 못했습니다: %s\n' "${build:-<없음>}" >&2
    exit 22
fi

case "$EXPECTED_SHA" in
    "$actual"*) ;;   # 앞자리 일치 (build 쪽이 짧을 수 있다)
    *)
        case "$actual" in
            "$EXPECTED_SHA"*) ;;   # 반대 방향도 허용
            *)
                printf 'build 불일치: 기대 %s / 실제 %s\n' "$EXPECTED_SHA" "$actual" >&2
                printf '컨테이너가 교체되지 않았을 수 있습니다. 재적용 후에도 같으면 공급사에 문의하십시오.\n' >&2
                exit 21
                ;;
        esac
        ;;
esac

printf '적용 완료 (build %s)\n' "$actual"
exit 0
