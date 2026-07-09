/*=====================================================================
  302_fn_compa_ratio.sql — PostgreSQL conversion of the compa-ratio calculation
  Source: ts-plsql-oracle-forms-hrms/schema/views/hrms_views.sql
          ROUND(sr.BASE_SALARY / ((g.MIN_SALARY + g.MAX_SALARY) / 2) * 100, 1)

  Conversions applied:
    - ROUND(x, 1)   -> round(x, 1)
    - Oracle divide-by-zero raises; guard the grade midpoint with NULLIF so a
      zero-width band returns NULL rather than erroring (PostgreSQL raises
      division_by_zero identically).
=====================================================================*/

CREATE OR REPLACE FUNCTION "$(NS)".fn_compa_ratio(
    p_base_salary numeric,
    p_grade_min   numeric,
    p_grade_max   numeric
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT round(
        p_base_salary / NULLIF((p_grade_min + p_grade_max) / 2, 0) * 100,
        1
    );
$$;
