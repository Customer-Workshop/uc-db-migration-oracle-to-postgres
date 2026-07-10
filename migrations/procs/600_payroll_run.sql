/*=====================================================================
  600_payroll_run.sql — PostgreSQL conversion of PKG_PAYROLL run processing
  Source: ts-plsql-oracle-forms-hrms/plsql/packages/PKG_PAYROLL.pkb

  Conversions applied:
    - Package program units       -> schema-scoped functions/procedures
    - Cursor FOR loops            -> PL/pgSQL FOR ... IN SELECT loops
    - SQL%ROWCOUNT                -> GET DIAGNOSTICS ... = ROW_COUNT
    - SEQ.NEXTVAL                 -> schema-qualified nextval(...)
    - SELECT ... FROM DUAL        -> direct expression assignment
    - NVL                         -> COALESCE
    - DBMS_OUTPUT.PUT_LINE        -> RAISE NOTICE
    - UTL_FILE pay-register CSV   -> fn_pay_register rowset; callers export
                                     it with psql \copy or an application job

  The Phase 1 target omits Oracle EMPLOYEE_TAX_INFO and
  EMPLOYEE_PAY_ELEMENTS. Run processing therefore uses SINGLE/zero-allowance
  federal defaults and processes base pay plus statutory federal, Social
  Security, and Medicare taxes. State and employee-specific deductions can be
  added when their source tables are migrated.
=====================================================================*/

SELECT
    setval(
        '"$(NS)".seq_pay_element',
        greatest(coalesce(max(element_id), 0) + 1, 1),
        false
    )
FROM "$(NS)".pay_elements;

SELECT
    setval(
        '"$(NS)".seq_payroll_run',
        greatest(coalesce(max(run_id), 0) + 1, 1),
        false
    )
FROM "$(NS)".payroll_runs;

SELECT
    setval(
        '"$(NS)".seq_payroll_detail',
        greatest(coalesce(max(detail_id), 0) + 1, 1),
        false
    )
FROM "$(NS)".payroll_details;

INSERT INTO "$(NS)".pay_elements (
    element_id,
    element_code,
    element_name,
    element_type
)
SELECT
    nextval('"$(NS)".seq_pay_element') AS element_id,
    'SS_TAX' AS element_code,
    'Social Security Tax' AS element_name,
    'TAX' AS element_type
WHERE NOT EXISTS (
    SELECT 1
    FROM "$(NS)".pay_elements
    WHERE element_code = 'SS_TAX'
);

INSERT INTO "$(NS)".pay_elements (
    element_id,
    element_code,
    element_name,
    element_type
)
SELECT
    nextval('"$(NS)".seq_pay_element') AS element_id,
    'MEDICARE' AS element_code,
    'Medicare Tax' AS element_name,
    'TAX' AS element_type
WHERE NOT EXISTS (
    SELECT 1
    FROM "$(NS)".pay_elements
    WHERE element_code = 'MEDICARE'
);

CREATE OR REPLACE FUNCTION "$(NS)".fn_payroll_salary_as_of(
    p_emp_id integer,
    p_as_of date
)
RETURNS numeric(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_salary numeric(12, 2);
BEGIN
    SELECT sr.base_salary
    INTO v_salary
    FROM "$(NS)".salary_records AS sr
    WHERE
        sr.emp_id = p_emp_id
        AND sr.effective_date <= p_as_of
        AND (sr.end_date IS NULL OR sr.end_date >= p_as_of)
    ORDER BY sr.effective_date DESC
    LIMIT 1;

    RETURN COALESCE(v_salary, 0);
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_calculate_federal_tax(
    p_taxable_income numeric,
    p_filing_status varchar,
    p_allowances numeric DEFAULT 0,
    p_additional_wh numeric DEFAULT 0,
    p_pay_frequency varchar DEFAULT 'MONTHLY'
)
RETURNS numeric(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_annualized numeric;
    v_standard_deduction numeric;
    v_taxable numeric;
    v_tax numeric := 0;
    v_periods numeric;
BEGIN
    v_periods := CASE p_pay_frequency
        WHEN 'WEEKLY' THEN 52
        WHEN 'BIWEEKLY' THEN 26
        WHEN 'SEMIMONTHLY' THEN 24
        WHEN 'MONTHLY' THEN 12
        ELSE 12
    END;

    v_annualized := p_taxable_income * v_periods;
    v_standard_deduction := CASE
        WHEN p_filing_status = 'MARRIED_JOINT' THEN 29200
        ELSE 14600
    END;
    v_taxable := v_annualized - v_standard_deduction
        - (COALESCE(p_allowances, 0) * 4300);

    IF v_taxable <= 0 THEN
        RETURN 0;
    END IF;

    IF p_filing_status IN ('SINGLE', 'MARRIED_SEPARATE') THEN
        v_tax := CASE
            WHEN v_taxable <= 11600 THEN v_taxable * 0.10
            WHEN v_taxable <= 47150 THEN 1160 + (v_taxable - 11600) * 0.12
            WHEN v_taxable <= 100525 THEN 5426 + (v_taxable - 47150) * 0.22
            WHEN v_taxable <= 191950 THEN 17168.50 + (v_taxable - 100525) * 0.24
            WHEN v_taxable <= 243725 THEN 39110.50 + (v_taxable - 191950) * 0.32
            WHEN v_taxable <= 609350 THEN 55678.50 + (v_taxable - 243725) * 0.35
            ELSE 183647.25 + (v_taxable - 609350) * 0.37
        END;
    ELSIF p_filing_status = 'MARRIED_JOINT' THEN
        v_tax := CASE
            WHEN v_taxable <= 23200 THEN v_taxable * 0.10
            WHEN v_taxable <= 94300 THEN 2320 + (v_taxable - 23200) * 0.12
            WHEN v_taxable <= 201050 THEN 10852 + (v_taxable - 94300) * 0.22
            WHEN v_taxable <= 383900 THEN 34337 + (v_taxable - 201050) * 0.24
            WHEN v_taxable <= 487450 THEN 78221 + (v_taxable - 383900) * 0.32
            WHEN v_taxable <= 731200 THEN 111357 + (v_taxable - 487450) * 0.35
            ELSE 196669.50 + (v_taxable - 731200) * 0.37
        END;
    END IF;

    RETURN round(v_tax / v_periods, 2) + COALESCE(p_additional_wh, 0);
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_calculate_fica(
    p_gross_pay numeric,
    p_ytd_gross numeric
)
RETURNS numeric(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_taxable numeric;
BEGIN
    IF p_ytd_gross >= 168600 THEN
        RETURN 0;
    END IF;

    v_taxable := LEAST(p_gross_pay, 168600 - p_ytd_gross);
    RETURN round(v_taxable * 0.062, 2);
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_calculate_medicare(
    p_gross_pay numeric,
    p_ytd_gross numeric
)
RETURNS numeric(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_base_tax numeric;
    v_additional_tax numeric := 0;
BEGIN
    v_base_tax := round(p_gross_pay * 0.0145, 2);

    IF p_ytd_gross + p_gross_pay > 200000 THEN
        IF p_ytd_gross >= 200000 THEN
            v_additional_tax := round(p_gross_pay * 0.009, 2);
        ELSE
            v_additional_tax := round(
                (p_ytd_gross + p_gross_pay - 200000) * 0.009,
                2
            );
        END IF;
    END IF;

    RETURN v_base_tax + v_additional_tax;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_get_ytd_earnings(
    p_emp_id integer,
    p_tax_year integer DEFAULT extract(YEAR FROM current_date)::integer
)
RETURNS numeric(15, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ytd numeric(15, 2);
BEGIN
    SELECT COALESCE(SUM(pd.amount), 0)
    INTO v_ytd
    FROM "$(NS)".payroll_details AS pd
    INNER JOIN "$(NS)".payroll_runs AS pr
        ON pd.run_id = pr.run_id
    INNER JOIN "$(NS)".pay_periods AS pp
        ON pr.period_id = pp.period_id
    WHERE
        pd.emp_id = p_emp_id
        AND pd.element_type = 'EARNING'
        AND pd.status = 'CALCULATED'
        AND extract(year FROM pp.period_start_date) = p_tax_year;

    RETURN v_ytd;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_create_payroll_run(
    p_period_id integer,
    p_run_type varchar DEFAULT 'REGULAR',
    p_user varchar DEFAULT current_user
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id integer;
    v_status varchar(20);
BEGIN
    SELECT pp.status
    INTO v_status
    FROM "$(NS)".pay_periods AS pp
    WHERE pp.period_id = p_period_id;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Unknown pay period: %', p_period_id;
    ELSIF v_status = 'CLOSED' THEN
        RAISE EXCEPTION 'Cannot create run for closed period: %', p_period_id;
    END IF;

    v_run_id := nextval('"$(NS)".seq_payroll_run');

    INSERT INTO "$(NS)".payroll_runs (
        run_id,
        period_id,
        run_type,
        run_date,
        status
    )
    VALUES (
        v_run_id,
        p_period_id,
        p_run_type,
        current_date,
        'PENDING'
    );

    RAISE NOTICE 'Payroll run % created by %', v_run_id, p_user;
    RETURN v_run_id;
END;
$$;

CREATE OR REPLACE PROCEDURE "$(NS)".sp_calculate_employee_pay(
    p_run_id integer,
    p_emp_id integer,
    p_period_id integer,
    p_user varchar DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_annual_salary numeric;
    v_period_gross numeric;
    v_period_end date;
    v_pay_frequency varchar(20);
    v_periods_per_year integer;
    v_federal_tax numeric;
    v_social_security_tax numeric;
    v_medicare_tax numeric;
    v_ytd_gross numeric;
    v_base_element_id integer;
    v_federal_element_id integer;
    v_ss_element_id integer;
    v_medicare_element_id integer;
BEGIN
    SELECT
        pp.period_end_date,
        pp.pay_frequency
    INTO
        v_period_end,
        v_pay_frequency
    FROM "$(NS)".pay_periods AS pp
    WHERE pp.period_id = p_period_id;

    IF v_period_end IS NULL THEN
        RAISE EXCEPTION 'Unknown pay period: %', p_period_id;
    END IF;

    v_periods_per_year := CASE v_pay_frequency
        WHEN 'WEEKLY' THEN 52
        WHEN 'BIWEEKLY' THEN 26
        WHEN 'SEMIMONTHLY' THEN 24
        WHEN 'MONTHLY' THEN 12
        ELSE 12
    END;

    v_annual_salary := "$(NS)".fn_payroll_salary_as_of(
        p_emp_id,
        v_period_end
    );

    IF v_annual_salary = 0 THEN
        RAISE EXCEPTION 'No active salary record for employee %', p_emp_id;
    END IF;

    SELECT pe.element_id
    INTO v_base_element_id
    FROM "$(NS)".pay_elements AS pe
    WHERE pe.element_code = 'BASE';

    SELECT pe.element_id
    INTO v_federal_element_id
    FROM "$(NS)".pay_elements AS pe
    WHERE pe.element_code = 'FED_TAX';

    SELECT pe.element_id
    INTO v_ss_element_id
    FROM "$(NS)".pay_elements AS pe
    WHERE pe.element_code = 'SS_TAX';

    SELECT pe.element_id
    INTO v_medicare_element_id
    FROM "$(NS)".pay_elements AS pe
    WHERE pe.element_code = 'MEDICARE';

    v_period_gross := round(v_annual_salary / v_periods_per_year, 2);

    INSERT INTO "$(NS)".payroll_details (
        detail_id,
        run_id,
        emp_id,
        element_id,
        element_type,
        amount,
        status
    )
    VALUES (
        nextval('"$(NS)".seq_payroll_detail'),
        p_run_id,
        p_emp_id,
        v_base_element_id,
        'EARNING',
        v_period_gross,
        'CALCULATED'
    );

    v_ytd_gross := "$(NS)".fn_get_ytd_earnings(
        p_emp_id,
        extract(year FROM v_period_end)::integer
    );
    v_federal_tax := "$(NS)".fn_calculate_federal_tax(
        v_period_gross,
        'SINGLE',
        0,
        0,
        v_pay_frequency
    );
    v_social_security_tax := "$(NS)".fn_calculate_fica(
        v_period_gross,
        v_ytd_gross
    );
    v_medicare_tax := "$(NS)".fn_calculate_medicare(
        v_period_gross,
        v_ytd_gross
    );

    IF v_federal_tax > 0 THEN
        INSERT INTO "$(NS)".payroll_details (
            detail_id,
            run_id,
            emp_id,
            element_id,
            element_type,
            amount,
            status
        )
        VALUES (
            nextval('"$(NS)".seq_payroll_detail'),
            p_run_id,
            p_emp_id,
            v_federal_element_id,
            'TAX',
            -v_federal_tax,
            'CALCULATED'
        );
    END IF;

    IF v_social_security_tax > 0 THEN
        INSERT INTO "$(NS)".payroll_details (
            detail_id,
            run_id,
            emp_id,
            element_id,
            element_type,
            amount,
            status
        )
        VALUES (
            nextval('"$(NS)".seq_payroll_detail'),
            p_run_id,
            p_emp_id,
            v_ss_element_id,
            'TAX',
            -v_social_security_tax,
            'CALCULATED'
        );
    END IF;

    IF v_medicare_tax > 0 THEN
        INSERT INTO "$(NS)".payroll_details (
            detail_id,
            run_id,
            emp_id,
            element_id,
            element_type,
            amount,
            status
        )
        VALUES (
            nextval('"$(NS)".seq_payroll_detail'),
            p_run_id,
            p_emp_id,
            v_medicare_element_id,
            'TAX',
            -v_medicare_tax,
            'CALCULATED'
        );
    END IF;

    RAISE NOTICE 'Calculated employee % in run % by %',
        p_emp_id,
        p_run_id,
        p_user;
END;
$$;

CREATE OR REPLACE PROCEDURE "$(NS)".sp_calculate_payroll(
    p_run_id integer,
    p_user varchar DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_period_id integer;
    v_employee_count integer := 0;
    v_error_count integer := 0;
    v_deleted_count integer;
    v_updated_count integer;
    emp_rec record;
BEGIN
    SELECT pr.period_id
    INTO v_period_id
    FROM "$(NS)".payroll_runs AS pr
    WHERE pr.run_id = p_run_id;

    IF v_period_id IS NULL THEN
        RAISE EXCEPTION 'Unknown payroll run: %', p_run_id;
    END IF;

    DELETE FROM "$(NS)".payroll_details
    WHERE run_id = p_run_id;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    UPDATE "$(NS)".payroll_runs
    SET status = 'CALCULATING'
    WHERE run_id = p_run_id;

    FOR emp_rec IN
        SELECT e.emp_id
        FROM "$(NS)".employees AS e
        WHERE
            e.employment_status = 'ACTIVE'
            AND e.active_flag = 'Y'
        ORDER BY e.emp_id
    LOOP
        BEGIN
            CALL "$(NS)".sp_calculate_employee_pay(
                p_run_id,
                emp_rec.emp_id,
                v_period_id,
                p_user
            );
            v_employee_count := v_employee_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                v_error_count := v_error_count + 1;
                RAISE NOTICE 'Payroll calculation failed for employee %: %',
                    emp_rec.emp_id,
                    SQLERRM;
        END;
    END LOOP;

    UPDATE "$(NS)".payroll_runs
    SET
        status = CASE
            WHEN v_error_count > 0 THEN 'ERROR'
            ELSE 'CALCULATED'
        END,
        employee_count = v_employee_count,
        total_gross = (
            SELECT COALESCE(
                SUM(
                    CASE
                        WHEN pd.element_type = 'EARNING' THEN pd.amount
                        ELSE 0
                    END
                ),
                0
            )
            FROM "$(NS)".payroll_details AS pd
            WHERE
                pd.run_id = p_run_id
                AND pd.status != 'ERROR'
        ),
        total_deductions = (
            SELECT COALESCE(
                SUM(
                    CASE
                        WHEN pd.element_type IN ('DEDUCTION', 'TAX', 'BENEFIT')
                            THEN ABS(pd.amount)
                        ELSE 0
                    END
                ),
                0
            )
            FROM "$(NS)".payroll_details AS pd
            WHERE
                pd.run_id = p_run_id
                AND pd.status != 'ERROR'
        ),
        total_net = (
            SELECT COALESCE(
                SUM(
                    CASE
                        WHEN pd.element_type = 'EARNING' THEN pd.amount
                        WHEN pd.element_type IN ('DEDUCTION', 'TAX', 'BENEFIT')
                            THEN -ABS(pd.amount)
                        WHEN pd.element_type = 'REIMBURSEMENT' THEN pd.amount
                        ELSE 0
                    END
                ),
                0
            )
            FROM "$(NS)".payroll_details AS pd
            WHERE
                pd.run_id = p_run_id
                AND pd.status != 'ERROR'
        )
    WHERE run_id = p_run_id;
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    RAISE NOTICE
        'Payroll run % calculated: employees=%, errors=%, replaced_details=%, updated_runs=%',
        p_run_id,
        v_employee_count,
        v_error_count,
        v_deleted_count,
        v_updated_count;
END;
$$;

CREATE OR REPLACE PROCEDURE "$(NS)".sp_approve_payroll(
    p_run_id integer,
    p_user varchar DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status varchar(20);
    v_updated_count integer;
BEGIN
    SELECT pr.status
    INTO v_status
    FROM "$(NS)".payroll_runs AS pr
    WHERE pr.run_id = p_run_id
    FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Unknown payroll run: %', p_run_id;
    ELSIF v_status != 'CALCULATED' THEN
        RAISE EXCEPTION 'Cannot approve run in status: %', v_status;
    END IF;

    UPDATE "$(NS)".payroll_runs
    SET status = 'APPROVED'
    WHERE run_id = p_run_id;
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    RAISE NOTICE 'Approved payroll run % by %; rows=%',
        p_run_id,
        p_user,
        v_updated_count;
END;
$$;

CREATE OR REPLACE PROCEDURE "$(NS)".sp_reverse_payroll(
    p_run_id integer,
    p_reason varchar,
    p_user varchar DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_updated_count integer;
    v_detail_count integer;
BEGIN
    UPDATE "$(NS)".payroll_runs
    SET status = 'REVERSED'
    WHERE run_id = p_run_id;
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    IF v_updated_count = 0 THEN
        RAISE EXCEPTION 'Unknown payroll run: %', p_run_id;
    END IF;

    UPDATE "$(NS)".payroll_details
    SET status = 'REVERSED'
    WHERE run_id = p_run_id;
    GET DIAGNOSTICS v_detail_count = ROW_COUNT;

    RAISE NOTICE 'Reversed payroll run % by %: reason=%, details=%',
        p_run_id,
        p_user,
        p_reason,
        v_detail_count;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".fn_pay_register(
    p_run_id integer
)
RETURNS TABLE (
    emp_number varchar,
    employee_name text,
    department varchar,
    gross_pay numeric,
    federal_tax numeric,
    state_tax numeric,
    social_security numeric,
    medicare numeric,
    deductions numeric,
    net_pay numeric
)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE
        'Pay register % returned as a rowset; export with client-side COPY',
        p_run_id;

    RETURN QUERY
    SELECT
        e.emp_number,
        "$(NS)".fn_employee_full_name(e.first_name, e.last_name),
        d.dept_name,
        SUM(
            CASE
                WHEN pd.element_type = 'EARNING' THEN pd.amount
                ELSE 0
            END
        ),
        SUM(
            CASE
                WHEN pe.element_code = 'FED_TAX' THEN ABS(pd.amount)
                ELSE 0
            END
        ),
        SUM(
            CASE
                WHEN pe.element_code = 'STATE_TAX' THEN ABS(pd.amount)
                ELSE 0
            END
        ),
        SUM(
            CASE
                WHEN pe.element_code = 'SS_TAX' THEN ABS(pd.amount)
                ELSE 0
            END
        ),
        SUM(
            CASE
                WHEN pe.element_code = 'MEDICARE' THEN ABS(pd.amount)
                ELSE 0
            END
        ),
        SUM(
            CASE
                WHEN pd.element_type IN ('DEDUCTION', 'BENEFIT')
                    THEN ABS(pd.amount)
                ELSE 0
            END
        ),
        SUM(pd.amount)
    FROM "$(NS)".payroll_details AS pd
    INNER JOIN "$(NS)".pay_elements AS pe
        ON pd.element_id = pe.element_id
    INNER JOIN "$(NS)".employees AS e
        ON pd.emp_id = e.emp_id
    INNER JOIN "$(NS)".departments AS d
        ON e.dept_id = d.dept_id
    WHERE
        pd.run_id = p_run_id
        AND pd.status != 'ERROR'
    GROUP BY
        e.emp_number,
        e.first_name,
        e.last_name,
        d.dept_name
    ORDER BY e.last_name;
END;
$$;
