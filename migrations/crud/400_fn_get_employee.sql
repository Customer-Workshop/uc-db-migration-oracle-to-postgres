/*=====================================================================
  400_fn_get_employee.sql — PostgreSQL conversion of PKG_EMPLOYEE.get_employee
  Source: ts-plsql-oracle-forms-hrms/plsql/packages/PKG_EMPLOYEE.pkb

  Conversions applied:
    - Oracle procedure with OUT SYS_REFCURSOR
        -> PostgreSQL set-returning function (RETURNS TABLE)
    - %ROWTYPE result shape           -> explicit RETURNS TABLE column list
    - Package-qualified table access  -> $(NS)-schema-qualified access
    - String concatenation via fn_employee_full_name (300)
=====================================================================*/

CREATE OR REPLACE FUNCTION "$(NS)".fn_get_employee(
    p_emp_id integer
) RETURNS TABLE (
    emp_id        integer,
    emp_number    varchar,
    full_name     text,
    email         varchar,
    dept_name     varchar,
    job_title     varchar,
    employment_status varchar
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        e.emp_id,
        e.emp_number,
        "$(NS)".fn_employee_full_name(e.first_name, e.last_name),
        e.email,
        d.dept_name,
        j.job_title,
        e.employment_status
    FROM "$(NS)".employees e
    JOIN "$(NS)".departments d ON e.dept_id = d.dept_id
    JOIN "$(NS)".job_titles j ON e.job_id = j.job_id
    WHERE e.emp_id = p_emp_id;
$$;
