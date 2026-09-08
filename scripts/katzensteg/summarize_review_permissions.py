"""Report Claude permission denials without exposing tool arguments or results."""

import collections
import json
import sys


def category(denial):
    name = denial.get("tool_name")
    if name != "Bash":
        return name if name in {"Read", "Grep", "Glob", "Write", "Edit", "Agent", "Task", "WebFetch", "WebSearch"} else "other tool"
    command = denial.get("tool_input", {}).get("command", "").lstrip()
    for prefix in ("gh pr comment", "gh pr diff", "gh pr view", "gh api", "git diff", "git show", "git log", "cat", "sed", "rg", "grep", "python3", "python", "node", "ls"):
        if command == prefix or command.startswith(prefix + " "):
            return "Bash: " + prefix
    return "Bash: other command"


def summarize(messages):
    results = [message for message in messages if message.get("type") == "result"]
    if not results:
        raise ValueError("Claude execution output contains no result")
    counts = collections.Counter(category(denial) for result in results for denial in result.get("permission_denials", []))
    return {"permission_denials": sum(counts.values()), "categories": dict(sorted(counts.items()))}


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        print(json.dumps(summarize(json.load(source)), indent=2))
