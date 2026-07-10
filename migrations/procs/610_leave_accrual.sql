/*=====================================================================
  610_leave_accrual.sql — PostgreSQL conversion of PKG_LEAVE accrual routines
  Source: ts-plsql-oracle-forms-hrms/plsql/packages/PKG_LEAVE.pkb

  Conversions applied:
    - Package units -> schema-scoped PL/pgSQL routines
    - SYSDATE -> current_date / clock_timestamp()
    - NVL and nullable arithmetic -> explicit COALESCE
    - SEQ_*.NEXTVAL -> nextval(schema-qualified regclass)
    - SQL%ROWCOUNT -> GET DIAGNOSTICS ... = ROW_COUNT
    - DBMS_OUTPUT.PUT_LINE -> RAISE NOTICE
    - ADD_MONTHS -> make_date + make_interval
    - DUP_VAL_ON_INDEX -> unique_violation
    - GREATEST and LEAST retained with explicit NULL guards

  Transaction control is caller-managed rather than reproducing Oracle's
  periodic COMMIT behavior inside the accrual routine.
=====================================================================*/

CREATE OR REPLACE FUNCTION "$(NS)".fn_get_leave_balance(
    p_emp_id integer,
    p_leave_type_id integer,
    p_year integer DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::integer
) RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_balance numeric;
BEGIN
    SELECT
        COALESCE(lb.opening_balance, 0)
        + COALESCE(lb.accrued, 0)
        - COALESCE(lb.used, 0)
        + COALESCE(lb.adjustment, 0)
        - COALESCE(lb.pending, 0)
    INTO STRICT v_balance
    FROM "$(NS)".leave_balances AS lb
    WHERE
        lb.emp_id = p_emp_id
        AND lb.leave_type_id = p_leave_type_id
        AND lb.calendar_year = p_year;

    RETURN COALESCE(v_balance, 0);
EXCEPTION
    WHEN no_data_found THEN
        RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".sp_initialize_leave_balances(  -- noqa: PRS
    p_emp_id integer,
    p_year integer,
    p_user text DEFAULT SESSION_USER
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    lt record;
BEGIN
    FOR lt IN
        SELECT leave_type_id
        FROM "$(NS)".leave_types
        WHERE active_flag = 'Y'
    LOOP
        BEGIN
            INSERT INTO "$(NS)".leave_balances (
                balance_id,
                emp_id,
                leave_type_id,
                calendar_year,
                opening_balance,
                accrued,
                used,
                adjustment,
                pending,
                created_by,
                created_date
            ) VALUES (
                nextval('"$(NS)".seq_leave_balance'::regclass),
                p_emp_id,
                lt.leave_type_id,
                p_year,
                0,
                0,
                0,
                0,
                0,
                p_user,
                clock_timestamp()
            );
        EXCEPTION
            WHEN unique_violation THEN
                NULL;
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".sp_run_monthly_leave_accrual(
    p_accrual_date date DEFAULT CURRENT_DATE,
    p_user text DEFAULT SESSION_USER
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    emp_rec record;
    lt_rec record;
    v_accrued numeric := 0;
    v_current_balance numeric;
    v_rows_updated bigint;
    v_total_employees integer := 0;
    v_total_accrued numeric := 0;
BEGIN
    RAISE NOTICE 'Starting monthly leave accrual for %',
        to_char(p_accrual_date, 'YYYY-MM');

    FOR emp_rec IN
        SELECT e.emp_id, e.hire_date
        FROM "$(NS)".employees AS e
        WHERE
            e.employment_status = 'ACTIVE'
            AND e.active_flag = 'Y'
    LOOP
        v_total_employees := v_total_employees + 1;

        FOR lt_rec IN
            SELECT
                lt.leave_type_id,
                lt.accrual_rate,
                lt.max_balance,
                lt.min_tenure_days
            FROM "$(NS)".leave_types AS lt
            WHERE
                lt.active_flag = 'Y'
                AND lt.accrual_flag = 'Y'
                AND lt.accrual_frequency = 'MONTHLY'
        LOOP
            IF
                p_accrual_date - emp_rec.hire_date
                >= COALESCE(lt_rec.min_tenure_days, 0)
            THEN
                v_current_balance := "$(NS)".fn_get_leave_balance(
                    emp_rec.emp_id,
                    lt_rec.leave_type_id,
                    extract(year FROM p_accrual_date)::integer
                );

                IF
                    lt_rec.max_balance IS NULL
                    OR v_current_balance + COALESCE(lt_rec.accrual_rate, 0)
                    <= lt_rec.max_balance
                THEN
                    v_accrued := COALESCE(lt_rec.accrual_rate, 0);
                ELSE
                    v_accrued := GREATEST(
                        0::numeric,
                        lt_rec.max_balance - v_current_balance
                    );
                END IF;

                IF v_accrued > 0 THEN
                    UPDATE "$(NS)".leave_balances
                    SET
                        accrued = COALESCE(accrued, 0) + v_accrued,
                        modified_by = p_user,
                        modified_date = clock_timestamp()
                    WHERE
                        emp_id = emp_rec.emp_id
                        AND leave_type_id = lt_rec.leave_type_id
                        AND calendar_year
                        = extract(year FROM p_accrual_date)::integer;

                    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

                    IF v_rows_updated = 0 THEN
                        PERFORM "$(NS)".sp_initialize_leave_balances(
                            emp_rec.emp_id,
                            extract(year FROM p_accrual_date)::integer,
                            p_user
                        );

                        UPDATE "$(NS)".leave_balances
                        SET
                            accrued = v_accrued,
                            modified_by = p_user,
                            modified_date = clock_timestamp()
                        WHERE
                            emp_id = emp_rec.emp_id
                            AND leave_type_id = lt_rec.leave_type_id
                            AND calendar_year
                            = extract(year FROM p_accrual_date)::integer;
                    END IF;

                    INSERT INTO "$(NS)".leave_accrual_log (
                        accrual_id,
                        emp_id,
                        leave_type_id,
                        accrual_date,
                        accrual_amount,
                        balance_after,
                        created_by,
                        created_date
                    ) VALUES (
                        nextval('"$(NS)".seq_leave_accrual'::regclass),
                        emp_rec.emp_id,
                        lt_rec.leave_type_id,
                        p_accrual_date,
                        v_accrued,
                        v_current_balance + v_accrued,
                        p_user,
                        clock_timestamp()
                    );

                    v_total_accrued := v_total_accrued + v_accrued;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Accrual complete: % employees, % total days accrued',
        v_total_employees,
        v_total_accrued;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".sp_process_leave_carryover(
    p_year integer,
    p_user text DEFAULT SESSION_USER
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    bal_rec record;
    v_next_year integer := p_year + 1;
    v_carryover numeric;
BEGIN
    FOR bal_rec IN
        SELECT
            lb.emp_id,
            lb.leave_type_id,
            COALESCE(lb.opening_balance, 0)
                + COALESCE(lb.accrued, 0)
                - COALESCE(lb.used, 0)
                + COALESCE(lb.adjustment, 0) AS remaining,
            lt.carryover_max,
            lt.carryover_expiry
        FROM "$(NS)".leave_balances AS lb
        INNER JOIN "$(NS)".leave_types AS lt
            ON lb.leave_type_id = lt.leave_type_id
        WHERE
            lb.calendar_year = p_year
            AND (
                COALESCE(lb.opening_balance, 0)
                + COALESCE(lb.accrued, 0)
                - COALESCE(lb.used, 0)
                + COALESCE(lb.adjustment, 0)
            ) > 0
    LOOP
        v_carryover := bal_rec.remaining;

        IF bal_rec.carryover_max IS NOT NULL THEN
            v_carryover := LEAST(v_carryover, bal_rec.carryover_max);
        END IF;

        IF v_carryover > 0 THEN
            PERFORM "$(NS)".sp_initialize_leave_balances(
                bal_rec.emp_id,
                v_next_year,
                p_user
            );

            UPDATE "$(NS)".leave_balances
            SET
                carryover_from_prev = v_carryover,
                opening_balance = v_carryover,
                carryover_expiry_dt = CASE
                    WHEN bal_rec.carryover_expiry IS NOT NULL
                        THEN (
                            make_date(v_next_year, 1, 1)
                            + make_interval(months => bal_rec.carryover_expiry)
                        )::date
                    ELSE NULL
                END,
                modified_by = p_user,
                modified_date = clock_timestamp()
            WHERE
                emp_id = bal_rec.emp_id
                AND leave_type_id = bal_rec.leave_type_id
                AND calendar_year = v_next_year;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION "$(NS)".sp_expire_leave_carryover(
    p_user text DEFAULT SESSION_USER
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "$(NS)".leave_balances
    SET
        adjustment = COALESCE(adjustment, 0)
            - COALESCE(carryover_from_prev, 0),
        carryover_from_prev = 0,
        modified_by = p_user,
        modified_date = clock_timestamp()
    WHERE
        carryover_expiry_dt <= current_date
        AND COALESCE(carryover_from_prev, 0) > 0;
END;
$$;
