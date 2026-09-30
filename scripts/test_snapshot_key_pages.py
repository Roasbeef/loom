"""Keep register pagination off a repeated scan of already visited keys."""

from pathlib import Path
import re
import sqlite3
import unittest


STORAGE = Path(__file__).resolve().parents[1] / "packages" / "storage"


def statement(name):
    source = (STORAGE / "src/storage/sql/snapshot.sql").read_text()
    match = re.search(r"-- name: " + name + r" :(?:one|many)\n(.*?);", source, re.S)
    if match is None:
        raise AssertionError(f"Missing named query: {name}")
    return match.group(1)


class KeyPageSeekTest(unittest.TestCase):
    def test_late_pages_seek_past_prior_history(self):
        with sqlite3.connect(":memory:") as conn:
            conn.executescript((STORAGE / "sql/session.sql").read_text())
            conn.executemany(
                "INSERT INTO registers(ns,key,seq,value) VALUES(?,?,?,?)",
                [("fact.custom", f"mail/{n:05}", n + 1, b"{}") for n in range(20000)],
            )
            for name in ("SnapshotRegisterPageHeaders", "SnapshotRegisterPageBudget"):
                for cursor in ("", "mail/19990"):
                    with self.subTest(query=name, cursor=cursor):
                        steps = 0

                        def progress():
                            nonlocal steps
                            steps += 1
                            return 0

                        conn.set_progress_handler(progress, 1)
                        rows = conn.execute(statement(name), {
                            "namespace": "fact.custom",
                            "prefix": "mail/",
                            "after_key": cursor,
                            "prefix_upper": "mail0",
                            "page_size": 1,
                        }).fetchall()
                        conn.set_progress_handler(None, 0)

                        # Indexed cursor seeks stay small regardless of the
                        # preceding history. The former dual lower bounds
                        # used roughly 100,000 VM steps for the late page.
                        self.assertLess(steps, 2000)
                        self.assertEqual(len(rows), 1)
                        if name == "SnapshotRegisterPageHeaders":
                            expected = "mail/00000" if not cursor else "mail/19991"
                            self.assertEqual(rows[0][0], expected)
                        else:
                            self.assertEqual(rows[0][0], 1)


if __name__ == "__main__":
    unittest.main()
