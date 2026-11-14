# TB M50 Single Channel Strip (Mountain Lion VST)

One input channel of the **TASCAM M-50** mixing console, **mono in and mono out**, as a **VST 2.4,
64-bit Intel plugin for Mac OS X 10.8.5** (Pro Tools 11 through Blue Cat PatchWork). Non-commercial,
for personal use.

It goes as an insert on every track, so a whole session sounds recorded through an M-50, with
**TB M50 Dual Channel Strip** on the mix buss as the tracks return from tape. The signal goes straight
through the strip to the channel fader and out: no PAN, no buss, no master.

The sound is the approved dual build's channel, unchanged (`Source/DSP/M50.cpp`; see the
[TB-M50-Dual-Channel-Strip-MOUNTAIN-LION](https://github.com/tonybuzzcock/TB-M50-Dual-Channel-Strip-MOUNTAIN-LION)
README for how it is modelled and the estimates to tune). The modern Mac version will live in
`TB-M50-Single-Channel-Strip-2026-MAC`.

## Panel

A tall narrow strip in the M-50's colours, in the same lacquered mahogany frame as the dual
(368 x 1028). Top to bottom:

| Control | Range |
|---|---|
| VU | 0 VU = nominal (-10 dBV = -18 dBFS) |
| INPUT | MIC / D.I. / LINE slide switch; the lever glows at the engaged position |
| TRIM | MIC +20..+60 dB, D.I. +12..+48 dB, LINE -15..+25 dB; nominal at 0.375 (about 11 o'clock) |
| OVERLOAD LED | large, beside TRIM: lights 25 dB over nominal |
| EQUALIZER BYPASS | lit red with its LED when bypassed |
| HIGH / MID / LOW | orange ring = FREQUENCY (2.5-15 kHz, 500 Hz-5 kHz, 50 Hz-1 kHz), dark cap = BOOST / CUT +-15 dB |
| BYPASS | the whole plugin, lit red when in; a 10 ms fade to the dry input, then untouched. This plugin only (not tied to the host's bypass); presets don't change it |
| Fader | 10 = +8 dB, 7.5 = 0 dB, 5 = -10, 2.5 = -25, 1 = -40, 0 = off |

Right-click (or Control-click) any control to see its exact value in the readout without moving it.
Bottom strip: the TB electronic logo, SAVE, 8 named preset keys (two rows of 4; the one in use glows
red), "M-50" and the tan readout.

## The OVERLOAD LED is part of the sound

On the real desk things start to sound great when the red OVERLOAD LED flashes now and then; on a
strip used on every track that matters even more. The LED's comparator watches the preamp and lights
25 dB over nominal (held 120 ms so each flash shows). The preamp's rails are about 4 dB above that, and
the rounding starts gently just under the LED's point, so when it flashes the peaks are being shaped.
Turn TRIM up until it flashes on the loudest moments, then set the level with the fader.

## Build

GitHub Actions builds the bundle on an Intel macOS runner with `-mmacosx-version-min=10.8.5`, checks
the binary declares 10.8.5 and links only libraries 10.8.5 has, loads it in a test host, drives the
panel offscreen and publishes screenshots to the `gui-preview` branch.

Local tests: `make -C Tests run vst-run`, sanitizers: `make -C Tests asan`.

## Install

Actions -> latest run -> Artifacts -> `TB-M50-Single-Channel-Strip-mountain-lion-vst`. Unzip it
(twice), copy `TB M50 Single Channel Strip.vst` to `/Library/Audio/Plug-Ins/VST/`, then rescan in
PatchWork.
