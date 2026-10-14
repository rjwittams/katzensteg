# Common Probe Contracts

This directory holds cross-frontend probe contracts (scenario names, expected logs, pass/fail intent).

Implementations remain per-frontend in `examples/probes/sdl2` and `examples/probes/sdl3`.
The one shared source is `audio_tone.h`, the tone both audio probes play; the
analysis in `scripts/katzensteg/audio_tone_analysis.py` checks against the same
constants.
