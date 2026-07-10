"""
generate_and_load.py — Deterministic synthetic HRMS data seeder (PostgreSQL).

Populates the PostgreSQL ``raw`` schema with HR data that exercises every
Oracle-to-PostgreSQL conversion gotcha the demo relies on:

  - Active employees WITH and WITHOUT a current salary record
    (the Oracle ``LEFT JOIN SALARY_RECORDS`` → naive ``INNER JOIN`` trap).
  - A self-referencing manager hierarchy rooted at a single CEO
    (Oracle ``CONNECT BY`` → PostgreSQL recursive CTE).
  - A latest APPROVED payroll run whose detail rows must foot to the run
    control totals (SUM/CASE sign-handling parity).
  - Leave balances whose available = opening + accrued - used + adjustment
    - pending is always non-negative (business-rule parity).

The data is deterministic (fixed RNG seed) so reconciliation controls produce
stable, reproducible results across runs.

Usage:
    python seed/generate_and_load.py                 # default: raw schema
    python seed/generate_and_load.py --schema raw
    python seed/generate_and_load.py --dry-run       # print counts, no execute

Environment variables:
    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

from __future__ import annotations

import argparse
import os
import random
import re
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:  # pragma: no cover - import guard
    psycopg2 = None  # type: ignore[assignment]
    execute_values = None  # type: ignore[assignment]

try:
    from faker import Faker
except ImportError:  # pragma: no cover - import guard
    Faker = None  # type: ignore[assignment,misc]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SEED = 42
DEPARTMENT_COUNT = 12
EMPLOYEE_COUNT = 300
CALENDAR_YEAR = 2024
BASE_DATE = date(2024, 6, 30)

STATES = ["CA", "TX", "FL", "NY", "IL", "PA", "OH"]
LOCATIONS = [
    ("NYC", "New York HQ", "New York", "NY", "USA"),
    ("SFO", "San Francisco", "San Francisco", "CA", "USA"),
    ("AUS", "Austin", "Austin", "TX", "USA"),
]
EMPLOYMENT_TYPES = ["FULL_TIME", "FULL_TIME", "FULL_TIME", "PART_TIME", "CONTRACT"]

# Fraction of ACTIVE employees that have a *current* salary record. The rest
# have no current salary row — these are the employees that silently vanish if
# the VW_ACTIVE_EMPLOYEES LEFT JOIN is converted to an INNER JOIN.
CURRENT_SALARY_PROBABILITY = 0.80

LEAVE_TYPES = [
    (1, "ANNUAL", "Annual Leave", "Y", Decimal("1.67"), Decimal("30.0")),
    (2, "SICK", "Sick Leave", "Y", Decimal("0.83"), Decimal("15.0")),
    (3, "PERSONAL", "Personal Day", "Y", Decimal("0.42"), Decimal("5.0")),
]

PAY_ELEMENTS = [
    (1, "BASE", "Base Salary", "EARNING"),
    (2, "BONUS", "Bonus", "EARNING"),
    (3, "FED_TAX", "Federal Tax", "TAX"),
    (4, "STATE_TAX", "State Tax", "TAX"),
    (5, "HEALTH", "Health Insurance", "DEDUCTION"),
    (6, "K401", "401(k) Contribution", "DEDUCTION"),
]

# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class Department:
    dept_id: int
    dept_code: str
    dept_name: str
    parent_dept_id: int | None
    cost_center: str
    location_code: str


@dataclass
class JobGrade:
    grade_id: int
    grade_code: str
    grade_name: str
    min_salary: Decimal
    max_salary: Decimal
    overtime_eligible: str


@dataclass
class JobTitle:
    job_id: int
    job_code: str
    job_title: str
    job_family: str
    grade_id: int
    flsa_status: str


@dataclass
class Employee:
    emp_id: int
    emp_number: str
    first_name: str
    last_name: str
    email: str
    phone_work: str
    phone_mobile: str
    hire_date: date
    termination_date: date | None
    dept_id: int
    job_id: int
    manager_emp_id: int | None
    location_code: str
    employment_type: str
    employment_status: str
    active_flag: str


@dataclass
class SalaryRecord:
    salary_id: int
    emp_id: int
    effective_date: date
    end_date: date | None
    base_salary: Decimal
    currency_code: str
    pay_frequency: str
    active_flag: str


@dataclass
class LeaveBalance:
    balance_id: int
    emp_id: int
    leave_type_id: int
    calendar_year: int
    opening_balance: Decimal
    accrued: Decimal
    used: Decimal
    adjustment: Decimal
    pending: Decimal


@dataclass
class PayrollDetail:
    detail_id: int
    run_id: int
    emp_id: int
    element_id: int
    element_type: str
    amount: Decimal


@dataclass
class SeedData:
    departments: list[Department] = field(default_factory=list)
    job_grades: list[JobGrade] = field(default_factory=list)
    job_titles: list[JobTitle] = field(default_factory=list)
    employees: list[Employee] = field(default_factory=list)
    salary_records: list[SalaryRecord] = field(default_factory=list)
    leave_balances: list[LeaveBalance] = field(default_factory=list)
    payroll_details: list[PayrollDetail] = field(default_factory=list)
    # Latest approved payroll run control totals (derived from details).
    run_total_gross: Decimal = Decimal(0)
    run_total_deductions: Decimal = Decimal(0)
    run_total_net: Decimal = Decimal(0)
    run_employee_count: int = 0


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------


def generate(seed: int = SEED) -> SeedData:
    """Generate deterministic synthetic HRMS data."""
    if Faker is None:
        raise ImportError("Faker is required: pip install Faker")
    rng = random.Random(seed)
    fake = Faker()
    Faker.seed(seed)
    data = SeedData()

    # --- Job grades ---
    grade_specs = [
        ("G1", "Entry", 45000, 70000, "Y"),
        ("G2", "Associate", 60000, 95000, "Y"),
        ("G3", "Senior", 85000, 135000, "N"),
        ("G4", "Lead", 120000, 180000, "N"),
        ("G5", "Director", 160000, 250000, "N"),
    ]
    for i, (code, name, lo, hi, ot) in enumerate(grade_specs, start=1):
        data.job_grades.append(
            JobGrade(i, code, name, Decimal(lo), Decimal(hi), ot)
        )

    # --- Job titles (one per grade family) ---
    families = ["Engineering", "Finance", "Operations", "Sales", "People"]
    job_id = 1
    for fam in families:
        for g in data.job_grades:
            data.job_titles.append(
                JobTitle(
                    job_id=job_id,
                    job_code=f"{fam[:3].upper()}-{g.grade_code}",
                    job_title=f"{fam} {g.grade_name}",
                    job_family=fam,
                    grade_id=g.grade_id,
                    flsa_status="EXEMPT" if g.overtime_eligible == "N" else "NON_EXEMPT",
                )
            )
            job_id += 1

    # --- Departments (dept 1 is the root, others report to it) ---
    for i in range(1, DEPARTMENT_COUNT + 1):
        data.departments.append(
            Department(
                dept_id=i,
                dept_code=f"D{i:03d}",
                dept_name=f"{rng.choice(families)} {rng.choice(['Group', 'Team', 'Division'])} {i}",
                parent_dept_id=None if i == 1 else 1,
                cost_center=f"CC{1000 + i}",
                location_code=rng.choice([loc[0] for loc in LOCATIONS]),
            )
        )

    # --- Employees ---
    # emp 10000 is the CEO (manager NULL, root of the org tree).
    ceo_id = 10000
    active_emp_ids: list[int] = []
    for n in range(EMPLOYEE_COUNT):
        emp_id = ceo_id + n
        is_ceo = n == 0

        hire = BASE_DATE - timedelta(days=rng.randint(120, 5400))
        job = rng.choice(data.job_titles)

        # ~7% of employees are terminated (inactive).
        terminated = (not is_ceo) and rng.random() < 0.07
        term_date = None
        status = "ACTIVE"
        active = "Y"
        if terminated:
            term_date = hire + timedelta(days=rng.randint(200, 3000))
            status = "TERMINATED"
            active = "N"

        # Manager: the CEO reports to nobody; everyone else reports to an
        # already-created ACTIVE employee. Picking only active managers keeps
        # every active employee reachable from the CEO through active links,
        # so the converted recursive-CTE org hierarchy covers all of them.
        manager = None if is_ceo else rng.choice(active_emp_ids)

        data.employees.append(
            Employee(
                emp_id=emp_id,
                emp_number=f"EMP-{emp_id}",
                first_name=fake.first_name(),
                last_name=fake.last_name(),
                email=fake.unique.email(),
                phone_work=f"+1-212-555-{n:04d}",
                phone_mobile=f"+1-917-555-{n:04d}",
                hire_date=hire,
                termination_date=term_date,
                dept_id=rng.randint(1, DEPARTMENT_COUNT),
                job_id=job.job_id,
                manager_emp_id=manager,
                location_code=rng.choice([loc[0] for loc in LOCATIONS]),
                employment_type="FULL_TIME" if is_ceo else rng.choice(EMPLOYMENT_TYPES),
                employment_status=status,
                active_flag=active,
            )
        )
        if status == "ACTIVE":
            active_emp_ids.append(emp_id)

    # --- Salary records ---
    # Every employee gets a historical (ended) salary row. ACTIVE employees
    # additionally get a *current* row with probability CURRENT_SALARY_PROBABILITY.
    # Active employees WITHOUT a current row are the outer-join trap population.
    salary_id = 1
    grade_by_job = {j.job_id: j.grade_id for j in data.job_titles}
    grade_by_id = {g.grade_id: g for g in data.job_grades}
    for e in data.employees:
        grade = grade_by_id[grade_by_job[e.job_id]]
        band = float(grade.max_salary - grade.min_salary)
        base = Decimal(str(round(float(grade.min_salary) + rng.random() * band, 2)))

        # Historical salary row (always present, always ended).
        hist_eff = e.hire_date
        hist_end = e.hire_date + timedelta(days=365)
        data.salary_records.append(
            SalaryRecord(
                salary_id=salary_id,
                emp_id=e.emp_id,
                effective_date=hist_eff,
                end_date=hist_end,
                base_salary=(base * Decimal("0.9")).quantize(Decimal("0.01")),
                currency_code="USD",
                pay_frequency="MONTHLY",
                active_flag="N",
            )
        )
        salary_id += 1

        has_current = e.employment_status == "ACTIVE" and (
            rng.random() < CURRENT_SALARY_PROBABILITY
        )
        if has_current:
            data.salary_records.append(
                SalaryRecord(
                    salary_id=salary_id,
                    emp_id=e.emp_id,
                    effective_date=hist_end + timedelta(days=1),
                    end_date=None,
                    base_salary=base,
                    currency_code="USD",
                    pay_frequency="MONTHLY",
                    active_flag="Y",
                )
            )
            salary_id += 1

    # --- Leave balances (active employees only) ---
    balance_id = 1
    for e in data.employees:
        if e.employment_status != "ACTIVE":
            continue
        for lt_id, _code, _name, _paid, accrual_rate, _max_bal in LEAVE_TYPES:
            opening = Decimal(str(round(rng.uniform(0, 5), 1)))
            accrued = (accrual_rate * Decimal(rng.randint(1, 12))).quantize(Decimal("0.1"))
            used = Decimal(str(round(rng.uniform(0, float(opening + accrued)), 1)))
            adjustment = Decimal("0.0")
            pending = Decimal(str(round(rng.uniform(0, 2), 1)))
            # Ensure available = opening + accrued - used + adjustment - pending
            # stays non-negative: cap used + pending at the amount available to
            # draw down (opening + accrued + adjustment).
            max_out = opening + accrued + adjustment
            if used + pending > max_out:
                pending = min(pending, max_out)
                used = max_out - pending
                if used < 0:
                    used = Decimal("0.0")
            data.leave_balances.append(
                LeaveBalance(
                    balance_id=balance_id,
                    emp_id=e.emp_id,
                    leave_type_id=lt_id,
                    calendar_year=CALENDAR_YEAR,
                    opening_balance=opening,
                    accrued=accrued,
                    used=used,
                    adjustment=adjustment,
                    pending=pending,
                )
            )
            balance_id += 1

    # --- Payroll (latest approved run, run_id = 1) ---
    detail_id = 1
    gross = Decimal(0)
    deductions = Decimal(0)
    net = Decimal(0)
    paid_emps = set()
    for e in data.employees:
        if e.employment_status != "ACTIVE":
            continue
        paid_emps.add(e.emp_id)
        monthly_base = Decimal(rng.randint(4000, 18000))
        # Earnings (positive), taxes + deductions (negative).
        rows = [
            (1, "EARNING", monthly_base),
            (2, "EARNING", Decimal(rng.randint(0, 2000))),
            (3, "TAX", -(monthly_base * Decimal("0.18")).quantize(Decimal("0.01"))),
            (4, "TAX", -(monthly_base * Decimal("0.05")).quantize(Decimal("0.01"))),
            (5, "DEDUCTION", -Decimal(rng.randint(80, 400))),
            (6, "DEDUCTION", -(monthly_base * Decimal("0.04")).quantize(Decimal("0.01"))),
        ]
        for element_id, etype, amount in rows:
            data.payroll_details.append(
                PayrollDetail(detail_id, 1, e.emp_id, element_id, etype, amount)
            )
            detail_id += 1
            if etype == "EARNING":
                gross += amount
            else:
                deductions += -amount
            net += amount

    data.run_total_gross = gross
    data.run_total_deductions = deductions
    data.run_total_net = net
    data.run_employee_count = len(paid_emps)

    return data


# ---------------------------------------------------------------------------
# PostgreSQL loader
# ---------------------------------------------------------------------------


def get_connection() -> psycopg2.extensions.connection:
    """Build a psycopg2 connection from standard PG* environment variables."""
    if psycopg2 is None:
        raise ImportError("psycopg2 is required: pip install psycopg2-binary")

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "hrms"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", ""),
    )
    conn.autocommit = True
    return conn


def _validate_schema_name(name: str) -> None:
    """Reject schema names that are not safe identifiers."""
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError(f"Invalid schema name: {name!r}")


RAW_DDL = """
DROP SCHEMA IF EXISTS {schema} CASCADE;
CREATE SCHEMA {schema};

CREATE TABLE {schema}.locations (
    location_code  varchar(10) PRIMARY KEY,
    location_name  varchar(100) NOT NULL,
    address_line1  varchar(200),
    address_line2  varchar(200),
    city           varchar(100),
    state_province varchar(100),
    postal_code    varchar(20),
    country_code   varchar(3),
    phone_number   varchar(30),
    timezone       varchar(50) DEFAULT 'America/New_York',
    active_flag    char(1) DEFAULT 'Y' NOT NULL,
    created_by     varchar(30),
    created_date   timestamptz DEFAULT now() NOT NULL,
    modified_by    varchar(30),
    modified_date  timestamptz
);

CREATE TABLE {schema}.job_grades (
    grade_id          integer PRIMARY KEY,
    grade_code        varchar(10) NOT NULL,
    grade_name        varchar(50) NOT NULL,
    min_salary        numeric(12,2) NOT NULL,
    max_salary        numeric(12,2) NOT NULL,
    overtime_eligible char(1) DEFAULT 'N'
);

CREATE TABLE {schema}.job_titles (
    job_id      integer PRIMARY KEY,
    job_code    varchar(20) NOT NULL,
    job_title   varchar(100) NOT NULL,
    job_family  varchar(50),
    grade_id    integer NOT NULL REFERENCES {schema}.job_grades (grade_id),
    flsa_status varchar(20) DEFAULT 'EXEMPT'
);

CREATE TABLE {schema}.departments (
    dept_id        integer PRIMARY KEY,
    dept_code      varchar(20) NOT NULL,
    dept_name      varchar(100) NOT NULL,
    parent_dept_id integer,
    cost_center    varchar(20),
    location_code  varchar(10)
);

CREATE TABLE {schema}.employees (
    emp_id            integer PRIMARY KEY,
    emp_number        varchar(20) NOT NULL,
    first_name        varchar(50) NOT NULL,
    last_name         varchar(50) NOT NULL,
    email             varchar(100),
    phone_work        varchar(30),
    phone_mobile      varchar(30),
    hire_date         date NOT NULL,
    termination_date  date,
    dept_id           integer NOT NULL REFERENCES {schema}.departments (dept_id),
    job_id            integer NOT NULL REFERENCES {schema}.job_titles (job_id),
    manager_emp_id    integer REFERENCES {schema}.employees (emp_id),
    location_code     varchar(10) REFERENCES {schema}.locations (location_code),
    employment_type   varchar(20) DEFAULT 'FULL_TIME',
    employment_status varchar(20) DEFAULT 'ACTIVE',
    active_flag       char(1) DEFAULT 'Y' NOT NULL
);

CREATE TABLE {schema}.salary_records (
    salary_id      integer PRIMARY KEY,
    emp_id         integer NOT NULL REFERENCES {schema}.employees (emp_id),
    effective_date date NOT NULL,
    end_date       date,
    base_salary    numeric(12,2) NOT NULL,
    currency_code  varchar(3) DEFAULT 'USD',
    pay_frequency  varchar(20) DEFAULT 'MONTHLY',
    active_flag    char(1) DEFAULT 'Y' NOT NULL
);

CREATE TABLE {schema}.leave_types (
    leave_type_id   integer PRIMARY KEY,
    leave_type_code varchar(20) NOT NULL,
    leave_type_name varchar(50) NOT NULL,
    paid_flag       char(1) DEFAULT 'Y',
    accrual_rate    numeric(6,2),
    max_balance     numeric(6,2)
);

CREATE TABLE {schema}.leave_balances (
    balance_id      integer PRIMARY KEY,
    emp_id          integer NOT NULL REFERENCES {schema}.employees (emp_id),
    leave_type_id   integer NOT NULL REFERENCES {schema}.leave_types (leave_type_id),
    calendar_year   integer NOT NULL,
    opening_balance numeric(6,2) DEFAULT 0,
    accrued         numeric(6,2) DEFAULT 0,
    used            numeric(6,2) DEFAULT 0,
    adjustment      numeric(6,2) DEFAULT 0,
    pending         numeric(6,2) DEFAULT 0
);

CREATE TABLE {schema}.pay_elements (
    element_id   integer PRIMARY KEY,
    element_code varchar(30) NOT NULL,
    element_name varchar(100) NOT NULL,
    element_type varchar(20) NOT NULL
);

CREATE TABLE {schema}.pay_periods (
    period_id         integer PRIMARY KEY,
    period_name       varchar(50) NOT NULL,
    pay_frequency     varchar(20) NOT NULL,
    period_start_date date NOT NULL,
    period_end_date   date NOT NULL,
    pay_date          date NOT NULL,
    status            varchar(20) DEFAULT 'OPEN'
);

CREATE TABLE {schema}.payroll_runs (
    run_id           integer PRIMARY KEY,
    period_id        integer NOT NULL REFERENCES {schema}.pay_periods (period_id),
    run_type         varchar(20) DEFAULT 'REGULAR',
    run_date         date NOT NULL,
    status           varchar(20) DEFAULT 'PENDING',
    total_gross      numeric(15,2),
    total_deductions numeric(15,2),
    total_net        numeric(15,2),
    employee_count   integer
);

CREATE TABLE {schema}.payroll_details (
    detail_id    integer PRIMARY KEY,
    run_id       integer NOT NULL REFERENCES {schema}.payroll_runs (run_id),
    emp_id       integer NOT NULL REFERENCES {schema}.employees (emp_id),
    element_id   integer NOT NULL REFERENCES {schema}.pay_elements (element_id),
    element_type varchar(20) NOT NULL,
    amount       numeric(12,2) NOT NULL,
    status       varchar(20) DEFAULT 'CALCULATED'
);
"""


def load(data: SeedData, schema: str = "raw", dry_run: bool = False) -> None:
    """Load generated data into PostgreSQL under ``schema``."""
    _validate_schema_name(schema)

    if dry_run:
        print(
            f"[DRY RUN] Would load {len(data.departments)} departments, "
            f"{len(data.job_titles)} job titles, {len(data.employees)} employees, "
            f"{len(data.salary_records)} salary records, "
            f"{len(data.leave_balances)} leave balances, "
            f"{len(data.payroll_details)} payroll details into [{schema}]"
        )
        return

    conn = get_connection()
    cur = conn.cursor()
    print(f"Loading into [{schema}] schema...")
    cur.execute(RAW_DDL.format(schema=schema))

    execute_values(
        cur,
        f"INSERT INTO {schema}.locations "
        f"(location_code, location_name, city, state_province, country_code, "
        f"active_flag, created_by) VALUES %s",
        [
            (code, name, city, state, country, "Y", "SEED")
            for code, name, city, state, country in LOCATIONS
        ],
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.job_grades "
        f"(grade_id, grade_code, grade_name, min_salary, max_salary, overtime_eligible) "
        f"VALUES %s",
        [
            (g.grade_id, g.grade_code, g.grade_name, g.min_salary,
             g.max_salary, g.overtime_eligible)
            for g in data.job_grades
        ],
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.job_titles "
        f"(job_id, job_code, job_title, job_family, grade_id, flsa_status) VALUES %s",
        [
            (j.job_id, j.job_code, j.job_title, j.job_family, j.grade_id, j.flsa_status)
            for j in data.job_titles
        ],
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.departments "
        f"(dept_id, dept_code, dept_name, parent_dept_id, cost_center, location_code) "
        f"VALUES %s",
        [
            (d.dept_id, d.dept_code, d.dept_name, d.parent_dept_id, d.cost_center, d.location_code)
            for d in data.departments
        ],
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.employees "
        f"(emp_id, emp_number, first_name, last_name, email, phone_work, "
        f"phone_mobile, hire_date, termination_date, dept_id, job_id, "
        f"manager_emp_id, location_code, employment_type, employment_status, "
        f"active_flag) VALUES %s",
        [
            (
                e.emp_id, e.emp_number, e.first_name, e.last_name, e.email,
                e.phone_work, e.phone_mobile, e.hire_date, e.termination_date,
                e.dept_id, e.job_id, e.manager_emp_id, e.location_code,
                e.employment_type, e.employment_status, e.active_flag,
            )
            for e in data.employees
        ],
    )
    print(f"  Loaded {len(data.employees)} employees")

    execute_values(
        cur,
        f"INSERT INTO {schema}.salary_records "
        f"(salary_id, emp_id, effective_date, end_date, base_salary, "
        f"currency_code, pay_frequency, active_flag) VALUES %s",
        [
            (
                s.salary_id, s.emp_id, s.effective_date, s.end_date,
                s.base_salary, s.currency_code, s.pay_frequency, s.active_flag,
            )
            for s in data.salary_records
        ],
    )
    print(f"  Loaded {len(data.salary_records)} salary records")

    execute_values(
        cur,
        f"INSERT INTO {schema}.leave_types "
        f"(leave_type_id, leave_type_code, leave_type_name, paid_flag, accrual_rate, max_balance) "
        f"VALUES %s",
        [(lt[0], lt[1], lt[2], lt[3], lt[4], lt[5]) for lt in LEAVE_TYPES],
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.leave_balances "
        f"(balance_id, emp_id, leave_type_id, calendar_year, opening_balance, "
        f"accrued, used, adjustment, pending) VALUES %s",
        [
            (
                b.balance_id, b.emp_id, b.leave_type_id, b.calendar_year,
                b.opening_balance, b.accrued, b.used, b.adjustment, b.pending,
            )
            for b in data.leave_balances
        ],
    )

    execute_values(
        cur,
        f"INSERT INTO {schema}.pay_elements "
        f"(element_id, element_code, element_name, element_type) VALUES %s",
        [(pe[0], pe[1], pe[2], pe[3]) for pe in PAY_ELEMENTS],
    )
    cur.execute(
        f"INSERT INTO {schema}.pay_periods "
        f"(period_id, period_name, pay_frequency, period_start_date, "
        f"period_end_date, pay_date, status) "
        f"VALUES (1, 'June 2024', 'MONTHLY', '2024-06-01', '2024-06-30', "
        f"'2024-07-05', 'CLOSED')"
    )
    cur.execute(
        f"INSERT INTO {schema}.payroll_runs "
        f"(run_id, period_id, run_type, run_date, status, total_gross, "
        f"total_deductions, total_net, employee_count) "
        f"VALUES (1, 1, 'REGULAR', '2024-07-01', 'APPROVED', %s, %s, %s, %s)",
        (
            data.run_total_gross,
            data.run_total_deductions,
            data.run_total_net,
            data.run_employee_count,
        ),
    )
    execute_values(
        cur,
        f"INSERT INTO {schema}.payroll_details "
        f"(detail_id, run_id, emp_id, element_id, element_type, amount) VALUES %s",
        [
            (d.detail_id, d.run_id, d.emp_id, d.element_id, d.element_type, d.amount)
            for d in data.payroll_details
        ],
    )
    print(f"  Loaded {len(data.payroll_details)} payroll details")

    cur.close()
    conn.close()
    print(f"Done. Source-of-truth data loaded into [{schema}].")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Seed deterministic synthetic HRMS data into PostgreSQL"
    )
    parser.add_argument("--schema", default="raw", help="Target schema (default: raw)")
    parser.add_argument(
        "--dry-run", action="store_true", help="Print row counts without executing"
    )
    args = parser.parse_args()

    data = generate()
    load(data, schema=args.schema, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
