import unittest

from verify_review_posted import find_review


class ReviewPostedTests(unittest.TestCase):
    marker = "<!-- claude-review:123:2:abc -->"

    def comment(self, body=None, login="claude[bot]", kind="Bot"):
        return {"user": {"login": login, "type": kind},
                "body": body if body is not None else "No findings.\n" + self.marker}

    def test_finds_review_on_later_page(self):
        review = self.comment()
        self.assertEqual(find_review([[], [review]], self.marker), review)

    def test_missing_or_previous_attempt_does_not_pass(self):
        self.assertIsNone(find_review([], self.marker))
        for marker in ("<!-- claude-review:122:2:abc -->",
                       "<!-- claude-review:123:1:abc -->",
                       "<!-- claude-review:123:2:old -->"):
            self.assertIsNone(find_review([[self.comment("Review. " + marker)]], self.marker))

    def test_marker_from_another_author_does_not_pass(self):
        for login, kind in (("rjwittams", "User"), ("another[bot]", "Bot"), ("claude[bot]", "User")):
            self.assertIsNone(find_review([[self.comment(login=login, kind=kind)]], self.marker))

    def test_empty_comment_does_not_pass(self):
        for body in ("", self.marker, "  " + self.marker + "\n"):
            self.assertIsNone(find_review([[self.comment(body)]], self.marker))


if __name__ == "__main__":
    unittest.main()
