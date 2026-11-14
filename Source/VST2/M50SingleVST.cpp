// M50SingleVST.cpp
// VST 2.4 wrapper for TB M50 Single Channel Strip: one TASCAM M-50 input
// channel (no PAN, no master), mono in and mono out, for an insert on every
// track of a session.
//
// - Parameters top to bottom as on the strip, then BYPASS.
// - BYPASS (the panel button) crossfades to the dry input over 10 ms; presets
//   leave it alone. It is not tied to the host's bypass, so it never touches
//   anything else in the host (other plugins in PatchWork).
// - On the Mac, a custom panel (PanelView.mm) with the VU and OVERLOAD LED;
//   elsewhere the host shows generic controls.
// - No latency. Plain C++98; the editor uses only Cocoa APIs present in Mac OS X 10.8.5.

#include "vst2_abi.h"
#include "Params.h"
#include "Editor.h"
#include "Presets.h"
#include "../DSP/M50.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>

#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
  #include <xmmintrin.h>
  #define TBVS_HAVE_SSE 1
#endif

namespace
{

const VstInt32 kUniqueID    = VST_FOURCC ('T', 'B', 'm', '1');
const VstInt32 kVersion     = 1000;       // 1.0.0
const VstInt32 kNumChannels = 1;     // mono
const char* const kPluginName = "TB M50 Single Channel Strip";

using namespace tbm50s;

void copyString (char* dst, const char* src, size_t maxLen)
{
    std::strncpy (dst, src, maxLen);
    dst[maxLen] = 0;
}

class M50SingleVST : public EditorHost
{
public:
    explicit M50SingleVST (audioMasterCallback hostCallback)
        : host (hostCallback), sampleRate (44100.0), editor (0), byp (0.0f), bypK (0.01f)
    {
        std::memset (&effect, 0, sizeof (effect));
        effect.magic = kEffectMagic;
        effect.dispatcher = &dispatcherProc;
        effect.process = &processAccumulateProc;
        effect.setParameter = &setParameterProc;
        effect.getParameter = &getParameterProc;
        effect.processReplacing = &processReplacingProc;
        effect.processDoubleReplacing = 0;
        effect.numPrograms = 1;
        effect.numParams = kNumParams;
        effect.numInputs = kNumChannels;
        effect.numOutputs = kNumChannels;
        effect.flags = effFlagsCanReplacing;
#if defined(__APPLE__)
        effect.flags |= effFlagsHasEditor;
#endif
        effect.initialDelay = M50::latencySamples();
        effect.ioRatio = 1.0f;
        effect.object = this;
        effect.uniqueID = kUniqueID;
        effect.version = kVersion;

        for (int i = 0; i < kNumParams; ++i)
            params[i] = kDefaults[i];

        copyString (programName, "Default", kVstMaxProgNameLen);
        applyAllParams();
        prepare();
    }

    ~M50SingleVST()
    {
#if defined(__APPLE__)
        if (editor) editorClose (editor);
#endif
    }

    AEffect* getAEffect() { return &effect; }

    //==========================================================================
    // EditorHost
    float getParam (int index) const
    {
        return (index >= 0 && index < kNumParams) ? params[index] : 0.0f;
    }
    void getParamDisplay (int index, char* text) const
    {
        if (index >= 0 && index < kNumParams) formatParam (index, text);
        else text[0] = 0;
    }
    float getMeter (int which) const
    {
        if (which == kMeterVu) return vuOf (ch.vu(), M50::vuZeroVolts());
        if (which == kMeterOl) return ch.overload() ? 1.0f : 0.0f;
        return 0.0f;
    }
    static float vuOf (double v, double zero)
    {
        if (v < 1e-9) return -60.0f;
        const double db = 20.0 * std::log10 (v / zero);
        return (float) (db < -60.0 ? -60.0 : db);
    }
    void guiBeginEdit (int index) { if (host) host (&effect, audioMasterBeginEdit, index, 0, 0, 0.0f); }
    void guiEndEdit (int index)   { if (host) host (&effect, audioMasterEndEdit, index, 0, 0, 0.0f); }
    void guiSetParam (int index, float value)
    {
        setParameter (index, value);
        if (host && index >= 0 && index < kNumParams)
            host (&effect, audioMasterAutomate, index, 0, 0, params[index]);
    }

    void refreshPresets() { presets.load(); }
    bool presetExists (int slot) const { return presets.has (slot); }
    bool savePreset (int slot)
    {
        presets.load();                 // keep slots saved by other instances
        presets.put (slot, params);
        return presets.save();
    }
    void presetName (int slot, char* text, int size) const
    {
        if (! text || size <= 0) return;
        const std::string n = presets.name (slot);
        std::strncpy (text, n.c_str(), (size_t) size - 1);
        text[size - 1] = 0;
    }
    bool renamePreset (int slot, const char* name)
    {
        presets.load();                 // keep slots saved by other instances
        if (! presets.has (slot)) return false;
        presets.setName (slot, name ? name : "");
        return presets.save();
    }
    bool loadPreset (int slot)
    {
        float v[kNumParams];
        if (! presets.get (slot, v)) return false;
        for (int i = 0; i < kNumParams; ++i)
        {
            if (i == kBypass) continue;        // a preset never bypasses the plugin
            guiBeginEdit (i);
            guiSetParam (i, v[i]);
            guiEndEdit (i);
        }
        return true;
    }

private:
    //==========================================================================
    static M50SingleVST* self (AEffect* e) { return static_cast<M50SingleVST*> (e->object); }

    static VstIntPtr VST_CALL dispatcherProc (AEffect* e, VstInt32 opcode, VstInt32 index,
                                              VstIntPtr value, void* ptr, float opt)
    {
        M50SingleVST* p = self (e);
        if (opcode == effClose)
        {
            delete p;
            return 1;
        }
        return p->dispatch (opcode, index, value, ptr, opt);
    }

    static void VST_CALL setParameterProc (AEffect* e, VstInt32 index, float value)
    {
        self (e)->setParameter (index, value);
    }

    static float VST_CALL getParameterProc (AEffect* e, VstInt32 index)
    {
        M50SingleVST* p = self (e);
        return (index >= 0 && index < kNumParams) ? p->params[index] : 0.0f;
    }

    static void VST_CALL processReplacingProc (AEffect* e, float** in, float** out, VstInt32 n)
    {
        self (e)->processReplacing (in, out, n);
    }

    static void VST_CALL processAccumulateProc (AEffect* e, float** in, float** out, VstInt32 n)
    {
        M50SingleVST* p = self (e);
        float* tmp[kNumChannels];
        for (int c = 0; c < kNumChannels; ++c)
            tmp[c] = p->scratch[c];

        VstInt32 done = 0;
        while (done < n)
        {
            const VstInt32 chunk = (n - done) < kScratch ? (n - done) : kScratch;
            float* ins[kNumChannels];
            for (int c = 0; c < kNumChannels; ++c)
                ins[c] = in[c] + done;
            p->processReplacing (ins, tmp, chunk);
            for (int c = 0; c < kNumChannels; ++c)
                for (VstInt32 i = 0; i < chunk; ++i)
                    out[c][done + i] += tmp[c][i];
            done += chunk;
        }
    }

    //==========================================================================
    VstIntPtr dispatch (VstInt32 opcode, VstInt32 index, VstIntPtr value, void* ptr, float opt)
    {
        switch (opcode)
        {
            case effOpen:              return 0;
            case effSetProgram:        return 0;
            case effGetProgram:        return 0;
            case effSetProgramName:
                if (ptr) copyString (programName, (const char*) ptr, kVstMaxProgNameLen);
                return 0;
            case effGetProgramName:
                if (ptr) copyString ((char*) ptr, programName, kVstMaxProgNameLen);
                return 0;
            case effGetProgramNameIndexed:
                if (ptr && index == 0) { copyString ((char*) ptr, programName, kVstMaxProgNameLen); return 1; }
                return 0;

            case effGetParamLabel:
                if (ptr && index >= 0 && index < kNumParams)
                {
                    const int k = kParamKind[index];
                    const char* lab = "";
                    if (k == kTrimDb || k == kEqDb || k == kFaderDb) lab = "dB";
                    else if (k == kHiHz || k == kMidHz || k == kLoHz) lab = "Hz";
                    copyString ((char*) ptr, lab, kVstMaxParamStrLen);
                }
                return 0;
            case effGetParamDisplay:
                if (ptr && index >= 0 && index < kNumParams)
                    formatParam (index, (char*) ptr);
                return 0;
            case effGetParamName:
                if (ptr && index >= 0 && index < kNumParams)
                    copyString ((char*) ptr, kParamNames[index], kVstMaxParamStrLen);
                return 0;
            case effCanBeAutomated:
                return (index >= 0 && index < kNumParams) ? 1 : 0;

            case effSetSampleRate:
                if (opt > 0.0f) sampleRate = opt;
                return 0;
            case effSetBlockSize:
                return 0;
            case effMainsChanged:
                if (value) prepare();
                return 0;

#if defined(__APPLE__)
            case effEditGetRect:
                if (ptr)
                {
                    editRect.top = 0; editRect.left = 0;
                    editRect.bottom = (short) kEditorHeight; editRect.right = (short) kEditorWidth;
                    *(ERect**) ptr = &editRect;
                    return 1;
                }
                return 0;
            case effEditOpen:
                if (editor) { editorClose (editor); editor = 0; }
                if (ptr) editor = editorOpen (ptr, this);
                return editor ? 1 : 0;
            case effEditClose:
                if (editor) { editorClose (editor); editor = 0; }
                return 0;
            case effEditIdle:
                return 0;
#endif
            case effGetPlugCategory:   return kPlugCategEffect;
            case effGetEffectName:
                if (ptr) copyString ((char*) ptr, kPluginName, kVstMaxEffectNameLen);
                return 1;
            case effGetProductString:
                if (ptr) copyString ((char*) ptr, kPluginName, kVstMaxProductStrLen);
                return 1;
            case effGetVendorString:
                if (ptr) copyString ((char*) ptr, "TB", kVstMaxVendorStrLen);
                return 1;
            case effGetVendorVersion:  return kVersion;
            case effGetVstVersion:     return 2400;

            case effCanDo:
                if (ptr)
                {
                    const char* s = (const char*) ptr;
                    if (! std::strcmp (s, "plugAsChannelInsert") || ! std::strcmp (s, "plugAsSend"))
                        return 1;
                    if (! std::strcmp (s, "receiveVstEvents") || ! std::strcmp (s, "receiveVstMidiEvent")
                        || ! std::strcmp (s, "sendVstEvents") || ! std::strcmp (s, "sendVstMidiEvent"))
                        return -1;
                }
                return 0;

            case effGetTailSize:       return (VstIntPtr) (sampleRate * 0.5);    // EQ and coupling ring-down
            case effStartProcess:      return 0;
            case effStopProcess:       return 0;
            default:                   return 0;
        }
    }

    void formatParam (int index, char* text) const
    {
        char buf[32];
        const float v = params[index];
        switch (kParamKind[index])
        {
            case kMicLine:
            {
                static const char* const names[3] = { "Mic", "D.I.", "Line" };
                std::strcpy (buf, names[inputIndex (v)]);
                break;
            }
            case kTrimDb:
                std::snprintf (buf, sizeof (buf), "%+.1f", Channel::trimDb (inputIndex (params[kInput]), v));
                break;
            case kBypassSw: std::strcpy (buf, isOn (v) ? "Bypass" : "In"); break;
            case kBypassAll: std::strcpy (buf, isOn (v) ? "On" : "Off"); break;
            case kHiHz: case kMidHz: case kLoHz:
            {
                const int band = kParamKind[index] == kHiHz ? kHigh : (kParamKind[index] == kMidHz ? kMid : kLow);
                const double hz = Channel::eqHz (band, v);
                if (hz >= 1000.0) std::snprintf (buf, sizeof (buf), hz >= 9950.0 ? "%.1fk" : "%.2fk", hz / 1000.0);
                else std::snprintf (buf, sizeof (buf), "%.0f", hz);
                break;
            }
            case kEqDb:     std::snprintf (buf, sizeof (buf), "%+.1f", Channel::eqDb (v)); break;
            case kFaderDb:
            {
                const double db = Channel::faderDb (v);
                if (db < -99.0 || v < 0.0005f) std::strcpy (buf, "-inf");
                else std::snprintf (buf, sizeof (buf), "%+.1f", db);
                break;
            }
            default:        buf[0] = 0; break;
        }
        copyString (text, buf, kVstMaxParamStrLen);
    }

    void setParameter (VstInt32 index, float value)
    {
        if (index < 0 || index >= kNumParams) return;
        if (! (value == value)) return;   // NaN guard
        if (value < 0.0f) value = 0.0f;
        if (value > 1.0f) value = 1.0f;
        params[index] = value;
        applyParam (index);
    }

    void applyParam (int index)
    {
        const double v = params[index];
        switch (index)
        {
            case kInput:    ch.setInput (inputIndex (params[index])); break;
            case kTrim:     ch.setTrim (v); break;
            case kEqBypass: ch.setBypass (isOn (params[index])); break;
            case kHiFreq:   ch.setEqFreq (kHigh, v); break;
            case kHiGain:   ch.setEqGain (kHigh, v); break;
            case kMidFreq:  ch.setEqFreq (kMid, v); break;
            case kMidGain:  ch.setEqGain (kMid, v); break;
            case kLoFreq:   ch.setEqFreq (kLow, v); break;
            case kLoGain:   ch.setEqGain (kLow, v); break;
            case kFader:    ch.setFader (v); break;
            default: break;                    // BYPASS is read in processReplacing
        }
    }

    void applyAllParams()
    {
        for (int i = 0; i < kNumParams; ++i)
            applyParam (i);
    }

    void prepare()
    {
        ch.prepare (sampleRate, 0x1234567u);
        bypK = (float) (1.0 - std::exp (-1.0 / (0.003 * sampleRate)));   // about 10 ms to settle
        byp = isOn (params[kBypass]) ? 1.0f : 0.0f;
    }

    // One channel: the strip's output (no PAN) is the plugin's output
    void processReplacing (float** in, float** out, VstInt32 n)
    {
        if (n <= 0 || ! in || ! out) return;

#if TBVS_HAVE_SSE
        const unsigned int oldCsr = _mm_getcsr();
        _mm_setcsr (oldCsr | 0x8040);   // flush denormals to zero
#endif
        const double toV = M50::voltsPerUnit(), fromV = 1.0 / M50::voltsPerUnit();
        const float target = isOn (params[kBypass]) ? 1.0f : 0.0f;
        for (VstInt32 i = 0; i < n; ++i)
        {
            const float x = in[0][i];                 // read before writing (in-place)
            float y = (float) (ch.processMono (x * toV) * fromV);
            // BYPASS: fade to the dry input (no latency, so the two line up), then pass it bit for bit
            if (target != byp || byp != 0.0f)
            {
                byp += (target - byp) * bypK;
                if (std::fabs (target - byp) < 1e-5f) byp = target;
                y = byp >= 1.0f ? x : y + (x - y) * byp;
            }
            out[0][i] = y;
        }

#if TBVS_HAVE_SSE
        _mm_setcsr (oldCsr);
#endif
    }

    //==========================================================================
    enum { kScratch = 512 };

    AEffect effect;
    audioMasterCallback host;
    double sampleRate;
    float params[kNumParams];
    char programName[kVstMaxProgNameLen + 1];
    Channel ch;
    void* editor;
    float byp, bypK;                         // BYPASS crossfade (1 = dry)
    ERect editRect;
    PresetStore presets;
    float scratch[kNumChannels][kScratch];   // processAccumulate's outputs
};

} // namespace

//==============================================================================
VST_EXPORT AEffect* VSTPluginMain (audioMasterCallback host)
{
    if (! host)
        return 0;
    M50SingleVST* plugin = new M50SingleVST (host);
    return plugin->getAEffect();
}

#if defined(__APPLE__)
VST_EXPORT AEffect* main_macho (audioMasterCallback host)
{
    return VSTPluginMain (host);
}
#endif
