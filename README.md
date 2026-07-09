# uc-db-migration-oracle-to-postgres

A turnkey **Oracle → PostgreSQL / EnterpriseDB** database-migration target repo
with a verified reconciliation harness. It pairs with the Oracle source repo
[`ts-plsql-oracle-forms-hrms`](https://github.com/Cognition-Partner-Workshops/ts-plsql-oracle-forms-hrms)
(an Oracle 19c Forms-era HRMS: packages, DDL, sequences, views, triggers) and
demonstrates converting Oracle schema and PL/SQL to PostgreSQL PL/pgSQL where a
"reasonable-looking" conversion silently drops rows — and gets caught.

The methodology mirrors the sibling repo
[`uc-db-migration-sybase-to-sqlserver`](https://github.com/Cognition-Partner-Workshops/uc-db-migration-sybase-to-sqlserver):
deterministic synthetic data, namespaced deploys, a Python reconciliation
harness, and CI gating.

## Table of Contents

- [Quick Start](#quick-start)
- [How it works](#how-it-works)
- [Before / After](#before-after)
- [Reconciliation controls](#controls)
- [Migration map](#map)
- [Concurrent runs](#concurrent)
- [Related repositories](#related)

<a id="quick-start"></a>

## Quick Start

Requires Docker (or a reachable PostgreSQL 15+/EDB instance) and Python 3.10+.

```bash
# 1. Connection settings (standard libpq env vars)
export PGHOST=localhost PGPORT=5432 PGDATABASE=hrms \
       PGUSER=postgres PGPASSWORD=postgres

# 2. Start PostgreSQL locally (optional if you already have one)
make docker-up

# 3. Install Python deps + pre-commit hooks
make install

# 4. Full lifecycle: seed source data → deploy converted objects → reconcile
make demo-up NS=dev

# 5. Tear down the namespace (raw source data untouched)
make demo-down NS=dev
```

`make demo-up` prints a reconciliation report showing which controls pass. On a
fresh clone (Phase 1 only), two controls pass and two report FAIL because the
objects they validate (`vw_active_employees`, `vw_org_hierarchy`) are converted
live during the demo.

<a id="how-it-works"></a>

## How it works

- **`raw` schema** — the source-of-truth synthetic HRMS data, generated
  deterministically (fixed RNG seed) by `seed/generate_and_load.py`.
- **`$(NS)` namespace schema** — the converted PostgreSQL objects. Every run
  targets its own schema (`NS=dev`, `NS=qa`, `NS=alice`, …) so parallel runs
  never collide.
- **`migrations/`** — the converted DDL and PL/pgSQL, deployed in filename order
  by `seed/deploy.py`. The `$(NS)` token is substituted with the target schema.
- **`verify/reconcile.py`** — the reconciliation controls comparing `raw`
  (source) against `$(NS)` (target).

<a id="before-after"></a>

## Before / After

| | `main` (Phase 1) | PR branches (Phase 2, converted live) |
|---|---|---|
| Schema DDL, sequences | ✅ converted | — |
| Simple scalar / CRUD functions | ✅ converted | — |
| `VW_ACTIVE_EMPLOYEES` (outer join) | ❌ not yet | ✅ `LEFT JOIN` preserved |
| `VW_ORG_HIERARCHY` (`CONNECT BY`) | ❌ not yet | ✅ `WITH RECURSIVE` |
| Payroll / leave procedures, audit trigger | ❌ not yet | ✅ |
| Reconciliation controls passing | 2 / 4 | 4 / 4 |

<a id="controls"></a>

## Reconciliation controls

| Control | Catches |
|---|---|
| `active_employee_completeness` | Oracle `LEFT JOIN salary_records` naively rewritten as `INNER JOIN` — active employees with no current salary row silently dropped |
| `org_hierarchy_reachability` | Errors converting `CONNECT BY` to `WITH RECURSIVE` (bad anchor / missing `UNION ALL`) |
| `payroll_control_totals` | `EARNING`/`TAX`/`DEDUCTION` sign errors in `SUM`/`CASE` conversion |
| `leave_balance_nonnegative` | NULL-arithmetic / `COALESCE` errors in the available-balance calculation |

Run `make reconcile NS=dev` for the markdown report, or `make test NS=dev` to
gate (non-zero exit on any FAIL).

<a id="map"></a>

## Migration map

See [`docs/ORACLE_TO_POSTGRES_MIGRATION_MAP.md`](docs/ORACLE_TO_POSTGRES_MIGRATION_MAP.md)
for the full Oracle→PostgreSQL construct mapping and object inventory, and
[`docs/CONVERSION_PLAYBOOK.md`](docs/CONVERSION_PLAYBOOK.md) for the 7-step
conversion procedure with worked examples.

<a id="concurrent"></a>

## Concurrent runs

Every command takes an `NS` parameter. Independent runs use independent schemas
and never interfere:

```bash
make demo-up NS=alice
make demo-up NS=bob
make demo-up NS=state_ca
```

`make seed` loads the shared `raw` source data once; each `NS` gets its own
converted copy.

<a id="related"></a>

## Related repositories

- [`ts-plsql-oracle-forms-hrms`](https://github.com/Cognition-Partner-Workshops/ts-plsql-oracle-forms-hrms)
  — the Oracle 19c source system.
- [`uc-db-migration-sybase-to-sqlserver`](https://github.com/Cognition-Partner-Workshops/uc-db-migration-sybase-to-sqlserver)
  — the sibling DB-migration target repo this one mirrors.
