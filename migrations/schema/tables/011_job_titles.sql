/*=====================================================================
  011_job_titles.sql — PostgreSQL conversion of HRMS.JOB_TITLES
  Source: ts-plsql-oracle-forms-hrms/schema/tables/01_core_tables.sql
=====================================================================*/

CREATE TABLE "$(NS)".job_titles (
    job_id      integer       NOT NULL,
    job_code    varchar(20)   NOT NULL,
    job_title   varchar(100)  NOT NULL,
    job_family  varchar(50),
    grade_id    integer       NOT NULL,
    flsa_status varchar(20)   DEFAULT 'EXEMPT',
    created_date timestamptz  DEFAULT now() NOT NULL,
    CONSTRAINT pk_job_titles PRIMARY KEY (job_id),
    CONSTRAINT uk_job_code UNIQUE (job_code),
    CONSTRAINT fk_job_grade FOREIGN KEY (grade_id)
        REFERENCES "$(NS)".job_grades (grade_id),
    CONSTRAINT chk_flsa CHECK (flsa_status IN ('EXEMPT', 'NON_EXEMPT'))
);
