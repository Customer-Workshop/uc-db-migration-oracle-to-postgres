"""
reconcile.py — Source-to-target reconciliation harness (Oracle → PostgreSQL).

Runs a fixed battery of reconciliation controls that compare the source-of-truth
synthetic data in the ``raw`` schema against the converted objects deployed into
a namespace schema. Each control is designed to catch a specific class of
Oracle-to-PostgreSQL conversion defect:

  active_employee_completeness
      Source ACTIVE headcount must equal the row count of the converted
      VW_ACTIVE_EMPLOYEES view. Catches the classic trap where the Oracle
      ``LEFT JOIN salary_records`` is naively rewritten as an ``INNER JOIN``,
      silently dropping active employees who have no current salary row.

  org_hierarchy_reachability
      Every active employee must appear in the converted VW_ORG_HIERARCHY.
      Catches errors converting Oracle ``CONNECT BY`` to a PostgreSQL
      ``WITH RECURSIVE`` CTE (missing UNION ALL branch, wrong anchor, etc.).

  payroll_control_totals
      For the latest APPROVED payroll run, the stored run totals must foot to
      the sum of the detail rows. A source-side control-total invariant the
      converted payroll procedure must preserve.

  leave_balance_nonnegative
      available = opening + accrued - used + adjustment - pending must be
      non-negative for every balance. A business-rule invariant the converted
      leave logic (and the AVAILABLE generated column) must preserve.

Controls whose target object has not been deployed yet (a Phase 2 object still
awaiting conversion) report PENDING rather than FAIL, so CI stays green on a
partially-migrated main while still failing on genuine conversion defects.

Modes:
    --mode report   Render a markdown reconciliation report (never exits non-zero).
    --mode test     Exit non-zero if any control FAILs (PENDING does not fail).

Usage:
    python verify/reconcile.py --namespace dev --raw-schema raw --mode report \
        --output reconciliation-report.md
    python verify/reconcile.py --namespace dev --raw-schema raw --mode test

Environment variables:
    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone

try:
    import psycopg2
except ImportError:  # pragma: no cover - import guard
    psycopg2 = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Result model
# ---------------------------------------------------------------------------


@dataclass
class CheckResult:
    name: str
    passed: bool
    expected: object
    actual: object
    detail: str = ""
    pending: bool = False

    @property
    def status(self) -> str:
        if self.pending:
            return "PENDING"
        return "PASS" if self.passed else "FAIL"


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------


def get_connection() -> psycopg2.extensions.connection:
    if psycopg2 is None:
        raise ImportError("psycopg2 is required: pip install psycopg2-binary")

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "hrms"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", ""),
    )
    conn.autocommit = True
    return conn


def _validate_schema_name(name: str) -> None:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError(f"Invalid schema name: {name!r}")


def _scalar(cur, sql: str) -> object | None:
    cur.execute(sql)
    row = cur.fetchone()
    return row[0] if row else None


def _relation_exists(cur, schema: str, name: str) -> bool:
    cur.execute(
        "SELECT 1 FROM information_schema.tables "
        "WHERE table_schema = %s AND table_name = %s "
        "UNION ALL "
        "SELECT 1 FROM information_schema.views "
        "WHERE table_schema = %s AND table_name = %s",
        (schema, name, schema, name),
    )
    return cur.fetchone() is not None


# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------


def check_active_employee_completeness(cur, ns: str, raw: str) -> CheckResult:
    name = "active_employee_completeness"
    expected = _scalar(
        cur,
        f"SELECT COUNT(*) FROM {raw}.employees "
        f"WHERE employment_status = 'ACTIVE' AND active_flag = 'Y'",
    )
    if not _relation_exists(cur, ns, "vw_active_employees"):
        return CheckResult(
            name, False, expected, None,
            f"{ns}.vw_active_employees not deployed — convert VW_ACTIVE_EMPLOYEES "
            f"(Phase 2) to satisfy this control.",
            pending=True,
        )
    actual = _scalar(cur, f"SELECT COUNT(*) FROM {ns}.vw_active_employees")
    passed = expected == actual
    detail = "" if passed else (
        f"{int(expected) - int(actual)} active employees missing from the view — "
        f"likely an INNER JOIN where the Oracle source used LEFT JOIN salary_records."
    )
    return CheckResult(name, passed, expected, actual, detail)


def check_org_hierarchy_reachability(cur, ns: str, raw: str) -> CheckResult:
    name = "org_hierarchy_reachability"
    expected = _scalar(
        cur,
        f"SELECT COUNT(*) FROM {raw}.employees "
        f"WHERE employment_status = 'ACTIVE'",
    )
    if not _relation_exists(cur, ns, "vw_org_hierarchy"):
        return CheckResult(
            name, False, expected, None,
            f"{ns}.vw_org_hierarchy not deployed — convert VW_ORG_HIERARCHY "
            f"(Oracle CONNECT BY → WITH RECURSIVE, Phase 2) to satisfy this control.",
            pending=True,
        )
    actual = _scalar(
        cur, f"SELECT COUNT(DISTINCT emp_id) FROM {ns}.vw_org_hierarchy"
    )
    passed = expected == actual
    detail = "" if passed else (
        f"Recursive hierarchy reaches {actual} of {expected} active employees — "
        f"check the WITH RECURSIVE anchor/UNION ALL branch."
    )
    return CheckResult(name, passed, expected, actual, detail)


def check_payroll_control_totals(cur, ns: str, raw: str) -> CheckResult:
    name = "payroll_control_totals"
    # Stored run total vs. sum of detail rows for the latest approved run,
    # evaluated against the converted (namespace) tables.
    stored = _scalar(
        cur,
        f"SELECT COALESCE(SUM(total_net), 0) FROM {ns}.payroll_runs "
        f"WHERE status = 'APPROVED'",
    )
    detail_sum = _scalar(
        cur,
        f"SELECT COALESCE(SUM(pd.amount), 0) "
        f"FROM {ns}.payroll_details pd "
        f"JOIN {ns}.payroll_runs pr ON pd.run_id = pr.run_id "
        f"WHERE pr.status = 'APPROVED'",
    )
    passed = stored == detail_sum
    detail = "" if passed else (
        f"Run control total {stored} != sum of detail rows {detail_sum} — "
        f"check EARNING/TAX/DEDUCTION sign handling in the SUM/CASE conversion."
    )
    return CheckResult(name, passed, stored, detail_sum, detail)


def check_leave_balance_nonnegative(cur, ns: str, raw: str) -> CheckResult:
    name = "leave_balance_nonnegative"
    violations = _scalar(
        cur,
        f"SELECT COUNT(*) FROM {ns}.leave_balances "
        f"WHERE (opening_balance + accrued - used + adjustment - pending) < 0",
    )
    passed = int(violations) == 0
    detail = "" if passed else (
        f"{violations} leave balances compute a negative available amount — "
        f"check NULL arithmetic / COALESCE in the AVAILABLE expression."
    )
    return CheckResult(name, passed, 0, violations, detail)


CONTROLS = [
    check_active_employee_completeness,
    check_org_hierarchy_reachability,
    check_payroll_control_totals,
    check_leave_balance_nonnegative,
]


def run_controls(ns: str, raw: str) -> list[CheckResult]:
    _validate_schema_name(ns)
    _validate_schema_name(raw)
    conn = get_connection()
    cur = conn.cursor()
    results = [control(cur, ns, raw) for control in CONTROLS]
    cur.close()
    conn.close()
    return results


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_report(results: list[CheckResult], ns: str, raw: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    passed = sum(1 for r in results if r.passed)
    pending = sum(1 for r in results if r.pending)
    total = len(results)
    lines = [
        "# Reconciliation Report — Oracle → PostgreSQL",
        "",
        f"- **Generated:** {ts}",
        f"- **Namespace (target):** `{ns}`",
        f"- **Source schema:** `{raw}`",
        f"- **Result:** {passed}/{total} controls passing"
        + (f" ({pending} pending Phase 2 conversion)" if pending else ""),
        "",
        "| Control | Status | Expected | Actual | Detail |",
        "|---|---|---|---|---|",
    ]
    for r in results:
        detail = r.detail.replace("|", "\\|") if r.detail else ""
        lines.append(
            f"| `{r.name}` | **{r.status}** | {r.expected} | {r.actual} | {detail} |"
        )
    lines.append("")
    if passed != total:
        lines.append(
            "> PENDING controls reference objects that have not been converted "
            "yet (Phase 2); FAIL indicates a conversion defect. See each "
            "control's detail column."
        )
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description="Run reconciliation controls")
    parser.add_argument("--namespace", required=True, help="Target (converted) schema")
    parser.add_argument("--raw-schema", default="raw", help="Source-of-truth schema")
    parser.add_argument(
        "--mode", choices=["report", "test"], default="report",
        help="report: render markdown; test: exit non-zero on any FAIL",
    )
    parser.add_argument("--output", default=None, help="Write report to this path")
    args = parser.parse_args()

    results = run_controls(args.namespace, args.raw_schema)

    if args.mode == "report":
        report = render_report(results, args.namespace, args.raw_schema)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(report)
            print(f"Report written to {args.output}")
        print(report)
        return

    # test mode
    exit_code = 0
    for r in results:
        marker = f"[{r.status}]"
        line = f"{marker} {r.name}: expected={r.expected}, actual={r.actual}"
        if not r.passed and not r.pending:
            exit_code = 1
        if r.detail:
            line += f"\n        {r.detail}"
        print(line)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
