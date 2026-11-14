// editor_test.mm  (macOS only)
// Loads the built plugin, opens its panel in an offscreen window the way a host
// does, renders screenshots, drives the controls with synthetic mouse events,
// checks host automation messages, and closes it again.
//
//   editor_test <plugin binary> <output dir for PNGs>

#import <Cocoa/Cocoa.h>

#include "../Source/VST2/vst2_abi.h"
#include "../Source/VST2/Params.h"
#include "../Source/VST2/Editor.h"

#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <algorithm>
#include <vector>

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static int automateCalls = 0, beginCalls = 0, endCalls = 0;
static VstIntPtr VST_CALL hostCallback (AEffect*, VstInt32 opcode, VstInt32, VstIntPtr, void*, float)
{
    switch (opcode)
    {
        case audioMasterVersion:   return 2400;
        case audioMasterAutomate:  ++automateCalls; return 0;
        case audioMasterBeginEdit: ++beginCalls; return 1;
        case audioMasterEndEdit:   ++endCalls; return 1;
        default:                   return 0;
    }
}

typedef AEffect* (*EntryProc) (audioMasterCallback);

static VstIntPtr call (AEffect* e, VstInt32 op, VstInt32 idx = 0, VstIntPtr val = 0, void* ptr = 0, float opt = 0.0f)
{
    return e->dispatcher (e, op, idx, val, ptr, opt);
}

static NSData* renderPNG (NSView* v, const std::string& path)
{
    const NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect: b];
    [v cacheDisplayInRect: b toBitmapImageRep: rep];
    NSData* png = [rep representationUsingType: NSPNGFileType properties: [NSDictionary dictionary]];
    [png writeToFile: [NSString stringWithUTF8String: path.c_str()] atomically: YES];
    std::printf ("  wrote %s (%lu bytes)\n", path.c_str(), (unsigned long) [png length]);
    return png;
}

// Send a mouse event at a point in the panel's (flipped) coordinates.
static void mouse (NSWindow* w, NSView* v, NSEventType type, NSPoint panelPt, int clicks = 1)
{
    // panelPt is in face coordinates; the face sits inside the wooden frame
    const NSPoint wp = [v convertPoint: NSMakePoint (panelPt.x + tbm50s::kPanelFrame, panelPt.y + tbm50s::kPanelFrame) toView: nil];
    NSEvent* e = [NSEvent mouseEventWithType: type location: wp modifierFlags: 0 timestamp: 0
                                windowNumber: [w windowNumber] context: nil eventNumber: 0
                                  clickCount: clicks pressure: 1.0f];
    if (type == NSRightMouseDown) [v rightMouseDown: e];
    else if (type == NSLeftMouseDown) [v mouseDown: e];
    else if (type == NSLeftMouseDragged) [v mouseDragged: e];
    else [v mouseUp: e];
}

// Fader cap centre for a value (as PanelView.mm)
static CGFloat faderPos (float v) { return 742.0 - v * 142.0; }

static void pump (double secs)
{
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: secs]];
}

int main (int argc, char** argv)
{
    if (argc < 3) { std::printf ("usage: %s <plugin binary> <png dir>\n", argv[0]); return 2; }
    setvbuf (stdout, 0, _IONBF, 0);   // unbuffered, so a crash still shows how far it got
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    const std::string dir = argv[2];

    // Keep the test's presets away from any real ones
    const std::string presetFile = dir + "/test_presets/Presets.txt";
    setenv ("TBM50S_PRESET_FILE", presetFile.c_str(), 1);
    std::remove (presetFile.c_str());

    void* lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
    if (! lib) { std::printf ("dlopen failed: %s\n", dlerror()); return 1; }
    EntryProc entry = (EntryProc) dlsym (lib, "VSTPluginMain");
    if (! entry) { std::printf ("no entry point\n"); return 1; }
    AEffect* e = entry (hostCallback);
    call (e, effOpen);
    call (e, effSetSampleRate, 0, 0, 0, 44100.0f);
    call (e, effMainsChanged, 0, 1);

    using namespace tbm50s;
    std::printf ("Editor\n");
    check ((e->flags & effFlagsHasEditor) != 0, "plugin reports a custom editor");
    ERect* r = 0;
    call (e, effEditGetRect, 0, 0, &r);
    check (r && r->right - r->left == kEditorWidth && r->bottom - r->top == kEditorHeight,
           "editor size as declared");

    NSWindow* win = [[NSWindow alloc] initWithContentRect: NSMakeRect (0, 0, kEditorWidth, kEditorHeight)
                                                styleMask: NSBorderlessWindowMask
                                                  backing: NSBackingStoreBuffered defer: NO];
    NSView* parent = [win contentView];
    check (call (e, effEditOpen, 0, 0, parent) == 1, "effEditOpen succeeds");
    check ([[parent subviews] count] == 1, "panel view added to the host's view");
    NSView* panel = [[parent subviews] count] ? [[parent subviews] objectAtIndex: 0] : nil;
    if (! panel) return 1;
    check (NSEqualSizes ([panel frame].size, NSMakeSize (kEditorWidth, kEditorHeight)), "panel has the declared size");

    NSData* pngDefault = renderPNG (panel, dir + "/panel_default.png");
    check ([pngDefault length] > 10000, "panel renders");

    std::printf ("\nControls\n");
    const float g0 = e->getParameter (e, kFader);
    automateCalls = beginCalls = endCalls = 0;
    const CGFloat capY = faderPos (0.75f);
    mouse (win, panel, NSLeftMouseDown,    NSMakePoint (160, capY));
    mouse (win, panel, NSLeftMouseDragged, NSMakePoint (160, capY + 20));
    mouse (win, panel, NSLeftMouseDragged, NSMakePoint (160, capY + 35.5));
    mouse (win, panel, NSLeftMouseUp,      NSMakePoint (160, capY + 35.5));
    const float g1 = e->getParameter (e, kFader);
    std::printf ("  fader %.2f -> %.2f\n", g0, g1);
    check (std::fabs (g1 - (g0 - 0.25f)) < 0.02f, "dragging the fader down follows the hand");
    check (automateCalls > 0 && beginCalls == 1 && endCalls == 1, "host gets begin / automate / end");
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (160, faderPos (g1)), 2);
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (160, faderPos (g1)), 2);
    check (std::fabs (e->getParameter (e, kFader) - kDefaults[kFader]) < 1e-6f, "double-click resets the fader");

    {
        const int ps[8] = { kTrim, kHiGain, kHiFreq, kMidGain, kMidFreq, kLoGain, kLoFreq, kFader };
        const NSPoint at[8] = { NSMakePoint (160, 212), NSMakePoint (160, 334), NSMakePoint (160, 316), NSMakePoint (160, 408),
                                NSMakePoint (160, 390), NSMakePoint (160, 482), NSMakePoint (160, 464), NSMakePoint (160, faderPos (0.5f)) };
        bool all = true;
        for (int k = 0; k < 8; ++k)
        {
            for (int j = 0; j < 8; ++j) e->setParameter (e, ps[j], 0.5f);
            mouse (win, panel, NSLeftMouseDown,    at[k]);
            mouse (win, panel, NSLeftMouseDragged, NSMakePoint (at[k].x, at[k].y - 20));
            mouse (win, panel, NSLeftMouseUp,      NSMakePoint (at[k].x, at[k].y - 20));
            bool others = true;
            for (int j = 0; j < 8; ++j) if (j != k && e->getParameter (e, ps[j]) != 0.5f) others = false;
            if (! (e->getParameter (e, ps[k]) > 0.55f) || ! others) { all = false; std::printf ("  control %d did not move alone\n", ps[k]); }
        }
        for (int j = 0; j < 8; ++j) e->setParameter (e, ps[j], kDefaults[ps[j]]);
        check (all, "all 7 knobs and the fader move, each on its own");
    }
    {
        const CGFloat xs[3] = { 132, 160, 188 };
        int got[3];
        for (int k = 0; k < 3; ++k)
        {
            mouse (win, panel, NSLeftMouseDown, NSMakePoint (xs[k], 152));
            mouse (win, panel, NSLeftMouseUp,   NSMakePoint (xs[k], 152));
            got[k] = inputIndex (e->getParameter (e, kInput));
        }
        std::printf ("  INPUT clicks: %d %d %d\n", got[0], got[1], got[2]);
        check (got[0] == 0 && got[1] == 1 && got[2] == 2, "INPUT: MIC, D.I., LINE where they are marked");
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (200, 278));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (200, 278));
        check (e->getParameter (e, kEqBypass) >= 0.5f, "EQ BYPASS latches in");
        e->setParameter (e, kInput, 0.0f);
        pump (0.1);
        renderPNG (panel, dir + "/panel_switches.png");
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (200, 278));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (200, 278));
        check (e->getParameter (e, kEqBypass) < 0.5f, "and out again");
        e->setParameter (e, kInput, 1.0f);
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (160, 556));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (160, 556));
        check (e->getParameter (e, kBypass) >= 0.5f, "BYPASS latches in");
        pump (0.1);
        renderPNG (panel, dir + "/panel_bypassed.png");
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (160, 556));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (160, 556));
        check (e->getParameter (e, kBypass) < 0.5f, "and out again");
        // right-click: the exact value, nothing moves
        e->setParameter (e, kMidFreq, 0.3f);
        mouse (win, panel, NSRightMouseDown, NSMakePoint (160, 390));
        pump (0.1);
        renderPNG (panel, dir + "/panel_rightclick.png");
        check (e->getParameter (e, kMidFreq) == 0.3f, "right-click changes nothing");
        e->setParameter (e, kMidFreq, kDefaults[kMidFreq]);
    }

    std::printf ("\nPresets\n");
    #define SLOT(k) NSMakePoint (136.0 + ((k) % 4) * 44.0 + 19.0, 822.0 + ((k) / 4) * 34.0 + 14.0)
    e->setParameter (e, kHiGain, 0.8f);
    e->setParameter (e, kEqBypass, 1.0f);
    pump (0.1);
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (69, 908));     // SAVE
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (69, 908));
    mouse (win, panel, NSLeftMouseDown, SLOT (2));
    mouse (win, panel, NSLeftMouseUp,   SLOT (2));
    FILE* pf = std::fopen (presetFile.c_str(), "r");
    check (pf != 0, "SAVE then a slot writes the preset file");
    if (pf) std::fclose (pf);
    NSTextField* field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil, "saving opens a box to name the preset");
    renderPNG (panel, dir + "/panel_naming.png");
    if (field)
    {
        [field setStringValue: @"Snare through the M-50"];
        [field sendAction: [field action] to: [field target]];
        pump (0.2);
    }
    bool named = false;
    pf = std::fopen (presetFile.c_str(), "r");
    if (pf) { char ln[256]; while (std::fgets (ln, sizeof (ln), pf)) if (std::strstr (ln, "name 3: Snare through the M-50")) named = true; std::fclose (pf); }
    check (named, "Return saves the name with the preset");
    bool gone = true;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) gone = false;
    check (gone, "and the name box goes away");
    renderPNG (panel, dir + "/panel_preset_saved.png");
    e->setParameter (e, kHiGain, 0.2f);
    e->setParameter (e, kEqBypass, 0.0f);
    pump (0.1);
    automateCalls = 0;
    mouse (win, panel, NSLeftMouseDown, SLOT (2));
    mouse (win, panel, NSLeftMouseUp,   SLOT (2));
    check (std::fabs (e->getParameter (e, kHiGain) - 0.8f) < 1e-5f && e->getParameter (e, kEqBypass) >= 0.5f, "clicking the slot recalls the saved settings");
    check (automateCalls >= kNumParams - 1, "recall tells the host about every parameter (BYPASS stays as it is)");
    renderPNG (panel, dir + "/panel_preset_loaded.png");
    mouse (win, panel, NSLeftMouseDown, NSMakePoint (160, 951));
    mouse (win, panel, NSLeftMouseUp,   NSMakePoint (160, 951));
    field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil && [[field stringValue] isEqualToString: @"Snare through the M-50"], "clicking the readout opens the name to edit");
    if (field)
    {
        [field setStringValue: @"Something else"];
        [(id) panel control: field textView: nil doCommandBySelector: @selector (cancelOperation:)];
        pump (0.2);
    }
    const float before = e->getParameter (e, kHiGain);
    mouse (win, panel, NSLeftMouseDown, SLOT (5));
    mouse (win, panel, NSLeftMouseUp,   SLOT (5));
    check (e->getParameter (e, kHiGain) == before, "an empty slot changes nothing");
    for (int i = 0; i < kNumParams; ++i) e->setParameter (e, i, kDefaults[i]);

    std::printf ("\nHost automation shows on the panel\n");
    pump (0.1);
    NSData* pngBefore = renderPNG (panel, dir + "/panel_before_host.png");
    e->setParameter (e, kFader, 0.4f);
    e->setParameter (e, kLoGain, 0.9f);
    pump (0.3);
    NSData* pngAfter = renderPNG (panel, dir + "/panel_changed.png");
    check (! [pngAfter isEqualToData: pngBefore], "panel redraws after host changes");
    for (int i = 0; i < kNumParams; ++i) e->setParameter (e, i, kDefaults[i]);

    std::printf ("\nMeters\n");
    {
        e->setParameter (e, kTrim, 0.9f);
        e->setParameter (e, kLoGain, 0.7f);
        e->setParameter (e, kHiFreq, 0.4f);
        e->setParameter (e, kHiGain, 0.65f);
        e->setParameter (e, kFader, 0.62f);
        const int n = 13000;      // ends 45 ms after a hit: the OVERLOAD LED mid-flash
        std::vector<float> a (n), oa (n);
        for (int i = 0; i < n; ++i)
        {
            const double t = i / 44100.0;
            a[i] = (float) (0.35 * std::sin (2.0 * 3.14159265358979 * 110.0 * t) * std::exp (-std::fmod (t, 0.25) * 9.0));
        }
        float* in[1] = { &a[0] };
        float* out[1] = { &oa[0] };
        mouse (win, panel, NSLeftMouseDown, NSMakePoint (160, 212));
        mouse (win, panel, NSLeftMouseUp,   NSMakePoint (160, 212));
        NSData* quiet = renderPNG (panel, dir + "/panel_meters_off.png");
        e->processReplacing (e, in, out, n);
        pump (0.3);
        NSData* lit = renderPNG (panel, dir + "/panel_showcase.png");
        check (! [lit isEqualToData: quiet], "the VU and the OVERLOAD LED follow the audio");
    }
    std::printf ("\nClose\n");
    call (e, effEditClose);
    check ([[parent subviews] count] == 0, "effEditClose removes the panel");
    check (call (e, effEditOpen, 0, 0, parent) == 1 && [[parent subviews] count] == 1, "reopens");
    call (e, effEditClose);
    call (e, effMainsChanged, 0, 0);
    call (e, effClose);
    [win release];
    [pool release];      // drain before unloading the plugin's code
    dlclose (lib);

    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL EDITOR CHECKS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
