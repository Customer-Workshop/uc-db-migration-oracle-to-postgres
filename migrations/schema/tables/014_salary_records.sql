/*=====================================================================
  014_salary_records.sql — PostgreSQL conversion of HRMS.SALARY_RECORDS
  Source: ts-plsql-oracle-forms-hrms/schema/tables/02_payroll_tables.sql

  Conversions applied:
    - NUMBER(12,2)   -> numeric(12,2)
    - VARCHAR2(3)    -> varchar(3)
    - CHAR(1)        -> char(1)
=====================================================================*/

CREATE TABLE "$(NS)".salary_records (
    salary_id integer NOT NULL,
    emp_id integer NOT NULL,
    effective_date date NOT NULL,
    end_date date,
    base_salary numeric(12, 2) NOT NULL,
    currency_code varchar(3) DEFAULT 'USD',
    pay_frequency varchar(20) DEFAULT 'MONTHLY',
    active_flag char(1) DEFAULT 'Y' NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_salary_records PRIMARY KEY (salary_id),
    CONSTRAINT fk_sal_emp FOREIGN KEY (emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT chk_pay_freq CHECK (
        pay_frequency IN ('WEEKLY', 'BIWEEKLY', 'SEMIMONTHLY', 'MONTHLY')
    )
);

CREATE INDEX ix_$(NS)_salary_emp ON "$(NS)".salary_records (emp_id, active_flag);
