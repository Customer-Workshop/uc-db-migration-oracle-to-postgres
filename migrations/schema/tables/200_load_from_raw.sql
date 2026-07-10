/*=====================================================================
  200_load_from_raw.sql — Populate the converted namespace from source data

  Copies the source-of-truth synthetic data from the `raw` schema into the
  converted `$(NS)` tables so the namespace is a fully-populated converted
  database. Reconciliation controls then compare the source (`raw`) against the
  converted target (`$(NS)`).

  Runs after the table DDL (01x) and before functions/views (3xx+). Idempotent
  within a fresh namespace deploy (tables are created empty immediately above).

  Note: $(NS).leave_balances.available is a GENERATED column and is therefore
  omitted from the explicit column list below.
=====================================================================*/

INSERT INTO "$(NS)".locations
(
    location_code, location_name, address_line1, address_line2, city,
    state_province, postal_code, country_code, phone_number, timezone,
    active_flag, created_by, created_date, modified_by, modified_date
)
SELECT
    location_code,
    location_name,
    address_line1,
    address_line2,
    city,
    state_province,
    postal_code,
    country_code,
    phone_number,
    timezone,
    active_flag,
    created_by,
    created_date,
    modified_by,
    modified_date
FROM raw.locations;

INSERT INTO "$(NS)".job_grades
(grade_id, grade_code, grade_name, min_salary, max_salary, overtime_eligible)
SELECT
    grade_id,
    grade_code,
    grade_name,
    min_salary,
    max_salary,
    overtime_eligible
FROM raw.job_grades;

INSERT INTO "$(NS)".job_titles
(job_id, job_code, job_title, job_family, grade_id, flsa_status)
SELECT
    job_id,
    job_code,
    job_title,
    job_family,
    grade_id,
    flsa_status
FROM raw.job_titles;

INSERT INTO "$(NS)".departments
(dept_id, dept_code, dept_name, parent_dept_id, cost_center, location_code)
SELECT
    dept_id,
    dept_code,
    dept_name,
    parent_dept_id,
    cost_center,
    location_code
FROM raw.departments;

INSERT INTO "$(NS)".employees
(
    emp_id, emp_number, first_name, last_name, email, phone_work,
    phone_mobile, hire_date, termination_date, dept_id, job_id,
    manager_emp_id, location_code, employment_type, employment_status,
    active_flag
)
SELECT
    emp_id,
    emp_number,
    first_name,
    last_name,
    email,
    phone_work,
    phone_mobile,
    hire_date,
    termination_date,
    dept_id,
    job_id,
    manager_emp_id,
    location_code,
    employment_type,
    employment_status,
    active_flag
FROM raw.employees;

INSERT INTO "$(NS)".salary_records
(
    salary_id, emp_id, effective_date, end_date, base_salary,
    currency_code, pay_frequency, active_flag
)
SELECT
    salary_id,
    emp_id,
    effective_date,
    end_date,
    base_salary,
    currency_code,
    pay_frequency,
    active_flag
FROM raw.salary_records;

INSERT INTO "$(NS)".leave_types
(
    leave_type_id, leave_type_code, leave_type_name, paid_flag,
    accrual_rate, max_balance
)
SELECT
    leave_type_id,
    leave_type_code,
    leave_type_name,
    paid_flag,
    accrual_rate,
    max_balance
FROM raw.leave_types;

INSERT INTO "$(NS)".leave_balances
(
    balance_id, emp_id, leave_type_id, calendar_year, opening_balance,
    accrued, used, adjustment, pending
)
SELECT
    balance_id,
    emp_id,
    leave_type_id,
    calendar_year,
    opening_balance,
    accrued,
    used,
    adjustment,
    pending
FROM raw.leave_balances;

INSERT INTO "$(NS)".pay_elements
(element_id, element_code, element_name, element_type)
SELECT
    element_id,
    element_code,
    element_name,
    element_type
FROM raw.pay_elements;

INSERT INTO "$(NS)".pay_periods
(
    period_id, period_name, pay_frequency, period_start_date,
    period_end_date, pay_date, status
)
SELECT
    period_id,
    period_name,
    pay_frequency,
    period_start_date,
    period_end_date,
    pay_date,
    status
FROM raw.pay_periods;

INSERT INTO "$(NS)".payroll_runs
(
    run_id, period_id, run_type, run_date, status, total_gross,
    total_deductions, total_net, employee_count
)
SELECT
    run_id,
    period_id,
    run_type,
    run_date,
    status,
    total_gross,
    total_deductions,
    total_net,
    employee_count
FROM raw.payroll_runs;

INSERT INTO "$(NS)".payroll_details
(detail_id, run_id, emp_id, element_id, element_type, amount, status)
SELECT
    detail_id,
    run_id,
    emp_id,
    element_id,
    element_type,
    amount,
    status
FROM raw.payroll_details;
