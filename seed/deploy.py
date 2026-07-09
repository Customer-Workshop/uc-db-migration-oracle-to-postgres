"""
deploy.py — Deploy converted PostgreSQL objects into a namespace schema.

Reads .sql migration files from the migrations/ directory tree, substitutes the
$(NS) namespace variable with the target schema name, and executes each file
against PostgreSQL in filename order.

Each migration file is executed as a single script (PostgreSQL accepts multiple
statements per execute, and $$-quoted PL/pgSQL bodies are preserved intact — no
batch splitting is required, unlike SQL Server's GO separator).

Usage:
    python seed/deploy.py --namespace dev
    python seed/deploy.py --namespace dev --migrations-dir migrations/

Environment variables:
    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys

try:
    import psycopg2
except ImportError:  # pragma: no cover - import guard
    psycopg2 = None  # type: ignore[assignment]


def get_connection() -> "psycopg2.extensions.connection":
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


def deploy(namespace: str, migrations_dir: str = "migrations/") -> None:
    """Find all .sql files under migrations_dir, sort by filename, execute."""
    _validate_schema_name(namespace)
    conn = get_connection()
    cur = conn.cursor()

    # Ensure the namespace schema exists.
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{namespace}"')

    sql_files = sorted(
        glob.glob(os.path.join(migrations_dir, "**", "*.sql"), recursive=True),
        key=lambda f: os.path.basename(f),
    )

    if not sql_files:
        print(f"No .sql files found under {migrations_dir}")
        sys.exit(1)

    print(f"Deploying {len(sql_files)} files into [{namespace}]...")

    errors = []
    for filepath in sql_files:
        basename = os.path.basename(filepath)
        with open(filepath, "r", encoding="utf-8") as f:
            sql = f.read()

        sql = sql.replace("$(NS)", namespace)

        try:
            cur.execute(sql)
            print(f"  Deployed: {basename}")
        except Exception as exc:  # noqa: BLE001 - report and continue
            errors.append((basename, str(exc)))
            print(f"  ERROR in {basename}: {exc}")

    cur.close()
    conn.close()

    if errors:
        print(f"\n{len(errors)} errors during deployment:")
        for fname, msg in errors:
            print(f"  {fname}: {msg}")
        sys.exit(1)
    print(f"All {len(sql_files)} files deployed successfully into [{namespace}].")


def main() -> None:
    parser = argparse.ArgumentParser(description="Deploy migrations to namespace")
    parser.add_argument("--namespace", required=True, help="Target PostgreSQL schema")
    parser.add_argument(
        "--migrations-dir", default="migrations/", help="Path to migrations directory"
    )
    args = parser.parse_args()
    deploy(args.namespace, args.migrations_dir)


if __name__ == "__main__":
    main()
