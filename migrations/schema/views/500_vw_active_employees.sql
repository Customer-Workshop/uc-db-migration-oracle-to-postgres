/*=====================================================================
  500_vw_active_employees.sql — PostgreSQL conversion of VW_ACTIVE_EMPLOYEES
  Source: ts-plsql-oracle-forms-hrms/schema/views/hrms_views.sql

  Conversions applied:
    - Oracle string concatenation -> fn_employee_full_name
    - TRUNC(MONTHS_BETWEEN(...))  -> fn_tenure_years
    - SYSDATE                     -> current_date
    - Oracle object references    -> namespace-qualified PostgreSQL objects
=====================================================================*/

CREATE OR REPLACE VIEW "$(NS)".vw_active_employees AS
SELECT  -- noqa: ST06
    e.emp_id,
    e.emp_number,
    e.first_name,
    e.last_name,
    "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS full_name,
    e.email,
    e.phone_work,
    e.phone_mobile,
    e.hire_date,
    "$(NS)".fn_tenure_years(e.hire_date) AS tenure_years,
    e.employment_type,
    e.employment_status,
    e.dept_id,
    d.dept_name,
    d.dept_code,
    d.cost_center,
    e.job_id,
    j.job_title,
    j.job_code,
    g.grade_id,
    g.grade_name,
    e.manager_emp_id,
    "$(NS)".fn_employee_full_name(m.first_name, m.last_name) AS manager_name,
    e.location_code,
    l.location_name,
    l.city,
    l.state_province,
    l.country_code,
    sr.base_salary AS current_salary,
    sr.currency_code,
    sr.pay_frequency
FROM "$(NS)".employees AS e
INNER JOIN "$(NS)".departments AS d
    ON e.dept_id = d.dept_id
INNER JOIN "$(NS)".job_titles AS j
    ON e.job_id = j.job_id
INNER JOIN "$(NS)".job_grades AS g
    ON j.grade_id = g.grade_id
LEFT JOIN "$(NS)".employees AS m
    ON e.manager_emp_id = m.emp_id
LEFT JOIN "$(NS)".locations AS l
    ON e.location_code = l.location_code
LEFT JOIN "$(NS)".salary_records AS sr
    ON
        e.emp_id = sr.emp_id
        AND sr.active_flag = 'Y'
        AND sr.effective_date <= current_date
        AND (sr.end_date IS NULL OR sr.end_date > current_date)
WHERE
    e.employment_status = 'ACTIVE'
    AND e.active_flag = 'Y';

COMMENT ON VIEW "$(NS)".vw_active_employees IS
'Denormalized view of active employees with department, job, manager, location, and salary';
