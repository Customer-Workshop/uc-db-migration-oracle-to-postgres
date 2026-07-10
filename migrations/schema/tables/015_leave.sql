/*=====================================================================
  015_leave.sql — PostgreSQL conversion of HRMS leave tables
  Source: ts-plsql-oracle-forms-hrms/schema/tables/03_leave_tables.sql

  Conversions applied:
    - NUMBER(6,2)  -> numeric(6,2)
    - Oracle DATE audit columns -> timestamptz
    - Oracle VIRTUAL generated column
        AVAILABLE ... AS (...) VIRTUAL
      -> PostgreSQL GENERATED ALWAYS AS (...) STORED
      (PostgreSQL has no VIRTUAL/non-stored generated columns; STORED is the
       closest equivalent and is materialised on write.)
    - NULL arithmetic in AVAILABLE made explicit with COALESCE
=====================================================================*/

CREATE TABLE "$(NS)".leave_types (
    leave_type_id integer NOT NULL,
    leave_type_code varchar(20) NOT NULL,
    leave_type_name varchar(50) NOT NULL,
    paid_flag char(1) DEFAULT 'Y',
    accrual_flag char(1) DEFAULT 'Y',
    accrual_rate numeric(6, 2),
    accrual_frequency varchar(20),
    max_balance numeric(6, 2),
    carryover_max numeric(6, 2),
    carryover_expiry integer,
    min_tenure_days integer DEFAULT 0,
    requires_approval char(1) DEFAULT 'Y',
    requires_document char(1) DEFAULT 'N',
    active_flag char(1) DEFAULT 'Y' NOT NULL,
    created_by varchar(30) DEFAULT current_user NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    modified_by varchar(30),
    modified_date timestamptz,
    CONSTRAINT pk_leave_types PRIMARY KEY (leave_type_id),
    CONSTRAINT uk_leave_type_code UNIQUE (leave_type_code),
    CONSTRAINT chk_accrual_freq CHECK (
        accrual_frequency IN ('MONTHLY', 'BIWEEKLY', 'ANNUAL')
        OR accrual_frequency IS NULL
    )
);

CREATE TABLE "$(NS)".leave_balances (
    balance_id integer NOT NULL,
    emp_id integer NOT NULL,
    leave_type_id integer NOT NULL,
    calendar_year integer NOT NULL,
    opening_balance numeric(6, 2) DEFAULT 0,
    accrued numeric(6, 2) DEFAULT 0,
    used numeric(6, 2) DEFAULT 0,
    adjustment numeric(6, 2) DEFAULT 0,
    pending numeric(6, 2) DEFAULT 0,
    available numeric(6, 2)
    GENERATED ALWAYS AS
    (
        coalesce(opening_balance, 0)
        + coalesce(accrued, 0)
        - coalesce(used, 0)
        + coalesce(adjustment, 0)
        - coalesce(pending, 0)
    ) STORED,
    carryover_from_prev numeric(6, 2) DEFAULT 0,
    carryover_expiry_dt date,
    created_by varchar(30) DEFAULT current_user NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    modified_by varchar(30),
    modified_date timestamptz,
    CONSTRAINT pk_leave_balances PRIMARY KEY (balance_id),
    CONSTRAINT fk_lb_emp FOREIGN KEY (emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_lb_type FOREIGN KEY (leave_type_id)
    REFERENCES "$(NS)".leave_types (leave_type_id),
    CONSTRAINT uk_leave_bal UNIQUE (emp_id, leave_type_id, calendar_year)
);

CREATE TABLE "$(NS)".leave_accrual_log (
    accrual_id bigint NOT NULL,
    emp_id integer NOT NULL,
    leave_type_id integer NOT NULL,
    accrual_date date NOT NULL,
    accrual_amount numeric(6, 2) NOT NULL,
    balance_after numeric(6, 2),
    run_id integer,
    created_by varchar(30) DEFAULT current_user NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_leave_accrual_log PRIMARY KEY (accrual_id),
    CONSTRAINT fk_lal_emp FOREIGN KEY (emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_lal_type FOREIGN KEY (leave_type_id)
    REFERENCES "$(NS)".leave_types (leave_type_id)
);
