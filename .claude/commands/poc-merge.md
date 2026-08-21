---
description: 리뷰를 통과한 PR을 머지하고 이슈를 닫은 뒤 후속 이슈의 차단을 푼다
allowed-tools: Bash, Read, Grep, Glob
---

PoC 하네스의 **머지 단계**.

## 1. 머지 전 확인

$ARGUMENTS 의 PR 번호(없으면 현재 브랜치).

아래를 **전부** 확인한다. 하나라도 아니면 머지하지 말고 이유를 보고하라.
- `gh pr checks <번호>` 가 전부 통과
- `/poc-review` 가 blocker 0으로 판정
- PR 본문에 `Closes #<이슈>` 존재
- 충돌 없음 (`gh pr view <번호> --json mergeable`)

## 2. 머지

```
gh pr merge <번호> --squash --delete-branch
```

squash 를 쓴다. PoC 저장소의 히스토리는 "가설 하나당 커밋 하나"로 읽혀야 한다.

## 3. 이슈 정리

`Closes` 로 자동으로 닫혔는지 확인한다. 안 닫혔으면 직접 닫는다.

머지된 PR에서 나온 **측정값**(`plan.md` 5장 지표)이 있으면 `measurements/` 아래
해당 파일에 기록됐는지 확인하라. PR 본문에만 있고 저장소에 없으면 4단계에서
전부 다시 찾아야 한다.

## 4. 후속 이슈 차단 해제

방금 닫힌 이슈를 선행으로 걸고 있던 이슈를 찾는다.

```
gh issue list --state open --label status:blocked --json number,title,body
```

각 이슈 본문의 "선행 이슈" 항목을 읽고, 거기 적힌 이슈가 **전부** 닫혔으면:

```
gh issue edit <번호> --remove-label status:blocked --add-label status:ready
gh issue comment <번호> --body "선행 이슈 #N 완료로 착수 가능."
```

선행 중 하나라도 열려 있으면 그대로 둔다.

## 5. 보고

머지한 PR, 닫힌 이슈, 새로 `status:ready` 가 된 이슈 목록을 보고한다.
