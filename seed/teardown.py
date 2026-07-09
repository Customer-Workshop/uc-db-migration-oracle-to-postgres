"""
teardown.py — Drop a namespace schema and all its objects.

Usage:
    python seed/teardown.py --schema dev
    python seed/teardown.py --schema raw

Environment variables:
    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

from __future__ import annotations

import argparse
import os
import re

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


def _validate_schema_name(schema: str) -> None:
    """Reject schema names that are not safe identifiers."""
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", schema):
        raise ValueError(f"Invalid schema name: {schema!r}")


def teardown(schema: str) -> None:
    """Drop the schema and every object it contains (CASCADE)."""
    _validate_schema_name(schema)
    conn = get_connection()
    cur = conn.cursor()

    cur.execute(
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = %s",
        (schema,),
    )
    if not cur.fetchone():
        print(f"Schema [{schema}] does not exist. Nothing to do.")
        cur.close()
        conn.close()
        return

    print(f"Tearing down [{schema}]...")
    cur.execute(f'DROP SCHEMA "{schema}" CASCADE')
    print(f"  Dropped schema: [{schema}]")

    cur.close()
    conn.close()
    print("Done.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Tear down a namespace")
    parser.add_argument("--schema", required=True, help="Schema to drop")
    args = parser.parse_args()
    teardown(args.schema)


if __name__ == "__main__":
    main()
