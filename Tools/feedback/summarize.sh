#!/usr/bin/env bash
set -euo pipefail
dir="${1:-$HOME/Downloads/OpenHuman-feedback}"
[[ -d "$dir" ]] || { echo "summarize: no folder $dir" >&2; exit 2; }
exec python3 -I - "$dir" <<'PY'
import json, pathlib, sys

def clean(value, limit=300):
    text = "".join(ch if ch.isprintable() else " " for ch in str(value))
    return text if len(text) <= limit else text[: limit - 1] + "…"

folder = pathlib.Path(sys.argv[1])
files = sorted(folder.glob("feedback-*.json"))
if not files:
    print(f"no feedback-*.json in {clean(folder)}")
for path in files:
    try:
        if path.stat().st_size > 20 * 1024 * 1024:
            print(f"== {clean(path.name)}: larger than 20 MB, skipped"); continue
        bundle = json.loads(path.read_text(encoding="utf-8"))
        assert isinstance(bundle, dict) and bundle.get("format") == "openhuman-dev-feedback"
    except Exception:
        print(f"== {clean(path.name)}: not a readable feedback bundle"); continue
    snap = bundle.get("snapshot") or {}
    app = snap.get("app") or {}
    logs = [l for l in (bundle.get("logs") or []) if isinstance(l, dict)]
    attached = [k for k, v in (bundle.get("attachments") or {}).items() if v]
    print(f"== {clean(path.name)}")
    print("   " + clean(f"{bundle.get('createdAt')}  {bundle.get('category')}  route={snap.get('route', '-')}  "
                         f"safe={snap.get('safeMode', '-')}  data={app.get('dataMode', '-')}  "
                         f"build={app.get('version', '?')} {app.get('gitCommit', '?')} {app.get('configuration', '')}"))
    for a in snap.get("accounts") or []:
        print("   " + clean(f"account {a.get('index')} {a.get('idHash')}: {a.get('connectivity') or a.get('syncPhase') or '-'} "
                             f"threads={a.get('threadCount')} messages={a.get('messageCount')} inbox={a.get('inboxThreads')}"))
    reader = snap.get("reader")
    if reader:
        print("   " + clean(f"reader thread={reader.get('threadID')} mode={reader.get('mode')} "
                             f"images={reader.get('imagePolicy')} messages={reader.get('messageCount')}"))
    errors = sum(1 for l in logs if l.get("level") == "error")
    print("   " + clean(f"errors: {len(snap.get('recentErrors') or [])} recent, {errors} error log lines of {len(logs)}; "
                         f"attached: {', '.join(attached) or 'nothing'}"))
    if "threadSubjectAndSender" in attached or "screenshot" in attached:
        print("   NOTE: this bundle contains email content (not printed)")
    keys = [c.get("id") for c in (snap.get("recentCommands") or []) if isinstance(c, dict)][-12:]
    if keys:
        print("   keys: " + clean(" ".join(map(str, keys))))
    if snap.get("checklistViewing"):
        print("   viewing checklist item: " + clean(snap["checklistViewing"], 80))
    text = str(bundle.get("text") or "").strip()
    if text:
        print("   text: " + clean(text.replace("\n", " / "), 600))
    checklist = bundle.get("checklist") or {}
    answers = [a for a in (checklist.get("answers") or []) if isinstance(a, dict)]
    print("   " + clean(f"checklist ({checklist.get('source')}): {checklist.get('testedCount')}/{checklist.get('itemCount')} "
                         f"tested, {len(answers)} new answers"))
    for a in answers:
        note = str(a.get("note") or "").strip().replace("\n", " / ")
        print("     " + clean(f"{a.get('result') or 'note':<10} {a.get('itemID')}" + (f"  - {note}" if note else ""), 300))
PY
