"""Specification tests for .factory/models.yaml selection + checks split (issue #26)."""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODELS = ROOT / ".factory" / "models.yaml"


def _match_when(when: dict, ctx: dict) -> bool:
    if not when:
        return True
    if "any" in when:
        return any(_match_when(branch, ctx) for branch in when["any"])
    for key, expected in when.items():
        if key == "predicted_cost_usd_gt":
            if ctx.get("predicted_cost_usd") is None:
                return False
            if not (ctx["predicted_cost_usd"] > expected):
                return False
        elif ctx.get(key) != expected:
            return False
    return True


def select_model(routing_rules: list, ctx: dict) -> tuple[str | None, int | None]:
    for rule in routing_rules:
        if _match_when(rule.get("when") or {}, ctx):
            return rule.get("model"), rule.get("rule")
    return None, None


def run_checks(checks: list, ctx: dict) -> list[str]:
    actions: list[str] = []
    for check in checks:
        if _match_when(check.get("when") or {}, ctx):
            action = check.get("action")
            if action:
                actions.append(action)
    return actions


class RoutingWorkedExamplesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        data = yaml.safe_load(MODELS.read_text())
        cls.routing_rules = data["routing_rules"]
        cls.checks = data["checks"]
        cls.examples = data["routing_worked_examples"]

    def test_yaml_parses_and_has_checks_block(self) -> None:
        self.assertIn("checks", yaml.safe_load(MODELS.read_text()))
        rule_nums = [r["rule"] for r in self.routing_rules]
        self.assertEqual(rule_nums, [5, 4, 7, 1, 2, 3])

    def test_worked_examples(self) -> None:
        for ex in self.examples:
            ctx = dict(ex["context"])
            model, via = select_model(self.routing_rules, ctx)
            self.assertEqual(model, ex["expect"]["selected_model"], ex["name"])
            self.assertEqual(via, ex["expect"]["selected_via_rule"], ex["name"])
            actions = run_checks(self.checks, ctx)
            self.assertEqual(actions, ex["expect"]["check_actions"], ex["name"])


if __name__ == "__main__":
    unittest.main()
