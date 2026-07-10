/*=====================================================================
  010_job_grades.sql — PostgreSQL conversion of HRMS.JOB_GRADES
  Source: ts-plsql-oracle-forms-hrms/schema/tables/01_core_tables.sql

  Conversions applied:
    - NUMBER(10)        -> integer
    - NUMBER(12,2)      -> numeric(12,2)
    - VARCHAR2(n)       -> varchar(n)
    - CHAR(1)           -> char(1)
    - DATE DEFAULT SYSDATE -> timestamptz DEFAULT now()
=====================================================================*/

CREATE SCHEMA IF NOT EXISTS "$(NS)";

CREATE TABLE "$(NS)".job_grades (
    grade_id integer NOT NULL,
    grade_code varchar(10) NOT NULL,
    grade_name varchar(50) NOT NULL,
    min_salary numeric(12, 2) NOT NULL,
    max_salary numeric(12, 2) NOT NULL,
    overtime_eligible char(1) DEFAULT 'N',
    created_by varchar(30),
    created_date timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT pk_job_grades PRIMARY KEY (grade_id),
    CONSTRAINT uk_job_grade_code UNIQUE (grade_code),
    CONSTRAINT chk_grade_ot CHECK (overtime_eligible IN ('Y', 'N'))
);
