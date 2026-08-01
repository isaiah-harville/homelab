import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = (
    Path(__file__).parents[2]
    / "apps/base/qbittorrent/scripts/cleanup.py"
)
SPEC = importlib.util.spec_from_file_location("qbittorrent_cleanup", MODULE_PATH)
cleanup = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cleanup)


class CleanupSelectionTests(unittest.TestCase):
    def test_selects_only_imported_torrent_at_least_24_hours_old(self):
        now = 200_000
        torrents = [
            {
                "hash": "eligible",
                "category": "imported",
                "completion_on": now - 86_400,
            },
            {
                "hash": "young",
                "category": "imported",
                "completion_on": now - 86_399,
            },
            {
                "hash": "failed",
                "category": "books",
                "completion_on": now - 200_000,
            },
            {"hash": "incomplete", "category": "imported", "completion_on": 0},
        ]

        self.assertEqual(cleanup.select_cleanup_hashes(torrents, now), ["eligible"])

    def test_delete_payload_requests_file_deletion(self):
        payload = cleanup.delete_payload(["one", "two"], delete_files=True)

        self.assertEqual(payload["hashes"], "one|two")
        self.assertEqual(payload["deleteFiles"], "true")

    def test_empty_selection_never_builds_a_delete_request(self):
        self.assertEqual(cleanup.select_cleanup_hashes([], 200_000), [])


if __name__ == "__main__":
    unittest.main()
