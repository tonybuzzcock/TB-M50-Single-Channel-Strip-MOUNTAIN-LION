// m50_test.cpp
// DSP tests for the M-50 model: unity at the defaults, every control's law, the
// EQ's bands, pan, faders, MIC vs LINE, the OVERLOAD point, VU calibration,
// stability under abuse, automation, CPU, and demo renders.
//
//   m50_test [render dir]

#include "../Source/DSP/M50.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

using namespace tbm50s;

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static const double kFs = 44100.0;
static const double kNom = 0.316228 * std::sqrt (2.0) / 2.5;   // -18 dBFS rms sine, peak in host units

// A console at the plugin's defaults (Params.h)
static void defaults (M50& m)
{
    for (int c = 0; c < 2; ++c)
    {
        Channel& ch = m.channel (c);
        ch.setInput (kInLine); ch.setTrim (0.375); ch.setBypass (false);
        for (int b = 0; b < kNumBands; ++b) { ch.setEqFreq (b, 0.5); ch.setEqGain (b, 0.5); }
        ch.setPan (c == 0 ? 0.0 : 1.0);
        ch.setFader (0.75);
    }
    m.setMaster (0.75);
}

// rms gain (dB) from input to each output for a sine
static void gainAt (M50& m, double hz, double amp, double& gl, double& gr)
{
    m.reset();
    const int n = (int) (kFs * 0.5);
    std::vector<float> x (n), l (n), r (n);
    for (int i = 0; i < n; ++i) x[i] = (float) (amp * std::sin (2.0 * kPi * hz * i / kFs));
    m.process (&x[0], &x[0], &l[0], &r[0], n);
    double si = 0.0, sl = 0.0, sr = 0.0;
    for (int i = n / 2; i < n; ++i) { si += (double) x[i] * x[i]; sl += (double) l[i] * l[i]; sr += (double) r[i] * r[i]; }
    gl = 10.0 * std::log10 ((sl + 1e-30) / si);
    gr = 10.0 * std::log10 ((sr + 1e-30) / si);
}

static double gainL (M50& m, double hz, double amp = kNom)
{
    double gl, gr;
    gainAt (m, hz, amp, gl, gr);
    return gl;
}

static void writeWav (const std::string& path, const std::vector<float>& l, const std::vector<float>& r)
{
    FILE* f = std::fopen (path.c_str(), "wb");
    if (! f) return;
    const unsigned n = (unsigned) l.size(), bytes = n * 4;
    unsigned char h[44];
    std::memcpy (h, "RIFF", 4);
    unsigned v = 36 + bytes; std::memcpy (h + 4, &v, 4);
    std::memcpy (h + 8, "WAVEfmt ", 8);
    v = 16; std::memcpy (h + 16, &v, 4);
    unsigned short s = 1; std::memcpy (h + 20, &s, 2);
    s = 2; std::memcpy (h + 22, &s, 2);
    v = (unsigned) kFs; std::memcpy (h + 24, &v, 4);
    v = (unsigned) kFs * 4; std::memcpy (h + 28, &v, 4);
    s = 4; std::memcpy (h + 32, &s, 2);
    s = 16; std::memcpy (h + 34, &s, 2);
    std::memcpy (h + 36, "data", 4);
    std::memcpy (h + 40, &bytes, 4);
    std::fwrite (h, 1, 44, f);
    for (unsigned i = 0; i < n; ++i)
    {
        const float a[2] = { l[i], r[i] };
        for (int c = 0; c < 2; ++c)
        {
            double y = a[c] * 32767.0;
            if (y > 32767.0) y = 32767.0;
            if (y < -32768.0) y = -32768.0;
            const short q = (short) y;
            std::fwrite (&q, 2, 1, f);
        }
    }
    std::fclose (f);
}

int main (int argc, char** argv)
{
    setvbuf (stdout, 0, _IONBF, 0);
    const std::string dir = argc > 1 ? argv[1] : ".";
    M50* mp = new M50();
    M50& m = *mp;
    m.prepare (kFs);

    std::printf ("Defaults\n");
    defaults (m);
    {
        double gl, gr;
        gainAt (m, 1000.0, kNom, gl, gr);
        std::printf ("  1 kHz at -18 dBFS: L %+.2f dB, R %+.2f dB\n", gl, gr);
        check (std::fabs (gl) < 0.2 && std::fabs (gr) < 0.2, "unity on both sides at the defaults");
        const double g40 = gainL (m, 40.0), g15k = gainL (m, 15000.0);
        std::printf ("  40 Hz %+.2f dB, 15 kHz %+.2f dB\n", g40, g15k);
        check (std::fabs (g40) < 0.5 && std::fabs (g15k) < 0.5, "flat across the band (LINE, EQ flat)");
    }

    std::printf ("\nTRIM\n");
    {
        m.channel (0).setTrim (1.0);
        const double hi = gainL (m, 1000.0, kNom * 0.05);
        m.channel (0).setTrim (0.0);
        const double lo = gainL (m, 1000.0);
        m.channel (0).setTrim (0.375);
        std::printf ("  LINE trim: max %+.1f dB, min %+.1f dB\n", hi, lo);
        check (std::fabs (hi - 25.0) < 0.5 && std::fabs (lo + 15.0) < 0.5, "LINE trim -15..+25 dB");
        m.channel (0).setInput (kInMic);
        const double mic = gainL (m, 1000.0);
        std::printf ("  MIC at 0.375: %+.2f dB\n", mic);
        check (std::fabs (mic) < 0.5, "MIC at 0.375 is nominal too");
        m.channel (0).setTrim (1.0);
        const double m1k = gainL (m, 1000.0, kNom * 0.01), m15k = gainL (m, 15000.0, kNom * 0.01);
        std::printf ("  MIC at full gain: 1 kHz %+.1f dB, 15 kHz %+.1f dB\n", m1k, m15k);
        check (std::fabs (m1k - 25.0) < 0.6, "MIC trim reaches +60 dB (+25 over nominal)");
        check (m15k < m1k - 0.8, "the mic preamp's top end closes in at full gain");
        m.channel (0).setTrim (0.375);
        m.channel (0).setInput (kInDI);
        const double di1k = gainL (m, 1000.0), di100 = gainL (m, 100.0), di5k = gainL (m, 5000.0);
        std::printf ("  D.I. at 0.375: 100 Hz %+.2f, 1 kHz %+.2f, 5 kHz %+.2f dB\n", di100, di1k, di5k);
        check (std::fabs (di100) < 0.5 && std::fabs (di1k) < 1.0, "D.I. at 0.375 is nominal");
        check (di5k < di1k - 1.5, "D.I.: the 100k input damps the pickup's top end");
        m.channel (0).setTrim (1.0);
        const double diMax = gainL (m, 100.0, kNom * 0.05);
        m.channel (0).setTrim (0.0);
        const double diMin = gainL (m, 100.0);
        std::printf ("  D.I. trim: %+.1f .. %+.1f dB around nominal\n", diMin, diMax);
        check (std::fabs (diMax - 22.5) < 0.6 && std::fabs (diMin + 13.5) < 0.6, "D.I. trim +12..+48 dB");
        m.channel (0).setTrim (0.375);
        m.channel (0).setInput (kInLine);
    }

    std::printf ("\nEQUALIZER\n");
    {
        const char* names[3] = { "LOW", "MID", "HIGH" };
        const double fmin[3] = { 50.0, 500.0, 2500.0 }, fmax[3] = { 1000.0, 5000.0, 15000.0 };
        bool all = true;
        for (int b = 0; b < kNumBands; ++b)
        {
            for (int end = 0; end < 2; ++end)
            {
                const double f = end ? fmax[b] : fmin[b];
                m.channel (0).setEqFreq (b, end ? 1.0 : 0.0);
                m.channel (0).setEqGain (b, 1.0);
                const double boost = gainL (m, f, kNom * 0.15);
                m.channel (0).setEqGain (b, 0.0);
                const double cut = gainL (m, f);
                std::printf ("  %-4s at %6.0f Hz: boost %+.1f dB, cut %+.1f dB\n", names[b], f, boost, cut);
                if (std::fabs (boost - 15.0) > 1.0 || std::fabs (cut + 15.0) > 1.0) all = false;
            }
            m.channel (0).setEqFreq (b, 0.5);
            m.channel (0).setEqGain (b, 0.5);
        }
        check (all, "every section boosts and cuts 15 dB across its whole sweep");
        // A bell, not a shelf: two octaves away the boost has mostly gone
        m.channel (0).setEqFreq (kMid, 0.5);
        m.channel (0).setEqGain (kMid, 1.0);
        const double fc = Channel::eqHz (kMid, 0.5);
        const double at = gainL (m, fc, kNom * 0.15), away = gainL (m, fc / 4.0, kNom * 0.15);
        std::printf ("  MID at %.0f Hz %+.1f dB, two octaves below %+.1f dB\n", fc, at, away);
        check (at > 14.0 && away < 4.0, "peaking bell");
        m.channel (0).setBypass (true);
        const double byp = gainL (m, fc);
        std::printf ("  EQ BYPASS: %+.2f dB\n", byp);
        check (std::fabs (byp) < 0.2, "EQ BYPASS takes the EQ out");
        m.channel (0).setBypass (false);
        m.channel (0).setEqGain (kMid, 0.5);
    }

    std::printf ("\nPAN and faders\n");
    {
        m.channel (1).setFader (0.0);
        m.channel (0).setPan (0.5);
        double gl, gr;
        gainAt (m, 1000.0, kNom, gl, gr);
        std::printf ("  channel 1 centred: L %+.2f, R %+.2f dB\n", gl, gr);
        check (std::fabs (gl + 3.01) < 0.2 && std::fabs (gr + 3.01) < 0.2, "centre is -3 dB each side");
        m.channel (0).setPan (0.0);
        gainAt (m, 1000.0, kNom, gl, gr);
        check (gr < -80.0, "hard left leaves the right side empty");
        m.channel (0).setFader (1.0);
        const double top = gainL (m, 1000.0, kNom * 0.3);
        m.channel (0).setFader (0.5);
        const double mid = gainL (m, 1000.0);
        m.channel (0).setFader (0.0);
        const double off = gainL (m, 1000.0);
        std::printf ("  fader 10: %+.1f, 5: %+.1f, 0: %+.0f dB\n", top, mid, off);
        check (std::fabs (top - 8.0) < 0.3 && std::fabs (mid + 10.0) < 0.3 && off < -80.0, "fader law (+8 / -10 / off: down to the buss hiss)");
        m.channel (0).setFader (0.75);
        m.setMaster (0.25);
        const double mst = gainL (m, 1000.0);
        std::printf ("  master at 2.5: %+.1f dB\n", mst);
        check (std::fabs (mst + 25.0) < 0.3, "master fader follows the same law");
        defaults (m);
        gainAt (m, 1000.0, kNom, gl, gr);
        check (std::fabs (gl) < 0.2 && std::fabs (gr) < 0.2, "back to unity");
    }

    std::printf ("\nStereo: left -> channel 1, right -> channel 2\n");
    {
        const int n = (int) (kFs * 0.5);
        std::vector<float> a (n), z (n, 0.0f), l (n), r (n);
        for (int i = 0; i < n; ++i) a[i] = (float) (kNom * std::sin (2.0 * kPi * 440.0 * i / kFs));
        m.reset();
        m.process (&a[0], &z[0], &l[0], &r[0], n);
        double pl = 0.0, pr = 0.0;
        for (int i = n / 2; i < n; ++i) { pl += (double) l[i] * l[i]; pr += (double) r[i] * r[i]; }
        std::printf ("  left-only source: left %.1f dB above right\n", 10.0 * std::log10 (pl / (pr + 1e-30)));
        check (pl > 1e6 * pr, "the stereo image is kept (left stays left)");
        // channel 2 EQ only touches the right side
        m.channel (1).setEqGain (kMid, 1.0);
        double gl, gr;
        gainAt (m, Channel::eqHz (kMid, 0.5), kNom * 0.15, gl, gr);
        std::printf ("  channel 2 MID boost: L %+.1f, R %+.1f dB\n", gl, gr);
        check (std::fabs (gl) < 0.3 && std::fabs (gr - 15.0) < 0.5, "each channel works on its own side");
        defaults (m);
    }

    std::printf ("\nBoth channels centred\n");
    {
        // Both channels centred, one with the LOW boosted: the sum shows both
        m.channel (0).setPan (0.5); m.channel (1).setPan (0.5);
        double gl, gr;
        gainAt (m, 1000.0, kNom * 0.5, gl, gr);
        std::printf ("  both centred: %+.2f dB each side\n", gl);
        check (std::fabs (gl - 3.01) < 0.3 && std::fabs (gl - gr) < 0.01, "two centred channels sum to +3 dB");
        defaults (m);
    }

    std::printf ("\nOVERLOAD and VU\n");
    {
        m.reset();
        const int n = (int) kFs;
        std::vector<float> x (n), l (n), r (n);
        for (int i = 0; i < n; ++i) x[i] = (float) (kNom * std::sin (2.0 * kPi * 1000.0 * i / kFs));
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        const double vu = 20.0 * std::log10 (m.channel (0).vu() / M50::vuZeroVolts());
        const double vl = 20.0 * std::log10 (m.vuL() / M50::vuZeroVolts());
        std::printf ("  nominal sine: channel VU %+.2f, master L %+.2f VU\n", vu, vl);
        check (std::fabs (vu) < 0.3 && std::fabs (vl) < 0.3, "-18 dBFS reads 0 VU");
        check (! m.channel (0).overload(), "OVERLOAD off at nominal");
        // The LED's point: 24 dB over nominal stays dark, 26 dB lights it (TRIM up)
        m.channel (0).setTrim (0.375 + 24.0 / 40.0);
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        const bool at24 = m.channel (0).overload();
        for (int i = 0; i < n; ++i) x[i] *= (float) std::pow (10.0, 2.0 / 20.0);   // +26 dB
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        const bool at26 = m.channel (0).overload();
        std::printf ("  +24 dB: %s, +26 dB: %s\n", at24 ? "lit" : "dark", at26 ? "lit" : "dark");
        check (! at24 && at26, "OVERLOAD lights 25 dB over nominal");
        // At the LED's point the preamp has only just begun to round the peaks;
        // 6 dB further it is shaping them clearly (third harmonic)
        {
            double h3[2];
            const double over[2] = { 25.5, 31.5 };
            for (int k = 0; k < 2; ++k)
            {
                m.channel (0).setTrim (0.375 + 22.0 / 40.0);
                std::vector<float> y (n);
                const double a = kNom * std::pow (10.0, (over[k] - 22.0) / 20.0);
                for (int i = 0; i < n; ++i) y[i] = (float) (a * std::sin (2.0 * kPi * 1000.0 * i / kFs));
                m.setMaster (0.2);
                m.reset();
                m.process (&y[0], &y[0], &l[0], &r[0], n);
                double c1 = 0.0, s1 = 0.0, c3 = 0.0, s3 = 0.0;
                for (int i = n / 2; i < n; ++i)
                {
                    const double w = 2.0 * kPi * 1000.0 * i / kFs;
                    c1 += l[i] * std::cos (w); s1 += l[i] * std::sin (w);
                    c3 += l[i] * std::cos (3 * w); s3 += l[i] * std::sin (3 * w);
                }
                h3[k] = 20.0 * std::log10 (std::sqrt ((c3 * c3 + s3 * s3) / (c1 * c1 + s1 * s1)) + 1e-12);
            }
            m.setMaster (0.75);
            std::printf ("  3rd harmonic: %.0f dB at the LED's point, %.0f dB 6 dB hotter\n", h3[0], h3[1]);
            check (h3[0] < -30.0 && h3[0] > -70.0 && h3[1] > h3[0] + 8.0, "rounding starts around the LED and grows when pushed");
        }
        // a step: the VU's rise time
        m.channel (0).setTrim (0.375);
        m.reset();
        for (int i = 0; i < n; ++i) x[i] = (float) (kNom * std::sin (2.0 * kPi * 1000.0 * i / kFs));
        const int t300 = (int) (0.3 * kFs);
        m.process (&x[0], &x[0], &l[0], &r[0], t300);
        const double rise = m.channel (0).vu() / M50::vuZeroVolts();
        std::printf ("  after 300 ms: %.0f %% of the steady reading\n", 100.0 * rise);
        check (rise > 0.9 && rise < 1.02, "VU ballistics (about 300 ms)");
    }

    std::printf ("\nStability\n");
    {
        unsigned seed = 7u;
        bool ok = true;
        const int n = 4096;
        std::vector<float> x (n), l (n), r (n);
        for (int trial = 0; trial < 120 && ok; ++trial)
        {
            for (int c = 0; c < 2; ++c)
            {
                Channel& ch = m.channel (c);
                seed = seed * 1664525u + 1013904223u; ch.setInput ((int) ((seed >> 8) % 3u));
                seed = seed * 1664525u + 1013904223u; ch.setTrim ((seed >> 8) / 16777216.0);
                for (int b = 0; b < kNumBands; ++b)
                {
                    seed = seed * 1664525u + 1013904223u; ch.setEqFreq (b, (seed >> 8) / 16777216.0);
                    seed = seed * 1664525u + 1013904223u; ch.setEqGain (b, (seed >> 8) / 16777216.0);
                }
                seed = seed * 1664525u + 1013904223u; ch.setPan ((seed >> 8) / 16777216.0);
                seed = seed * 1664525u + 1013904223u; ch.setFader ((seed >> 8) / 16777216.0);
                seed = seed * 1664525u + 1013904223u; ch.setBypass ((seed >> 31) & 1u);
            }
            seed = seed * 1664525u + 1013904223u; m.setMaster ((seed >> 8) / 16777216.0);
            const double amp = (trial % 4 == 0) ? 4.0 : 0.001 * std::pow (10.0, (trial % 7) * 0.5);
            const double hz = 41.0 * std::pow (2.0, (trial % 9) * 0.97);
            for (int i = 0; i < n; ++i)
            {
                seed = seed * 1664525u + 1013904223u;
                const double nz = (trial % 3 == 0) ? ((seed >> 8) / 8388608.0 - 1.0) : 0.0;
                x[i] = (float) (amp * (std::sin (2.0 * kPi * hz * i / kFs) + nz));
            }
            m.process (&x[0], &x[0], &l[0], &r[0], n);
            for (int i = 0; i < n; ++i)
                if (! (l[i] == l[i]) || ! (r[i] == r[i]) || std::fabs (l[i]) > 20.0f || std::fabs (r[i]) > 20.0f) { ok = false; break; }
        }
        check (ok, "random settings, 0.1 mV - 10 V, 41 Hz - 15 kHz, loud noise: finite and bounded");
        defaults (m);
    }

    std::printf ("\nAutomation and CPU\n");
    {
        const int n = (int) kFs * 2;
        std::vector<float> x (n), l (n), r (n);
        for (int i = 0; i < n; ++i) x[i] = (float) (0.2 * std::sin (2.0 * kPi * 220.0 * i / kFs));
        std::clock_t t0 = std::clock();
        for (int pos = 0; pos < n; pos += 64)
        {
            const double t = (double) pos / n;
            for (int c = 0; c < 2; ++c)
            {
                Channel& ch = m.channel (c);
                ch.setTrim (0.5 + 0.4 * std::sin (6.28 * 3 * t + c));
                for (int b = 0; b < kNumBands; ++b) { ch.setEqFreq (b, 0.5 + 0.5 * std::sin (6.28 * (b + 1) * t)); ch.setEqGain (b, 0.5 + 0.5 * std::cos (6.28 * (b + 2) * t)); }
                ch.setPan (0.5 + 0.5 * std::sin (6.28 * 5 * t));
                ch.setFader (0.5 + 0.4 * std::sin (6.28 * 2 * t));
            }
            m.process (&x[pos], &x[pos], &l[pos], &r[pos], (n - pos) < 64 ? n - pos : 64);
        }
        const double secs = (double) (std::clock() - t0) / CLOCKS_PER_SEC;
        bool ok = true;
        for (int i = 0; i < n; ++i) if (! (l[i] == l[i]) || std::fabs (l[i]) > 10.0f) ok = false;
        check (ok, "every control automated at once");
        std::printf ("  CPU: %.2f %% of one core\n", 100.0 * secs / 2.0);
        defaults (m);
    }

    std::printf ("\nRenders (%s)\n", dir.c_str());
    {
        const int n = (int) kFs * 3;
        std::vector<float> x (n), l (n), r (n);
        unsigned seed = 3u;
        // a plucked, buzzy test tone with a little noise
        for (int i = 0; i < n; ++i)
        {
            const double t = (double) i / kFs, ph = std::fmod (t, 0.5);
            seed = seed * 1664525u + 1013904223u;
            const double saw = 2.0 * std::fmod (110.0 * t, 1.0) - 1.0;
            x[i] = (float) (0.25 * std::exp (-ph * 4.0) * saw + 0.002 * ((seed >> 8) / 8388608.0 - 1.0));
        }
        m.reset();
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        writeWav (dir + "/m50_defaults.wav", l, r);
        // channel 1: mids scooped, panned left; channel 2: bright, panned right
        m.channel (0).setEqFreq (kMid, 0.4); m.channel (0).setEqGain (kMid, 0.1);
        m.channel (0).setEqGain (kLow, 0.7);
        m.channel (1).setEqFreq (kHigh, 0.6); m.channel (1).setEqGain (kHigh, 0.9);
        m.channel (1).setEqFreq (kLow, 0.3); m.channel (1).setEqGain (kLow, 0.15);
        m.reset();
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        writeWav (dir + "/m50_two_channels.wav", l, r);
        // driven MIC preamp
        defaults (m);
        m.channel (0).setInput (kInMic); m.channel (0).setTrim (0.85);
        m.channel (1).setFader (0.0); m.channel (0).setPan (0.5);
        m.setMaster (0.4);
        m.reset();
        m.process (&x[0], &x[0], &l[0], &r[0], n);
        writeWav (dir + "/m50_mic_driven.wav", l, r);
        check (true, "wrote m50_defaults.wav, m50_two_channels.wav, m50_mic_driven.wav");
    }

    delete mp;
    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL DSP TESTS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
