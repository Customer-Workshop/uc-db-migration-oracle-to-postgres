/*=====================================================================
  300_fn_employee_full_name.sql — PostgreSQL conversion of a PKG_EMPLOYEE helper
  Source: ts-plsql-oracle-forms-hrms/plsql/packages/PKG_EMPLOYEE.pkb
          (FIRST_NAME || ' ' || LAST_NAME full-name derivation)

  Conversions applied:
    - Package function PKG_EMPLOYEE.get_full_name
        -> schema-scoped function $(NS).fn_employee_full_name
    - Oracle VARCHAR2 return  -> PostgreSQL text
    - Oracle NULL concatenation ('' behaves as NULL in Oracle) made explicit
      with COALESCE so a NULL name component does not collapse the whole string.
=====================================================================*/

CREATE OR REPLACE FUNCTION "$(NS)".fn_employee_full_name(
    p_first_name text,
    p_last_name  text
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT trim(COALESCE(p_first_name, '') || ' ' || COALESCE(p_last_name, ''));
$$;
