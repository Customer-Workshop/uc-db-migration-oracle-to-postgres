/*=====================================================================
  700_trg_audit.sql — PostgreSQL (PL/pgSQL) conversion of the HRMS audit triggers
  Source: ts-plsql-oracle-forms-hrms/plsql/triggers/trg_audit.sql
          (audit sink: ts-plsql-oracle-forms-hrms/plsql/packages/PKG_AUDIT.pkb
           PKG_AUDIT.log_action)

  Converts the three generic audit triggers and their shared logging routine:
    - TRG_SALARY_AUDIT           AFTER INSERT/UPDATE/DELETE ON salary_records
    - TRG_LEAVE_REQUEST_AUDIT    AFTER UPDATE OF status    ON leave_requests
    - TRG_DEPARTMENT_AUDIT       AFTER INSERT/UPDATE/DELETE ON departments

  ---------------------------------------------------------------------
  Construct mapping (see docs/ORACLE_TO_POSTGRES_MIGRATION_MAP.md)
  ---------------------------------------------------------------------
  | Oracle                                   | PostgreSQL                       |
  |------------------------------------------|----------------------------------|
  | CREATE TRIGGER ... FOR EACH ROW + body   | trigger FUNCTION + CREATE TRIGGER |
  | :NEW / :OLD                              | new / old                         |
  | INSERTING / UPDATING / DELETING          | TG_OP = 'INSERT'/'UPDATE'/'DELETE' |
  | AFTER UPDATE OF STATUS                    | AFTER UPDATE OF status            |
  | NVL(x, y)                                | COALESCE(x, y)                    |
  | USER                                     | current_user                      |
  | SEQ_AUDIT.NEXTVAL                        | nextval('$(NS).seq_audit')        |
  | SYS_CONTEXT('USERENV','IP_ADDRESS')      | host(inet_client_addr())          |
  | SYS_CONTEXT('USERENV','SESSIONID')       | pg_backend_pid()::text (stable/session) |
  | manual '||' JSON string building          | jsonb_build_object(...)::text (NULL-safe) |
  | PKG_AUDIT.log_action(...)                | $(NS).fn_audit_log_action(...)    |
  | PRAGMA AUTONOMOUS_TRANSACTION + COMMIT    | see note below                    |

  ---------------------------------------------------------------------
  PRAGMA AUTONOMOUS_TRANSACTION handling
  ---------------------------------------------------------------------
  PKG_AUDIT.log_action ran as an Oracle autonomous transaction: it COMMITted the
  audit row independently of the caller and, on any error, ROLLBACKed only its
  own work (`EXCEPTION WHEN OTHERS THEN ROLLBACK`) so auditing could never fail
  the business transaction.

  PostgreSQL has no native autonomous transactions. Two options exist
  (migration map): (a) a dblink loopback connection that commits the audit row
  out-of-band, or (b) caller-managed / same-transaction restructuring.

  This conversion implements (b), the viable dependency-free local-demo
  approach: the audit INSERT participates in the caller's transaction, and the
  fatal-side-effect isolation is provided by a PL/pgSQL `BEGIN ... EXCEPTION
  WHEN OTHERS` block. That block is an implicit subtransaction (savepoint): if
  the audit write fails, it rolls back to the savepoint and the caller's
  statement proceeds — reproducing "auditing never breaks the caller" without a
  second connection. The trade-off vs. Oracle: if the *caller* rolls back, the
  audit row rolls back too (it is not independently committed).

  For true autonomous semantics on PostgreSQL, swap the INSERT in
  fn_audit_log_action for a dblink call, e.g.:
      PERFORM dblink('dbname=' || current_database(),
                     format('INSERT INTO %I.audit_log (...) VALUES (...)', tgt));
  which requires `CREATE EXTENSION dblink` and a loopback connection. It is
  intentionally omitted here to keep the demo free of external dependencies.

  ---------------------------------------------------------------------
  Column verification against the target DDL
  ---------------------------------------------------------------------
  - $(NS).salary_records has no modified_by column (verified: 014_salary_records.sql),
    so the Oracle NVL(:NEW.MODIFIED_BY, USER) collapses to current_user.
  - $(NS).departments also has no modified_by; the Oracle trigger used USER ->
    current_user regardless.
  - $(NS).leave_requests (017_leave_requests.sql) retains modified_by, so its
    changed_by faithfully maps NVL(:NEW.MODIFIED_BY, USER) ->
    COALESCE(new.modified_by, current_user).
=====================================================================*/

-- ---------------------------------------------------------------------
-- Shared audit sink — PKG_AUDIT.log_action equivalent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "$(NS)".fn_audit_log_action(
    p_table_name text,
    p_record_id bigint,
    p_action text,
    p_user text DEFAULT NULL,
    p_old_values text DEFAULT NULL,
    p_new_values text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO "$(NS)".audit_log (
        audit_id, table_name, record_id, action_type,
        old_values, new_values, changed_by, changed_date,
        ip_address, session_id
    ) VALUES (
        nextval('$(NS).seq_audit'), p_table_name, p_record_id, p_action,
        p_old_values, p_new_values, COALESCE(p_user, current_user), now(),
        host(inet_client_addr()), pg_backend_pid()::text
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Audit logging must never fail the calling transaction (mirrors the
        -- Oracle autonomous-transaction ROLLBACK). The subtransaction created
        -- by this block rolls back only the failed audit INSERT.
        NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- TRG_SALARY_AUDIT — tracks all salary record changes for compliance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "$(NS)".fn_trg_salary_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_action text;
    v_record_id bigint;
    v_old_json text;
    v_new_json text;
BEGIN
    IF tg_op = 'INSERT' THEN
        v_action := 'INSERT';
        v_record_id := new.salary_id;
        v_new_json := jsonb_build_object(
            'emp_id', new.emp_id,
            'salary', new.base_salary,
            'effective', to_char(new.effective_date, 'YYYY-MM-DD')
        )::text;
    ELSIF tg_op = 'UPDATE' THEN
        v_action := 'UPDATE';
        v_record_id := new.salary_id;
        v_old_json := jsonb_build_object(
            'salary', old.base_salary, 'active', old.active_flag
        )::text;
        v_new_json := jsonb_build_object(
            'salary', new.base_salary, 'active', new.active_flag
        )::text;
    ELSIF tg_op = 'DELETE' THEN
        v_action := 'DELETE';
        v_record_id := old.salary_id;
        v_old_json := jsonb_build_object(
            'emp_id', old.emp_id, 'salary', old.base_salary
        )::text;
    END IF;

    -- salary_records has no modified_by column: NVL(:NEW.MODIFIED_BY, USER)
    -- reduces to current_user.
    PERFORM "$(NS)".fn_audit_log_action(
        'SALARY_RECORDS', v_record_id, v_action,
        current_user, v_old_json, v_new_json
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_salary_audit ON "$(NS)".salary_records;
CREATE TRIGGER trg_salary_audit
AFTER INSERT OR UPDATE OR DELETE ON "$(NS)".salary_records
FOR EACH ROW
EXECUTE FUNCTION "$(NS)".fn_trg_salary_audit();

-- ---------------------------------------------------------------------
-- TRG_LEAVE_REQUEST_AUDIT — tracks leave request status changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "$(NS)".fn_trg_leave_request_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM "$(NS)".fn_audit_log_action(
        'LEAVE_REQUESTS',
        new.request_id,
        'STATUS_CHANGE',
        COALESCE(new.modified_by, current_user),
        jsonb_build_object('status', old.status)::text,
        jsonb_build_object('status', new.status)::text
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_leave_request_audit ON "$(NS)".leave_requests;
CREATE TRIGGER trg_leave_request_audit
AFTER UPDATE OF status ON "$(NS)".leave_requests
FOR EACH ROW
EXECUTE FUNCTION "$(NS)".fn_trg_leave_request_audit();

-- ---------------------------------------------------------------------
-- TRG_DEPARTMENT_AUDIT — tracks department structure changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "$(NS)".fn_trg_department_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_action text;
    v_record_id bigint;
BEGIN
    IF tg_op = 'INSERT' THEN
        v_action := 'INSERT';
        v_record_id := new.dept_id;
    ELSIF tg_op = 'UPDATE' THEN
        v_action := 'UPDATE';
        v_record_id := new.dept_id;
    ELSIF tg_op = 'DELETE' THEN
        v_action := 'DELETE';
        v_record_id := old.dept_id;
    END IF;

    PERFORM "$(NS)".fn_audit_log_action(
        'DEPARTMENTS', v_record_id, v_action, current_user
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_department_audit ON "$(NS)".departments;
CREATE TRIGGER trg_department_audit
AFTER INSERT OR UPDATE OR DELETE ON "$(NS)".departments
FOR EACH ROW
EXECUTE FUNCTION "$(NS)".fn_trg_department_audit();
