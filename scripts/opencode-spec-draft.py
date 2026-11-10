#!/usr/bin/env python3
"""/oc spec helper (#78): model choice, the spec run's cost guard, draft extraction and checks.

Script only: the worker writes the spec text; every fact around it (status, model, predicted
build cost, spec-run cost, reviewer, checks) is filled here, never by the model.

  model [--context F] [--labels L] [--guidance G]
                                 print the model for spec runs: the models.yaml routing rule whose
                                 `when` is exactly {work_type: spec, risk: high} (rule 2, V4 Pro)
                                 when a structured signal says high risk (#153: the issue's
                                 `risk:high` label, or a leading / own-line `risk: high` token in
                                 the /oc spec guidance), or when there is no context to tell
                                 (fail closed); else exactly {work_type: spec} (rule 9, V4 Flash).
                                 Prose in the issue or guidance ("high-risk", "risk high") never
                                 routes. L is issue-labels.txt (default: beside F).
  preflight [--context F] [--labels L] [--guidance G]
                                 print model, predicted spec-run cost and cap; exit 1 when the
                                 prediction is above budget.issue_cap_usd (refuse to run)
  build --log L --issue N --out-dir D [--usage U] [--run-url URL]
                                 extract the worker's spec from L, normalize the harness-owned
                                 front matter fields, predict the build cost, run the checks and
                                 write D/spec-comment.md (a DRAFT comment, or a "no draft"
                                 comment listing the failures) and D/spec-meta.txt
  check-comment F --issue N      publish: re-check a comment file before posting it
  approve TEXT --approved-by WHO [--at ISO] [--over-target-ok]
                                 print TEXT (a draft spec) as the approved spec comment body;
                                 --over-target-ok (Michael only) sets over_target_approved_by:
                                 michael, which run start needs when the build prediction is over
                                 budget.issue_target_usd
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
SPEC_MODEL_RULE_HIGH = {"work_type": "spec", "risk": "high"}
# #153: high risk only from a structured signal, never from prose in the issue or comments:
#   1. the issue carries the label RISK_HIGH_LABEL (names come from the GitHub API, written by
#      opencode-build-context.py to issue-labels.txt, one per line), or
#   2. the /oc spec guidance starts with `risk: high` (or `risk:high`), as in
#      `/oc spec risk: high ...`, or has a line that is only that token.
# Fails closed: no issue context -> high (V4 Pro). A missing labels file is not a signal.
RISK_HIGH_LABEL = "risk:high"
GUIDANCE_HIGH_START_RE = re.compile(r"\Arisk:[ \t]*high(?![\w-])", re.I)
GUIDANCE_HIGH_LINE_RE = re.compile(r"risk:[ \t]*high", re.I)
# Spec-run token prior when models.yaml has no token_priors.spec (owner-only file).
DEFAULT_SPEC_PRIOR = {"tokens_in": 150000, "tokens_cached_fraction": 0.80, "tokens_out": 12000}
DEFAULT_TARGET_USD = 0.15
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


def target_usd(data: dict) -> float:
    return float((data.get("budget") or {}).get("issue_target_usd", DEFAULT_TARGET_USD))


def _norm_label(name: str) -> str:
    return re.sub(r"\s+", "", name.strip().lower())


def read_labels(path: str | None) -> list[str] | None:
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    return [line.strip() for line in p.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]


def guidance_says_high(guidance: str | None) -> bool:
    """True only for a leading `risk: high` token or a line that is only that token."""
    text = (guidance or "").strip()
    if not text:
        return False
    if GUIDANCE_HIGH_START_RE.match(text):
        return True
    return any(GUIDANCE_HIGH_LINE_RE.fullmatch(line.strip()) for line in text.splitlines())


def issue_high_risk(context: str | None, guidance: str | None, labels: list[str] | None = None) -> bool:
    """Spec-run risk class (#153): the issue's risk:high label or an explicit `risk: high`
    guidance token. No context -> high (fail closed). Prose is never read for risk."""
    if context is None or not context.strip():
        return True
    if any(_norm_label(lab) == RISK_HIGH_LABEL for lab in (labels or [])):
        return True
    return guidance_says_high(guidance)


def spec_model(data: dict, high: bool = True) -> tuple[str, str]:
    want = SPEC_MODEL_RULE_HIGH if high else SPEC_MODEL_RULE
    for rule in data.get("routing_rules") or []:
        if (rule.get("when") or {}) == want:
            return str(rule["model"]), f"models.yaml rule {rule.get('rule')}"
    die(f"models.yaml has no routing rule with when: {want}")
    raise AssertionError


def price(data: dict, model: str) -> dict:
    for row in data.get("models") or []:
        if row.get("id") == model:
            return row
    die(f"model {model} not in models.yaml")
    raise AssertionError


def spec_run_prediction(data: dict, high: bool = True) -> tuple[str, float, float]:
    model, _ = spec_model(data, high)
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


def del_field(fm: list[str], key: str) -> list[str]:
    out, skip = [], False
    for line in fm:
        if skip and (line.startswith(" ") or line.startswith("\t")):
            continue
        skip = bool(re.match(rf"^{re.escape(key)}:(\s|$)", line))
        if not skip:
            out.append(line)
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


def prose_without_code(text: str) -> str:
    """Drop fenced code blocks and inline `code` spans so literal markers may appear there (#149)."""
    # Fenced blocks first (```lang? ... ```), then single-line inline spans.
    out = re.sub(r"^```[^\n]*\n.*?^```[ \t]*$", "", text, flags=re.M | re.S)
    out = re.sub(r"`[^`\n]+`", "", out)
    return out


def checks(spec: str, issue: str) -> list[str]:
    """Problems that stop a draft from being posted. Empty list = all checks passed."""
    sc = load("spec_check", "factory-spec-check.py")
    errors = list(sc.validate_text(sc.strip_comment_wrapper(spec)))
    if len(spec.encode()) > MAX_SPEC_BYTES:
        errors.append(f"spec is {len(spec.encode())} bytes (limit {MAX_SPEC_BYTES})")
    # HTML comments are banned in prose (template notes leak otherwise). Exact marker strings may
    # sit in backtick code spans or fenced code blocks so the build can copy them (#149).
    after_first = spec.split("\n", 1)[1] if "\n" in spec else ""
    if "<!--" in prose_without_code(after_first):
        errors.append(
            "HTML comments are not allowed in a draft (remove the template's <!-- --> notes; "
            "put literal markers inside backtick code spans or a fenced code block)"
        )
    if re.search(r"(?<![\w.`/@-])@[A-Za-z][\w-]*", spec):
        errors.append("@mentions are not allowed in a draft (the bot would notify people)")
    if END in spec or DRAFT_TAG in spec or FAILED_TAG in spec:
        errors.append("the spec contains a harness marker line")
    ver = section(spec, "Verification")
    block = re.search(r"^```(bash|sh)[ \t]*\n(.*?)^```[ \t]*$", ver, re.M | re.S)
    if not block or not block.group(2).strip():
        errors.append("## Verification has no ```bash block with commands")
    else:
        cmds = block.group(2)
        # Piping into head/tail/grep -q hides a failing left-hand command unless pipefail is on (#149).
        if re.search(r"\|\s*(head|tail|grep\b[^\n]*-q)", cmds) and "pipefail" not in cmds:
            errors.append(
                "## Verification pipes into head/tail/grep -q without pipefail "
                "(those mask exit codes; use set -o pipefail or print full output)"
            )
    if not re.search(r"expect", ver, re.I):
        errors.append("## Verification does not state the expected output")
    files = re.sub(r"\s+", "", section(spec, "Files"))
    if len(files) < 5:
        errors.append("## Files is empty")
    if not re.search(r"\S", section(spec, "Worker prompt")):
        errors.append("## Worker prompt is empty")
    return errors


# Who may approve, by the spec's risk class (Michael's decision, 2026-11-02; factory/specs/README.md):
# trivial or normal -> Grok Bot reviews and may approve (approved_by: grok-bot); high -> Michael only.
GROK_APPROVES = frozenset({"trivial", "normal"})


def reviewer(risk: str, complexity: str) -> tuple[str, str]:
    """(review, approval) lines for the draft comment, from the risk class only."""
    if risk in GROK_APPROVES:
        return f"Grok Bot (risk {risk})", f"Grok Bot may approve (risk {risk}; approved_by: grok-bot)"
    return f"Michael (risk {risk}), with Grok Bot's notes", f"Michael only (risk {risk}; approved_by: michael)"


def usage(path: str | None) -> tuple[str, float | None]:
    if not path or not Path(path).is_file():
        return "not captured", None
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    def m(label: str) -> str:
        r = re.search(rf"^- {re.escape(label)}: (.+)$", text, re.M)
        return r.group(1).strip() if r else "?"
    cost = re.search(r"^- OpenCode-reported cost: \$([0-9.]+)", text, re.M)
    toks = f"{m('Input tokens')} in / {m('Cache read')} cached / {m('Output tokens')} out"
    # #88: a session that ended early can leave empty stats; that is "not measured", never $0.
    if all(m(k) in ("0", "?") for k in ("Input tokens", "Output tokens")) and (not cost or float(cost.group(1)) == 0):
        return toks + " (OpenCode stats empty)", None
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


def over_target_line(predicted: float, target: float) -> str:
    """Top-of-spec line for a build prediction over budget.issue_target_usd (empty when not over)."""
    if predicted <= target:
        return ""
    return (f"**Over ${target:.2f} target: needs Michael's approval** (predicted build ${predicted:.4f}). "
            "Run start refuses `/oc` until the approved spec has `over_target_approved_by: michael` "
            "(`approve ... --approved-by michael --over-target-ok`).")


def run_high_risk(a: argparse.Namespace) -> bool:
    path = getattr(a, "context", None)
    context = Path(path).read_text(encoding="utf-8", errors="replace") if path and Path(path).is_file() else None
    lpath = getattr(a, "labels", None)
    if not lpath and path:
        sibling = Path(path).parent / "issue-labels.txt"
        if sibling.is_file():
            lpath = str(sibling)
    return issue_high_risk(context, getattr(a, "guidance", None), read_labels(lpath))


def cmd_build(a: argparse.Namespace) -> int:
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    data = models_data(Path(a.models))
    high = run_high_risk(a)
    run_model, rule = spec_model(data, high)
    _, predicted_run, cap = spec_run_prediction(data, high)
    target = target_usd(data)
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
        fm = del_field(fm, "over_target_approved_by")  # only Michael's approval sets it
        fm, pred, err = fill_prediction(head, fm, tail, Path(a.models))
        if pred is None:
            problems.append(f"factory-predict-cost.py refused the spec: {err}")
        spec = "\n".join(head + fm + tail)
        problems += checks(spec, a.issue)
    if run_cost is not None and run_cost > cap:
        problems.append(f"this spec run cost ${run_cost:.4f}, above the ${cap:.2f} cap; not posted as a draft")
    run_line = (f"- Spec run: {run_model} ({rule}, set by the harness), tokens {toks}, cost "
                + (f"${run_cost:.4f} (OpenCode-reported)" if run_cost is not None else "not measured")
                + f"; predicted ${predicted_run:.4f}, target under ${target:.2f}, cap ${cap:.2f}"
                + (" (over target)" if run_cost is not None and run_cost > target else ""))
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
        over = over_target_line(pred["predicted_cost_usd"], target)
        body = [DRAFT_TAG] + ([over, ""] if over else []) + [
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
                "Files and Worker prompt filled; no HTML comments in prose (code spans/fences OK)",
                run_line, run_url]
        if risk == "high" and not high:
            body.append(f"- Note: the issue has no risk:high label, so this spec run used {run_model} ({rule}); "
                        "the spec says risk high. For a V4 Pro draft, add the risk:high label or re-run `/oc spec risk: high`.")
        body += ["", spec.rstrip("\n")]
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
    if who == "grok-bot":
        if risk not in GROK_APPROVES:
            die(f"risk {risk}: only Michael approves high-risk specs (approved_by: michael)")
    elif who != "michael":
        die("approved_by must be grok-bot (trivial or normal risk) or michael")
    at = a.at or datetime.now().astimezone().isoformat(timespec="seconds")
    for key, val in (("status", "approved"), ("approved_by", who), ("approved_at", yq(at))):
        fm = set_field(fm, key, val)
    fm, pred, err = fill_prediction(head, fm, tail, Path(a.models))
    if pred is None:
        die(f"factory-predict-cost.py refused the spec: {err}")
    target = target_usd(models_data(Path(a.models)))
    fm = del_field(fm, "over_target_approved_by")
    if a.over_target_ok:
        if who != "michael":
            die("--over-target-ok is Michael's approval only (approved_by: michael)")
        if pred["predicted_cost_usd"] > target:
            fm = set_field(fm, "over_target_approved_by", "michael")
    elif pred["predicted_cost_usd"] > target:
        print(f"spec-draft: {over_target_line(pred['predicted_cost_usd'], target)}", file=sys.stderr)
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
    for name in ("model", "preflight"):
        sp = sub.add_parser(name)
        sp.add_argument("--context", help="issue-context.md (no context -> high risk, fail closed)")
        sp.add_argument("--labels", help="issue-labels.txt, one label per line (default: beside --context); "
                                         "label risk:high -> high risk")
        sp.add_argument("--guidance", default="", help="the /oc spec guidance text")
    b = sub.add_parser("build")
    b.add_argument("--context")
    b.add_argument("--labels")
    b.add_argument("--guidance", default="")
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
    p.add_argument("--over-target-ok", action="store_true")
    a = ap.parse_args()
    if getattr(a, "issue", None) not in (None, "") and not str(a.issue).isdigit():
        die("issue must be digits")
    if a.cmd == "model":
        print(spec_model(models_data(Path(a.models)), run_high_risk(a))[0])
        return 0
    if a.cmd == "preflight":
        high = run_high_risk(a)
        model, usd, cap = spec_run_prediction(models_data(Path(a.models)), high)
        print(f"model={model}\nrisk_class={'high' if high else 'not_high'}\n"
              f"predicted_spec_run_usd={usd:.4f}\ncap_usd={cap:.2f}")
        if usd > cap:
            die(f"predicted spec-run cost ${usd:.4f} is above the ${cap:.2f} cap; refusing to run")
        return 0
    return {"build": cmd_build, "check-comment": cmd_check_comment, "approve": cmd_approve}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
