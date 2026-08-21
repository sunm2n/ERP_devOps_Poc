---
description: 다음 작업 이슈를 선택해 브랜치 → 구현 → PR 까지 진행한다
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent
---

PoC 하네스의 **작업 단계**. 다음 이슈 하나를 골라 PR을 여는 데까지 간다.

## 1. 이슈 선택

$ARGUMENTS 에 이슈 번호가 있으면 그것을 쓴다. 없으면 아래로 고른다.

```
gh issue list --state open --label status:ready --json number,title,labels --limit 50
```

선택 우선순위:
1. `phase:` 숫자가 가장 낮은 것
2. 같은 단계면 `prio:must` → `prio:should` → `prio:conditional`
3. 같으면 이슈 번호가 작은 것

**`status:blocked` 는 절대 고르지 마라.** 선행 이슈가 아직 안 닫혔다는 뜻이다.

`type:env` 이슈를 골랐다면 PR을 만들 수 없다(사람이 VM/레지스트리에서 직접 해야 함).
그 경우: 이슈에 실행 절차와 기록할 항목을 코멘트로 남기고, `status:ready` 인 다른
`type:repo` 이슈로 넘어간다. `type:repo` 가 하나도 없으면 **거기서 멈추고**
사람이 처리해야 할 `type:env` 이슈 목록을 보고하라.

착수할 이슈가 없으면 그대로 보고하고 끝낸다. 없는 일을 만들지 마라.

## 2. 준비

```
git checkout main && git pull --ff-only
git checkout -b <phase>/<issue번호>-<짧은-영문-슬러그>
```

`plan.md` 에서 이 이슈에 해당하는 실행 단계와 가설을 읽는다. 이슈 본문의
완료 조건이 계획과 어긋나면 **구현하기 전에 그 사실을 이슈에 코멘트로 남겨라.**

## 3. 구현

이슈의 완료 조건을 전부 만족시킨다. 일부만 하고 PR을 열지 마라.

지켜야 할 것:
- `plan.md` 2장의 **제외 목록**을 넘지 마라. K8s, 인증, 모니터링, 메타데이터 엔진,
  실제 ERP 로직은 이 PoC의 범위가 아니다.
- 코어 앱은 12-factor를 처음부터 지킨다: 설정은 환경변수, 로그는 stdout,
  로컬 디스크 저장 없음, 헬스체크, 그레이스풀 셧다운.
- 시크릿을 커밋하지 마라. 이 저장소는 public 이다.
- 실행해서 확인할 수 있는 것은 실행해서 확인하라. 확인 못 한 것을 확인한 것처럼
  PR에 쓰지 마라.

## 4. PR

```
git push -u origin HEAD
gh pr create --fill-first --body-file <작성한 본문>
```

PR 본문은 `.github/PULL_REQUEST_TEMPLATE.md` 형식을 따른다. 특히:
- `Closes #<이슈번호>` 를 반드시 넣어라 (머지 시 자동 클로즈).
- **검증 방법**에는 실제 실행한 명령과 그 출력을 쓴다. 실행하지 못했으면
  "미실행"이라고 쓰고 이유를 밝혀라.
- **알면서 안 한 것**을 채워라. 리뷰어 3명이 같은 걸 중복 지적하는 걸 막는다.

## 5. 보고

PR 번호와 URL, 그리고 이 PR이 어느 가설에 기여하는지 한 줄로 보고한다.
