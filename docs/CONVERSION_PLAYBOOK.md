# Conversion Playbook — Oracle → PostgreSQL

A reusable 7-step procedure for converting any Oracle PL/SQL package, view,
trigger, or function to PostgreSQL (PL/pgSQL) with verified reconciliation.

This playbook is the procedure Devin follows during live conversions. Each step
is atomic and produces a verifiable artifact.

---

## Step 1 — Read the Source

Read the Oracle source file in `ts-plsql-oracle-forms-hrms/`. Identify:

- **Object type**: package (spec `.pks` + body `.pkb`), view, trigger, function
- **Dependencies**: tables, views, functions, sequences referenced
- **Oracle-specific constructs**: compare against
  [`ORACLE_TO_POSTGRES_MIGRATION_MAP.md`](ORACLE_TO_POSTGRES_MIGRATION_MAP.md)
- **Business rules**: comments, implicit invariants, regulatory requirements

Produce a bullet list of every construct that requires conversion.

---

## Step 2 — Map Constructs

For each identified construct, write the PostgreSQL equivalent. Reference the
migration map for standard patterns. Flag any construct that requires a design
decision (e.g. `PRAGMA AUTONOMOUS_TRANSACTION` → `dblink` vs. refactor;
`CONNECT BY` → `WITH RECURSIVE`).

Example mapping for `VW_ACTIVE_EMPLOYEES`:

| Line(s) | Oracle Construct | PostgreSQL Equivalent |
|---|---|---|
| `LEFT JOIN SALARY_RECORDS sr ...` | outer join to current salary | `LEFT JOIN ns.salary_records sr ... AND sr.active_flag = 'Y'` |
| `FIRST_NAME \|\| ' ' \|\| LAST_NAME` | Oracle concat (NULL-collapsing) | `fn_employee_full_name(first_name, last_name)` (NULL-safe) |
| `TRUNC(MONTHS_BETWEEN(SYSDATE, HIRE_DATE)/12, 1)` | tenure years | `fn_tenure_years(hire_date)` |
| `SYSDATE` | current timestamp | `now()` / `current_date` |

---

## Step 3 — Write the Converted Object

Create the new file in the appropriate `migrations/` subdirectory:

- Tables: `migrations/schema/tables/NNN_tablename.sql`
- Sequences: `migrations/schema/sequences/NNN_*.sql`
- Views: `migrations/schema/views/NNN_viewname.sql`
- Functions: `migrations/functions/NNN_fn_name.sql`
- Procedures / CRUD: `migrations/crud/NNN_name.sql`
- Triggers: `migrations/triggers/NNN_trg_name.sql`

Apply all construct mappings from Step 2. Ensure:

- **Namespace isolation**: all object references use the `"$(NS)"` schema prefix
- Package program units become individual schema-scoped functions/procedures
- `RAISE NOTICE` replaces `DBMS_OUTPUT.PUT_LINE`
- `GET DIAGNOSTICS ... = ROW_COUNT` replaces `SQL%ROWCOUNT`
- NULL-safe concatenation (`COALESCE`) replaces Oracle `||` where a component
  may be NULL
- `WITH RECURSIVE` replaces `CONNECT BY` / `START WITH`
- Deploy files are ordered by filename so dependencies resolve

---

## Step 4 — Add Reconciliation Controls

For each converted object, add or update controls in `verify/reconcile.py`:

- **Completeness**: row/record count matches source
- **Control totals**: `SUM`/`COUNT` aggregates match
- **Business-rule parity**: invariants hold (e.g. available leave ≥ 0)
- **Referential integrity**: FK relationships preserved

Controls query both `raw` (source-of-truth seeded data) and `"$(NS)"`
(converted target) and compare results.

---

## Step 5 — Deploy and Seed

```bash
make seed                 # load synthetic data into raw (idempotent)
make build NS=dev         # deploy all converted objects into dev
```

Verify no deployment errors. If errors occur, fix the conversion and redeploy.

---

## Step 6 — Verify

```bash
make reconcile NS=dev     # render the reconciliation report
make test NS=dev          # gate: exits non-zero on any FAIL
```

Expected output once the target object is converted correctly:

```
[PASS] active_employee_completeness: expected=277, actual=277
[PASS] org_hierarchy_reachability: expected=277, actual=277
[PASS] payroll_control_totals: expected=..., actual=...
[PASS] leave_balance_nonnegative: expected=0, actual=0
```

If any control FAILs:

1. Read the failure detail to identify the root cause
2. Fix the conversion in the migration file
3. Redeploy: `make demo-down NS=dev && make demo-up NS=dev`
4. Re-verify: `make test NS=dev`

---

## Step 7 — Open Verified PR

Once all controls PASS:

1. Create a feature branch: `devin/<timestamp>-convert-<object-name>`
2. Commit the new/modified migration file(s)
3. Push and open a PR
4. CI runs: lint → deploy → reconcile
5. PR description includes the source file reference, the constructs converted,
   and the reconciliation report (all PASS)

---

## Worked Example: `VW_ACTIVE_EMPLOYEES`

### Oracle Source (annotated)

```sql
FROM EMPLOYEES e
JOIN DEPARTMENTS d ON e.DEPT_ID = d.DEPT_ID
...
LEFT JOIN SALARY_RECORDS sr ON e.EMP_ID = sr.EMP_ID   -- ← outer join
    AND sr.ACTIVE_FLAG = 'Y'
WHERE e.EMPLOYMENT_STATUS = 'ACTIVE';
```

Not every active employee has a *current* salary row. The `LEFT JOIN` keeps
those employees (with `current_salary` NULL).

### Naive (Wrong) Conversion

```sql
FROM "$(NS)".employees e
JOIN "$(NS)".departments d ON e.dept_id = d.dept_id
...
JOIN "$(NS)".salary_records sr ON e.emp_id = sr.emp_id   -- ← INNER JOIN drops them!
    AND sr.active_flag = 'Y'
WHERE e.employment_status = 'ACTIVE';
```

**Result**: `active_employee_completeness` FAILs — active employees with no
current salary record silently disappear from the view.

### Correct Conversion

```sql
FROM "$(NS)".employees e
JOIN "$(NS)".departments d ON e.dept_id = d.dept_id
...
LEFT JOIN "$(NS)".salary_records sr ON e.emp_id = sr.emp_id
    AND sr.active_flag = 'Y'
WHERE e.employment_status = 'ACTIVE' AND e.active_flag = 'Y';
```

**Result**: `active_employee_completeness` PASSES — all active employees
preserved.

---

## Worked Example: `VW_ORG_HIERARCHY` (`CONNECT BY` → `WITH RECURSIVE`)

### Oracle Source

```sql
SELECT EMP_ID, LEVEL AS ORG_LEVEL,
       SYS_CONNECT_BY_PATH(FIRST_NAME || ' ' || LAST_NAME, ' > ') AS ORG_PATH
FROM EMPLOYEES
START WITH MANAGER_EMP_ID IS NULL
CONNECT BY PRIOR EMP_ID = MANAGER_EMP_ID;
```

### Correct Conversion

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, manager_emp_id, 1 AS org_level,
           "$(NS)".fn_employee_full_name(first_name, last_name) AS org_path
    FROM "$(NS)".employees
    WHERE manager_emp_id IS NULL AND employment_status = 'ACTIVE'
    UNION ALL
    SELECT e.emp_id, e.manager_emp_id, o.org_level + 1,
           o.org_path || ' > ' ||
               "$(NS)".fn_employee_full_name(e.first_name, e.last_name)
    FROM "$(NS)".employees e
    JOIN org o ON e.manager_emp_id = o.emp_id
    WHERE e.employment_status = 'ACTIVE'
)
SELECT * FROM org;
```

**Result**: `org_hierarchy_reachability` PASSES — the anchor (`START WITH`)
becomes the base term, `CONNECT BY PRIOR` becomes the recursive join, `LEVEL`
becomes a depth counter, and `SYS_CONNECT_BY_PATH` becomes string accumulation.
