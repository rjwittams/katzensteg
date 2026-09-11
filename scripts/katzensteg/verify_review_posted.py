"""Require a Claude review comment belonging to this exact CI attempt."""

import json
import os
import subprocess


def find_review(pages, marker):
    for page in pages:
        for comment in page:
            user = comment.get("user") or {}
            body = comment.get("body") or ""
            if (user.get("login") == "claude[bot]"
                    and user.get("type") == "Bot"
                    and marker in body
                    and body.replace(marker, "").strip()):
                return comment
    return None


def main():
    repo = os.environ["REVIEW_REPO"]
    pr = int(os.environ["REVIEW_PR"])
    marker = os.environ["REVIEW_MARKER"]
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp",
         f"repos/{repo}/issues/{pr}/comments?per_page=100"],
        check=True, capture_output=True, text=True,
    )
    if find_review(json.loads(result.stdout), marker) is None:
        raise SystemExit("Claude did not post a review comment for this run, attempt, and commit.")
    print("Verified Claude review comment for this run, attempt, and commit.")


if __name__ == "__main__":
    main()
