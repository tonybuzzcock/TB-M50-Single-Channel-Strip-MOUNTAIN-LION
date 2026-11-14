// vst_host_test.cpp
// A minimal VST 2.4 host that loads the built plugin binary through its entry
// point and checks it behaves: opcodes, parameters, processing, latency,
// sample-rate changes, in-place buffers and shutdown.
//
//   vst_host_test <path to plugin binary>
// On macOS pass the binary inside the bundle:
//   "TB M50 Single Channel Strip.vst/Contents/MacOS/TBM50SingleChannelStrip"

#include "../Source/VST2/vst2_abi.h"
#include "../Source/DSP/M50.h"
#include "../Source/VST2/Params.h"

#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <vector>

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static int automateCalls = 0;
static VstIntPtr VST_CALL hostCallback (AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    switch (opcode)
    {
        case audioMasterVersion:   return 2400;
        case audioMasterAutomate:  ++automateCalls; return 0;
        default:                   return 0;
    }
}

typedef AEffect* (*EntryProc) (audioMasterCallback);

static VstIntPtr call (AEffect* e, VstInt32 op, VstInt32 idx = 0, VstIntPtr val = 0, void* ptr = 0, float opt = 0.0f)
{
    return e->dispatcher (e, op, idx, val, ptr, opt);
}

static bool finite (const std::vector<float>& x)
{
    for (size_t i = 0; i < x.size(); ++i)
        if (! (x[i] == x[i]) || std::fabs (x[i]) > 100.0f) return false;
    return true;
}

// Mono: one input, one output
static void runBlocks (AEffect* e, std::vector<float>& x, std::vector<float>& y, int block)
{
    for (size_t pos = 0; pos < x.size(); pos += block)
    {
        const int n = (int) ((x.size() - pos) < (size_t) block ? x.size() - pos : block);
        float* in[1]  = { &x[pos] };
        float* out[1] = { &y[pos] };
        e->processReplacing (e, in, out, n);
    }
}

int main (int argc, char** argv)
{
    if (argc < 2) { std::printf ("usage: %s <plugin binary>\n", argv[0]); return 2; }
    std::printf ("Loading %s\n", argv[1]);
    void* lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
    if (! lib) { std::printf ("dlopen failed: %s\n", dlerror()); return 1; }
    EntryProc entry = (EntryProc) dlsym (lib, "VSTPluginMain");
    check (entry != 0, "exports VSTPluginMain");
#if defined(__APPLE__)
    check (dlsym (lib, "main_macho") != 0, "exports main_macho (older Mac hosts)");
#endif
    if (! entry) return 1;
    AEffect* e = entry (hostCallback);
    check (e != 0, "entry point returns an effect");
    if (! e) return 1;
    using namespace tbm50s;

    std::printf ("\nIdentity\n");
    check (e->magic == kEffectMagic, "magic is 'VstP'");
    check (e->numInputs == 1 && e->numOutputs == 1, "mono in, mono out");
    check (e->numParams == kNumParams && kNumParams == 11, "11 parameters (10 on the strip + bypass)");
    check ((e->flags & effFlagsCanReplacing) != 0, "processReplacing supported");
    check (e->initialDelay == 0, "no latency");
    check (e->uniqueID == VST_FOURCC ('T', 'B', 'm', '1'), "unique ID 'TBm1'");
    char buf[256];
    std::memset (buf, 0, sizeof (buf));
    call (e, effGetEffectName, 0, 0, buf);
    check (std::strcmp (buf, "TB M50 Single Channel Strip") == 0, "effect name");
    check (call (e, effGetPlugCategory) == kPlugCategEffect, "category: effect");
    check (call (e, effCanDo, 0, 0, (void*) "bypass") != 1, "doesn't take over the host's bypass");

    call (e, effOpen);
    call (e, effSetSampleRate, 0, 0, 0, 44100.0f);
    call (e, effSetBlockSize, 0, 512);

    std::printf ("\nParameters\n");
    const char* expectDisp[11] = { "Line", "+0.0", "In", "6.12k", "+0.0", "1.58k", "+0.0", "224", "+0.0", "+0.0", "Off" };
    for (int i = 0; i < kNumParams; ++i)
    {
        char name[64] = { 0 }, disp[64] = { 0 }, label[64] = { 0 };
        call (e, effGetParamName, i, 0, name);
        call (e, effGetParamDisplay, i, 0, disp);
        call (e, effGetParamLabel, i, 0, label);
        std::printf ("  %-8s = %-6s %-3s (%.3f)\n", name, disp, label, e->getParameter (e, i));
        check (std::strcmp (name, kParamNames[i]) == 0 && std::strlen (name) <= 8 && std::strlen (disp) <= 8, "name and display string length");
        check (std::strcmp (disp, expectDisp[i]) == 0, "default value as on the panel");
    }
    struct { int p; float v; const char* want; const char* what; } shows[] = {
        { kInput,   0.5f, "D.I.",   "Input switch shows D.I." },
        { kTrim,    0.0f, "+12.0",  "D.I. trim starts at +12 dB" },
        { kInput,   0.0f, "Mic",    "Input switch shows Mic" },
        { kTrim,    1.0f, "+60.0",  "MIC trim tops out at +60 dB" },
        { kInput,   1.0f, "Line",   "back to Line" },
        { kTrim,    0.0f, "-15.0",  "LINE trim bottoms out at -15 dB" },
        { kLoFreq,  0.0f, "50",     "LOW sweeps from 50 Hz" },
        { kMidFreq, 1.0f, "5.00k",  "MID sweeps to 5 kHz" },
        { kHiFreq,  1.0f, "15.0k",  "HIGH sweeps to 15 kHz" },
        { kHiGain,  0.0f, "-15.0",  "cut -15 dB" },
        { kFader,   1.0f, "+8.0",   "fader at 10 shows +8 dB" },
        { kFader,   0.0f, "-inf",   "fader down shows -inf" },
        { kEqBypass, 1.0f, "Bypass", "EQ bypass" },
        { kBypass,  1.0f, "On",     "Bypass shows On" },
    };
    for (size_t k = 0; k < sizeof (shows) / sizeof (shows[0]); ++k)
    {
        e->setParameter (e, shows[k].p, shows[k].v);
        std::memset (buf, 0, sizeof (buf));
        call (e, effGetParamDisplay, shows[k].p, 0, buf);
        if (std::strcmp (buf, shows[k].want) != 0) std::printf ("  got '%s'\n", buf);
        check (std::strcmp (buf, shows[k].want) == 0, shows[k].what);
    }
    for (int i = 0; i < kNumParams; ++i) e->setParameter (e, i, kDefaults[i]);
    e->setParameter (e, 1, 7.0f);
    check (e->getParameter (e, 1) == 1.0f, "out-of-range values are clamped");
    e->setParameter (e, 1, kDefaults[1]);
    e->setParameter (e, 99, 0.5f);
    check (e->getParameter (e, 99) == 0.0f, "invalid parameter index is harmless");

    std::printf ("\nProcessing\n");
    call (e, effMainsChanged, 0, 1);
    const int sr = 44100;
    std::vector<float> x (sr), y (sr);
    for (int i = 0; i < sr; ++i) x[i] = (float) (0.2 * std::sin (2.0 * 3.14159265358979 * 196.0 * i / sr));
    {
        // Reference: one Channel straight through processMono at the defaults
        Channel* ref = new Channel();
        ref->prepare (sr, 0x1234567u);
        std::vector<float> refOut (sr);
        for (int i = 0; i < sr; ++i) refOut[i] = (float) (ref->processMono (x[i] * M50::voltsPerUnit()) / M50::voltsPerUnit());
        delete ref;
        runBlocks (e, x, y, 512);
        double maxDiff = 0.0, si = 0.0, so = 0.0;
        for (int i = 0; i < sr; ++i)
        {
            maxDiff = std::max (maxDiff, (double) std::fabs (y[i] - refOut[i]));
            if (i > sr / 2) { si += (double) x[i] * x[i]; so += (double) y[i] * y[i]; }
        }
        std::printf ("  max diff vs DSP core %.2g, level %+.3f dB\n", maxDiff, 10.0 * std::log10 (so / si));
        check (maxDiff < 1e-6, "matches the DSP core sample for sample");
        check (std::fabs (10.0 * std::log10 (so / si)) < 0.1, "unity at the defaults");
        check (finite (y), "output finite");
    }
    {
        std::vector<float> a (x);
        for (size_t pos = 0; pos < a.size(); pos += 333)
        {
            const int n = (int) ((a.size() - pos) < 333 ? a.size() - pos : 333);
            float* io[1] = { &a[pos] };
            e->processReplacing (e, io, io, n);
        }
        check (finite (a), "in-place processing, odd block size");
        std::vector<float> b (x), ob (sr);
        runBlocks (e, b, ob, 1);
        check (finite (ob), "1-sample blocks");
        runBlocks (e, b, ob, 8192);
        check (finite (ob), "8192-sample blocks");
    }
    {
        std::vector<float> z (sr * 2, 0.0f), oz (sr * 2);
        runBlocks (e, z, oz, 512);
        double tail = 0.0;
        for (int i = sr; i < sr * 2; ++i) tail = std::max (tail, (double) std::fabs (oz[i]));
        std::printf ("  residual after 1 s of silence: %.2g (hiss)\n", tail);
        check (tail < 1e-3, "silence settles to the noise floor");
    }
    // Fader at 5: -10 dB
    {
        e->setParameter (e, kFader, 0.5f);
        runBlocks (e, x, y, 512);
        double si = 0.0, so = 0.0;
        for (int i = sr / 2; i < sr; ++i) { si += (double) x[i] * x[i]; so += (double) y[i] * y[i]; }
        std::printf ("  fader at 5: %+.2f dB\n", 10.0 * std::log10 (so / si));
        check (std::fabs (10.0 * std::log10 (so / si) + 10.0) < 0.3, "the channel fader sets the output");
        e->setParameter (e, kFader, kDefaults[kFader]);
    }
    // BYPASS: the dry input, exactly, once the fade is over
    {
        std::vector<float> a (sr), oa (sr);
        for (int i = 0; i < sr; ++i) a[i] = (float) (0.3 * std::sin (0.031 * i));
        e->setParameter (e, kHiGain, 1.0f);
        e->setParameter (e, kBypass, 1.0f);
        runBlocks (e, a, oa, 512);
        double d = 0.0;
        for (int i = sr / 10; i < sr; ++i) d = std::max (d, (double) std::fabs (oa[i] - a[i]));
        std::printf ("  BYPASS: largest difference from the input %.2g\n", d);
        check (d == 0.0, "BYPASS passes the input untouched");
        e->setParameter (e, kBypass, 0.0f);
        runBlocks (e, a, oa, 512);
        d = 0.0;
        for (int i = sr / 10; i < sr; ++i) d = std::max (d, (double) std::fabs (oa[i] - a[i]));
        check (d > 0.01, "and out again (the EQ is heard)");
        call (e, effSetBypass, 0, 1);
        check (e->getParameter (e, kBypass) == 0.0f, "the host's bypass leaves the BYPASS button alone");
        call (e, effSetBypass, 0, 0);
        e->setParameter (e, kHiGain, 0.5f);
    }
    // processAccumulate adds
    {
        std::vector<float> a (512), oa (512, 1.0f);
        for (int i = 0; i < 512; ++i) a[i] = (float) (0.2 * std::sin (2.0 * 3.14159265358979 * 440.0 * i / 44100.0));
        float* in[1] = { &a[0] };
        float* out[1] = { &oa[0] };
        e->process (e, in, out, 512);
        float mx = 0.0f; for (int i = 0; i < 512; ++i) mx = std::max (mx, oa[i]);
        check (mx > 1.1f, "process() accumulates into the output");
    }

    std::printf ("\nSample-rate change to 96 kHz\n");
    call (e, effMainsChanged, 0, 0);
    call (e, effSetSampleRate, 0, 0, 0, 96000.0f);
    call (e, effMainsChanged, 0, 1);
    {
        std::vector<float> a (96000), oa (96000);
        for (int i = 0; i < 96000; ++i) a[i] = (float) (0.2 * std::sin (2.0 * 3.14159265358979 * 196.0 * i / 96000));
        std::clock_t t0 = std::clock();
        runBlocks (e, a, oa, 512);
        const double secs = (double) (std::clock() - t0) / CLOCKS_PER_SEC;
        check (finite (oa), "runs at 96 kHz");
        std::printf ("  CPU at 96 kHz: %.2f%% of one core\n", 100.0 * secs);
    }

    std::printf ("\nAutomation while processing\n");
    {
        std::vector<float> a (sr), oa (sr);
        for (int i = 0; i < sr; ++i) a[i] = (float) (0.3 * std::sin (2.0 * 3.14159265358979 * 110.0 * i / sr));
        for (size_t pos = 0; pos < a.size(); pos += 64)
        {
            const float t = (float) pos / a.size();
            for (int p = 0; p < kNumParams; ++p) if (p != kBypass) e->setParameter (e, p, 0.5f + 0.5f * std::sin (6.2831853f * (p + 1) * t));
            const int n = (int) ((a.size() - pos) < 64 ? a.size() - pos : 64);
            float* in[1]  = { &a[pos] };
            float* out[1] = { &oa[pos] };
            e->processReplacing (e, in, out, n);
        }
        check (finite (oa), "all parameters automated together");
    }

    call (e, effMainsChanged, 0, 0);
    call (e, effClose);
    check (true, "effClose");
    dlclose (lib);
    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL HOST CHECKS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
