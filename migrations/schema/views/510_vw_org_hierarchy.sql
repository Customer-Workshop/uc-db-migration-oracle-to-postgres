/*=====================================================================
  510_vw_org_hierarchy.sql — PostgreSQL conversion of VW_ORG_HIERARCHY
  Source: ts-plsql-oracle-forms-hrms/schema/views/hrms_views.sql

  Conversions applied:
    - START WITH / CONNECT BY PRIOR -> WITH RECURSIVE
    - LEVEL                         -> recursive depth counter
    - SYS_CONNECT_BY_PATH           -> accumulated text path
    - CONNECT_BY_ISLEAF             -> active-child existence check
    - ORDER SIBLINGS BY             -> accumulated sibling sort path
=====================================================================*/

CREATE OR REPLACE VIEW "$(NS)".vw_org_hierarchy AS
WITH RECURSIVE org AS (
    SELECT  -- noqa: ST06
        e.emp_id,
        e.emp_number,
        "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS emp_name,
        e.manager_emp_id,
        e.dept_id,
        1 AS org_level,
        "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS org_path,
        ARRAY[e.last_name, e.emp_id::text] AS sort_path
    FROM "$(NS)".employees AS e
    WHERE
        e.manager_emp_id IS NULL
        AND e.employment_status = 'ACTIVE'

    UNION ALL

    SELECT  -- noqa: ST06
        e.emp_id,
        e.emp_number,
        "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS emp_name,
        e.manager_emp_id,
        e.dept_id,
        org.org_level + 1 AS org_level,
        org.org_path || ' > '
        || "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS org_path,
        org.sort_path || ARRAY[e.last_name, e.emp_id::text] AS sort_path
    FROM "$(NS)".employees AS e
    INNER JOIN org
        ON e.manager_emp_id = org.emp_id
    WHERE e.employment_status = 'ACTIVE'
)

SELECT  -- noqa: ST06
    org.emp_id,
    org.emp_number,
    org.emp_name,
    org.manager_emp_id,
    org.dept_id,
    org.org_level,
    org.org_path,
    CASE
        WHEN
            EXISTS (
                SELECT 1
                FROM "$(NS)".employees AS child
                WHERE
                    child.manager_emp_id = org.emp_id
                    AND child.employment_status = 'ACTIVE'
            )
            THEN 0
        ELSE 1
    END AS is_leaf
FROM org
ORDER BY org.sort_path;
