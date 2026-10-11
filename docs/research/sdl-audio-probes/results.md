| run | exit | source | content | cadence |
| --- | --- | --- | --- | --- |
| base-sdl2-callback | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| base-sdl2-callback | 0 | log |  | |
| base-sdl3-bound | 0 | disk.raw (786432 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| base-sdl3-bound | 0 | log |  | |
| compat-callback-dynapi3only | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.1768 (0.500x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | |
| compat-callback-dynapi3only | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 8192 B, period 21.33 ms, median gap 21.32 ms, max gap 21.9 ms, bursts 0%, data/wall 0.999 |
| compat-callback-dynapi3only | 0 | log | sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| compat-callback-g0 | 0 | disk.raw (380928 B, read as 0x8120) | silent | |
| compat-callback-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.30 ms, max gap 29.9 ms, bursts 0%, data/wall 0.991 |
| compat-callback-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-callback-g1 | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | |
| compat-callback-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 21.33 ms, median gap 21.31 ms, max gap 32.3 ms, bursts 0%, data/wall 0.995 |
| compat-callback-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 0 (385024 of 385024 B) | |
| compat-callback-g1 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-callback-preload2-dynapi3 | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.0884 (0.250x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | |
| compat-callback-preload2-dynapi3 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 21.33 ms, median gap 21.37 ms, max gap 29.5 ms, bursts 0%, data/wall 0.992 |
| compat-callback-preload2-dynapi3 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.1768 (0.500x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 8192 B, period 21.33 ms, median gap 21.37 ms, max gap 29.5 ms, bursts 0%, data/wall 0.992 |
| compat-callback-preload2-dynapi3 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1, sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| compat-callback-preload2then3 | 139 | log | sdl2:SDL_OpenAudioDevice x1 | |
| compat-callback-preload2then3v | 0 | disk.raw (380928 B, read as 0x8010) | rms 0.1768 (0.500x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| compat-callback-preload2then3v | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.34 ms, max gap 30.3 ms, bursts 0%, data/wall 0.992 |
| compat-callback-preload2then3v | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-callback-preload2vthen3v | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.1768 (0.500x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | |
| compat-callback-preload2vthen3v | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 21.33 ms, median gap 21.31 ms, max gap 31.8 ms, bursts 0%, data/wall 0.994 |
| compat-callback-preload2vthen3v | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-callback-preload3only | 139 | log |  | |
| compat-callback-preload3then2 | 139 | log |  | |
| compat-callback-preload3vonly | 0 | disk.raw (376832 B, read as 0x8010) | rms 0.3535 (1.000x), 440.2 Hz, 94207 frames, glitches 0, dropouts 0 | |
| compat-callback-preload3vonly | 0 | log |  | |
| compat-callback-preload3vthen2 | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.1768 (0.500x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | |
| compat-callback-preload3vthen2 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 21.33 ms, median gap 21.33 ms, max gap 23.4 ms, bursts 0%, data/wall 0.999 |
| compat-callback-preload3vthen2 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-callback-reopen-g0 | 0 | disk.raw (192512 B, read as 0x8120) | silent | |
| compat-callback-reopen-g0 | 0 | disk.raw.seg2 (198656 B, read as 0x8120) | silent | |
| compat-callback-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 439.8 Hz, 48127 frames, glitches 0, dropouts 0 | 47 calls x 4096 B, period 21.33 ms, median gap 21.36 ms, max gap 24.7 ms, bursts 0%, data/wall 0.996 |
| compat-callback-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 49664 frames, glitches 0, dropouts 0 | 97 calls x 2048 B, period 10.67 ms, median gap 10.28 ms, max gap 19.0 ms, bursts 0%, data/wall 1.026 |
| compat-callback-reopen-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x2, sdl2:SDL_OpenAudioDevice x2, sdl2:SDL_PauseAudioDevice x2 | |
| compat-legacy-g0 | 0 | disk.raw (385024 B, read as 0x8120) | silent | |
| compat-legacy-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 96255 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 21.33 ms, median gap 21.33 ms, max gap 21.9 ms, bursts 0%, data/wall 0.999 |
| compat-legacy-g0 | 0 | log | sdl2:SDL_CloseAudio x1, sdl2:SDL_OpenAudio x1, sdl2:SDL_PauseAudio x1 | |
| compat-legacy-g1 | 0 | disk.raw (380928 B, read as 0x8010) | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| compat-legacy-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.32 ms, max gap 25.2 ms, bursts 0%, data/wall 0.991 |
| compat-legacy-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 0 (380928 of 380928 B) | |
| compat-legacy-g1 | 0 | log | sdl2:SDL_CloseAudio x1, sdl2:SDL_OpenAudio x1, sdl2:SDL_PauseAudio x1 | |
| compat-legacy-reopen-g0 | 0 | disk.raw (192512 B, read as 0x8120) | silent | |
| compat-legacy-reopen-g0 | 0 | disk.raw.seg2 (198656 B, read as 0x8120) | silent | |
| compat-legacy-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 439.8 Hz, 48127 frames, glitches 0, dropouts 0 | 47 calls x 4096 B, period 21.33 ms, median gap 21.30 ms, max gap 21.6 ms, bursts 0%, data/wall 1.001 |
| compat-legacy-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 439.8 Hz, 49664 frames, glitches 0, dropouts 0 | 97 calls x 2048 B, period 10.67 ms, median gap 10.28 ms, max gap 14.9 ms, bursts 0%, data/wall 1.030 |
| compat-legacy-reopen-g0 | 0 | log | sdl2:SDL_CloseAudio x2, sdl2:SDL_OpenAudio x2, sdl2:SDL_PauseAudio x2 | |
| compat-queue-dynapi3only | 0 | disk.raw (397312 B, read as 0x8010) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-dynapi3only | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.28 ms, max gap 28.4 ms, bursts 0%, data/wall 0.998 |
| compat-queue-dynapi3only | 0 | log | sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| compat-queue-g0 | 0 | disk.raw (393216 B, read as 0x8120) | silent | |
| compat-queue-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.29 ms, max gap 29.1 ms, bursts 0%, data/wall 0.994 |
| compat-queue-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-queue-g1 | 0 | disk.raw (393216 B, read as 0x8010) | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.29 ms, max gap 22.1 ms, bursts 0%, data/wall 1.001 |
| compat-queue-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 0 (393216 of 393216 B) | |
| compat-queue-g1 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-queue-preload2-dynapi3 | 0 | disk.raw (393216 B, read as 0x8010) | rms 0.0884 (0.250x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-preload2-dynapi3 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.35 ms, max gap 33.1 ms, bursts 0%, data/wall 0.993 |
| compat-queue-preload2-dynapi3 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.34 ms, max gap 33.1 ms, bursts 0%, data/wall 0.993 |
| compat-queue-preload2-dynapi3 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1, sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| compat-queue-preload2then3 | 139 | log | sdl2:SDL_OpenAudioDevice x1 | |
| compat-queue-preload2then3v | 0 | disk.raw (397312 B, read as 0x8010) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-preload2then3v | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.33 ms, max gap 36.2 ms, bursts 0%, data/wall 0.988 |
| compat-queue-preload2then3v | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-queue-preload3only | 139 | log |  | |
| compat-queue-preload3then2 | 139 | log |  | |
| compat-queue-preload3vonly | 0 | disk.raw (393216 B, read as 0x8010) | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-preload3vonly | 0 | log |  | |
| compat-queue-preload3vthen2 | 0 | disk.raw (397312 B, read as 0x8010) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| compat-queue-preload3vthen2 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 4096 B, period 21.33 ms, median gap 21.37 ms, max gap 24.5 ms, bursts 0%, data/wall 0.995 |
| compat-queue-preload3vthen2 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| compat-queue-reopen-g0 | 0 | disk.raw (200704 B, read as 0x8120) | silent | |
| compat-queue-reopen-g0 | 0 | disk.raw.seg2 (202752 B, read as 0x8120) | silent | |
| compat-queue-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 49 calls x 4096 B, period 21.33 ms, median gap 21.51 ms, max gap 22.2 ms, bursts 0%, data/wall 0.992 |
| compat-queue-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 99 calls x 2048 B, period 10.67 ms, median gap 10.29 ms, max gap 14.5 ms, bursts 0%, data/wall 1.025 |
| compat-queue-reopen-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x2, sdl2:SDL_OpenAudioDevice x2, sdl2:SDL_PauseAudioDevice x2 | |
| sdl2-callback-g0 | 0 | disk.raw (385024 B, read as 0x8120) | silent | |
| sdl2-callback-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.32 ms, max gap 32.9 ms, bursts 0%, data/wall 0.992 |
| sdl2-callback-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-callback-g1 | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| sdl2-callback-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.29 ms, max gap 22.4 ms, bursts 0%, data/wall 1.001 |
| sdl2-callback-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 4096 (380928 of 385024 B) | |
| sdl2-callback-g1 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-callback-preload2vthen3v | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.1768 (0.500x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| sdl2-callback-preload2vthen3v | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.32 ms, max gap 21.6 ms, bursts 0%, data/wall 1.000 |
| sdl2-callback-preload2vthen3v | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-callback-reopen-g0 | 0 | disk.raw (192512 B, read as 0x8120) | silent | |
| sdl2-callback-reopen-g0 | 0 | disk.raw.seg2 (198656 B, read as 0x8120) | silent | |
| sdl2-callback-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.2 Hz, 47103 frames, glitches 0, dropouts 0 | 46 calls x 4096 B, period 21.33 ms, median gap 21.34 ms, max gap 25.1 ms, bursts 0%, data/wall 0.994 |
| sdl2-callback-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.4 Hz, 49152 frames, glitches 0, dropouts 0 | 96 calls x 2048 B, period 10.67 ms, median gap 10.31 ms, max gap 10.6 ms, bursts 0%, data/wall 1.033 |
| sdl2-callback-reopen-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x2, sdl2:SDL_OpenAudioDevice x2, sdl2:SDL_PauseAudioDevice x2 | |
| sdl2-legacy-g0 | 0 | disk.raw (385024 B, read as 0x8120) | silent | |
| sdl2-legacy-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.36 ms, max gap 28.7 ms, bursts 0%, data/wall 0.993 |
| sdl2-legacy-g0 | 0 | log | sdl2:SDL_CloseAudio x1, sdl2:SDL_OpenAudio x1, sdl2:SDL_PauseAudio x1 | |
| sdl2-legacy-g1 | 0 | disk.raw (385024 B, read as 0x8010) | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| sdl2-legacy-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 4096 B, period 21.33 ms, median gap 21.31 ms, max gap 21.5 ms, bursts 0%, data/wall 1.001 |
| sdl2-legacy-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 4096 (380928 of 385024 B) | |
| sdl2-legacy-g1 | 0 | log | sdl2:SDL_CloseAudio x1, sdl2:SDL_OpenAudio x1, sdl2:SDL_PauseAudio x1 | |
| sdl2-legacy-reopen-g0 | 0 | disk.raw (192512 B, read as 0x8120) | silent | |
| sdl2-legacy-reopen-g0 | 0 | disk.raw.seg2 (200704 B, read as 0x8120) | silent | |
| sdl2-legacy-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.2 Hz, 47103 frames, glitches 0, dropouts 0 | 46 calls x 4096 B, period 21.33 ms, median gap 21.27 ms, max gap 21.4 ms, bursts 0%, data/wall 1.002 |
| sdl2-legacy-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 439.8 Hz, 49664 frames, glitches 0, dropouts 0 | 97 calls x 2048 B, period 10.67 ms, median gap 10.25 ms, max gap 10.5 ms, bursts 0%, data/wall 1.040 |
| sdl2-legacy-reopen-g0 | 0 | log | sdl2:SDL_CloseAudio x2, sdl2:SDL_OpenAudio x2, sdl2:SDL_PauseAudio x2 | |
| sdl2-queue-f32-g0 | 0 | disk.raw (794624 B, read as 0x8120) | silent | |
| sdl2-queue-f32-g0 | 0 | sdl2-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.36 ms, max gap 22.3 ms, bursts 0%, data/wall 0.998 |
| sdl2-queue-f32-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-queue-f32-g1 | 0 | disk.raw (794624 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl2-queue-f32-g1 | 0 | sdl2-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.37 ms, max gap 54.0 ms, bursts 0%, data/wall 0.981 |
| sdl2-queue-f32-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 8192 (786432 of 794624 B) | |
| sdl2-queue-f32-g1 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-queue-g0 | 0 | disk.raw (397312 B, read as 0x8120) | silent | |
| sdl2-queue-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.28 ms, max gap 26.4 ms, bursts 0%, data/wall 0.996 |
| sdl2-queue-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-queue-g1 | 0 | disk.raw (397312 B, read as 0x8010) | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl2-queue-g1 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 4096 B, period 21.33 ms, median gap 21.28 ms, max gap 25.5 ms, bursts 0%, data/wall 1.000 |
| sdl2-queue-g1 | 0 | sdl2-0 vs disk.raw | tap bytes == disk bytes at offset 4096 (393216 of 397312 B) | |
| sdl2-queue-g1 | 0 | log | sdl2:SDL_CloseAudioDevice x1, sdl2:SDL_OpenAudioDevice x1, sdl2:SDL_PauseAudioDevice x1 | |
| sdl2-queue-reopen-g0 | 0 | disk.raw (204800 B, read as 0x8120) | silent | |
| sdl2-queue-reopen-g0 | 0 | disk.raw.seg2 (202752 B, read as 0x8120) | silent | |
| sdl2-queue-reopen-g0 | 0 | sdl2-0 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 49 calls x 4096 B, period 21.33 ms, median gap 21.30 ms, max gap 21.6 ms, bursts 0%, data/wall 1.001 |
| sdl2-queue-reopen-g0 | 0 | sdl2-1 fmt=0x8010 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 98 calls x 2048 B, period 10.67 ms, median gap 10.28 ms, max gap 28.6 ms, bursts 0%, data/wall 1.007 |
| sdl2-queue-reopen-g0 | 0 | log | sdl2:SDL_CloseAudioDevice x2, sdl2:SDL_OpenAudioDevice x2, sdl2:SDL_PauseAudioDevice x2 | |
| sdl3-bound-apppostmix-g0 | 0 | disk.raw (786432 B, read as 0x8120) | silent | |
| sdl3-bound-apppostmix-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.32 ms, max gap 28.8 ms, bursts 0%, data/wall 0.994 |
| sdl3-bound-apppostmix-g0 | 0 | log | sdl3:SDL_BindAudioStream x1, sdl3:SDL_CloseAudioDevice x1, sdl3:SDL_CreateAudioStream x1, sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDevice x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1, sdl3:SDL_SetAudioPostmixCallback x1 | |
| sdl3-bound-g0 | 0 | disk.raw (794624 B, read as 0x8120) | silent | |
| sdl3-bound-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.38 ms, max gap 27.7 ms, bursts 0%, data/wall 0.992 |
| sdl3-bound-g0 | 0 | log | sdl3:SDL_BindAudioStream x1, sdl3:SDL_CloseAudioDevice x1, sdl3:SDL_CreateAudioStream x1, sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDevice x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-bound-g1 | 0 | disk.raw (786432 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3-bound-g1 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.36 ms, max gap 30.6 ms, bursts 0%, data/wall 0.981 |
| sdl3-bound-g1 | 0 | sdl3-0 vs disk.raw | tap bytes == disk bytes at offset 0 (786432 of 786432 B) | |
| sdl3-bound-g1 | 0 | log | sdl3:SDL_BindAudioStream x1, sdl3:SDL_CloseAudioDevice x1, sdl3:SDL_CreateAudioStream x1, sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDevice x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-bound-preload2then3v | 139 | log |  | |
| sdl3-bound-preload2vthen3v | 0 | disk.raw (794624 B, read as 0x8120) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3-bound-preload2vthen3v | 0 | sdl3v-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.32 ms, max gap 54.6 ms, bursts 0%, data/wall 0.982 |
| sdl3-bound-preload2vthen3v | 0 | log | sdl3v:SDL_BindAudioStream x1, sdl3v:SDL_CloseAudioDevice x1, sdl3v:SDL_CreateAudioStream x1, sdl3v:SDL_DestroyAudioStream x1, sdl3v:SDL_OpenAudioDevice x1, sdl3v:SDL_PutAudioStreamData x1, sdl3v:SDL_Quit x1 | |
| sdl3-bound-preload3vthen2 | 0 | disk.raw (794624 B, read as 0x8120) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3-bound-preload3vthen2 | 0 | sdl3v-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.34 ms, max gap 23.4 ms, bursts 0%, data/wall 0.995 |
| sdl3-bound-preload3vthen2 | 0 | log | sdl3v:SDL_BindAudioStream x1, sdl3v:SDL_CloseAudioDevice x1, sdl3v:SDL_CreateAudioStream x1, sdl3v:SDL_DestroyAudioStream x1, sdl3v:SDL_OpenAudioDevice x1, sdl3v:SDL_PutAudioStreamData x1, sdl3v:SDL_Quit x1 | |
| sdl3-bound-reopen-g0 | 0 | disk.raw (401408 B, read as 0x8120) | silent | |
| sdl3-bound-reopen-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 49 calls x 8192 B, period 21.33 ms, median gap 21.31 ms, max gap 26.6 ms, bursts 0%, data/wall 0.995 |
| sdl3-bound-reopen-g0 | 0 | sdl3-1 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 98 calls x 4096 B, period 10.67 ms, median gap 10.25 ms, max gap 11.1 ms, bursts 0%, data/wall 1.039 |
| sdl3-bound-reopen-g0 | 0 | log | sdl3:SDL_BindAudioStream x2, sdl3:SDL_CloseAudioDevice x2, sdl3:SDL_CreateAudioStream x2, sdl3:SDL_DestroyAudioStream x2, sdl3:SDL_OpenAudioDevice x2, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-bound-s16-g0 | 0 | disk.raw (397312 B, read as 0x8120) | silent | |
| sdl3-bound-s16-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.29 ms, max gap 27.3 ms, bursts 0%, data/wall 0.997 |
| sdl3-bound-s16-g0 | 0 | log | sdl3:SDL_BindAudioStream x1, sdl3:SDL_CloseAudioDevice x1, sdl3:SDL_CreateAudioStream x1, sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDevice x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-cb-g0 | 0 | disk.raw (770048 B, read as 0x8120) | silent | |
| sdl3-devstream-cb-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 8192 B, period 21.33 ms, median gap 21.36 ms, max gap 32.4 ms, bursts 0%, data/wall 0.993 |
| sdl3-devstream-cb-g0 | 0 | log | sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDeviceStream x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-cb-g1 | 0 | disk.raw (770048 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | |
| sdl3-devstream-cb-g1 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 8192 B, period 21.33 ms, median gap 21.37 ms, max gap 24.0 ms, bursts 0%, data/wall 0.994 |
| sdl3-devstream-cb-g1 | 0 | sdl3-0 vs disk.raw | tap bytes == disk bytes at offset 8192 (761856 of 770048 B) | |
| sdl3-devstream-cb-g1 | 0 | log | sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDeviceStream x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-cb-reopen-g0 | 0 | disk.raw (385024 B, read as 0x8120) | silent | |
| sdl3-devstream-cb-reopen-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 45055 frames, glitches 0, dropouts 0 | 44 calls x 8192 B, period 21.33 ms, median gap 21.60 ms, max gap 65.1 ms, bursts 0%, data/wall 0.921 |
| sdl3-devstream-cb-reopen-g0 | 0 | sdl3-1 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 439.8 Hz, 48128 frames, glitches 0, dropouts 0 | 94 calls x 4096 B, period 10.67 ms, median gap 10.40 ms, max gap 15.5 ms, bursts 0%, data/wall 1.001 |
| sdl3-devstream-cb-reopen-g0 | 0 | log | sdl3:SDL_DestroyAudioStream x2, sdl3:SDL_OpenAudioDeviceStream x2, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-g0 | 0 | disk.raw (794624 B, read as 0x8120) | silent | |
| sdl3-devstream-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.30 ms, max gap 23.0 ms, bursts 0%, data/wall 1.000 |
| sdl3-devstream-g0 | 0 | log | sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDeviceStream x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-g1 | 0 | disk.raw (786432 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3-devstream-g1 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.29 ms, max gap 26.4 ms, bursts 0%, data/wall 0.996 |
| sdl3-devstream-g1 | 0 | sdl3-0 vs disk.raw | tap bytes == disk bytes at offset 0 (786432 of 786432 B) | |
| sdl3-devstream-g1 | 0 | log | sdl3:SDL_DestroyAudioStream x1, sdl3:SDL_OpenAudioDeviceStream x1, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3-devstream-preload3vthen2v | 0 | disk.raw (786432 B, read as 0x8120) | rms 0.1768 (0.500x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3-devstream-preload3vthen2v | 0 | sdl3v-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.31 ms, max gap 23.6 ms, bursts 0%, data/wall 0.998 |
| sdl3-devstream-preload3vthen2v | 0 | log | sdl3v:SDL_DestroyAudioStream x1, sdl3v:SDL_OpenAudioDeviceStream x1, sdl3v:SDL_PutAudioStreamData x1, sdl3v:SDL_Quit x1 | |
| sdl3-devstream-reopen-g0 | 0 | disk.raw (401408 B, read as 0x8120) | silent | |
| sdl3-devstream-reopen-g0 | 0 | sdl3-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 50 calls x 8192 B, period 21.33 ms, median gap 21.30 ms, max gap 22.7 ms, bursts 0%, data/wall 0.998 |
| sdl3-devstream-reopen-g0 | 0 | sdl3-1 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 47999 frames, glitches 0, dropouts 0 | 98 calls x 4096 B, period 10.67 ms, median gap 10.40 ms, max gap 14.3 ms, bursts 0%, data/wall 1.011 |
| sdl3-devstream-reopen-g0 | 0 | log | sdl3:SDL_DestroyAudioStream x2, sdl3:SDL_OpenAudioDeviceStream x2, sdl3:SDL_PutAudioStreamData x1, sdl3:SDL_Quit x1 | |
| sdl3dyn-bound-g0 | 0 | disk.raw (794624 B, read as 0x8120) | silent | |
| sdl3dyn-bound-g0 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.31 ms, max gap 23.3 ms, bursts 0%, data/wall 0.999 |
| sdl3dyn-bound-g0 | 0 | log | sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| sdl3dyn-bound-g1 | 0 | disk.raw (794624 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3dyn-bound-g1 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.33 ms, max gap 34.6 ms, bursts 0%, data/wall 0.988 |
| sdl3dyn-bound-g1 | 0 | sdl3dyn-0 vs disk.raw | tap bytes == disk bytes at offset 0 (794624 of 794624 B) | |
| sdl3dyn-bound-g1 | 0 | log | sdl3dyn:SDL_CloseAudioDevice x1, sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDevice x1, sdl3dyn:SDL_Quit x1 | |
| sdl3dyn-devstream-apppostmix-g0 | 0 | disk.raw (794624 B, read as 0x8120) | silent | |
| sdl3dyn-devstream-apppostmix-g0 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.31 ms, max gap 23.1 ms, bursts 0%, data/wall 0.998 |
| sdl3dyn-devstream-apppostmix-g0 | 0 | log | sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDeviceStream x1, sdl3dyn:SDL_Quit x1, sdl3dyn:SDL_SetAudioPostmixCallback x1 | |
| sdl3dyn-devstream-cb-g0 | 0 | disk.raw (770048 B, read as 0x8120) | silent | |
| sdl3dyn-devstream-cb-g0 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95231 frames, glitches 0, dropouts 0 | 93 calls x 8192 B, period 21.33 ms, median gap 21.39 ms, max gap 22.4 ms, bursts 0%, data/wall 0.997 |
| sdl3dyn-devstream-cb-g0 | 0 | log | sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDeviceStream x1, sdl3dyn:SDL_Quit x1 | |
| sdl3dyn-devstream-cb-g1 | 0 | disk.raw (761856 B, read as 0x8120) | rms 0.3535 (1.000x), 440.2 Hz, 94207 frames, glitches 0, dropouts 0 | |
| sdl3dyn-devstream-cb-g1 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3535 (1.000x), 440.2 Hz, 94207 frames, glitches 0, dropouts 0 | 92 calls x 8192 B, period 21.33 ms, median gap 21.39 ms, max gap 26.8 ms, bursts 0%, data/wall 0.991 |
| sdl3dyn-devstream-cb-g1 | 0 | sdl3dyn-0 vs disk.raw | tap bytes == disk bytes at offset 8192 (753664 of 761856 B) | |
| sdl3dyn-devstream-cb-g1 | 0 | log | sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDeviceStream x1, sdl3dyn:SDL_Quit x1 | |
| sdl3dyn-devstream-g0 | 0 | disk.raw (786432 B, read as 0x8120) | silent | |
| sdl3dyn-devstream-g0 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 96 calls x 8192 B, period 21.33 ms, median gap 21.31 ms, max gap 21.5 ms, bursts 0%, data/wall 1.001 |
| sdl3dyn-devstream-g0 | 0 | log | sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDeviceStream x1, sdl3dyn:SDL_Quit x1 | |
| sdl3dyn-devstream-g1 | 0 | disk.raw (794624 B, read as 0x8120) | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | |
| sdl3dyn-devstream-g1 | 0 | sdl3dyn-0 fmt=0x8120 ch=2 48000 Hz tid_changes=0 | rms 0.3536 (1.000x), 440.0 Hz, 95999 frames, glitches 0, dropouts 0 | 97 calls x 8192 B, period 21.33 ms, median gap 21.34 ms, max gap 27.8 ms, bursts 0%, data/wall 0.990 |
| sdl3dyn-devstream-g1 | 0 | sdl3dyn-0 vs disk.raw | tap bytes == disk bytes at offset 0 (794624 of 794624 B) | |
| sdl3dyn-devstream-g1 | 0 | log | sdl3dyn:SDL_DYNAPI_entry x1, sdl3dyn:SDL_DestroyAudioStream x1, sdl3dyn:SDL_OpenAudioDeviceStream x1, sdl3dyn:SDL_Quit x1 | |
