#!/usr/bin/env python3
"""plan.md 실행 단계를 이슈로 분할해 생성한다.

이슈 정의는 scripts/issues.json 에 있다. 의존은 key 로 선언하고, 생성 순서대로
실제 번호로 치환한다 — 선행이 항상 먼저 생성되도록 **위상정렬**한다.
선행이 있는 이슈는 status:blocked 로 시작하고, /poc-merge 가 해제한다.

  python3 scripts/create-issues.py --dry-run   # 생성 없이 확인
  python3 scripts/create-issues.py             # 실제 생성
"""
import json, os, subprocess, sys

REPO = os.environ.get("POC_REPO", "sunm2n/ERP_devOps_Poc")
HERE = os.path.dirname(os.path.abspath(__file__))
DRY = "--dry-run" in sys.argv

FIELDS = ("key", "title", "labels", "goal", "hyp", "done", "deps", "notes")


def load():
    with open(os.path.join(HERE, "issues.json"), encoding="utf-8") as f:
        rows = json.load(f)
    return [dict(zip(FIELDS, r)) for r in rows]


def toposort(items):
    """선행이 먼저 오도록 정렬. 순환이나 미정의 참조는 즉시 실패시킨다."""
    by_key = {i["key"]: i for i in items}
    for i in items:
        for d in i["deps"]:
            if d not in by_key:
                sys.exit("미정의 선행: %s -> %s" % (i["key"], d))
    out, done, temp = [], set(), set()

    def visit(k, trail):
        if k in done:
            return
        if k in temp:
            sys.exit("순환 의존: " + " -> ".join(trail + [k]))
        temp.add(k)
        for d in by_key[k]["deps"]:
            visit(d, trail + [k])
        temp.discard(k)
        done.add(k)
        out.append(by_key[k])

    for i in items:            # 원래 순서를 최대한 보존한다
        visit(i["key"], [])
    return out


def body(i, nmap):
    deps = ", ".join("#%d" % nmap[k] for k in i["deps"]) if i["deps"] else "없음"
    b = ["## 목표", "", i["goal"], "", "## 대상 가설", "", i["hyp"], "", "## 완료 조건", ""]
    b += ["- [ ] " + c for c in i["done"]]
    b += ["", "## 선행 이슈", "", deps]
    if i["notes"]:
        b += ["", "## 비고", "", i["notes"]]
    return "\n".join(b)


def main():
    items = toposort(load())
    nmap, ready, blocked = {}, 0, 0

    for i in items:
        labels = i["labels"] + (",status:blocked" if i["deps"] else ",status:ready")
        if i["deps"]:
            blocked += 1
        else:
            ready += 1
        text = body(i, nmap)

        if DRY:
            n = 900 + len(nmap)
            print("=" * 72)
            print("#%d %s\n[%s]\n" % (n, i["title"], labels))
            print(text)
        else:
            out = subprocess.run(
                ["gh", "issue", "create", "--repo", REPO, "--title", i["title"],
                 "--label", labels, "--body", text],
                capture_output=True, text=True, check=True).stdout.strip()
            n = int(out.rsplit("/", 1)[1])
            print("#%-4d %s" % (n, i["title"]))
        nmap[i["key"]] = n

    if not DRY:
        with open(os.path.join(HERE, "issue-map.json"), "w", encoding="utf-8") as f:
            json.dump(nmap, f, indent=2, ensure_ascii=False)
        print("\n%d개 생성 (ready %d / blocked %d)." % (len(items), ready, blocked))
        print("매핑: scripts/issue-map.json")


main()
