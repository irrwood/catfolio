"""SQLite persistence for Strategy Lab runs (one row per backtest run).

A run record stores the strategy code, the run config and a JSON snapshot of the
result (metrics, equity curve, trades) so the UI can list past runs and reload any
one of them — like a chat history of backtests.
"""

import json
import sqlite3
import time
from contextlib import contextmanager

from .settings import V2_DIR

DB_PATH = V2_DIR / "strategy_runs.db"


@contextmanager
def _conn():
    V2_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                name TEXT NOT NULL,
                code TEXT NOT NULL,
                config TEXT NOT NULL,
                metrics TEXT NOT NULL,
                result TEXT NOT NULL
            )"""
        )
        # Migration: persist the saved AI evaluation (added after the initial schema).
        try:
            conn.execute("ALTER TABLE runs ADD COLUMN ai_eval TEXT")
        except sqlite3.OperationalError:
            pass  # column already exists
        yield conn
        conn.commit()
    finally:
        conn.close()


def save_run(name, code, result):
    config = result.get("config", {})
    metrics = result.get("metrics", {})
    with _conn() as conn:
        cur = conn.execute(
            "INSERT INTO runs (created_at, name, code, config, metrics, result) VALUES (?,?,?,?,?,?)",
            (
                int(time.time()),
                name or "未命名回测",
                code,
                json.dumps(config, ensure_ascii=False),
                json.dumps(metrics, ensure_ascii=False),
                json.dumps(result, ensure_ascii=False),
            ),
        )
        return cur.lastrowid


def list_runs(limit=100):
    with _conn() as conn:
        rows = conn.execute(
            "SELECT id, created_at, name, config, metrics FROM runs ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
    out = []
    for r in rows:
        out.append({
            "id": r["id"],
            "created_at": r["created_at"],
            "name": r["name"],
            "config": json.loads(r["config"]),
            "metrics": json.loads(r["metrics"]),
        })
    return out


def get_run(run_id):
    with _conn() as conn:
        r = conn.execute(
            "SELECT id, created_at, name, code, config, metrics, result, ai_eval FROM runs WHERE id = ?",
            (run_id,),
        ).fetchone()
    if not r:
        return None
    return {
        "id": r["id"],
        "created_at": r["created_at"],
        "name": r["name"],
        "code": r["code"],
        "config": json.loads(r["config"]),
        "metrics": json.loads(r["metrics"]),
        "result": json.loads(r["result"]),
        "ai_eval": r["ai_eval"],
    }


def save_ai_eval(run_id, text):
    with _conn() as conn:
        conn.execute("UPDATE runs SET ai_eval = ? WHERE id = ?", (text, run_id))


def delete_run(run_id):
    with _conn() as conn:
        cur = conn.execute("DELETE FROM runs WHERE id = ?", (run_id,))
        return cur.rowcount > 0
