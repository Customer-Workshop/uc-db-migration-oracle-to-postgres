/*=====================================================================
  015_leave.sql — PostgreSQL conversion of HRMS leave tables
  Source: ts-plsql-oracle-forms-hrms/schema/tables/03_leave_tables.sql

  Conversions applied:
    - NUMBER(6,2)  -> numeric(6,2)
    - Oracle VIRTUAL generated column
        AVAILABLE ... AS (...) VIRTUAL
      -> PostgreSQL GENERATED ALWAYS AS (...) STORED
      (PostgreSQL has no VIRTUAL/non-stored generated columns; STORED is the
       closest equivalent and is materialised on write.)
=====================================================================*/

CREATE TABLE "$(NS)".leave_types (
    leave_type_id   integer      NOT NULL,
    leave_type_code varchar(20)  NOT NULL,
    leave_type_name varchar(50)  NOT NULL,
    paid_flag       char(1)      DEFAULT 'Y',
    accrual_rate    numeric(6,2),
    max_balance     numeric(6,2),
    active_flag     char(1)      DEFAULT 'Y' NOT NULL,
    created_date    timestamptz  DEFAULT now() NOT NULL,
    CONSTRAINT pk_leave_types PRIMARY KEY (leave_type_id),
    CONSTRAINT uk_leave_type_code UNIQUE (leave_type_code)
);

CREATE TABLE "$(NS)".leave_balances (
    balance_id      integer      NOT NULL,
    emp_id          integer      NOT NULL,
    leave_type_id   integer      NOT NULL,
    calendar_year   integer      NOT NULL,
    opening_balance numeric(6,2) DEFAULT 0,
    accrued         numeric(6,2) DEFAULT 0,
    used            numeric(6,2) DEFAULT 0,
    adjustment      numeric(6,2) DEFAULT 0,
    pending         numeric(6,2) DEFAULT 0,
    available       numeric(6,2)
        GENERATED ALWAYS AS
        (opening_balance + accrued - used + adjustment - pending) STORED,
    created_date    timestamptz  DEFAULT now() NOT NULL,
    CONSTRAINT pk_leave_balances PRIMARY KEY (balance_id),
    CONSTRAINT fk_lb_emp FOREIGN KEY (emp_id)
        REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_lb_type FOREIGN KEY (leave_type_id)
        REFERENCES "$(NS)".leave_types (leave_type_id),
    CONSTRAINT uk_leave_bal UNIQUE (emp_id, leave_type_id, calendar_year)
);
