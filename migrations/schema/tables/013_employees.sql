/*=====================================================================
  013_employees.sql — PostgreSQL conversion of HRMS.EMPLOYEES
  Source: ts-plsql-oracle-forms-hrms/schema/tables/01_core_tables.sql

  Conversions applied:
    - NUMBER(10)              -> integer
    - VARCHAR2(n)             -> varchar(n)
    - DATE                    -> date
    - DATE DEFAULT SYSDATE    -> timestamptz DEFAULT now()
    - self-referencing FK_EMP_MANAGER preserved
=====================================================================*/

CREATE TABLE "$(NS)".employees (
    emp_id integer NOT NULL,
    emp_number varchar(20) NOT NULL,
    first_name varchar(50) NOT NULL,
    last_name varchar(50) NOT NULL,
    email varchar(100),
    phone_work varchar(30),
    phone_mobile varchar(30),
    hire_date date NOT NULL,
    termination_date date,
    dept_id integer NOT NULL,
    job_id integer NOT NULL,
    manager_emp_id integer,
    location_code varchar(10),
    employment_type varchar(20) DEFAULT 'FULL_TIME',
    employment_status varchar(20) DEFAULT 'ACTIVE',
    active_flag char(1) DEFAULT 'Y' NOT NULL,
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_employees PRIMARY KEY (emp_id),
    CONSTRAINT uk_emp_number UNIQUE (emp_number),
    CONSTRAINT fk_emp_dept FOREIGN KEY (dept_id)
    REFERENCES "$(NS)".departments (dept_id),
    CONSTRAINT fk_emp_job FOREIGN KEY (job_id)
    REFERENCES "$(NS)".job_titles (job_id),
    CONSTRAINT fk_emp_manager FOREIGN KEY (manager_emp_id)
    REFERENCES "$(NS)".employees (emp_id),
    CONSTRAINT fk_emp_location FOREIGN KEY (location_code)
    REFERENCES "$(NS)".locations (location_code),
    CONSTRAINT chk_emp_status CHECK (
        employment_status IN ('ACTIVE', 'TERMINATED', 'ON_LEAVE', 'SUSPENDED')
    )
);

CREATE INDEX ix_$(NS)_employees_dept ON "$(NS)".employees (dept_id);
CREATE INDEX ix_$(NS)_employees_manager ON "$(NS)".employees (manager_emp_id);
CREATE INDEX ix_$(NS)_employees_status ON "$(NS)".employees (employment_status, active_flag);
