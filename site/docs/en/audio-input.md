# Audio Input and BPM

The sound selected with “Audio Input” at the top, and how BPM and beats are matched.

## Audio input

Use “Audio Input” at the top to choose the sound to react to.

- App audio: the sound of clips. Received regardless of master volume and mute.
- Input device: microphone or line input. Bring in sound from a DJ mixer or other apps through a line input or a virtual device such as BlackHole. The first time, you are asked for permission to use the microphone.

### Audio bands

The sound is split into these 5 bands.

| Band | Contents |
|---|---|
| Volume | Overall loudness |
| Low | up to 150 Hz |
| Mid | 150–2500 Hz |
| High | 2500 Hz and up |
| Attack | Becomes 1 the moment the bass suddenly gets loud (the start of a kick), then eases back |

- Auto gain (the loudest recent sound becomes 100%, so it works regardless of input level).
- You can set how quickly the values fall back when the sound stops.
- Meters of the current values appear next to the button and in the settings.

Audio input settings are per Mac and are not saved in the project (motion settings are). For driving values with audio, see [Animating Values](animation.md).

## Auto BPM

“Auto” in the BPM field keeps matching the BPM and the downbeat to the sound (the one selected with “Audio Input” at the top).

- Onset strength (low band and overall) is sampled about 190 times per second.
- The BPM is found from repetition (autocorrelation) over the last 8 seconds, and the downbeat from the position where summing at that interval gives the strongest result.
- It checks every second, and adjusts when 3 consecutive results are within 2% (green number = locked).
- Small differences (under 0.4 BPM or 30 ms) are not adjusted.
- It searches between 78 and 160 BPM. Faster tracks are detected at half tempo (174 BPM DnB reads as 87).
- BPM changes made automatically don't count as edits for saving or undo.
- Tap and “Resync” can be used at any time. → [Live Panel and Tempo](live.md)
