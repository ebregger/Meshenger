import os
import sqlite3
import tempfile
import unittest

from tools import gap_catchup


def rows(n):
    # Ids that do not sort like their ages, as real UUIDs do not.
    return [(f"id{(i * 7919) % 1009:04d}", f"hlc{i:04d}") for i in range(n)]


class ChooseGapIdsTests(unittest.TestCase):
    def test_oldest_takes_the_oldest_block(self):
        data = rows(50)
        picked = gap_catchup.choose_gap_ids(data, 10, "oldest")
        expected = [msg_id for msg_id, _ in sorted(data, key=lambda r: r[1])[:10]]
        self.assertEqual(picked, expected)

    def test_each_lagging_phone_gets_a_different_oldest_block(self):
        data = rows(50)
        first = gap_catchup.choose_gap_ids(data, 10, "oldest", block_index=0)
        second = gap_catchup.choose_gap_ids(data, 10, "oldest", block_index=1)
        self.assertFalse(set(first) & set(second))
        self.assertEqual(len(second), 10)

    def test_scatter_is_reproducible_and_differs_per_phone(self):
        data = rows(200)
        a = gap_catchup.choose_gap_ids(data, 30, "scatter", seed=3, block_index=0)
        again = gap_catchup.choose_gap_ids(data, 30, "scatter", seed=3, block_index=0)
        b = gap_catchup.choose_gap_ids(data, 30, "scatter", seed=3, block_index=1)
        self.assertEqual(a, again)
        self.assertNotEqual(set(a), set(b))
        self.assertEqual(len(set(a)), 30)

    def test_never_asks_for_more_rows_than_exist(self):
        self.assertEqual(len(gap_catchup.choose_gap_ids(rows(5), 99, "scatter")), 5)
        self.assertEqual(gap_catchup.choose_gap_ids(rows(5), 0, "oldest"), [])

    def test_unknown_mode_is_rejected(self):
        with self.assertRaises(ValueError):
            gap_catchup.choose_gap_ids(rows(5), 2, "newest")


class MessageCountTests(unittest.TestCase):
    def test_accepts_both_response_shapes(self):
        self.assertEqual(gap_catchup.parse_message_count([{}, {}]), 2)
        self.assertEqual(gap_catchup.parse_message_count({"messages": [{}]}), 1)
        self.assertEqual(gap_catchup.parse_message_count({"status": "ok"}), 0)


class SummarizeTests(unittest.TestCase):
    def test_passes_when_everyone_reaches_the_target(self):
        lagging = gap_catchup.DeviceRun("b", True, start_count=800)
        complete = gap_catchup.DeviceRun("a", False, start_count=1100)
        for seconds, count in [(0, 800), (30, 950), (60, 1100)]:
            lagging.record(seconds, count, 1100)
        for seconds in (0, 30, 60):
            complete.record(seconds, 1100, 1100)
        result = gap_catchup.summarize([lagging, complete], 1100, 300)
        self.assertTrue(result["passed"])
        self.assertEqual(result["all_full_at_s"], 60)
        self.assertEqual(result["devices"][0]["rows_per_s"], 5.0)

    def test_fails_when_a_phone_never_finishes(self):
        lagging = gap_catchup.DeviceRun("b", True, start_count=800)
        lagging.record(0, 800, 1100)
        result = gap_catchup.summarize([lagging], 1100, 300)
        self.assertFalse(result["passed"])
        self.assertIsNone(result["all_full_at_s"])

    def test_fails_when_a_complete_phone_loses_rows(self):
        complete = gap_catchup.DeviceRun("a", False, start_count=1100)
        complete.record(0, 1100, 1100)
        complete.record(10, 1090, 1100)
        complete.record(20, 1100, 1100)
        result = gap_catchup.summarize([complete], 1100, 300)
        self.assertFalse(result["passed"])
        self.assertTrue(any("dropped" in p for p in result["problems"]))


class PunchGapTests(unittest.TestCase):
    def test_removes_only_live_room_messages(self):
        path = os.path.join(tempfile.mkdtemp(), "t.db")
        connection = sqlite3.connect(path)
        connection.execute(
            "CREATE TABLE messages (msg_id TEXT, hlc TEXT, is_deleted INT, "
            "conversation_id TEXT, text_content TEXT)"
        )
        connection.executemany(
            "INSERT INTO messages VALUES (?, ?, 0, '', 'hi')",
            [(f"m{i}", f"h{i:03d}") for i in range(10)],
        )
        connection.execute("INSERT INTO messages VALUES ('dm1', 'h900', 0, 'dm:a:b', 'x')")
        connection.execute("INSERT INTO messages VALUES ('tomb', 'h901', 1, '', 'x')")
        connection.commit()
        connection.close()

        removed, remaining = gap_catchup.punch_gap(path, 4, "oldest", 0, 0)

        self.assertEqual((removed, remaining), (4, 6))
        connection = sqlite3.connect(path)
        kept = {r[0] for r in connection.execute("SELECT msg_id FROM messages")}
        connection.close()
        self.assertTrue({"dm1", "tomb"} <= kept)
        self.assertFalse({"m0", "m1", "m2", "m3"} & kept)


if __name__ == "__main__":
    unittest.main()
