import json
import unittest

from summarize_review_permissions import summarize, debug_details


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

    def test_debug_shapes_preserve_pipeline_but_not_arguments(self):
        details = debug_details([{"type": "result", "result": "Could not read the diff.", "permission_denials": [
            {"tool_name": "Bash", "tool_input": {"command": "gh pr diff 33 --repo private/repo | head -n 200"}},
            {"tool_name": "Bash", "tool_input": {"command": "gh pr comment 33 --body 'secret body'"}},
        ]}, {"type": "user", "content": "secret tool output"}])
        self.assertEqual(details["denied_command_shapes"][0], "gh pr diff <arg> --repo <arg> | head -n <arg>")
        self.assertNotIn("private/repo", json.dumps(details))
        self.assertNotIn("secret", json.dumps(details))
        self.assertEqual(details["final_responses"], ["Could not read the diff."])


if __name__ == "__main__":
    unittest.main()
