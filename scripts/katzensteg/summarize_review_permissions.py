"""Report Claude permission denials without exposing tool arguments or results."""

import collections
import json
import os
import shlex
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


def debug_details(messages):
    """Expose shell structure, never arbitrary command arguments or tool output."""
    vocabulary = set("gh pr diff view comment list issue api git show log status cat sed rg grep head tail wc python python3 node ls cd echo printf bash sh curl true false --repo --json --jq --body --body-file --stat --name-only --patch --raw -R -r -n -c -s -L -f | || && ; > >> < << ( )".split())
    shapes = []
    for result in messages:
        if result.get("type") != "result":
            continue
        for denial in result.get("permission_denials", []):
            if denial.get("tool_name") != "Bash":
                continue
            command = denial.get("tool_input", {}).get("command", "")
            try:
                lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
                lexer.whitespace_split = True
                shapes.append(" ".join(token if token in vocabulary else "<arg>" for token in lexer))
            except ValueError:
                shapes.append("<unparsed command>")
    # Only Claude's final response, not intermediate messages or tool results.
    return {"denied_command_shapes": shapes,
            "final_responses": [result.get("result", "") for result in messages if result.get("type") == "result"]}


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        messages = json.load(source)
    print(json.dumps(summarize(messages), indent=2))
    if os.environ.get("RUNNER_DEBUG") == "1":
        print(json.dumps(debug_details(messages), indent=2))
