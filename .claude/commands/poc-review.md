---
description: PR을 3개 관점(CI/CD·실무도입·보안)으로 병렬 리뷰하고 결과를 PR에 남긴다
allowed-tools: Bash, Read, Grep, Glob, Agent
---

PoC 하네스의 **리뷰 단계**. PR 하나를 세 관점으로 리뷰한다.

## 1. 대상 확인

$ARGUMENTS 에 PR 번호가 있으면 그것, 없으면 현재 브랜치의 PR.

```
gh pr view <번호> --json number,title,body,headRefName,files
gh pr diff <번호>
```

CI 상태도 확인한다: `gh pr checks <번호>`.
정적 검증이 실패했으면 **리뷰를 돌리기 전에 먼저 고쳐라.** 깨진 PR을 세 에이전트에
보내면 세 명이 똑같이 CI 실패를 지적한다.

## 2. 병렬 리뷰

Agent 도구로 **세 개를 한 메시지에서 동시에** 띄운다. 순차로 돌리지 마라.

- `subagent_type: cicd-reviewer`
- `subagent_type: adoption-reviewer`
- `subagent_type: security-reviewer`

각 에이전트에 넘길 프롬프트에 포함할 것:
- PR 번호와 제목, `Closes` 대상 이슈 번호
- 대상 가설 (H1~H8)
- 리뷰 방법: `gh pr diff <번호>` 로 변경분을 직접 읽으라고 지시
- PR 본문의 "알면서 안 한 것" 내용 — 중복 지적 방지
- 리뷰 라운드 번호 (2라운드 이상이면 이전 라운드 지적과 대응 내역도 함께)

## 3. 취합

세 리뷰를 하나의 코멘트로 합쳐 PR에 남긴다. 관점별 판정과 지적을 그대로 보존하되,
세 명이 같은 것을 지적했으면 합치고 "3개 관점 공통"이라고 표시하라 — 그건 거의
확실히 진짜 문제다.

관점 간 **의견이 충돌하면 숨기지 말고 드러내라.** 보안이 서명 검증을 요구하고
실무도입이 "PoC엔 과하다"고 하면, 양쪽을 다 적고 네 판단과 근거를 덧붙여라.
이 충돌 자체가 보고서 6장(설계 결정에 미치는 영향)의 재료다.

```
gh pr comment <번호> --body-file <취합한 리뷰>
```

## 4. 판정

- 세 관점 모두 `blocker` 없음 → **통과**. PR에 `review:passed` 표시를 남긴다.
- 하나라도 `blocker` → **수정 필요**. blocker 목록을 정리해 보고한다.

`should-fix` 와 `nit` 은 머지를 막지 않는다. 다만 `report` 로 분류된 항목은
`docs/findings.md` 에 누적하라 — 최종 보고서 5·7장이 여기서 나온다.
파일이 없으면 만들고, 있으면 PR 번호와 함께 덧붙인다.

## 5. 보고

관점별 판정 한 줄씩, blocker 개수, 그리고 머지 가능 여부를 보고한다.
