/*=====================================================================
  001_sequences.sql — PostgreSQL conversion of HRMS surrogate-key sequences
  Source: ts-plsql-oracle-forms-hrms/schema/sequences/hrms_sequences.sql

  Conversions applied:
    - CREATE SEQUENCE HRMS.SEQ_x START WITH n INCREMENT BY 1 NOCACHE
        -> CREATE SEQUENCE $(NS).seq_x START WITH n INCREMENT BY 1
           (PostgreSQL caches per-session by default; NOCACHE has no direct
            equivalent — use CACHE 1 for gap-minimising behaviour)
    - Oracle SEQ.NEXTVAL  -> PostgreSQL nextval('$(NS).seq_x')
    - Oracle SEQ.CURRVAL  -> PostgreSQL currval('$(NS).seq_x')

  Note: several tables below are better modelled with GENERATED ALWAYS AS
  IDENTITY (see the table DDL). These standalone sequences are retained where
  the application reads SEQ.NEXTVAL explicitly.
=====================================================================*/

CREATE SCHEMA IF NOT EXISTS "$(NS)";

CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_department START WITH 100 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_job_grade  START WITH 100 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_job_title  START WITH 100 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_employee   START WITH 10000 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_salary     START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_leave_type    START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_leave_balance START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_pay_element   START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_pay_period    START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_payroll_run    START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_payroll_detail START WITH 1 INCREMENT BY 1 CACHE 1;
CREATE SEQUENCE IF NOT EXISTS "$(NS)".seq_audit          START WITH 1 INCREMENT BY 1 CACHE 100;
