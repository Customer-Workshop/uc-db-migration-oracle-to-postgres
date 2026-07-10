/*=====================================================================
  510_vw_org_hierarchy.sql — PostgreSQL conversion of VW_ORG_HIERARCHY
  Source: ts-plsql-oracle-forms-hrms/schema/views/hrms_views.sql (lines 47-57)

  Oracle hierarchical query (CONNECT BY) → PostgreSQL WITH RECURSIVE CTE.

  Conversions applied:
    - START WITH MANAGER_EMP_ID IS NULL   -> recursive anchor (base term)
    - CONNECT BY PRIOR EMP_ID = MANAGER_EMP_ID -> recursive join term
    - LEVEL                               -> org_level depth counter
    - SYS_CONNECT_BY_PATH(name, ' > ')    -> accumulated org_path text
    - CONNECT_BY_ISLEAF                   -> computed leaf indicator (EXISTS)
    - ORDER SIBLINGS BY LAST_NAME         -> accumulated sibling sort key,
                                             deterministic (last_name, emp_id)
    - FIRST_NAME || ' ' || LAST_NAME      -> fn_employee_full_name(...)
    - WHERE EMPLOYMENT_STATUS = 'ACTIVE'  -> preserved in anchor and recursion
    - Oracle object references            -> "$(NS)"-qualified objects
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
        ARRAY[e.last_name, lpad(e.emp_id::text, 12, '0')] AS sibling_path
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
        o.org_level + 1 AS org_level,
        o.org_path || ' > '
        || "$(NS)".fn_employee_full_name(e.first_name, e.last_name) AS org_path,
        o.sibling_path || ARRAY[e.last_name, lpad(e.emp_id::text, 12, '0')] AS sibling_path
    FROM "$(NS)".employees AS e
    INNER JOIN org AS o
        ON e.manager_emp_id = o.emp_id
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
ORDER BY org.sibling_path;

COMMENT ON VIEW "$(NS)".vw_org_hierarchy IS
'Hierarchical org chart (Oracle CONNECT BY converted to WITH RECURSIVE); one row per active employee reachable from a top-level manager';
