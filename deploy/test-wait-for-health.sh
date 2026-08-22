#!/usr/bin/env bash
#
# wait-for-health.sh 자체 테스트.
#
# 이 계약이 문서 코드블록 안에 있던 동안 shellcheck 도 테스트도 닿지 않았고,
# 처음 실행해 본 순간 조용히 틀리는 경로가 둘 나왔다 —
# (a) build 에서 SHA 를 못 뽑으면 빈 패턴이 무엇에나 일치해 통과
# (b) code=000 일 때 직전 폴링의 낡은 본문을 출력
# 그래서 실패 경로를 전부 돌린다.

set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="$HERE/wait-for-health.sh"
WORK="$(mktemp -d)"
PORT=18099
SRV_PID=''
cleanup() { [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

export ERP_HEALTH_LOG="$WORK/health.json"
export ERP_POLL_INTERVAL=1

PASS=0; FAIL=0
check() { if [ "$1" = "$3" ]; then printf '  PASS  %-44s exit=%s\n' "$2" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %-44s 기대=%s 실제=%s\n' "$2" "$1" "$3"; FAIL=$((FAIL+1)); fi; }

# 응답을 파일로 제어하는 최소 서버. $WORK/code 와 $WORK/body 를 읽어 응답한다.
start_server() {
  # 서버가 뜨기 전에 응답 파일이 있어야 한다.
  printf '%s' 200 > "$WORK/code"; printf '%s' '{}' > "$WORK/body"
  python3 - "$PORT" "$WORK" <<'PY' &
import http.server, sys, os
port, work = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = int(open(os.path.join(work, 'code')).read().strip())
        body = open(os.path.join(work, 'body'), 'rb').read()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  SRV_PID=$!
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && return 0; sleep 0.2; done
  return 1
}
respond() { printf '%s' "$1" > "$WORK/code"; printf '%s' "$2" > "$WORK/body"; }
run() { "$WAIT" "http://127.0.0.1:$PORT/health" "${1:-}" "${2:-5}" >/dev/null 2>&1 && printf 0 || printf '%s' "$?"; }

SHA=3c0e93ca6c86664cbe0890f7f92a2b6db9b50cde
OK_BODY="{\"status\":\"Healthy\",\"build\":\"1.0.0+$SHA\",\"buildIdentity\":\"ok\",\"connectionSource\":\"env\"}"

printf '\n=== wait-for-health.sh 자체 테스트 ===\n\n'
start_server || { echo "서버 기동 실패"; exit 1; }

printf '[성공 경로]\n'
respond 200 "$OK_BODY"
check 0 "200 + SHA 일치" "$(run "$SHA")"
check 0 "200 + 기대 SHA 미지정" "$(run '')"
check 0 "200 + 기대 SHA 가 더 김 (앞자리 일치)" "$(run "${SHA}extra")"

printf '\n[build 대조 — 빈 SHA 가 통과하면 안 된다]\n'
for b in "1.0.0+${SHA:0:7}-dirty" "1.0.0+feature-x" "1.0.0+3C0E93CA" "1.0.0"; do
  respond 200 "{\"status\":\"Healthy\",\"build\":\"$b\",\"buildIdentity\":\"ok\"}"
  case "$b" in
    1.0.0) exp=22 ;;                       # + 가 없다 -> SHA 추출 불가
    *dirty|*feature-x|*3C0E93CA) exp=21 ;; # 뽑히지만 불일치
  esac
  check "$exp" "build=$b" "$(run "$SHA")"
done
respond 200 "{\"status\":\"Healthy\",\"build\":\"1.0.0\",\"buildIdentity\":\"missing-commit-sha\"}"
check 22 "buildIdentity=missing-commit-sha" "$(run "$SHA")"

printf '\n[503 은 종료가 아니라 대기다]\n'
respond 503 '{"status":"Unhealthy","checks":{"database":{"description":"database unreachable"}}}'
# 인자 없는 `wait` 는 서버 프로세스까지 기다려 영원히 멈춘다. PID 를 지정한다.
( sleep 3; printf '%s' 200 > "$WORK/code"; printf '%s' "$OK_BODY" > "$WORK/body" ) &
flipper=$!
check 0 "503 -> 200 (DB 가 늦게 뜨는 정상 경로)" "$(run "$SHA" 20)"
wait "$flipper" 2>/dev/null || true
respond 503 '{"status":"Unhealthy"}'
check 20 "503 이 상한까지 지속" "$(run "$SHA" 3)"

printf '\n[응답 없음]\n'
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=''
sleep 1
check 23 "연결 불가 (code=000)" "$(run "$SHA" 3)"
printf '  로그에 낡은 본문이 남았는가: '
if [ -s "$ERP_HEALTH_LOG" ]; then printf 'FAIL (%s바이트 잔존)\n' "$(wc -c < "$ERP_HEALTH_LOG" | tr -d ' ')"; FAIL=$((FAIL+1))
else printf 'PASS (비어 있음)\n'; PASS=$((PASS+1)); fi

printf '\n[전제]\n'
D="$WORK/nocurl"; mkdir -p "$D"
for c in bash sed grep date sleep mkdir dirname cat printf wc; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$D/$c" 2>/dev/null || true
done
out="$(PATH="$D" "$WAIT" "http://127.0.0.1:$PORT/health" "$SHA" 3 2>&1; printf '|%s' "$?")"
check 23 "curl 없음" "${out##*|}"

printf '\n=== 결과: %s PASS / %s FAIL ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
