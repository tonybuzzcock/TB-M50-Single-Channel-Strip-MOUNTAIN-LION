// M50.cpp
// See M50.h. Every value the M-50 manual doesn't give is a named estimate here.

#include "M50.h"

#include <cmath>

namespace tbm50s
{

namespace
{
    // ---- From the manual -------------------------------------------------
    const double kVoltsPerUnit = 2.5;          // host 1.0 = 2.5 V peak: -10 dBV nominal = -18 dBFS
    const double kNominalVrms  = 0.316228;     // -10 dBV, the M-50's nominal level (0 VU)
    const double kEqRangeDb    = 15.0;         // boost / cut +-15 dB
    const double kEqLo[kNumBands] = { 50.0, 500.0, 2500.0 };
    const double kEqHi[kNumBands] = { 1000.0, 5000.0, 15000.0 };
    const double kOverloadDb   = 25.0;         // OVERLOAD LED: 25 dB above nominal

    // ---- Estimates (no component schematic) ------------------------------
    const double kMicCalDb     = -35.0;        // a -18 dBFS track = a -45 dBV mic (nominal at TRIM 0.375)
    const double kMicTrimMinDb = 20.0, kMicTrimMaxDb = 60.0;   // from the mic input specs
    const double kDiCalDb      = -25.5;        // a -18 dBFS track = a -35.5 dBV instrument (nominal at 0.375)
    const double kDiTrimMinDb  = 12.0, kDiTrimMaxDb = 48.0;    // from the instrument input specs
    const double kDiLoadOhm    = 100.0e3;      // the M-50's instrument input
    const double kRefLoadOhm   = 1.0e6;        // what a DI track was recorded into
    const double kPickupL      = 2.5;          // a single-coil-ish pickup, H
    const double kPickupR      = 6.5e3;        // its resistance
    const double kPickupC      = 470.0e-12;    // cable
    const double kGuitarPotOhm = 250.0e3;      // guitar volume pot, on full (in parallel with the load)
    const double kDiEinVrms    = 2.0e-6;       // instrument preamp hiss
    const double kLineTrimMinDb = -15.0, kLineTrimMaxDb = 25.0; // 0 dB at 0.375 (about 11 o'clock)
    const double kMicGbwHz     = 20.0e6;       // mic preamp op-amp gain-bandwidth
    const double kMicHpHz      = 25.0;         // mic input coupling
    const double kDiHpHz       = 12.0;         // instrument input coupling
    const double kLineHpHz     = 8.0;          // line input coupling
    const double kOutHpHz      = 4.0;          // channel / master output coupling
    const double kEqQ          = 0.9;          // bell width, read from the manual's curves
    // Preamp output: op-amps on +-15 V rails swing about +13.5 / -12.5 V. The
    // OVERLOAD LED (8 V peak, 25 dB over nominal) comes on about 4 dB below the
    // rails, and the rounding starts gently a little before it: an occasional flash
    // means the peaks are being shaped, as the user hears on the real desk.
    const double kPreKneePosV  = 6.5, kPreSwingPosV = 13.5;
    const double kPreKneeNegV  = 6.0, kPreSwingNegV = 12.5;
    const double kOlHoldS      = 0.12;         // LED stays lit this long after a peak (visible flash)
    const double kBusKneeV     = 9.0, kBusSwingV = 12.5;    // summing / output amps
    const double kMicEinVrms   = 1.0e-6;       // -120 dBV input-referred mic hiss
    const double kLineNoiseVrms = 2.5e-5;      // -92 dBV at the line amp's output
    const double kBusNoiseVrms  = 1.8e-5;      // -95 dBV on each buss
    const double kSmoothS      = 0.012;        // pot smoothing
    const double kGainS        = 0.008;        // fader / pan smoothing
    const double kVuTauS       = 0.065;        // two poles: about 300 ms to 99 %, as a VU

    // Fader law (whole channel, the +8 dB channel buffer amp included): marks 0..10 -> dB
    const double kFaderMarks[7] = { 0.0, 0.5, 1.0, 2.5, 5.0, 7.5, 10.0 };
    const double kFaderDb[7]    = { -200.0, -60.0, -40.0, -25.0, -10.0, 0.0, 8.0 };

    inline double dbToGain (double db) { return std::pow (10.0, db / 20.0); }

    inline double softClip (double x, double knee, double swing)
    {
        const double a = x < 0.0 ? -x : x;
        if (a <= knee) return x;
        const double r = swing - knee;
        const double y = knee + r * std::tanh ((a - knee) / r);
        return x < 0.0 ? -y : y;
    }

    // The preamp's slightly lopsided swing (a touch of even harmonics as it rounds)
    inline double preClip (double x)
    {
        return x >= 0.0 ? softClip (x, kPreKneePosV, kPreSwingPosV) : softClip (x, kPreKneeNegV, kPreSwingNegV);
    }

    inline double noise (unsigned& s)
    {
        // roughly Gaussian, unit rms (sum of three uniforms)
        double acc = 0.0;
        for (int k = 0; k < 3; ++k)
        {
            s = s * 1664525u + 1013904223u;
            acc += (double) (s >> 8) / 16777216.0 - 0.5;
        }
        return acc * 2.0;      // var of the sum = 3/12 -> x2 gives 1
    }

    double faderLaw (double v)
    {
        const double m = (v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v)) * 10.0;
        for (int k = 1; k < 7; ++k)
            if (m <= kFaderMarks[k])
            {
                const double t = (m - kFaderMarks[k - 1]) / (kFaderMarks[k] - kFaderMarks[k - 1]);
                return kFaderDb[k - 1] + t * (kFaderDb[k] - kFaderDb[k - 1]);
            }
        return kFaderDb[6];
    }

    inline double faderGain (double v)
    {
        if (v <= 0.0) return 0.0;
        double g = dbToGain (faderLaw (v));
        if (v < 0.05) g *= v / 0.05;          // fully down: off
        return g;
    }

    inline double clamp01 (double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }
}

//==============================================================================
void Peak::set (double f, double gainDb, double q, double fs)
{
    if (f > 0.45 * fs) f = 0.45 * fs;
    const double A = std::pow (10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * f / fs;
    const double alpha = std::sin (w0) / (2.0 * q);
    const double c = std::cos (w0);
    const double a0 = 1.0 + alpha / A;
    bq.b0 = (1.0 + alpha * A) / a0;
    bq.b1 = (-2.0 * c) / a0;
    bq.b2 = (1.0 - alpha * A) / a0;
    bq.a1 = (-2.0 * c) / a0;
    bq.a2 = (1.0 - alpha / A) / a0;
}

//==============================================================================
Channel::Channel()
    : fs (44100.0), mode (kInLine), trimT (0.375), trim (0.375),
      bypassT (0.0), bypass (0.0), faderG (1.0), faderGT (1.0),
      panLT (1.0), panRT (0.0), pl (1.0), pr (0.0), smK (0.0), gainK (0.0), countdown (0),
      preGain (1.0), seed (1u),
      vuA (0.0), vuB (0.0), vuK (0.0), olCount (0), olHoldSamples (1), olThreshold (8.0)
{
    for (int b = 0; b < kNumBands; ++b) { fT[b] = f[b] = 0.5; gT[b] = g[b] = 0.5; }
}

void Channel::prepare (double sampleRate, unsigned s)
{
    fs = sampleRate;
    seed = s;
    smK = 1.0 - std::exp (-1.0 / (kSmoothS * fs));
    gainK = 1.0 - std::exp (-1.0 / (kGainS * fs));
    vuK = 1.0 - std::exp (-1.0 / (kVuTauS * fs));
    olHoldSamples = (int) (kOlHoldS * fs);
    olThreshold = kNominalVrms * std::sqrt (2.0) * dbToGain (kOverloadDb);
    hpOut.highpass (kOutHpHz, fs);
    updatePickup();
    reset();
}

void Channel::reset()
{
    trim = trimT;
    for (int b = 0; b < kNumBands; ++b) { f[b] = fT[b]; g[b] = gT[b]; eq[b].bq.reset(); }
    bypass = bypassT;
    faderG = faderGT;
    pl = panLT; pr = panRT;
    updatePreamp();
    updateFilters();
    hpIn.reset(); gbw.reset(); hpOut.reset(); pickup.reset();
    vuA = vuB = 0.0;
    olCount = 0;
    countdown = 0;
}

double Channel::trimDb (int m, double v)
{
    v = clamp01 (v);
    if (m == kInMic) return kMicTrimMinDb + (kMicTrimMaxDb - kMicTrimMinDb) * v;
    if (m == kInDI)  return kDiTrimMinDb + (kDiTrimMaxDb - kDiTrimMinDb) * v;
    return kLineTrimMinDb + (kLineTrimMaxDb - kLineTrimMinDb) * v;
}

double Channel::eqHz (int band, double v)
{
    if (band < 0) band = 0;
    if (band >= kNumBands) band = kNumBands - 1;
    return kEqLo[band] * std::pow (kEqHi[band] / kEqLo[band], clamp01 (v));
}

double Channel::eqDb (double v) { return (clamp01 (v) * 2.0 - 1.0) * kEqRangeDb; }
double Channel::faderDb (double v) { return v <= 0.0 ? -200.0 : faderLaw (v); }
double Channel::panL (double v) { return std::cos (clamp01 (v) * 0.5 * kPi); }
double Channel::panR (double v) { return std::sin (clamp01 (v) * 0.5 * kPi); }

void Channel::setInput (int m)
{
    if (m < 0) m = 0;
    if (m >= kNumInputs) m = kNumInputs - 1;
    if (m == mode) return;
    mode = m;
    updatePreamp();
}

void Channel::setTrim (double v) { trimT = clamp01 (v); }
void Channel::setEqFreq (int b, double v) { if (b >= 0 && b < kNumBands) fT[b] = clamp01 (v); }
void Channel::setEqGain (int b, double v) { if (b >= 0 && b < kNumBands) gT[b] = clamp01 (v); }
void Channel::setBypass (bool b) { bypassT = b ? 1.0 : 0.0; }
void Channel::setPan (double v) { panLT = panL (v); panRT = panR (v); }
void Channel::setFader (double v) { faderGT = faderGain (clamp01 (v)); }

void Channel::updatePreamp()
{
    const double cal = mode == kInMic ? kMicCalDb : (mode == kInDI ? kDiCalDb : 0.0);
    preGain = dbToGain (trimDb (mode, trim) + cal);
    // the mic / instrument preamp's closed-loop bandwidth: GBW / noise gain
    if (mode != kInLine)
    {
        double bw = kMicGbwHz / dbToGain (trimDb (mode, trim));
        if (bw > 0.45 * fs) bw = 0.45 * fs;
        gbw.lowpass (bw, fs);
    }
    else { gbw.b0 = 1.0; gbw.b1 = 0.0; gbw.a1 = 0.0; }
    hpIn.highpass (mode == kInMic ? kMicHpHz : (mode == kInDI ? kDiHpHz : kLineHpHz), fs);
}

// D.I.: the pickup + cable driving the 100k input, relative to the 1M it was
// recorded into. Each is 1 / (L C s^2 + (L / Rl + R C) s + 1 + R / Rl), Rl the load
// in parallel with the guitar's volume pot; the ratio, normalised at DC.
void Channel::updatePickup()
{
    const double rl1 = 1.0 / (1.0 / kDiLoadOhm + 1.0 / kGuitarPotOhm);
    const double rl0 = 1.0 / (1.0 / kRefLoadOhm + 1.0 / kGuitarPotOhm);
    const double L = kPickupL, R = kPickupR, C = kPickupC;
    const double n0 = 1.0 + R / rl0, d0 = 1.0 + R / rl1;
    const double k = d0 / n0;
    pickup.setAnalog (k * L * C, k * (L / rl0 + R * C), k * n0, L * C, L / rl1 + R * C, d0, fs);
}

void Channel::updateFilters()
{
    for (int b = 0; b < kNumBands; ++b)
        eq[b].set (eqHz (b, f[b]), eqDb (g[b]), kEqQ, fs);
}

inline void Channel::tick (double x, double& busL, double& busR)
{
    // Pots glide; filters follow every 16 samples while anything moves
    if (--countdown <= 0)
    {
        countdown = 16;
        bool moved = std::fabs (trimT - trim) > 1e-7;
        trim += (trimT - trim) * (1.0 - std::pow (1.0 - smK, 16.0));
        for (int b = 0; b < kNumBands; ++b)
        {
            if (std::fabs (fT[b] - f[b]) > 1e-7 || std::fabs (gT[b] - g[b]) > 1e-7) moved = true;
            f[b] += (fT[b] - f[b]) * (1.0 - std::pow (1.0 - smK, 16.0));
            g[b] += (gT[b] - g[b]) * (1.0 - std::pow (1.0 - smK, 16.0));
        }
        if (moved) { updatePreamp(); updateFilters(); }
    }

    // Input and preamp
    double v = hpIn.tick (x);
    if (mode == kInDI) v = pickup.tick (v);
    else pickup.tick (0.0);                     // idles, ready for the switch
    double pre = v * preGain;
    if (mode == kInMic) pre += kMicEinVrms * noise (seed) * dbToGain (trimDb (kInMic, trim));
    if (mode == kInDI)  pre += kDiEinVrms * noise (seed) * dbToGain (trimDb (kInDI, trim));
    pre = gbw.tick (pre);
    if (mode == kInLine) pre += kLineNoiseVrms * noise (seed);
    const double apre = pre < 0.0 ? -pre : pre;      // the LED's comparator looks at the preamp's drive
    if (apre > olThreshold) olCount = olHoldSamples;
    else if (olCount > 0) --olCount;
    pre = preClip (pre);

    // EQ (bypass crossfades so the switch doesn't click)
    double e = pre;
    for (int b = 0; b < kNumBands; ++b) e = eq[b].tick (e);
    e = softClip (e, kBusKneeV, kBusSwingV);
    bypass += (bypassT - bypass) * gainK;
    const double eqOut = pre + (e - pre) * (1.0 - bypass);

    // Fader and buffer amp
    faderG += (faderGT - faderG) * gainK;
    double out = hpOut.tick (softClip (eqOut * faderG, kBusKneeV, kBusSwingV));

    // VU: two-pole averaging of the rectified signal
    vuA += ((out < 0.0 ? -out : out) - vuA) * vuK;
    vuB += (vuA - vuB) * vuK;

    pl += (panLT - pl) * gainK;
    pr += (panRT - pr) * gainK;
    busL += out * pl;
    busR += out * pr;
}

double Channel::processMono (double x)
{
    double l = 0.0, r = 0.0;
    pl = panLT = 1.0; pr = panRT = 0.0;       // straight from the fader, no PAN
    tick (x, l, r);
    return l;
}

//==============================================================================
M50::M50()
    : fs (44100.0), masterG (1.0), masterGT (1.0), gainK (0.0),
      vuLA (0.0), vuLB (0.0), vuRA (0.0), vuRB (0.0), vuK (0.0), seed (50u)
{
    ch[0].setPan (0.0);
    ch[1].setPan (1.0);
}

double M50::masterDb (double v) { return Channel::faderDb (v); }
double M50::vuZeroVolts() { return kNominalVrms * 2.0 * std::sqrt (2.0) / kPi; }
double M50::overloadVolts() { return kNominalVrms * std::sqrt (2.0) * dbToGain (kOverloadDb); }
double M50::voltsPerUnit() { return kVoltsPerUnit; }

void M50::prepare (double sampleRate)
{
    fs = sampleRate > 1000.0 ? sampleRate : 44100.0;
    ch[0].prepare (fs, 0x1234567u);
    ch[1].prepare (fs, 0x7654321u);
    gainK = 1.0 - std::exp (-1.0 / (kGainS * fs));
    vuK = 1.0 - std::exp (-1.0 / (kVuTauS * fs));
    hpL.highpass (kOutHpHz, fs);
    hpR.highpass (kOutHpHz, fs);
    reset();
}

void M50::reset()
{
    ch[0].reset();
    ch[1].reset();
    masterG = masterGT;
    hpL.reset(); hpR.reset();
    vuLA = vuLB = vuRA = vuRB = 0.0;
}

void M50::setMaster (double v)
{
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;
    masterGT = faderGain (v);
}

void M50::process (const float* inL, const float* inR, float* outL, float* outR, int n)
{
    const double toV = kVoltsPerUnit, fromV = 1.0 / kVoltsPerUnit;
    for (int i = 0; i < n; ++i)
    {
        double bl = kBusNoiseVrms * noise (seed), br = kBusNoiseVrms * noise (seed);
        ch[0].tick ((double) inL[i] * toV, bl, br);
        ch[1].tick ((double) inR[i] * toV, bl, br);
        bl = softClip (bl, kBusKneeV, kBusSwingV);
        br = softClip (br, kBusKneeV, kBusSwingV);

        masterG += (masterGT - masterG) * gainK;
        double l = hpL.tick (softClip (bl * masterG, kBusKneeV, kBusSwingV));
        double r = hpR.tick (softClip (br * masterG, kBusKneeV, kBusSwingV));

        vuLA += ((l < 0.0 ? -l : l) - vuLA) * vuK;  vuLB += (vuLA - vuLB) * vuK;
        vuRA += ((r < 0.0 ? -r : r) - vuRA) * vuK;  vuRB += (vuRA - vuRB) * vuK;

        outL[i] = (float) (l * fromV);
        outR[i] = (float) (r * fromV);
    }
}

} // namespace tbm50s
