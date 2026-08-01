import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = (
    Path(__file__).parents[2]
    / "apps/base/qbittorrent/scripts/bootstrap.py"
)
SPEC = importlib.util.spec_from_file_location("qbittorrent_bootstrap", MODULE_PATH)
bootstrap = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_server_domain_allowlist_uses_semicolon_separator(self):
        values = bootstrap.preference_values("admin", "verifier")

        self.assertEqual(
            values["WebUI\\ServerDomains"],
            (
                "torrent.int.harville.dev;qbittorrent:8080;"
                "qbittorrent.apps.svc:8080;"
                "qbittorrent.apps.svc.cluster.local:8080"
            ),
        )

    def test_creates_preferences_and_preserves_unrelated_sections(self):
        original = "[LegalNotice]\nAccepted=true\n"

        rendered = bootstrap.upsert_section_values(
            original,
            "Preferences",
            {"WebUI\\Username": "admin", "WebUI\\Port": "8080"},
        )

        self.assertIn("[LegalNotice]\nAccepted=true", rendered)
        self.assertIn("[Preferences]", rendered)
        self.assertIn("WebUI\\Username=admin", rendered)

    def test_replaces_critical_value_without_duplication(self):
        original = "[Preferences]\nWebUI\\Username=old\nWebUI\\Port=8080\n"

        rendered = bootstrap.upsert_section_values(
            original,
            "Preferences",
            {"WebUI\\Username": "admin"},
        )

        self.assertEqual(rendered.count("WebUI\\Username="), 1)
        self.assertIn("WebUI\\Username=admin", rendered)

    def test_second_render_is_byte_identical(self):
        values = {"WebUI\\Username": "admin", "WebUI\\Port": "8080"}
        first = bootstrap.upsert_section_values("", "Preferences", values)

        self.assertEqual(
            first,
            bootstrap.upsert_section_values(first, "Preferences", values),
        )


if __name__ == "__main__":
    unittest.main()
