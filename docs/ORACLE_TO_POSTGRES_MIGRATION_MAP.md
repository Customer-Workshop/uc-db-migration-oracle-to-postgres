# Oracle → PostgreSQL Migration Map

Reference for converting the `ts-plsql-oracle-forms-hrms` Oracle 19c HRMS
database to PostgreSQL 15+ (or EnterpriseDB). Pairs each Oracle construct with
its PostgreSQL equivalent and tracks which objects are converted in each phase.

## Table of Contents

- [Data types](#datatypes)
- [Functions and expressions](#functions)
- [Procedural (PL/SQL → PL/pgSQL)](#procedural)
- [Sequences and identity](#sequences)
- [Object inventory and phases](#inventory)

<a id="datatypes"></a>

## Data types

| Oracle | PostgreSQL | Notes |
|---|---|---|
| `NUMBER(10)` | `integer` / `bigint` | `bigint` if values may exceed 2^31 |
| `NUMBER(p,s)` | `numeric(p,s)` | Exact decimal preserved |
| `VARCHAR2(n)` | `varchar(n)` | Length semantics identical |
| `CHAR(1)` | `char(1)` | Y/N flag columns kept as `char(1)` |
| `DATE` | `date` or `timestamp` | Oracle `DATE` carries a time component; use `timestamp` where time matters |
| `DATE DEFAULT SYSDATE` | `timestamptz DEFAULT now()` | See [functions](#functions) |
| `CLOB` | `text` | |
| `BLOB` | `bytea` | |
| `NUMBER GENERATED ... AS (...) VIRTUAL` | `numeric GENERATED ALWAYS AS (...) STORED` | PostgreSQL has no non-stored generated column; `STORED` is the closest equivalent |

<a id="functions"></a>

## Functions and expressions

| Oracle | PostgreSQL | Notes |
|---|---|---|
| `SYSDATE` | `now()` / `current_date` | `current_date` for date-only contexts |
| `SYSTIMESTAMP` | `now()` | |
| `a \|\| b` (with NULL) | `COALESCE(a,'') \|\| COALESCE(b,'')` | Oracle treats `''` as NULL; make concatenation NULL-safe explicitly |
| `NVL(x, y)` | `COALESCE(x, y)` | |
| `NVL2(x, a, b)` | `CASE WHEN x IS NOT NULL THEN a ELSE b END` | |
| `DECODE(...)` | `CASE ...` | |
| `MONTHS_BETWEEN(a, b)` | `extract` over `age(a, b)` | No direct builtin; derive whole months |
| `TRUNC(n, d)` | `trunc(n, d)` | Numeric truncation identical |
| `TO_CHAR(d, fmt)` | `to_char(d, fmt)` | Format models mostly compatible |
| `EXTRACT(YEAR FROM SYSDATE)` | `extract(year from now())` | |
| `ROWNUM` | `row_number() OVER (...)` / `LIMIT` | |
| `DUAL` | (omit) | `SELECT 1` needs no FROM in PostgreSQL |

<a id="procedural"></a>

## Procedural (PL/SQL → PL/pgSQL)

| Oracle | PostgreSQL | Notes |
|---|---|---|
| `CREATE PACKAGE` / `PACKAGE BODY` | schema + individual `FUNCTION`/`PROCEDURE` | A package becomes a schema; each program unit becomes a routine |
| `PROCEDURE p(... OUT SYS_REFCURSOR)` | `FUNCTION ... RETURNS TABLE (...)` / `RETURNS refcursor` | Prefer `RETURNS TABLE` for set results |
| `v_row table%ROWTYPE` | `v_row table%ROWTYPE` | Supported in PL/pgSQL |
| `FOR rec IN (SELECT ...) LOOP` | `FOR rec IN SELECT ... LOOP` | Cursor-for-loop supported |
| `SQL%ROWCOUNT` | `GET DIAGNOSTICS n = ROW_COUNT` | |
| `SEQ.NEXTVAL` | `nextval('seq')` | |
| `DBMS_OUTPUT.PUT_LINE(x)` | `RAISE NOTICE '%', x` | |
| `PRAGMA AUTONOMOUS_TRANSACTION` | `dblink` / refactor to caller-managed txn | No native autonomous transactions; isolate side effects (e.g. audit writes) via `dblink` or restructure |
| `RAISE_APPLICATION_ERROR(-20001, m)` | `RAISE EXCEPTION '%', m` | |
| `CONNECT BY` / `START WITH` | `WITH RECURSIVE` CTE | See worked example in the playbook |
| `SYS_CONNECT_BY_PATH(c, sep)` | string accumulation in the recursive CTE | Concatenate along the recursion |
| `LEVEL` | depth counter in the recursive CTE | Increment per recursion |
| `SYS_CONTEXT('USERENV', 'SESSION_USER')` | `current_user` / `session_user` | |

<a id="sequences"></a>

## Sequences and identity

- Oracle `CREATE SEQUENCE HRMS.SEQ_X START WITH n INCREMENT BY 1 NOCACHE`
  becomes `CREATE SEQUENCE ns.seq_x START WITH n INCREMENT BY 1 CACHE 1`.
  PostgreSQL caches sequence values per session; `NOCACHE` has no exact
  equivalent, so `CACHE 1` is used to minimise gaps.
- Where the application does not read `SEQ.NEXTVAL` directly, prefer
  `GENERATED ALWAYS AS IDENTITY` on the primary key column.

<a id="inventory"></a>

## Object inventory and phases

**Phase 1** ships on `main`: schema DDL, sequences, and simple scalar/CRUD
routines. It establishes the reconciliation baseline (two source-side controls
pass; two controls await their Phase 2 objects).

**Phase 2** is converted live during the demo on a PR branch, gated by CI and
the reconciliation controls.

| Oracle object (source) | PostgreSQL target | Phase | File |
|---|---|---|---|
| `schema/tables/*` (core, payroll, leave) | `ns` tables | 1 | `migrations/schema/tables/01x_*.sql` |
| `schema/sequences/hrms_sequences.sql` | `ns` sequences | 1 | `migrations/schema/sequences/001_sequences.sql` |
| `PKG_EMPLOYEE` full-name helper | `fn_employee_full_name` | 1 | `migrations/functions/300_*.sql` |
| `VW_ACTIVE_EMPLOYEES` tenure calc | `fn_tenure_years` | 1 | `migrations/functions/301_*.sql` |
| `VW_EMPLOYEE_COMPENSATION` compa-ratio | `fn_compa_ratio` | 1 | `migrations/functions/302_*.sql` |
| `PKG_EMPLOYEE.get_employee` | `fn_get_employee` | 1 | `migrations/crud/400_*.sql` |
| `VW_ACTIVE_EMPLOYEES` | `vw_active_employees` (LEFT JOIN salary) | 2 | live |
| `VW_ORG_HIERARCHY` (`CONNECT BY`) | `vw_org_hierarchy` (`WITH RECURSIVE`) | 2 | live |
| `PKG_PAYROLL` run processing | payroll procedure(s) | 2 | live |
| `PKG_LEAVE` accrual | leave accrual procedure(s) | 2 | live |
| `plsql/triggers/trg_audit.sql` | audit trigger + function | 2 | live |
