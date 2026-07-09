# ora2pg / EDB Migration Toolkit vs. This Approach

Automated schema-conversion tools (ora2pg, the EDB Migration Toolkit / Migration
Portal) are excellent at the mechanical 80%: data-type mapping, DDL translation,
sequence and default rewrites, and bulk data copy. This project is not a
replacement for them — it is what covers the remaining 20% that those tools flag
as "manual review required" and that silently changes behaviour if converted
naively.

## Where the tools do well

- Data-type mapping (`NUMBER` → `numeric`, `VARCHAR2` → `varchar`, `CLOB` → `text`)
- DDL generation for tables, constraints, indexes, sequences
- Bulk data unload/load
- Mechanical PL/SQL → PL/pgSQL syntax translation for straightforward routines

## Where they fall short (and this harness earns its keep)

| Concern | Tool behaviour | What this project adds |
|---|---|---|
| Outer-join semantics | Translates syntax, but a hand-fixed join can flip `LEFT`→`INNER` during cleanup | `active_employee_completeness` proves no rows were dropped |
| `CONNECT BY` hierarchies | Often emitted as a TODO or an approximate recursive CTE | `org_hierarchy_reachability` proves every active employee is still reachable |
| `PRAGMA AUTONOMOUS_TRANSACTION` | No PostgreSQL equivalent — flagged for manual rework | Playbook prescribes `dblink`/refactor; controls verify side effects |
| NULL / empty-string semantics | Oracle `''` = NULL; concatenation and predicates change meaning | NULL-safe `COALESCE` conversion plus business-rule controls |
| Business invariants | Not the tool's concern | Control totals + parity checks encode the rules the data must satisfy |
| Regression safety | One-time conversion, no ongoing gate | Deterministic seed + CI reconciliation gate on every PR |

## The point

A converted schema that compiles and loads is not the same as a converted
schema that is **correct**. The reconciliation harness turns "it looks right"
into a pass/fail control, and CI keeps it that way as objects are converted
incrementally. Use ora2pg / EDB tooling for the bulk lift; use this harness to
prove the result preserves row counts, control totals, and business rules.
