// Params.h
// Parameter table shared by the VST wrapper, the editor and the preset store.
//
// One TASCAM M-50 input channel, top to bottom as on the strip: INPUT (MIC /
// D.I. / LINE, as the real channels 1-2's MIC / INST / RMX), TRIM, EQUALIZER
// BYPASS, HIGH / MID / LOW (frequency, then boost / cut), the fader. Then
// BYPASS (the whole plugin; the user's addition, where PAN would be).
// Left off at the user's request: MIC ATT, PHASE, the AUX sends, ASSIGN, MUTE,
// SOLO / PFL, PAN.

#ifndef TBM50S_PARAMS_H
#define TBM50S_PARAMS_H

namespace tbm50s
{

enum Param
{
    kInput = 0, kTrim, kEqBypass, kHiFreq, kHiGain, kMidFreq, kMidGain, kLoFreq, kLoGain, kFader,
    kBypass,
    kNumParams
};

enum Kind { kMicLine, kTrimDb, kBypassSw, kHiHz, kMidHz, kLoHz, kEqDb, kFaderDb, kBypassAll };

const char* const kParamNames[kNumParams] = {
    "Input", "Trim", "EQ Byp", "HiFreq", "HiGain", "MdFreq", "MdGain", "LoFreq", "LoGain", "Fader", "Bypass"
};

const int kParamKind[kNumParams] = {
    kMicLine, kTrimDb, kBypassSw, kHiHz, kEqDb, kMidHz, kEqDb, kLoHz, kEqDb, kFaderDb, kBypassAll
};

// Defaults: LINE, TRIM at 0.375 (nominal, about 11 o'clock), EQ in and flat with
// the frequencies at 12 o'clock, fader at 7.5 (0 dB): unity.
const float kDefaults[kNumParams] = {
    1.0f, 0.375f, 0.0f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.75f, 0.0f
};

inline bool isOn (float v) { return v >= 0.5f; }

// INPUT selector: 0 MIC, 0.5 D.I., 1 LINE (the DSP's InputMode order)
inline int inputIndex (float v)
{
    const int k = (int) (v * 2.0f + 0.5f);
    return k < 0 ? 0 : (k > 2 ? 2 : k);
}
inline float inputValue (int k) { return (float) k * 0.5f; }

} // namespace tbm50s

#endif
