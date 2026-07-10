/*=====================================================================
  017_leave_requests.sql — PostgreSQL conversion of HRMS.LEAVE_REQUESTS
  Source: ts-plsql-oracle-forms-hrms/schema/tables/03_leave_tables.sql

  Added in the trigger-conversion session (Phase 2) because
  TRG_LEAVE_REQUEST_AUDIT (plsql/triggers/trg_audit.sql) binds to this table.
  The Phase 1 target shipped leave_types and leave_balances but not
  leave_requests; the audit trigger's target table is created here so the
  CREATE TRIGGER binding in migrations/triggers/700_trg_audit.sql resolves.

  Conversions applied:
    - NUMBER(10)/NUMBER(5)   -> integer
    - NUMBER(5,1)            -> numeric(5,1)
    - VARCHAR2(n)            -> varchar(n)
    - CHAR(1)                -> char(1)
    - DATE                   -> date
    - DATE DEFAULT SYSDATE   -> timestamptz DEFAULT now()

  Note: this table is not populated from raw (the synthetic seed has no
  leave_requests rows); it exists so the status-change audit trigger can be
  bound and exercised. modified_by is retained so the trigger's
  NVL(:NEW.MODIFIED_BY, USER) -> COALESCE(new.modified_by, current_user)
  mapping is faithful.
=====================================================================*/

CREATE TABLE "$(NS)".leave_requests (
    request_id integer NOT NULL,
    emp_id integer NOT NULL,
    leave_type_id integer NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    total_days numeric(5, 1) NOT NULL,
    half_day_flag char(1) DEFAULT 'N',
    half_day_period varchar(10),
    status varchar(20) DEFAULT 'PENDING',
    reason varchar(4000),
    supporting_doc_path varchar(500),
    approver_emp_id integer,
    approval_date date,
    approval_comments varchar(4000),
    cancel_reason varchar(4000),
    cancelled_date date,
    created_by varchar(30) NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    modified_by varchar(30),
    modified_date timestamptz,
    CONSTRAINT pk_leave_requests PRIMARY KEY (request_id),
    CONSTRAINT fk_lr_emp FOREIGN KEY (emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_lr_type FOREIGN KEY (leave_type_id)
    REFERENCES "$(NS)".leave_types (leave_type_id),
    CONSTRAINT fk_lr_approver FOREIGN KEY (approver_emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT chk_lr_status CHECK (
        status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED', 'TAKEN')
    ),
    CONSTRAINT chk_lr_dates CHECK (end_date >= start_date),
    CONSTRAINT chk_half_day CHECK (half_day_period IN ('AM', 'PM'))
);

CREATE INDEX ix_$(NS)_lr_emp ON "$(NS)".leave_requests (emp_id, status);
