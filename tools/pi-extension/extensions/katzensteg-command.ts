// Pure parsing for the `katzensteg-panel` slash command. Kept free of any
// pi-tui / pi-coding-agent runtime imports so it can be unit-tested standalone
// (mirrors katzensteg-geometry).

export type SizePresetName = "small" | "medium" | "large";

export type PanelCommand =
	| { kind: "toggle" }
	| { kind: "open"; profile?: string; args?: string[] }
	| { kind: "close" }
	| { kind: "size"; size: SizePresetName }
	| { kind: "profile"; profile: string; args?: string[] }
	| { kind: "inline"; profile?: string; args?: string[] };

export function isSizePreset(value: string | undefined): value is SizePresetName {
	return value === "small" || value === "medium" || value === "large";
}

export function sameArgs(a: string[], b: string[]): boolean {
	return a.length === b.length && a.every((value, index) => value === b[index]);
}

// Expand a leading `~` / `~/` to the home directory — shell tilde semantics:
// prefix only, never mid-string, and no other tokens. The launcher forwards
// extra args verbatim, so this is the only expansion a non-shell caller (this
// extension) applies; `$HOME`, `{repo}`, etc. are deliberately left literal so a
// path that genuinely contains them reaches the program unchanged.
export function expandHomePrefix(arg: string, home: string): string {
	if (arg === "~") return home;
	if (arg.startsWith("~/")) return home + arg.slice(1);
	return arg;
}

// Split a token list (already past any subcommand) into the profile name and
// the program args forwarded to the launcher. Parsing is positional: the first
// token is the profile and everything after it is forwarded verbatim. A `--`
// separator is optional — it may stand in place of the profile (`-- a b`, args
// only) or sit between the profile and its args (`retroarch -- -L core`); in
// both cases it is consumed, never forwarded.
function splitProfileArgs(tokens: string[]): { profile?: string; args: string[] } {
	if (tokens.length === 0) return { args: [] };
	if (tokens[0] === "--") return { args: tokens.slice(1) };
	const profile = tokens[0];
	const rest = tokens.slice(1);
	return { profile, args: rest[0] === "--" ? rest.slice(1) : rest };
}

export function parseCommand(input: string): PanelCommand {
	const tokens = input.trim().split(/\s+/).filter(Boolean);
	if (tokens.length === 0) return { kind: "toggle" };

	const head = tokens[0];
	if (head === "close") return { kind: "close" };
	if (head === "size" && isSizePreset(tokens[1])) return { kind: "size", size: tokens[1] };
	if (isSizePreset(head) && tokens.length === 1) return { kind: "size", size: head };

	if (head === "open" || head === "inline") {
		const { profile, args } = splitProfileArgs(tokens.slice(1));
		if (head === "open") return args.length > 0 ? { kind: "open", profile, args } : { kind: "open", profile };
		return args.length > 0 ? { kind: "inline", profile, args } : { kind: "inline", profile };
	}
	if (head === "profile") {
		const { profile, args } = splitProfileArgs(tokens.slice(1));
		if (profile === undefined) return { kind: "toggle" };
		return args.length > 0 ? { kind: "profile", profile, args } : { kind: "profile", profile };
	}

	// Bare form: first token is the profile, the rest are program args.
	const { profile, args } = splitProfileArgs(tokens);
	return args.length > 0 ? { kind: "open", profile, args } : { kind: "open", profile };
}
