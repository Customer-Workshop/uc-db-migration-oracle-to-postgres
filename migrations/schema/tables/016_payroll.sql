/*=====================================================================
  016_payroll.sql — PostgreSQL conversion of HRMS payroll tables
  Source: ts-plsql-oracle-forms-hrms/schema/tables/02_payroll_tables.sql

  Conversions applied:
    - NUMBER(15,2) / NUMBER(12,2) -> numeric(15,2) / numeric(12,2)
    - VARCHAR2(n)                 -> varchar(n)
=====================================================================*/

CREATE TABLE "$(NS)".pay_elements (
    element_id integer NOT NULL,
    element_code varchar(30) NOT NULL,
    element_name varchar(100) NOT NULL,
    element_type varchar(20) NOT NULL,
    active_flag char(1) DEFAULT 'Y' NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_pay_elements PRIMARY KEY (element_id),
    CONSTRAINT uk_pay_elem_code UNIQUE (element_code),
    CONSTRAINT chk_elem_type CHECK (
        element_type IN ('EARNING', 'DEDUCTION', 'TAX', 'BENEFIT', 'REIMBURSEMENT')
    )
);

CREATE TABLE "$(NS)".pay_periods (
    period_id integer NOT NULL,
    period_name varchar(50) NOT NULL,
    pay_frequency varchar(20) NOT NULL,
    period_start_date date NOT NULL,
    period_end_date date NOT NULL,
    pay_date date NOT NULL,
    status varchar(20) DEFAULT 'OPEN',
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_pay_periods PRIMARY KEY (period_id),
    CONSTRAINT chk_period_status CHECK (
        status IN ('OPEN', 'PROCESSING', 'CLOSED', 'REVERSED')
    )
);

CREATE TABLE "$(NS)".payroll_runs (
    run_id integer NOT NULL,
    period_id integer NOT NULL,
    run_type varchar(20) DEFAULT 'REGULAR',
    run_date date NOT NULL,
    status varchar(20) DEFAULT 'PENDING',
    total_gross numeric(15, 2),
    total_deductions numeric(15, 2),
    total_net numeric(15, 2),
    employee_count integer,
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_payroll_runs PRIMARY KEY (run_id),
    CONSTRAINT fk_pr_period FOREIGN KEY (period_id)
    REFERENCES "$(NS)".pay_periods (period_id),
    CONSTRAINT chk_run_status CHECK (
        status IN (
            'PENDING', 'CALCULATING', 'CALCULATED', 'APPROVED',
            'PAID', 'REVERSED', 'ERROR'
        )
    )
);

CREATE TABLE "$(NS)".payroll_details (
    detail_id integer NOT NULL,
    run_id integer NOT NULL,
    emp_id integer NOT NULL,
    element_id integer NOT NULL,
    element_type varchar(20) NOT NULL,
    amount numeric(12, 2) NOT NULL,
    status varchar(20) DEFAULT 'CALCULATED',
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_payroll_details PRIMARY KEY (detail_id),
    CONSTRAINT fk_pd_run FOREIGN KEY (run_id)
    REFERENCES "$(NS)".payroll_runs (run_id),
    CONSTRAINT fk_pd_emp FOREIGN KEY (emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_pd_element FOREIGN KEY (element_id)
    REFERENCES "$(NS)".pay_elements (element_id)
);

CREATE INDEX ix_$(NS)_payroll_details_run ON "$(NS)".payroll_details (run_id);
