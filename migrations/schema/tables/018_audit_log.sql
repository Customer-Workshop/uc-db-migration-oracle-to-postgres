/*=====================================================================
  018_audit_log.sql — PostgreSQL conversion of HRMS.AUDIT_LOG
  Source: ts-plsql-oracle-forms-hrms/schema/tables/04_performance_tables.sql

  Added in the trigger-conversion session (Phase 2). It is the write target of
  PKG_AUDIT.log_action (plsql/packages/PKG_AUDIT.pkb), which the converted audit
  trigger functions in migrations/triggers/700_trg_audit.sql invoke.

  Conversions applied:
    - NUMBER(15)             -> bigint
    - VARCHAR2(n)            -> varchar(n)
    - CLOB                   -> text
    - DATE DEFAULT SYSDATE   -> timestamptz DEFAULT now()

  Deliberate, documented deviation from the Oracle source:
    The Oracle table constrained ACTION_TYPE to ('INSERT','UPDATE','DELETE'),
    yet TRG_LEAVE_REQUEST_AUDIT logs the action 'STATUS_CHANGE'. In Oracle that
    INSERT violates CHK_AUDIT_ACTION and is silently swallowed by
    PKG_AUDIT.log_action's `EXCEPTION WHEN OTHERS THEN ROLLBACK`, so leave
    status-change audits were never actually persisted (a latent source bug).
    The converted CHECK adds 'STATUS_CHANGE' so the leave audit is captured as
    the trigger intends — remediation as a separate, deliberate decision.

  audit_id is populated by the trigger via nextval('$(NS).seq_audit')
  (Oracle SEQ_AUDIT.NEXTVAL); it is not GENERATED here so the sequence mapping
  is explicit and matches the source.
=====================================================================*/

CREATE TABLE "$(NS)".audit_log (
    audit_id bigint NOT NULL,
    table_name varchar(60) NOT NULL,
    record_id bigint NOT NULL,
    action_type varchar(20) NOT NULL,
    old_values text,
    new_values text,
    changed_by varchar(30) NOT NULL,
    changed_date timestamptz DEFAULT now() NOT NULL,
    ip_address varchar(50),
    session_id varchar(100),
    CONSTRAINT pk_audit_log PRIMARY KEY (audit_id),
    CONSTRAINT chk_audit_action CHECK (
        action_type IN ('INSERT', 'UPDATE', 'DELETE', 'STATUS_CHANGE')
    )
);

CREATE INDEX ix_$(NS)_audit_lookup
ON "$(NS)".audit_log (table_name, record_id, changed_date);
