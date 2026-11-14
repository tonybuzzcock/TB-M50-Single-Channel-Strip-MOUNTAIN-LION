// M50.h
// The TASCAM M-50's input channel (TB M50 Single Channel Strip uses one Channel
// on its own, through processMono). The M50 class is the dual build's: two input channels and the stereo master,
// as one effect for a stereo insert (a drum buss, the mix buss): the left input
// feeds channel 1 and the right input channel 2, each channel is panned onto the
// stereo programme buss (hard left and hard right by default, so the image is
// kept), and the STEREO MASTER fader sets the output.
//
// There is no component schematic: the model follows the M-50 operation and
// maintenance manual (block diagram, level diagram, specifications):
//
//   per channel
//     INPUT MIC / D.I. / LINE (the real channels 1-2 select MIC / INST / RMX)
//       -> input coupling high-pass
//       MIC:  low-noise mic preamp, trim +20..+60 dB (op-amp gain-bandwidth limits
//             its top end at high gain; input-referred hiss)
//       D.I.: the 100k instrument input, trim +12..+48 dB (from the specs). A guitar
//             pickup loaded by 100k instead of an interface's 1M: its resonance is
//             damped and the top end softens (a fixed pickup + cable model)
//       LINE: line amp, trim -15..+25 dB
//     -> preamp output: OVERLOAD LED 25 dB above nominal (the manual), op-amp rails
//        about 4 dB above that, rounding gently from just under the LED
//     -> three-section semi-parametric (sweep) EQ, +-15 dB:
//            LOW 50 Hz - 1 kHz, MID 500 Hz - 5 kHz, HIGH 2.5 kHz - 15 kHz
//        EQ BYPASS takes the whole section out
//     -> input fader -> channel buffer amp (+8 dB, as the manual says) -> VU
//     -> PAN (sine / cosine law: hard left or right is 0 dB, centre -3 dB)
//   stereo buss: summing amps (swing, buss hiss)
//   STEREO MASTER fader -> master output amps -> L / R VU
//
// Levels: 1.0 in the host = 2.5 V peak, so the M-50's nominal -10 dBV (0.316 V rms)
// is a -18 dBFS rms sine, and 0 VU. TRIM at 0.375 (about 11 o'clock) is nominal
// in every INPUT position; faders at 7.5,
// pans hard over and the EQ flat pass a source through at unity. MIC takes a
// -18 dBFS track as a -45 dBV microphone, D.I. as a -35.5 dBV instrument. Turning
// TRIM up from there drives the preamp towards the OVERLOAD LED.
//
// Every value the manual doesn't give is a named estimate in M50.cpp.
// Volts inside, plain C++98, no allocation, no latency.

#ifndef TBM50_M50_H
#define TBM50_M50_H

#include "Filters.h"

namespace tbm50s
{

enum Band { kLow = 0, kMid, kHigh, kNumBands };
enum InputMode { kInMic = 0, kInDI, kInLine, kNumInputs };

// RBJ peaking section with a fixed Q (the M-50's bells keep their width)
struct Peak
{
    Biquad bq;
    void set (double f, double gainDb, double q, double fs);
    inline double tick (double x) { return bq.tick (x); }
};

class Channel
{
public:
    Channel();
    void prepare (double fs, unsigned seed);
    void reset();

    void setInput (int mode);                   // InputMode
    void setTrim (double v);                    // 0..1, 0.375 = nominal
    void setEqFreq (int band, double v);        // 0..1 over the band's range
    void setEqGain (int band, double v);        // 0..1, 0.5 = flat
    void setBypass (bool b);
    void setPan (double v);                     // 0 = L, 0.5 = centre, 1 = R
    void setFader (double v);                   // 0..1 = marks 0..10

    // One sample: x is the source in volts at the input jack (before the MIC
    // calibration). Adds the channel's contribution to the buss.
    inline void tick (double x, double& busL, double& busR);

    // The single-channel plugin: one sample through the strip to the fader's
    // output (no PAN, no buss), volts in, volts out
    double processMono (double x);

    double vu() const { return vuB; }           // rectified average, volts
    bool overload() const { return olCount > 0; }   // OVERLOAD LED lit (held briefly after each peak)

    // Laws, for the wrapper's display and the tests
    static double trimDb (int mode, double v);
    static double eqHz (int band, double v);
    static double eqDb (double v);
    static double faderDb (double v);           // whole channel: fader + buffer amp
    static double panL (double v);
    static double panR (double v);

private:
    void updateFilters();
    void updatePreamp();
    void updatePickup();

    double fs;
    int mode;
    double trimT, trim;                         // pot targets, smoothed
    double fT[kNumBands], f[kNumBands], gT[kNumBands], g[kNumBands];
    double bypassT, bypass;                     // crossfade 0..1 (1 = bypassed)
    double faderG, faderGT, panLT, panRT, pl, pr;
    double smK, gainK;
    int    countdown;

    FirstOrder hpIn;                            // input coupling
    FirstOrder gbw;                             // mic / D.I. preamp's closed-loop bandwidth
    Biquad pickup;                              // D.I.: pickup into 100k vs into 1M
    Peak eq[kNumBands];
    FirstOrder hpOut;                           // channel output coupling
    double preGain;
    unsigned seed;

    double vuA, vuB, vuK;
    int    olCount, olHoldSamples;
    double olThreshold;
};

class M50
{
public:
    M50();
    void prepare (double sampleRate);
    void reset();

    Channel& channel (int i) { return ch[i]; }
    const Channel& channel (int i) const { return ch[i]; }
    void setMaster (double v);                  // 0..1 = marks 0..10

    // Left -> channel 1, right -> channel 2; stereo out (host units: 1.0 = 2.5 V peak).
    // inL and inR may be the same buffer (a mono source); outputs must not alias inputs.
    void process (const float* inL, const float* inR, float* outL, float* outR, int numSamples);

    static int latencySamples() { return 0; }
    static double masterDb (double v);

    // Meters, volts (rectified average for VUs)
    double vuL() const { return vuLB; }
    double vuR() const { return vuRB; }
    static double vuZeroVolts();                // rectified average of a 0 VU sine
    static double overloadVolts();              // OVERLOAD LED threshold, peak volts
    static double voltsPerUnit();               // 2.5

private:
    double fs;
    Channel ch[2];
    double masterG, masterGT, gainK;
    FirstOrder hpL, hpR;
    double vuLA, vuLB, vuRA, vuRB, vuK;
    unsigned seed;
};

} // namespace tbm50s

#endif
