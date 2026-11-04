"""One-shot setup steps for the Mem0 server, run by the Helm chart's init containers.

    python oreon_bootstrap.py databases   create the app and memory databases and the vector extension
    python oreon_bootstrap.py admin       create the first admin user (ADMIN_EMAIL / ADMIN_PASSWORD)

Both are idempotent. `admin` closes the first-run /setup page, which otherwise lets whoever reaches
the dashboard first register as admin.
"""

import os
import sys
import time


def _connect(dbname: str):
    import psycopg

    return psycopg.connect(
        host=os.environ.get("POSTGRES_HOST", "postgres"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        user=os.environ.get("POSTGRES_USER", "postgres"),
        password=os.environ.get("POSTGRES_PASSWORD", ""),
        dbname=dbname,
        sslmode=os.environ.get("PGSSLMODE", "prefer"),
        connect_timeout=5,
        autocommit=True,
    )


def _wait(dbname: str, timeout: int = 300):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return _connect(dbname)
        except Exception as exc:  # noqa: BLE001
            if time.monotonic() > deadline:
                raise
            print(f"waiting for PostgreSQL ({type(exc).__name__}: {str(exc).splitlines()[0][:120]})", flush=True)
            time.sleep(3)


def databases() -> int:
    from psycopg import sql

    memory_db = os.environ.get("POSTGRES_DB", "postgres")
    app_db = os.environ.get("APP_DB_NAME", "mem0_app")
    maintenance_db = os.environ.get("POSTGRES_MAINTENANCE_DB", "postgres")
    create = os.environ.get("MEM0_CREATE_DATABASES", "true").lower() == "true"

    if create:
        with _wait(maintenance_db) as conn:
            for name in dict.fromkeys([memory_db, app_db]):
                exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,)).fetchone()
                if exists:
                    print(f"database {name}: exists", flush=True)
                else:
                    conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
                    print(f"database {name}: created", flush=True)

    with _wait(memory_db) as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        version = conn.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector'").fetchone()[0]
        print(f"database {memory_db}: pgvector {version}", flush=True)
    _wait(app_db).close()
    return 0


def admin() -> int:
    email = os.environ.get("ADMIN_EMAIL", "").strip()
    password = os.environ.get("ADMIN_PASSWORD", "")
    if not email:
        print("ADMIN_EMAIL not set: skipping (the dashboard /setup page stays open until an admin registers)")
        return 0
    if len(password) < 8:
        print("ADMIN_PASSWORD must be at least 8 characters", file=sys.stderr)
        return 2

    from sqlalchemy import func, select

    from auth import hash_password
    from db import SessionLocal
    from models import User

    with SessionLocal() as db:
        if db.scalar(select(func.count(User.id))) > 0:
            print("admin: a user already exists, nothing to do")
            return 0
        db.add(User(name=os.environ.get("ADMIN_NAME", "Admin"), email=email,
                    password_hash=hash_password(password), role="admin"))
        db.commit()
    print(f"admin: created {email}")
    return 0


if __name__ == "__main__":
    steps = {"databases": databases, "admin": admin}
    if len(sys.argv) != 2 or sys.argv[1] not in steps:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(steps[sys.argv[1]]())
