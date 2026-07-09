/*=====================================================================
  012_departments.sql — PostgreSQL conversion of HRMS.DEPARTMENTS
  Source: ts-plsql-oracle-forms-hrms/schema/tables/01_core_tables.sql

  Note: self-referencing parent_dept_id FK preserved.
=====================================================================*/

CREATE TABLE "$(NS)".departments (
    dept_id        integer       NOT NULL,
    dept_code      varchar(20)   NOT NULL,
    dept_name      varchar(100)  NOT NULL,
    parent_dept_id integer,
    cost_center    varchar(20),
    location_code  varchar(10),
    active_flag    char(1)       DEFAULT 'Y' NOT NULL,
    created_date   timestamptz   DEFAULT now() NOT NULL,
    CONSTRAINT pk_departments PRIMARY KEY (dept_id),
    CONSTRAINT uk_dept_code UNIQUE (dept_code),
    CONSTRAINT fk_dept_parent FOREIGN KEY (parent_dept_id)
        REFERENCES "$(NS)".departments (dept_id)
);
