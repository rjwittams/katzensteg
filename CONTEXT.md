# Katzensteg

Katzensteg injects into SDL applications and mirrors their output into terminal
graphics, a desktop WM, or a Jackstay publication.

## Language

### Audio

**Audio model**:
The canonical owner of an app's audio state: its playback streams, gain, mute,
routing and pacing clock.
_Avoid_: mixer, which implies combining streams the model does not combine

**Audio sink**:
One place the app's playback goes. The model routes to sinks; sinks never make
routing or gain decisions.
_Avoid_: output, backend

**Local device sink**:
The audio sink that plays through the app's real SDL device on this machine,
and the only sink that volume and mute act on.

**Virtual paced device**:
The audio sink that stands in for a real device when nothing plays locally,
draining the app's audio on Katzensteg's own clock.
_Avoid_: dummy driver, which is SDL's own and paces inexactly

**Audio tap**:
The point in the audio model where every block is handed, unscaled and before
the local device sink applies gain, to the sinks that attach there.
_Avoid_: capture, which SDL uses for recording devices

**Published track**:
The audio sink that writes the app's unscaled playback into a Jackstay playback
track. See Jackstay's glossary for the track itself.
