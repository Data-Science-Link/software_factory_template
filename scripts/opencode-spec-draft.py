#!/usr/bin/env python3
"""/oc spec helper (#78): model choice, the spec run's cost guard, draft extraction and checks.

Script only: the worker writes the spec text; every fact around it (status, model, predicted
build cost, spec-run cost, reviewer, checks) is filled here, never by the model.

  model                          print the model for spec runs: the models.yaml routing rule
                                 whose `when` is exactly {work_type: spec} (rule 2)
  preflight                      print model, predicted spec-run cost and cap; exit 1 when the
                                 prediction is above budget.issue_cap_usd (refuse to run)
  build --log L --issue N --out-dir D [--usage U] [--run-url URL]
                                 extract the worker's spec from L, normalize the harness-owned
                                 front matter fields, predict the build cost, run the checks and
                                 write D/spec-comment.md (a DRAFT comment, or a "no draft"
                                 comment listing the failures) and D/spec-meta.txt
  check-comment F --issue N      publish: re-check a comment file before posting it
  approve TEXT --approved-by WHO [--at ISO]
                                 print TEXT (a draft spec) as the approved spec comment body
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MARKER = "<!-- factory-spec v1 -->"
END = "<!-- end factory-spec -->"
DRAFT_TAG = "<!-- factory-spec-draft v1 -->"
FAILED_TAG = "<!-- factory-spec-draft-failed v1 -->"
SPEC_MODEL_RULE = {"work_type": "spec"}
# Spec-run token prior when models.yaml has no token_priors.spec (owner-only file).
DEFAULT_SPEC_PRIOR = {"tokens_in": 150000, "tokens_cached_fraction": 0.80, "tokens_out": 12000}
TARGET_USD = 0.10
MAX_SPEC_BYTES = 40000
OWNED_FIELDS = ("issue", "status", "approved_by", "approved_at", "drafted_by", "model", "model_reason",
                "predicted_tokens_in", "predicted_tokens_cached", "predicted_tokens_out",
                "predicted_cost_usd", "budget_cap_usd", "price_table_version")


def die(msg: str, code: int = 1) -> None:
    print(f"spec-draft: {msg}", file=sys.stderr)
    sys.exit(code)


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def models_data(path: Path) -> dict:
    import yaml
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def spec_model(data: dict) -> tuple[str, str]:
    for rule in data.get("routing_rules") or []:
        if (rule.get("when") or {}) == SPEC_MODEL_RULE:
            return str(rule["model"]), f"models.yaml rule {rule.get('rule')}"
    die("models.yaml has no routing rule with when: {work_type: spec}")
    raise AssertionError


def price(data: dict, model: str) -> dict:
    for row in data.get("models") or []:
        if row.get("id") == model:
            return row
    die(f"model {model} not in models.yaml")
    raise AssertionError


def spec_run_prediction(data: dict) -> tuple[str, float, float]:
    model, _ = spec_model(data)
    p = price(data, model)
    prior = (data.get("token_priors") or {}).get("spec") or DEFAULT_SPEC_PRIOR
    t_in = int(prior["tokens_in"])
    cached = int(round(t_in * float(prior["tokens_cached_fraction"])))
    out = int(prior["tokens_out"])
    usd = ((t_in - cached) * p["price_in_per_mtok"] + cached * p["price_cached_per_mtok"]
           + out * p["price_out_per_mtok"]) / 1e6
    cap = float((data.get("budget") or {}).get("issue_cap_usd", 1.0))
    return model, round(usd, 4), cap


# --- front matter, edited line by line (never a YAML dump: the worker's text stays as written)
def split_spec(spec: str) -> tuple[list[str], list[str], list[str]]:
    lines = spec.split("\n")
    if not lines or lines[0] != MARKER or len(lines) < 3 or lines[1].strip() != "---":
        raise ValueError("the spec must start with the marker line, then a --- front matter line")
    for i in range(2, len(lines)):
        if lines[i].strip() == "---":
            return lines[:2], lines[2:i], lines[i:]
    raise ValueError("front matter has no closing --- line")


def set_field(fm: list[str], key: str, value: str) -> list[str]:
    out, done, skip = [], False, False
    for line in fm:
        if skip and (line.startswith(" ") or line.startswith("\t")):
            continue  # continuation lines of the old value
        skip = False
        if re.match(rf"^{re.escape(key)}:(\s|$)", line):
            if not done:
                out.append(f"{key}: {value}")
                done = True
            skip = True
            continue
        out.append(line)
    if not done:
        out.append(f"{key}: {value}")
    return out


def get_field(fm: list[str], key: str) -> str:
    for line in fm:
        m = re.match(rf"^{re.escape(key)}:\s*(.*?)\s*(#.*)?$", line)
        if m:
            return m.group(1).strip("'\"")
    return ""


def yq(text: str) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def section(spec: str, heading: str) -> str:
    m = re.search(rf"^##[ \t]+{re.escape(heading)}[ \t]*\n(.*?)(?=^##[ \t]|\Z)", spec, re.M | re.S)
    return m.group(1) if m else ""


def predict_build(spec: str, models: Path) -> tuple[dict | None, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(spec)
        tmp = f.name
    try:
        r = subprocess.run([sys.executable, str(HERE / "factory-predict-cost.py"), "--json", "--models", str(models), tmp],
                           capture_output=True, text=True)
    finally:
        Path(tmp).unlink(missing_ok=True)
    if r.returncode != 0:
        lines = (r.stderr or r.stdout or "").strip().splitlines()
        return None, lines[-1] if lines else f"exit {r.returncode}"
    return json.loads(r.stdout), ""


def fill_prediction(head: list[str], fm: list[str], tail: list[str], models: Path) -> tuple[list[str], dict | None, str]:
    """Route the build model and predict its cost (factory-predict-cost.py), then write those
    fields into the front matter by line edits. Returns (fm, prediction or None, error)."""
    if any(re.match(r"^model_override_reason:", ln) for ln in fm):
        fm = set_field(fm, "model_override_reason", "")
    pred, err = predict_build("\n".join(head + fm + tail), models)
    if pred is None:
        return fm, None, err
    for key, val in (("model", pred["model"]), ("model_reason", yq(pred["model_reason"])),
                     ("predicted_tokens_in", str(pred["predicted_tokens_in"])),
                     ("predicted_tokens_cached", str(pred["predicted_tokens_cached"])),
                     ("predicted_tokens_out", str(pred["predicted_tokens_out"])),
                     ("predicted_cost_usd", f"{pred['predicted_cost_usd']:.4f}"),
                     ("budget_cap_usd", f"{float(pred['budget_cap_usd']):.2f}"),
                     ("price_table_version", yq(pred["price_table_version"]))):
        fm = set_field(fm, key, val)
    return fm, pred, ""


def checks(spec: str, issue: str) -> list[str]:
    """Problems that stop a draft from being posted. Empty list = all checks passed."""
    sc = load("spec_check", "factory-spec-check.py")
    errors = list(sc.validate_text(sc.strip_comment_wrapper(spec)))
    if len(spec.encode()) > MAX_SPEC_BYTES:
        errors.append(f"spec is {len(spec.encode())} bytes (limit {MAX_SPEC_BYTES})")
    if "<!--" in spec.split("\n", 1)[1]:
        errors.append("HTML comments are not allowed in a draft (remove the template's <!-- --> notes)")
    if re.search(r"(?<![\w.`/@-])@[A-Za-z][\w-]*", spec):
        errors.append("@mentions are not allowed in a draft (the bot would notify people)")
    if END in spec or DRAFT_TAG in spec or FAILED_TAG in spec:
        errors.append("the spec contains a harness marker line")
    ver = section(spec, "Verification")
    block = re.search(r"^```(bash|sh)[ \t]*\n(.*?)^```[ \t]*$", ver, re.M | re.S)
    if not block or not block.group(2).strip():
        errors.append("## Verification has no ```bash block with commands")
    if not re.search(r"expect", ver, re.I):
        errors.append("## Verification does not state the expected output")
    files = re.sub(r"\s+", "", section(spec, "Files"))
    if len(files) < 5:
        errors.append("## Files is empty")
    if not re.search(r"\S", section(spec, "Worker prompt")):
        errors.append("## Worker prompt is empty")
    return errors


def reviewer(risk: str, complexity: str) -> tuple[str, str]:
    """(review, approval) lines. Review per #78; approval per factory/specs/README.md."""
    review = "Michael (risk high), with Grok Bot's notes" if risk == "high" else f"Grok Bot (risk {risk})"
    if risk == "trivial" and complexity == "simple":
        approval = "Grok Bot may approve (simple + trivial; factory/specs/README.md)"
    else:
        approval = f"Michael (complexity {complexity}, risk {risk}; factory/specs/README.md)"
    return review, approval


def usage(path: str | None) -> tuple[str, float | None]:
    if not path or not Path(path).is_file():
        return "not captured", None
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    def m(label: str) -> str:
        r = re.search(rf"^- {re.escape(label)}: (.+)$", text, re.M)
        return r.group(1).strip() if r else "?"
    cost = re.search(r"^- OpenCode-reported cost: \$([0-9.]+)", text, re.M)
    toks = f"{m('Input tokens')} in / {m('Cache read')} cached / {m('Output tokens')} out"
    return toks, (float(cost.group(1)) if cost else None)


def extract(log_text: str) -> str | None:
    clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", log_text).replace("\r", "")
    start = clean.rfind(MARKER)
    if start == -1:
        return None
    end = clean.find(END, start)
    if end == -1:
        return None
    inner = clean[start + len(MARKER):end].strip("\n")
    return MARKER + "\n" + inner.rstrip() + "\n"


def fence(text: str, limit: int) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as f:
        f.write(text)
        tmp = f.name
    try:
        return subprocess.run(["bash", str(HERE / "opencode-text-block.sh"), "fence", tmp, str(limit), "(no output)"],
                              capture_output=True, text=True, check=True).stdout
    finally:
        Path(tmp).unlink(missing_ok=True)


def cmd_build(a: argparse.Namespace) -> int:
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    data = models_data(Path(a.models))
    run_model, rule = spec_model(data)
    _, predicted_run, cap = spec_run_prediction(data)
    toks, run_cost = usage(a.usage)
    log_text = Path(a.log).read_text(encoding="utf-8", errors="replace") if Path(a.log).is_file() else ""
    problems: list[str] = []
    spec = extract(log_text)
    if spec is None:
        problems.append("the worker's output has no spec between the factory-spec marker line and the end marker line")
    pred: dict | None = None
    if spec is not None:
        try:
            head, fm, tail = split_spec(spec)
        except ValueError as exc:
            problems.append(str(exc))
            spec = None
    if spec is not None:
        for key, val in (("issue", a.issue), ("status", "draft"), ("approved_by", "null"),
                         ("approved_at", "null"), ("drafted_by", "oc-spec-run")):
            fm = set_field(fm, key, val)
        fm, pred, err = fill_prediction(head, fm, tail, Path(a.models))
        if pred is None:
            problems.append(f"factory-predict-cost.py refused the spec: {err}")
        spec = "\n".join(head + fm + tail)
        problems += checks(spec, a.issue)
    if run_cost is not None and run_cost > cap:
        problems.append(f"this spec run cost ${run_cost:.4f}, above the ${cap:.2f} cap; not posted as a draft")
    run_line = (f"- Spec run: {run_model} ({rule}, set by the harness), tokens {toks}, cost "
                + (f"${run_cost:.4f} (OpenCode-reported)" if run_cost is not None else "not measured")
                + f"; predicted ${predicted_run:.4f}, target under ${TARGET_USD:.2f}, cap ${cap:.2f}"
                + (" (over target)" if run_cost is not None and run_cost > TARGET_USD else ""))
    run_url = f"- Run: {a.run_url}" if a.run_url else "- Run: (not given)"
    meta = {"issue": a.issue, "spec_run_cost_usd": "" if run_cost is None else f"{run_cost:.4f}"}
    if problems:
        body = [FAILED_TAG, "**`/oc spec`: no draft posted.** The worker's spec failed the harness checks:", ""]
        body += [f"- {p}" for p in problems]
        body += ["", run_line, run_url, "", "Worker output (model-written, unverified; the last 6000 bytes, defanged):", ""]
        body.append(fence(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", log_text)[-6000:], 6000).rstrip("\n"))
        meta["status"] = "failed"
    else:
        risk, cx = get_field(fm, "risk"), get_field(fm, "complexity")
        review, approval = reviewer(risk, cx)
        body = [DRAFT_TAG,
                "**DRAFT spec, not approved.** Written by the `/oc spec` worker (model-written). `/oc` ignores it: "
                "only an owner comment with `status: approved` counts.",
                "",
                f"- Review: {review}",
                f"- Approval: {approval}",
                "- To approve: the owner posts the approved copy, e.g. `python3 scripts/factory-approve-spec.py "
                f"{a.issue} <this comment's URL> --approved-by <who>` (Grok Bot runs it as the owner)",
                f"- Build run prediction (factory-predict-cost.py): {pred['model']}, ${pred['predicted_cost_usd']:.4f} "
                f"(cap ${float(pred['budget_cap_usd']):.2f})",
                "- Checks (scripts): factory-spec-check.py passed; Verification has a bash block and expected output; "
                "Files and Worker prompt filled; no HTML comments",
                run_line, run_url, "", spec.rstrip("\n")]
        meta.update(status="draft", risk=risk, complexity=cx, reviewer=review.split(" ")[0],
                    build_predicted_usd=f"{pred['predicted_cost_usd']:.4f}")
        (out / "spec-draft.md").write_text(spec.rstrip("\n") + "\n", encoding="utf-8")
    (out / "spec-comment.md").write_text("\n".join(body) + "\n", encoding="utf-8")
    (out / "spec-meta.txt").write_text("".join(f"{k}={v}\n" for k, v in meta.items()), encoding="utf-8")
    print(f"spec-draft: {meta['status']}" + (f" ({len(problems)} problem(s))" if problems else ""))
    return 0


def cmd_check_comment(a: argparse.Namespace) -> int:
    text = Path(a.file).read_text(encoding="utf-8")
    if len(text.encode()) > 60000:
        die("comment is over 60000 bytes")
    first = text.split("\n", 1)[0]
    if first == FAILED_TAG:
        if MARKER in text:
            die("a no-draft comment must not contain the spec marker")
        return 0
    if first != DRAFT_TAG or text.count(MARKER) != 1:
        die("not a draft spec comment (tag on line 1, exactly one spec marker)")
    spec = text[text.index(MARKER):]
    head, fm, _ = split_spec(spec)
    if get_field(fm, "status") != "draft" or get_field(fm, "approved_by") not in ("null", "") \
            or get_field(fm, "issue") != str(a.issue) or get_field(fm, "drafted_by") != "oc-spec-run":
        die("draft front matter must say status: draft, approved_by: null, drafted_by: oc-spec-run, this issue")
    problems = checks(spec, str(a.issue))
    if problems:
        die("draft fails the checks: " + "; ".join(problems))
    return 0


def cmd_approve(a: argparse.Namespace) -> int:
    text = Path(a.text).read_text(encoding="utf-8").replace("\r\n", "\n")
    if MARKER not in text:
        die("no spec marker in the draft")
    spec = text[text.index(MARKER):].rstrip("\n") + "\n"
    head, fm, tail = split_spec(spec)
    if a.issue and get_field(fm, "issue") != str(a.issue):
        die(f"the spec is for issue {get_field(fm, 'issue')!r}, not #{a.issue}")
    who = a.approved_by.strip()
    risk, cx = get_field(fm, "risk"), get_field(fm, "complexity")
    if who != "michael" and not (risk == "trivial" and cx == "simple" and who == "grok-bot (simple+trivial)"):
        die(f"risk {risk} / complexity {cx}: approved_by must be michael "
            "(Grok Bot may approve only simple + trivial specs, as 'grok-bot (simple+trivial)')")
    at = a.at or datetime.now().astimezone().isoformat(timespec="seconds")
    for key, val in (("status", "approved"), ("approved_by", who), ("approved_at", yq(at))):
        fm = set_field(fm, key, val)
    fm, pred, err = fill_prediction(head, fm, tail, Path(a.models))
    if pred is None:
        die(f"factory-predict-cost.py refused the spec: {err}")
    spec = "\n".join(head + fm + tail)
    problems = checks(spec, get_field(fm, "issue"))
    if problems:
        die("spec fails the checks: " + "; ".join(problems))
    sys.stdout.write(spec.rstrip("\n") + "\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--models", default=str(ROOT / ".factory" / "models.yaml"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("model")
    sub.add_parser("preflight")
    b = sub.add_parser("build")
    b.add_argument("--log", required=True)
    b.add_argument("--issue", required=True)
    b.add_argument("--out-dir", required=True)
    b.add_argument("--usage")
    b.add_argument("--run-url", default="")
    c = sub.add_parser("check-comment")
    c.add_argument("file")
    c.add_argument("--issue", required=True)
    p = sub.add_parser("approve")
    p.add_argument("text")
    p.add_argument("--approved-by", required=True)
    p.add_argument("--at")
    p.add_argument("--issue", default="")
    a = ap.parse_args()
    if getattr(a, "issue", None) not in (None, "") and not str(a.issue).isdigit():
        die("issue must be digits")
    if a.cmd == "model":
        print(spec_model(models_data(Path(a.models)))[0])
        return 0
    if a.cmd == "preflight":
        model, usd, cap = spec_run_prediction(models_data(Path(a.models)))
        print(f"model={model}\npredicted_spec_run_usd={usd:.4f}\ncap_usd={cap:.2f}")
        if usd > cap:
            die(f"predicted spec-run cost ${usd:.4f} is above the ${cap:.2f} cap; refusing to run")
        return 0
    return {"build": cmd_build, "check-comment": cmd_check_comment, "approve": cmd_approve}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
