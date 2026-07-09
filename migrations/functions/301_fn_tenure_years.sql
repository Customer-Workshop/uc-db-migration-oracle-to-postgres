/*=====================================================================
  301_fn_tenure_years.sql — PostgreSQL conversion of the tenure calculation
  Source: ts-plsql-oracle-forms-hrms/schema/views/hrms_views.sql
          TRUNC(MONTHS_BETWEEN(SYSDATE, e.HIRE_DATE) / 12, 1) AS TENURE_YEARS

  Conversions applied:
    - SYSDATE                 -> current_date
    - MONTHS_BETWEEN(a, b)    -> whole-month difference via age()/extract
    - TRUNC(x, 1)             -> trunc(x, 1)  (identical semantics)
=====================================================================*/

CREATE OR REPLACE FUNCTION "$(NS)".fn_tenure_years(
    p_hire_date date,
    p_as_of     date DEFAULT current_date
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT trunc(
        (
            (extract(year FROM age(p_as_of, p_hire_date)) * 12
             + extract(month FROM age(p_as_of, p_hire_date)))
            / 12.0
        )::numeric,
        1
    );
$$;
