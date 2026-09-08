import json
import unittest

from summarize_review_permissions import summarize


class ReviewPermissionSummaryTests(unittest.TestCase):
    def test_only_fixed_categories_are_reported(self):
        summary = summarize([{"type": "result", "permission_denials": [
            {"tool_name": "Bash", "tool_input": {"command": "gh pr comment 33 --body secret"}},
            {"tool_name": "Read", "tool_input": {"file_path": "/secret"}},
            {"tool_name": "secret", "tool_input": {"command": "secret"}},
        ]}])
        self.assertEqual(summary["permission_denials"], 3)
        self.assertNotIn("secret", json.dumps(summary))
        self.assertEqual(summary["categories"]["Bash: gh pr comment"], 1)

    def test_missing_result_is_not_reported_as_zero_denials(self):
        with self.assertRaises(ValueError):
            summarize([])


if __name__ == "__main__":
    unittest.main()
