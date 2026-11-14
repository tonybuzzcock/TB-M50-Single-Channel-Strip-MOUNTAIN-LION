// PanelView.mm
// The custom panel for TB M50 Single Channel Strip: an original drawing laid out
// like one input strip of the user's TASCAM M-50, in the console's own colours
// (warm grey face, black lettering, charcoal knurled knobs with a red TRIM cap,
// orange EQ rings, cream fader cap, the red lip along the front), in the same
// lacquered mahogany frame as TB M50 Dual Channel Strip. Only the controls the
// user uses: the VU, INPUT (MIC / D.I. / LINE), TRIM with a large OVERLOAD LED
// (the drive the user listens for, not a warning), EQUALIZER BYPASS, the three
// sweep EQ sections (orange ring = FREQUENCY, dark cap = BOOST / CUT), BYPASS
// (the whole plugin, where PAN would be) and the fader. A right-click (or
// Control-click) on a control shows its exact value in the readout. No TASCAM
// artwork; the user's TB electronic logo, the presets, "M-50" and the readout
// are in the strip along the bottom.
//
// Every switch lights up in its engaged position (the user's standard).
// Cocoa, manual retain/release, and only APIs that exist in Mac OS X 10.8.5.
// Everything is drawn in code; no image files.

#import <Cocoa/Cocoa.h>

#include "Editor.h"
#include "Params.h"
#include "Presets.h"
#include "TBLogo.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace tbm50s;

namespace
{

enum CtlType { kCtlTrim, kCtlEqRing, kCtlEqCap, kCtlSlide3, kCtlButton, kCtlFader, kCtlBypass };

struct Ctl
{
    int param;
    int type;
    CGFloat cx, cy, r;
    const char* label;     // readout name
};

// Geometry (flipped: y down)
const CGFloat kChX = 160.0;                // the strip's centre line
const CGFloat kConsoleBottom = 808.0;      // the plugin strip starts here (a clear band of face below the faders' 0)
const CGFloat kVuTop = 38.0, kVuW = 92.0, kVuH = 60.0;
const CGFloat kInputY = 152.0;
const CGFloat kTrimY = 212.0;
const CGFloat kBypassY = 278.0;
const CGFloat kEqY[3] = { 334.0, 408.0, 482.0 };   // HIGH, MID, LOW (top to bottom)
const CGFloat kBypassAllY = 556.0;         // BYPASS, where PAN would be
const CGFloat kFaderTop = 600.0, kFaderBottom = 742.0;   // cap centre travel
const CGFloat kKnobR = 19.0, kEqR = 22.0, kEqCapR = 12.5;
const NSPoint kOlLed = { 160.0 + 54.0, 212.0 - 10.0 };   // OVERLOAD, large, beside TRIM
const CGFloat kOlR = 6.5;
const CGFloat kSlideHalf = 28.0;           // detent spacing of the INPUT switch
const CGFloat kCapW = 38.0, kCapH = 20.0;  // fader cap

const Ctl kCtls[] = {
    { kInput,    kCtlSlide3, kChX, kInputY,  0, "INPUT" },
    { kTrim,     kCtlTrim,   kChX, kTrimY,   kKnobR, "TRIM" },
    { kEqBypass, kCtlButton, kChX + 40.0, kBypassY, 0, "EQ" },
    { kHiGain,   kCtlEqCap,  kChX, kEqY[0],  kEqCapR, "HIGH" },
    { kHiFreq,   kCtlEqRing, kChX, kEqY[0],  kEqR, "HIGH FREQ" },
    { kMidGain,  kCtlEqCap,  kChX, kEqY[1],  kEqCapR, "MID" },
    { kMidFreq,  kCtlEqRing, kChX, kEqY[1],  kEqR, "MID FREQ" },
    { kLoGain,   kCtlEqCap,  kChX, kEqY[2],  kEqCapR, "LOW" },
    { kLoFreq,   kCtlEqRing, kChX, kEqY[2],  kEqR, "LOW FREQ" },
    { kBypass,   kCtlBypass, kChX, kBypassAllY, 0, "BYPASS" },
    { kFader,    kCtlFader,  kChX, 0,        0, "FADER" },
};
const int kNumCtls = (int) (sizeof (kCtls) / sizeof (kCtls[0]));
const CGFloat kBypassHalfW = 30.0, kBypassHalfH = 17.0;   // the BYPASS button

// Plugin strip: logo and SAVE on the left, the preset keys in two rows of 4,
// "M-50", the readout along the bottom
const NSRect kLogoBox = { { 14.0, 820.0 }, { 110.0, 64.0 } };
const NSRect kSaveRect = { { 22.0, 894.0 }, { 94.0, 28.0 } };
const CGFloat kSlotX0 = 136.0, kSlotPitch = 44.0, kSlotW = 38.0, kSlotY0 = 822.0, kSlotRowPitch = 34.0, kSlotH = 28.0;
const NSRect kReadoutRect = { { 14.0, 932.0 }, { 292.0, 38.0 } };

inline NSRect slotRect (int k) { return NSMakeRect (kSlotX0 + (k % 4) * kSlotPitch, kSlotY0 + (k / 4) * kSlotRowPitch, kSlotW, kSlotH); }
inline CGFloat faderY (CGFloat v) { return kFaderBottom - v * (kFaderBottom - kFaderTop); }
inline NSRect vuRect (CGFloat cx) { return NSMakeRect (cx - kVuW * 0.5, kVuTop, kVuW, kVuH); }

// Pointer angle (radians, 0 = up, clockwise positive) for a 0..1 value over 300 degrees.
inline CGFloat valueAngle (CGFloat v) { return (CGFloat) ((-150.0 + 300.0 * v) * M_PI / 180.0); }

inline NSPoint polar (CGFloat cx, CGFloat cy, CGFloat r, CGFloat a)
{
    return NSMakePoint (cx + r * std::sin (a), cy - r * std::cos (a));
}

NSColor* rgb (int r, int g, int b) { return [NSColor colorWithCalibratedRed: r / 255.0 green: g / 255.0 blue: b / 255.0 alpha: 1.0]; }
NSColor* rgba (int r, int g, int b, CGFloat a) { return [NSColor colorWithCalibratedRed: r / 255.0 green: g / 255.0 blue: b / 255.0 alpha: a]; }
// The M-50's colours (from the photo of the strip)
NSColor* ink()       { return rgb (28, 28, 26); }
NSColor* dimInk()    { return rgb (128, 125, 118); }
NSColor* faceTop()   { return rgb (204, 200, 191); }
NSColor* faceBot()   { return rgb (182, 178, 169); }
NSColor* trimRed()   { return rgb (206, 38, 34); }
NSColor* cream()     { return rgb (234, 228, 208); }
NSColor* amber()     { return rgb (255, 168, 40); }

NSFont* boldFont (CGFloat size)
{
    NSFont* f = [NSFont fontWithName: @"Helvetica-Bold" size: size];
    return f ? f : [NSFont boldSystemFontOfSize: size];
}

NSFont* plainFont (CGFloat size)
{
    NSFont* f = [NSFont fontWithName: @"Helvetica" size: size];
    return f ? f : [NSFont systemFontOfSize: size];
}

NSDictionary* textAttrs (NSFont* font, NSColor* color, CGFloat kern)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
              font, NSFontAttributeName, color, NSForegroundColorAttributeName,
              [NSNumber numberWithDouble: kern], NSKernAttributeName, nil];
}

void drawText (const char* s, NSFont* font, NSColor* color, CGFloat cx, CGFloat cy, CGFloat kern = 0.0)
{
    NSString* str = [NSString stringWithUTF8String: s];
    NSDictionary* attrs = textAttrs (font, color, kern);
    const NSSize sz = [str sizeWithAttributes: attrs];
    [str drawAtPoint: NSMakePoint (cx - (sz.width - kern) * 0.5, cy - sz.height * 0.5) withAttributes: attrs];
}

void line (CGFloat x0, CGFloat y0, CGFloat x1, CGFloat y1, CGFloat w)
{
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint: NSMakePoint (x0, y0)];
    [p lineToPoint: NSMakePoint (x1, y1)];
    [p setLineWidth: w];
    [p stroke];
}

// Tick marks round a knob over its 300 degrees
void drawTicks (CGFloat cx, CGFloat cy, CGFloat r, int n)
{
    [ink() set];
    for (int k = 0; k < n; ++k)
    {
        const CGFloat a = (CGFloat) ((-150.0 + 300.0 * k / (n - 1)) * M_PI / 180.0);
        line (polar (cx, cy, r + 4.0, a).x, polar (cx, cy, r + 4.0, a).y,
              polar (cx, cy, r + (k == 0 || k == n - 1 || k == (n - 1) / 2 ? 10.0 : 8.0), a).x,
              polar (cx, cy, r + (k == 0 || k == n - 1 || k == (n - 1) / 2 ? 10.0 : 8.0), a).y, 1.2);
    }
}

// End labels just outside a scale's end ticks
void endLabels (const char* a, const char* b, CGFloat cx, CGFloat cy, CGFloat r)
{
    NSFont* f = boldFont (8.0);
    const NSPoint pa = polar (cx, cy, r + 14.0, (CGFloat) (-150.0 * M_PI / 180.0));
    const NSPoint pb = polar (cx, cy, r + 14.0, (CGFloat) (150.0 * M_PI / 180.0));
    drawText (a, f, ink(), pa.x - 6.0, pa.y + 4.0);
    drawText (b, f, ink(), pb.x + 6.0, pb.y + 4.0);
}

void glowFill (NSBezierPath* p, NSColor* colour, CGFloat blur)
{
    [NSGraphicsContext saveGraphicsState];
    NSShadow* glow = [[[NSShadow alloc] init] autorelease];
    [glow setShadowOffset: NSMakeSize (0.0, 0.0)];
    [glow setShadowBlurRadius: blur];
    [glow setShadowColor: colour];
    [glow set];
    [colour set];
    [p fill];
    [p fill];
    [NSGraphicsContext restoreGraphicsState];
}

inline NSRect faceToView (NSRect r) { return NSOffsetRect (r, kPanelFrame, kPanelFrame); }
inline NSPoint viewToFace (NSPoint p) { return NSMakePoint (p.x - kPanelFrame, p.y - kPanelFrame); }

// One mahogany board: a deep red-brown with darker pores and lighter streaks of
// grain running along its length (horizontal or vertical), slightly wavy.
void drawMahoganyBoard (NSRect r, bool vertical, unsigned seed)
{
    NSGradient* base = [[[NSGradient alloc] initWithColorsAndLocations:
                           rgb (122, 46, 26), 0.0, rgb (104, 36, 20), 0.5, rgb (88, 30, 16), 1.0, nil] autorelease];
    [base drawInRect: r angle: vertical ? 0.0 : 90.0];
    const CGFloat len = vertical ? r.size.height : r.size.width;
    const CGFloat across = vertical ? r.size.width : r.size.height;
    for (int k = 0; k < (int) (across * 3.0); ++k)
    {
        seed = seed * 1664525u + 1013904223u;
        const CGFloat pos = (seed >> 8) / 16777216.0 * across;
        seed = seed * 1664525u + 1013904223u;
        const double q = (seed >> 8) / 16777216.0;
        seed = seed * 1664525u + 1013904223u;
        const CGFloat phase = (seed >> 8) / 16777216.0 * 6.283;
        const CGFloat amp = 0.6 + 1.6 * q, wave = 0.004 + 0.01 * q;
        NSColor* c = q < 0.55 ? rgba (40, 10, 4, 0.10 + 0.16 * q) : rgba (196, 92, 52, 0.05 + 0.10 * (q - 0.55));
        NSBezierPath* g = [NSBezierPath bezierPath];
        for (int i = 0; i <= 40; ++i)
        {
            const CGFloat t = len * i / 40.0;
            const CGFloat off = pos + amp * std::sin (t * wave * 6.283 + phase) + 0.8 * std::sin (t * 0.031 + phase * 2.0);
            const NSPoint pt = vertical ? NSMakePoint (r.origin.x + off, r.origin.y + t) : NSMakePoint (r.origin.x + t, r.origin.y + off);
            if (i == 0) [g moveToPoint: pt]; else [g lineToPoint: pt];
        }
        [g setLineWidth: 0.5 + 1.4 * (1.0 - q)];
        [c set];
        [g stroke];
    }
    // pores: short dark flecks along the grain
    for (int k = 0; k < (int) (len * across / 60.0); ++k)
    {
        seed = seed * 1664525u + 1013904223u; const CGFloat a = (seed >> 8) / 16777216.0 * len;
        seed = seed * 1664525u + 1013904223u; const CGFloat b = (seed >> 8) / 16777216.0 * across;
        [rgba (30, 6, 2, 0.35) set];
        NSRectFillUsingOperation (vertical ? NSMakeRect (r.origin.x + b, r.origin.y + a, 0.8, 3.0)
                                           : NSMakeRect (r.origin.x + a, r.origin.y + b, 3.0, 0.8), NSCompositeSourceOver);
    }
}

// The mahogany frame round the face: four boards mitred at the corners, then a
// clear lacquer (a soft sheen across each board, a bright line along its outer
// edge, a dark bevel where it meets the face).
void drawMahoganyFrame()
{
    const CGFloat W = kEditorWidth, H = kEditorHeight, F = kPanelFrame;
    for (int side = 0; side < 4; ++side)
    {
        NSBezierPath* clip = [NSBezierPath bezierPath];
        NSRect board;
        bool vertical;
        switch (side)
        {
            case 0:  // top
                [clip moveToPoint: NSMakePoint (0, 0)]; [clip lineToPoint: NSMakePoint (W, 0)];
                [clip lineToPoint: NSMakePoint (W - F, F)]; [clip lineToPoint: NSMakePoint (F, F)];
                board = NSMakeRect (0, 0, W, F); vertical = false; break;
            case 1:  // bottom
                [clip moveToPoint: NSMakePoint (0, H)]; [clip lineToPoint: NSMakePoint (W, H)];
                [clip lineToPoint: NSMakePoint (W - F, H - F)]; [clip lineToPoint: NSMakePoint (F, H - F)];
                board = NSMakeRect (0, H - F, W, F); vertical = false; break;
            case 2:  // left
                [clip moveToPoint: NSMakePoint (0, 0)]; [clip lineToPoint: NSMakePoint (F, F)];
                [clip lineToPoint: NSMakePoint (F, H - F)]; [clip lineToPoint: NSMakePoint (0, H)];
                board = NSMakeRect (0, 0, F, H); vertical = true; break;
            default: // right
                [clip moveToPoint: NSMakePoint (W, 0)]; [clip lineToPoint: NSMakePoint (W - F, F)];
                [clip lineToPoint: NSMakePoint (W - F, H - F)]; [clip lineToPoint: NSMakePoint (W, H)];
                board = NSMakeRect (W - F, 0, F, H); vertical = true; break;
        }
        [clip closePath];
        [NSGraphicsContext saveGraphicsState];
        [clip addClip];
        drawMahoganyBoard (board, vertical, 3301u + 977u * (unsigned) side);
        // lacquer: a rounded sheen across the board
        NSGradient* sheen = [[[NSGradient alloc] initWithColorsAndLocations:
                                rgba (255, 236, 220, 0.20), 0.0, rgba (255, 236, 220, 0.04), 0.35,
                                rgba (0, 0, 0, 0.0), 0.6, rgba (0, 0, 0, 0.22), 1.0, nil] autorelease];
        const CGFloat ang = side == 0 ? 90.0 : (side == 1 ? -90.0 : (side == 2 ? 0.0 : 180.0));
        [sheen drawInRect: board angle: ang];
        [NSGraphicsContext restoreGraphicsState];
        // the mitre joint
        [rgba (30, 8, 2, 0.7) set];
    }
    [rgba (30, 8, 2, 0.75) set];
    line (0, 0, F, F, 1.0);  line (W, 0, W - F, F, 1.0);
    line (0, H, F, H - F, 1.0);  line (W, H, W - F, H - F, 1.0);
    [rgba (255, 220, 200, 0.18) set];
    line (1, 0.5, W - 1, 0.5, 1.0);  line (0.5, 1, 0.5, H - 1, 1.0);
    // a soft highlight streak down the lacquer, lit from the top left
    [rgba (255, 240, 228, 0.10) set];
    NSRectFillUsingOperation (NSMakeRect (5, F, 3, H - 2 * F), NSCompositeSourceOver);
    NSRectFillUsingOperation (NSMakeRect (F, 5, W - 2 * F, 3), NSCompositeSourceOver);
    // the inner bevel where the wood meets the face
    [rgba (20, 6, 2, 0.9) set];
    NSFrameRectWithWidth (NSMakeRect (F - 2, F - 2, W - 2 * F + 4, H - 2 * F + 4), 2.0);
    [rgba (0, 0, 0, 0.85) set];
    NSFrameRectWithWidth (NSMakeRect (0, 0, W, H), 1.0);
}

// The model name in the spirit of the M-50's own: a very heavy, wide sans
// (Arial Black, which ships with OS X, stretched 25 % wider; Helvetica Bold
// thickened with an outline if it is missing). Plain lettering, no artwork.
void drawModelName (const char* text, CGFloat cx, CGFloat cy, CGFloat size)
{
    const CGFloat stretch = 1.25;
    NSFont* f = [NSFont fontWithName: @"Arial-Black" size: size];
    const bool black = f != nil;
    if (! f) f = boldFont (size);
    NSString* s = [NSString stringWithUTF8String: text];
    NSMutableDictionary* at = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                 f, NSFontAttributeName, ink(), NSForegroundColorAttributeName,
                                 [NSNumber numberWithDouble: 0.5], NSKernAttributeName, nil];
    if (! black)
    {
        [at setObject: ink() forKey: NSStrokeColorAttributeName];
        [at setObject: [NSNumber numberWithDouble: -9.0] forKey: NSStrokeWidthAttributeName];
    }
    const NSSize sz = [s sizeWithAttributes: at];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform* t = [NSAffineTransform transform];
    [t translateXBy: cx yBy: cy];
    [t scaleXBy: stretch yBy: 1.0];
    [t concat];
    [s drawAtPoint: NSMakePoint (-sz.width * 0.5, -sz.height * 0.5) withAttributes: at];
    [NSGraphicsContext restoreGraphicsState];
}

} // namespace

//==============================================================================
@interface TBM50SingleChannelStripPanelView : NSView <NSTextFieldDelegate>
{
    EditorHost* host;
    float shown[kNumParams];
    float meter[kNumMeters];
    NSTimer* timer;
    int dragCtl;
    CGFloat dragStartY, dragStartValue;
    int readoutParam;
    bool compare;             // readout shows both channels' values (right-click)
    bool saveMode;
    int activePreset;
    bool presetUsed[kNumPresetSlots];
    char status[96];
    NSImage* backdrop;        // face and fixed lettering, made once
    NSTextField* nameField;   // naming a preset, over the readout
    NSTextField* retiredField;// a finished one, taken away once its own event is over
    int namingSlot;
}
- (id) initWithFrame: (NSRect) frame host: (EditorHost*) h;
- (void) shutdown;
@end

@implementation TBM50SingleChannelStripPanelView

- (id) initWithFrame: (NSRect) frame host: (EditorHost*) h
{
    self = [super initWithFrame: frame];
    if (self)
    {
        host = h;
        for (int i = 0; i < kNumParams; ++i) shown[i] = host->getParam (i);
        for (int i = 0; i < kNumMeters; ++i) meter[i] = host->getMeter (i);
        dragCtl = -1;
        readoutParam = -1;
        compare = false;
        saveMode = false;
        activePreset = -1;
        status[0] = 0;
        backdrop = nil;
        nameField = nil;
        retiredField = nil;
        namingSlot = -1;
        host->refreshPresets();
        for (int k = 0; k < kNumPresetSlots; ++k) presetUsed[k] = host->presetExists (k);
        timer = [[NSTimer timerWithTimeInterval: 1.0 / 20.0 target: self selector: @selector (tick:)
                                       userInfo: nil repeats: YES] retain];
        [[NSRunLoop currentRunLoop] addTimer: timer forMode: NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] addTimer: timer forMode: NSEventTrackingRunLoopMode];
    }
    return self;
}

- (void) shutdown
{
    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    namingSlot = -1;
    [self dropRetired];
    if (nameField)
    {
        [nameField setDelegate: nil];
        [nameField setTarget: nil];
        [nameField removeFromSuperview];
        [nameField release];
        nameField = nil;
    }
    if (timer) { [timer invalidate]; [timer release]; timer = nil; }
    if (backdrop) { [backdrop release]; backdrop = nil; }
    host = 0;
}

- (void) dealloc
{
    [self shutdown];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstMouse: (NSEvent*) e { (void) e; return YES; }

// Host-side changes (automation, presets) and the meters redraw the panel.
- (void) tick: (NSTimer*) t
{
    (void) t;
    if (! host) return;
    bool changed = false;
    for (int i = 0; i < kNumParams; ++i)
    {
        const float v = host->getParam (i);
        if (v != shown[i]) { shown[i] = v; changed = true; }
    }
    bool vu = false, ol = false;
    for (int i = 0; i < kNumMeters; ++i)
    {
        const float v = host->getMeter (i);
        const bool isOl = i == kMeterOl;
        if (isOl ? v != meter[i] : std::fabs (v - meter[i]) > 0.05f)
        {
            meter[i] = v;
            if (isOl) ol = true; else vu = true;
        }
    }
    if (changed) { [self setNeedsDisplay: YES]; return; }
    if (vu) [self setNeedsDisplayInRect: faceToView (NSInsetRect (vuRect (kChX), -4.0, -4.0))];
    if (ol) [self setNeedsDisplayInRect: faceToView (NSMakeRect (kOlLed.x - 24.0, kOlLed.y - 24.0, 48.0, 48.0))];
}

//------------------------------------------------------------------------------
// Drawing

// The face and everything printed on it, drawn once
- (NSImage*) backdropImage
{
    if (backdrop) return backdrop;
    backdrop = [[NSImage alloc] initWithSize: NSMakeSize (kEditorWidth, kEditorHeight)];
    [backdrop lockFocusFlipped: YES];
    drawMahoganyFrame();

    // Everything else in face coordinates, inside the frame
    const CGFloat w = kFaceWidth;
    const CGFloat h = kFaceHeight;
    [NSGraphicsContext saveGraphicsState];
    {
        NSAffineTransform* t = [NSAffineTransform transform];
        [t translateXBy: kPanelFrame yBy: kPanelFrame];
        [t concat];
        NSRectClip (NSMakeRect (0, 0, w, h));
    }

    // The console face: warm grey, a faint brushed grain
    NSGradient* fg = [[[NSGradient alloc] initWithStartingColor: faceTop() endingColor: faceBot()] autorelease];
    [fg drawInRect: NSMakeRect (0, 0, w, kConsoleBottom) angle: 90.0];
    unsigned seed = 50u;
    for (int k = 0; k < 9000; ++k)
    {
        seed = seed * 1664525u + 1013904223u; const CGFloat x = (seed >> 8) / 16777216.0 * w;
        seed = seed * 1664525u + 1013904223u; const CGFloat y = (seed >> 8) / 16777216.0 * kConsoleBottom;
        seed = seed * 1664525u + 1013904223u; const double q = (seed >> 8) / 16777216.0;
        [[NSColor colorWithCalibratedWhite: q < 0.5 ? 1.0 : 0.0 alpha: 0.035 + 0.04 * q] set];
        NSRectFillUsingOperation (NSMakeRect (x, y, 3.0, 1.0), NSCompositeSourceOver);
    }

    // The red lip along the front, as on the console
    {
        const NSRect lip = NSMakeRect (0, kConsoleBottom - 14.0, w, 14.0);
        NSGradient* lg = [[[NSGradient alloc] initWithColorsAndLocations:
                             rgb (40, 38, 36), 0.0, rgb (40, 38, 36), 0.25, rgb (214, 52, 30), 0.3,
                             rgb (186, 40, 24), 0.7, rgb (40, 38, 36), 0.75, rgb (30, 29, 27), 1.0, nil] autorelease];
        [lg drawInRect: lip angle: 90.0];
    }

    // Plugin strip: a darker grey, a dark rule above
    {
        const NSRect strip = NSMakeRect (0, kConsoleBottom, w, h - kConsoleBottom);
        NSGradient* sg = [[[NSGradient alloc] initWithStartingColor: rgb (168, 164, 156) endingColor: rgb (150, 146, 139)] autorelease];
        [sg drawInRect: strip angle: 90.0];
        [rgb (30, 29, 27) set];
        NSRectFill (NSMakeRect (0, kConsoleBottom, w, 1.5));
        // the model name, plain lettering, beside the preset keys
        drawModelName ("M-50", (NSMinX (slotRect (0)) + NSMaxX (slotRect (3))) * 0.5, NSMidY (kSaveRect), 24.0);
    }
    [rgba (0, 0, 0, 0.6) set];
    NSFrameRectWithWidth (NSMakeRect (0, 0, w, h), 1.0);

    // The strip's lettering
    {
        const CGFloat x = kChX;
        drawText ("INPUT", boldFont (10.0), ink(), x, kInputY - 34.0, 0.8);

        drawText ("TRIM", boldFont (10.0), ink(), x - 46.0, kTrimY - 22.0, 0.6);
        drawTicks (x, kTrimY, kKnobR, 11);
        drawText ("OVER", boldFont (7.5), ink(), kOlLed.x, kOlLed.y + 15.0, 0.4);
        drawText ("LOAD", boldFont (7.5), ink(), kOlLed.x, kOlLed.y + 24.0, 0.4);

        // EQUALIZER section, bracketed
        [ink() set];
        line (x - 70.0, kBypassY - 26.0, x + 70.0, kBypassY - 26.0, 1.0);
        drawText ("EQUALIZER", boldFont (10.0), ink(), x, kBypassY - 16.0, 0.8);
        drawText ("BYPASS", boldFont (8.0), ink(), x + 2.0, kBypassY, 0.4);

        const char* const band[3] = { "HIGH", "MID", "LOW" };
        const char* const lo[3] = { "2.5K", "500", "50" };
        const char* const hi[3] = { "15K", "5K", "1K" };
        for (int b = 0; b < 3; ++b)
        {
            drawTicks (x, kEqY[b], kEqR, 11);
            endLabels (lo[b], hi[b], x, kEqY[b], kEqR);
            drawText (band[b], boldFont (9.0), ink(), x - 58.0, kEqY[b] - 18.0, 0.4);
        }
        drawText ("FREQ", plainFont (7.5), ink(), x + 58.0, kEqY[0] - 22.0, 0.3);
        drawText ("BOOST", plainFont (7.5), ink(), x + 58.0, kEqY[0] - 13.0, 0.3);
        drawText ("CUT", plainFont (7.5), ink(), x + 58.0, kEqY[0] - 4.0, 0.3);
        [ink() set];
        line (x - 70.0, kBypassAllY - 34.0, x + 70.0, kBypassAllY - 34.0, 1.0);
    }

    // Fader scale: 10 at the top to 0
    {
        const CGFloat x = kChX;
        NSBezierPath* slot = [NSBezierPath bezierPathWithRoundedRect: NSMakeRect (x - 3.0, kFaderTop - 12.0, 6.0, kFaderBottom - kFaderTop + 24.0)
                                                             xRadius: 3.0 yRadius: 3.0];
        [rgb (24, 23, 22) set];
        [slot fill];
        for (int k = 0; k <= 10; ++k)
        {
            const CGFloat y = faderY (k / 10.0f);
            [ink() set];
            line (x - 26.0, y, x - 14.0, y, k == 0 || k == 10 || k == 5 ? 1.4 : 0.9);
            line (x + 14.0, y, x + 26.0, y, k == 0 || k == 10 || k == 5 ? 1.4 : 0.9);
            char n[4];
            std::snprintf (n, sizeof (n), "%d", 10 - k);
            drawText (n, boldFont (8.0), ink(), x - 36.0, faderY ((10 - k) / 10.0f) + 0.5);
        }
    }

    // The TB electronic logo, red and black, in the strip's corner
    tblogo::drawTBLogo (kLogoBox);

    [NSGraphicsContext restoreGraphicsState];
    // the frame's shadow falling on the face's edge
    for (int k = 0; k < 6; ++k)
    {
        [rgba (0, 0, 0, 0.22 - 0.035 * k) set];
        NSFrameRectWithWidth (NSMakeRect (kPanelFrame + k, kPanelFrame + k, w - 2 * k, h - 2 * k), 1.0);
    }
    [backdrop unlockFocus];
    return backdrop;
}

- (void) drawBackground
{
    [[self backdropImage] drawInRect: [self bounds] fromRect: NSZeroRect
                           operation: NSCompositeSourceOver fraction: 1.0 respectFlipped: YES hints: nil];
}

// Small backlit VU: cream face, black scale, red over 0, black needle
- (void) drawVU: (NSRect) r value: (float) db label: (const char*) lab
{
    NSBezierPath* bezel = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (r, -3.0, -3.0) xRadius: 3.0 yRadius: 3.0];
    [rgb (26, 25, 24) set];
    [bezel fill];
    NSBezierPath* face = [NSBezierPath bezierPathWithRect: r];
    NSGradient* fg = [[[NSGradient alloc] initWithColorsAndLocations:
                         rgb (255, 244, 206), 0.0, rgb (246, 226, 168), 0.7, rgb (226, 200, 140), 1.0, nil] autorelease];
    [fg drawInBezierPath: face relativeCenterPosition: NSMakePoint (0.0, -0.3)];

    [NSGraphicsContext saveGraphicsState];
    [face addClip];
    const NSPoint pivot = NSMakePoint (NSMidX (r), NSMaxY (r) + 26.0);
    const CGFloat rad = r.size.height + 6.0;
    // Position follows the needle's voltage: -20 VU .. +3 VU over 80 degrees
    struct T { float db; const char* txt; } ticks[] = {
        { -20, "20" }, { -10, "10" }, { -7, "7" }, { -5, "5" }, { -3, "3" }, { -2, "" }, { -1, "" },
        { 0, "0" }, { 1, "" }, { 2, "" }, { 3, "+3" } };
    const CGFloat v0 = std::pow (10.0, -20.0 / 20.0), v1 = std::pow (10.0, 3.0 / 20.0);
    #define VU_ANGLE(d) ((CGFloat) ((-40.0 + 80.0 * (std::pow (10.0, (d) / 20.0) - v0) / (v1 - v0)) * M_PI / 180.0))
    // the red arc over 0
    {
        NSBezierPath* arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter: pivot radius: rad - 9.0
                                    startAngle: (CGFloat) (-90.0 + VU_ANGLE (0) * 180.0 / M_PI)
                                      endAngle: (CGFloat) (-90.0 + 40.0) clockwise: NO];
        [arc setLineWidth: 4.0];
        [rgb (204, 30, 24) set];
        [arc stroke];
        NSBezierPath* arc2 = [NSBezierPath bezierPath];
        [arc2 appendBezierPathWithArcWithCenter: pivot radius: rad - 9.0
                                     startAngle: -130.0 endAngle: (CGFloat) (-90.0 + VU_ANGLE (0) * 180.0 / M_PI) clockwise: NO];
        [arc2 setLineWidth: 1.0];
        [ink() set];
        [arc2 stroke];
    }
    for (size_t k = 0; k < sizeof (ticks) / sizeof (ticks[0]); ++k)
    {
        const CGFloat a = VU_ANGLE (ticks[k].db);
        [(ticks[k].db > 0 ? rgb (204, 30, 24) : ink()) set];
        line (polar (pivot.x, pivot.y, rad - 11.0, a).x, polar (pivot.x, pivot.y, rad - 11.0, a).y,
              polar (pivot.x, pivot.y, rad - 5.0, a).x, polar (pivot.x, pivot.y, rad - 5.0, a).y, 1.0);
        if (ticks[k].txt[0])
        {
            const NSPoint p = polar (pivot.x, pivot.y, rad + 1.0, a);
            drawText (ticks[k].txt, boldFont (7.0), ticks[k].db > 0 ? rgb (190, 26, 20) : ink(), p.x, p.y);
        }
    }
    drawText ("VU", boldFont (9.0), ink(), NSMidX (r), NSMaxY (r) - 13.0, 0.5);
    (void) lab;      // the channel / side is lettered outside the meter

    // the needle, pinned a little past each end
    float d = db < -22.0f ? -22.0f : (db > 4.0f ? 4.0f : db);
    CGFloat a = VU_ANGLE (d);
    if (db <= -59.0f) a = (CGFloat) (-43.0 * M_PI / 180.0);
    [rgb (16, 16, 16) set];
    line (pivot.x, pivot.y, polar (pivot.x, pivot.y, rad - 2.0, a).x, polar (pivot.x, pivot.y, rad - 2.0, a).y, 1.2);
    #undef VU_ANGLE
    [NSGraphicsContext restoreGraphicsState];

    // glass sheen
    [rgba (255, 255, 255, 0.18) set];
    NSRectFillUsingOperation (NSMakeRect (NSMinX (r), NSMinY (r), r.size.width, r.size.height * 0.35), NSCompositeSourceOver);
    [rgb (20, 20, 20) set];
    NSFrameRectWithWidth (r, 1.0);
}

// Charcoal knurled skirt (40 ridges) with a coloured cap and a pointer line.
// ringPointer: the pointer is on the skirt (the EQ's FREQUENCY ring).
- (void) drawKnobAt: (NSPoint) c radius: (CGFloat) r skirt: (NSColor*) skirtCol skirtDark: (NSColor*) skirtDark
             angle: (CGFloat) sa ringPointer: (bool) ringPointer
              capR: (CGFloat) rc cap: (NSColor*) capCol capDark: (NSColor*) capDark capAngle: (CGFloat) ca
           pointer: (NSColor*) ptr
{
    NSBezierPath* skirt = [NSBezierPath bezierPath];
    const int ridges = 40;
    for (int k = 0; k <= ridges * 4; ++k)
    {
        const CGFloat t = (CGFloat) (2.0 * M_PI * k / (ridges * 4));
        const CGFloat rr = r * (1.0 - 0.04 * (0.5 - 0.5 * std::cos (ridges * t)));
        const NSPoint p = polar (c.x, c.y, rr, t + sa);
        if (k == 0) [skirt moveToPoint: p]; else [skirt lineToPoint: p];
    }
    [skirt closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [[[NSShadow alloc] init] autorelease];
    [sh setShadowOffset: NSMakeSize (1.5, -3.0)];
    [sh setShadowBlurRadius: 4.0];
    [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.55]];
    [sh set];
    [skirtDark set];
    [skirt fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* sk = [[[NSGradient alloc] initWithColorsAndLocations: skirtCol, 0.0, skirtDark, 1.0, nil] autorelease];
    [sk drawInBezierPath: skirt relativeCenterPosition: NSMakePoint (-0.35, 0.5)];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.35] set];
    for (int k = 0; k < ridges; ++k)
    {
        const CGFloat t = (CGFloat) (2.0 * M_PI * k / ridges) + sa;
        line (polar (c.x, c.y, r * 0.82, t).x, polar (c.x, c.y, r * 0.82, t).y,
              polar (c.x, c.y, r * 0.97, t).x, polar (c.x, c.y, r * 0.97, t).y, 0.7);
    }
    if (ringPointer)
    {
        [[NSColor whiteColor] set];
        NSBezierPath* p = [NSBezierPath bezierPath];
        [p moveToPoint: polar (c.x, c.y, rc + 2.0, sa)];
        [p lineToPoint: polar (c.x, c.y, r * 0.98, sa)];
        [p setLineWidth: 2.6];
        [p setLineCapStyle: NSRoundLineCapStyle];
        [p stroke];
    }

    NSBezierPath* cap = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - rc, c.y - rc, 2 * rc, 2 * rc)];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* cs = [[[NSShadow alloc] init] autorelease];
    [cs setShadowOffset: NSMakeSize (0.8, -1.5)];
    [cs setShadowBlurRadius: 2.0];
    [cs setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.6]];
    [cs set];
    [capDark set];
    [cap fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* cg = [[[NSGradient alloc] initWithColorsAndLocations:
                         [capCol blendedColorWithFraction: 0.35 ofColor: [NSColor whiteColor]], 0.0, capCol, 0.5, capDark, 1.0, nil] autorelease];
    [cg drawInBezierPath: cap relativeCenterPosition: NSMakePoint (-0.3, 0.45)];
    [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.5] set];
    [cap setLineWidth: 0.8];
    [cap stroke];
    [ptr set];
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint: polar (c.x, c.y, rc * 0.25, ca)];
    [p lineToPoint: polar (c.x, c.y, rc * 0.92, ca)];
    [p setLineWidth: 2.2];
    [p setLineCapStyle: NSRoundLineCapStyle];
    [p stroke];
}

// INPUT: a three-position slide switch; the lever glows amber at the engaged
// position and that legend lights up, the others dim.
- (void) drawSlide3At: (NSPoint) c index: (int) idx
{
    const char* const names[3] = { "MIC", "D.I.", "LINE" };
    const NSRect slot = NSMakeRect (c.x - kSlideHalf - 16.0, c.y - 8.0, 2 * kSlideHalf + 32.0, 16.0);
    NSBezierPath* sp = [NSBezierPath bezierPathWithRoundedRect: slot xRadius: 3.0 yRadius: 3.0];
    [rgb (36, 35, 33) set];
    [sp fill];
    for (int k = 0; k < 3; ++k)
    {
        const CGFloat x = c.x + (k - 1) * kSlideHalf;
        const bool on = k == idx;
        if (on)
        {
            NSString* s = [NSString stringWithUTF8String: names[k]];
            NSDictionary* at = textAttrs (boldFont (9.5), ink(), 0.4);
            const NSSize sz = [s sizeWithAttributes: at];
            [NSGraphicsContext saveGraphicsState];
            NSShadow* g = [[[NSShadow alloc] init] autorelease];
            [g setShadowOffset: NSMakeSize (0.0, 0.0)];
            [g setShadowBlurRadius: 7.0];
            [g setShadowColor: amber()];
            [g set];
            [s drawAtPoint: NSMakePoint (x - sz.width * 0.5, c.y - 22.0 - sz.height * 0.5) withAttributes: at];
            [NSGraphicsContext restoreGraphicsState];
        }
        else
            drawText (names[k], boldFont (9.5), dimInk(), x, c.y - 22.0, 0.4);
        // detent dots
        [rgb (90, 88, 84) set];
        NSRectFill (NSMakeRect (x - 1.0, c.y - 1.0, 2.0, 2.0));
    }
    const CGFloat lx = c.x + (idx - 1) * kSlideHalf;
    NSBezierPath* lever = [NSBezierPath bezierPathWithRoundedRect: NSMakeRect (lx - 10.0, c.y - 6.5, 20.0, 13.0) xRadius: 2.5 yRadius: 2.5];
    glowFill (lever, amber(), 12.0);
    NSGradient* lg = [[[NSGradient alloc] initWithColorsAndLocations:
                         rgb (255, 246, 214), 0.0, rgb (255, 196, 90), 0.45, rgb (230, 140, 20), 1.0, nil] autorelease];
    [lg drawInBezierPath: lever relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    [rgb (60, 40, 10) set];
    [lever setLineWidth: 0.8];
    [lever stroke];
    [rgba (120, 70, 0, 0.6) set];
    line (lx, c.y - 4.0, lx, c.y + 4.0, 1.4);
}

// EQ BYPASS: square push button; in = bypassed, lit red with its LED
- (void) drawButtonAt: (NSPoint) c in: (bool) in
{
    const NSRect r = NSMakeRect (c.x - 11.0, c.y - 9.0, 22.0, 18.0);
    NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (r, -2.5, -2.5) xRadius: 2.0 yRadius: 2.0];
    [rgb (30, 29, 28) set];
    [bp fill];
    NSBezierPath* cp = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (r, in ? 1.0 : 0.0, in ? 1.0 : 0.0) xRadius: 1.5 yRadius: 1.5];
    if (in)
    {
        glowFill (cp, rgb (255, 40, 24), 14.0);
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (255, 230, 214), 0.0, rgb (255, 110, 86), 0.35, rgb (232, 30, 18), 1.0, nil] autorelease];
        [g drawInBezierPath: cp relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    }
    else
    {
        NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (226, 222, 212) endingColor: rgb (170, 166, 158)] autorelease];
        [g drawInBezierPath: cp angle: -90.0];
        [rgba (255, 255, 255, 0.5) set];
        NSRectFillUsingOperation (NSMakeRect (NSMinX (r) + 2.0, NSMinY (r) + 1.5, r.size.width - 4.0, 1.0), NSCompositeSourceOver);
    }
    [rgba (0, 0, 0, 0.5) set];
    [cp setLineWidth: 0.8];
    [cp stroke];
}

// BYPASS (whole plugin): a larger square push button with its name on it;
// in = bypassed, lit red with a glow
- (void) drawBypassAt: (NSPoint) c in: (bool) in title: (const char*) title
{
    const NSRect r = NSMakeRect (c.x - kBypassHalfW, c.y - kBypassHalfH, 2 * kBypassHalfW, 2 * kBypassHalfH);
    NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (r, -3.0, -3.0) xRadius: 2.5 yRadius: 2.5];
    [rgb (30, 29, 28) set];
    [bp fill];
    NSBezierPath* cp = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (r, in ? 1.0 : 0.0, in ? 1.0 : 0.0) xRadius: 2.0 yRadius: 2.0];
    if (in)
    {
        glowFill (cp, rgb (255, 40, 24), 18.0);
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (255, 230, 214), 0.0, rgb (255, 110, 86), 0.35, rgb (232, 30, 18), 1.0, nil] autorelease];
        [g drawInBezierPath: cp relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    }
    else
    {
        [NSGraphicsContext saveGraphicsState];
        NSShadow* sh = [[[NSShadow alloc] init] autorelease];
        [sh setShadowOffset: NSMakeSize (1.0, -2.5)];
        [sh setShadowBlurRadius: 3.0];
        [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.5]];
        [sh set];
        [rgb (170, 166, 158) set];
        [cp fill];
        [NSGraphicsContext restoreGraphicsState];
        NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (230, 226, 216) endingColor: rgb (172, 168, 160)] autorelease];
        [g drawInBezierPath: cp angle: -90.0];
        [rgba (255, 255, 255, 0.5) set];
        NSRectFillUsingOperation (NSMakeRect (NSMinX (r) + 2.0, NSMinY (r) + 1.5, r.size.width - 4.0, 1.0), NSCompositeSourceOver);
    }
    [rgba (0, 0, 0, 0.5) set];
    [cp setLineWidth: 0.8];
    [cp stroke];
    drawText (title, boldFont (12.0), in ? rgb (70, 8, 4) : ink(), c.x, c.y, 0.8);
}

// The OVERLOAD LED, larger than the others: on this strip a flash means the
// preamp is giving the sound its edge, so it sits proud beside TRIM in a
// chrome bezel and glows hard when lit.
- (void) drawOverloadLed: (bool) lit
{
    const NSPoint c = kOlLed;
    const CGFloat r = kOlR;
    NSBezierPath* bezel = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - r - 3.0, c.y - r - 3.0, 2 * r + 6.0, 2 * r + 6.0)];
    NSGradient* bg = [[[NSGradient alloc] initWithStartingColor: rgb (236, 234, 228) endingColor: rgb (110, 108, 102)] autorelease];
    [bg drawInBezierPath: bezel angle: -60.0];
    NSBezierPath* lens = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - r, c.y - r, 2 * r, 2 * r)];
    if (lit)
    {
        const CGFloat hr = 24.0;
        NSGradient* halo = [[[NSGradient alloc] initWithColorsAndLocations:
                               rgba (255, 40, 24, 0.85), 0.0, rgba (255, 40, 24, 0.3), 0.45, rgba (255, 40, 24, 0.0), 1.0, nil] autorelease];
        [halo drawInBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - hr, c.y - hr, 2 * hr, 2 * hr)]
              relativeCenterPosition: NSMakePoint (0.0, 0.0)];
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (255, 244, 230), 0.0, rgb (255, 90, 60), 0.45, rgb (220, 20, 10), 1.0, nil] autorelease];
        [g drawInBezierPath: lens relativeCenterPosition: NSMakePoint (-0.2, 0.3)];
    }
    else
    {
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (170, 50, 42), 0.0, rgb (110, 18, 14), 0.55, rgb (52, 8, 6), 1.0, nil] autorelease];
        [g drawInBezierPath: lens relativeCenterPosition: NSMakePoint (-0.3, 0.4)];
    }
    [rgb (30, 20, 18) set];
    [lens setLineWidth: 0.8];
    [lens stroke];
    // a glint on the lens
    [rgba (255, 255, 255, lit ? 0.7 : 0.35) set];
    [[NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - r * 0.55, c.y - r * 0.6, r * 0.5, r * 0.35)] fill];
}

- (void) drawLedAt: (NSPoint) c lit: (bool) lit
{
    const CGFloat r = 4.0;
    NSBezierPath* lens = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - r, c.y - r, 2 * r, 2 * r)];
    if (lit)
    {
        const CGFloat hr = 13.0;
        NSGradient* halo = [[[NSGradient alloc] initWithColorsAndLocations:
                               rgba (255, 40, 24, 0.75), 0.0, rgba (255, 40, 24, 0.22), 0.5, rgba (255, 40, 24, 0.0), 1.0, nil] autorelease];
        [halo drawInBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect (c.x - hr, c.y - hr, 2 * hr, 2 * hr)]
              relativeCenterPosition: NSMakePoint (0.0, 0.0)];
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (255, 236, 220), 0.0, rgb (255, 70, 46), 0.5, rgb (214, 20, 12), 1.0, nil] autorelease];
        [g drawInBezierPath: lens relativeCenterPosition: NSMakePoint (-0.2, 0.3)];
    }
    else
    {
        NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (130, 30, 26) endingColor: rgb (60, 10, 8)] autorelease];
        [g drawInBezierPath: lens relativeCenterPosition: NSMakePoint (-0.3, 0.4)];
    }
    [rgb (30, 20, 18) set];
    [lens setLineWidth: 0.8];
    [lens stroke];
}

- (void) drawFaderAt: (CGFloat) x value: (float) v
{
    const CGFloat y = faderY (v);
    const NSRect r = NSMakeRect (x - kCapW * 0.5, y - kCapH * 0.5, kCapW, kCapH);
    NSBezierPath* cp = [NSBezierPath bezierPathWithRoundedRect: r xRadius: 2.5 yRadius: 2.5];
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [[[NSShadow alloc] init] autorelease];
    [sh setShadowOffset: NSMakeSize (2.0, -4.0)];
    [sh setShadowBlurRadius: 5.0];
    [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.6]];
    [sh set];
    [rgb (150, 146, 132) set];
    [cp fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                        rgb (250, 246, 232), 0.0, cream(), 0.45, rgb (190, 184, 164), 0.55, rgb (226, 220, 200), 1.0, nil] autorelease];
    [g drawInBezierPath: cp angle: -90.0];
    [rgb (60, 58, 52) set];
    [cp setLineWidth: 0.8];
    [cp stroke];
    [rgb (20, 20, 20) set];
    line (x - kCapW * 0.5 + 3.0, y, x + kCapW * 0.5 - 3.0, y, 2.0);
}

- (void) drawReadout
{
    const NSRect box = kReadoutRect;
    NSBezierPath* p = [NSBezierPath bezierPathWithRect: box];
    NSGradient* glow = [[[NSGradient alloc] initWithStartingColor: rgb (232, 212, 170) endingColor: rgb (204, 178, 130)] autorelease];   // tan
    [glow drawInBezierPath: p relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    [rgb (40, 42, 38) set];
    [p setLineWidth: 1.0];
    [p stroke];

    if (status[0])
        [self drawFitted: status in: box];
    else if (readoutParam >= 0 && host)
    {
        char text[128];
        const char* name = "";
        for (int i = 0; i < kNumCtls; ++i)
            if (kCtls[i].param == readoutParam) { name = kCtls[i].label; break; }
        char v[40];
        [self valueText: readoutParam into: v size: sizeof (v)];
        std::snprintf (text, sizeof (text), "%s   %s", name, v);
        [self drawFitted: text in: box];
    }
}

// Readout text as large as fits the narrow readout (preset names up to 40 characters)
- (void) drawFitted: (const char*) text in: (NSRect) box
{
    NSString* s = [NSString stringWithUTF8String: text];
    CGFloat size = 17.0;
    while (size > 9.0 && [s sizeWithAttributes: textAttrs (boldFont (size), ink(), 0.0)].width > box.size.width - 12.0)
        size -= 0.5;
    drawText (text, boldFont (size), [NSColor blackColor], NSMidX (box), NSMidY (box));
}

// A parameter's value as the readout shows it, with units
- (void) valueText: (int) param into: (char*) out size: (size_t) size
{
    char disp[16] = { 0 };
    host->getParamDisplay (param, disp);
    const int kind = kParamKind[param];
    if (kind == kHiHz || kind == kMidHz || kind == kLoHz)
    {
        const size_t n = std::strlen (disp);
        if (n && disp[n - 1] == 'k') { disp[n - 1] = 0; std::snprintf (out, size, "%s kHz", disp); }
        else std::snprintf (out, size, "%s Hz", disp);
    }
    else if (kind == kBypassAll)
        std::snprintf (out, size, "%s", isOn (shown[param]) ? "ON" : "OFF");
    else if (kind == kBypassSw)
        std::snprintf (out, size, "%s", isOn (shown[param]) ? "BYPASSED" : "IN");
    else if (kind == kMicLine)
    {
        static const char* const names[3] = { "MIC", "D.I.", "LINE" };
        std::snprintf (out, size, "%s", names[inputIndex (shown[param])]);
    }
    else
        std::snprintf (out, size, "%s%s", disp, std::strcmp (disp, "-inf") ? " dB" : "");
}

// Preset keys: empty silver, saved charcoal, the one in use glowing red (the
// user's choice for this panel); SAVE lit red while armed.
- (void) drawKey: (NSRect) r state: (int) state
{
    NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect: r xRadius: 2.0 yRadius: 2.0];
    if (state == 3)
    {
        glowFill (bp, rgb (255, 40, 24), 12.0);
        NSGradient* g = [[[NSGradient alloc] initWithColorsAndLocations:
                            rgb (255, 210, 196), 0.0, rgb (255, 70, 46), 0.5, rgb (214, 20, 12), 1.0, nil] autorelease];
        [g drawInBezierPath: bp relativeCenterPosition: NSMakePoint (0.0, 0.0)];
    }
    else if (state == 2)
    {
        glowFill (bp, rgb (170, 240, 60), 10.0);
        NSGradient* g = [[[NSGradient alloc] initWithStartingColor: rgb (214, 255, 120) endingColor: rgb (150, 214, 40)] autorelease];
        [g drawInBezierPath: bp angle: -90.0];
    }
    else
    {
        [NSGraphicsContext saveGraphicsState];
        NSShadow* sh = [[[NSShadow alloc] init] autorelease];
        [sh setShadowOffset: NSMakeSize (1.0, -2.0)];
        [sh setShadowBlurRadius: 2.5];
        [sh setShadowColor: [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.5]];
        [sh set];
        [rgb (80, 78, 74) set];
        [bp fill];
        [NSGraphicsContext restoreGraphicsState];
        NSGradient* g = state == 1
            ? [[[NSGradient alloc] initWithStartingColor: rgb (84, 82, 78) endingColor: rgb (44, 43, 41)] autorelease]
            : [[[NSGradient alloc] initWithStartingColor: rgb (226, 223, 216) endingColor: rgb (184, 180, 172)] autorelease];
        [g drawInBezierPath: bp angle: -90.0];
    }
    [rgb (30, 29, 28) set];
    [bp setLineWidth: 1.0];
    [bp stroke];
}

- (void) drawPresets
{
    [self drawKey: kSaveRect state: saveMode ? 3 : 1];
    drawText ("SAVE", boldFont (14.0), saveMode ? rgb (60, 10, 6) : [NSColor whiteColor], NSMidX (kSaveRect), NSMidY (kSaveRect));
    for (int k = 0; k < kNumPresetSlots; ++k)
    {
        const NSRect r = slotRect (k);
        const int state = (k == activePreset) ? 3 : (presetUsed[k] ? 1 : 0);   // in use: glows red
        [self drawKey: r state: state];
        NSColor* text = state == 1 ? [NSColor whiteColor] : (state == 3 ? rgb (60, 10, 6) : [NSColor blackColor]);
        char num[4];
        std::snprintf (num, sizeof (num), "%d", k + 1);
        drawText (num, boldFont (15.0), text, NSMidX (r), NSMidY (r));
    }
}

- (void) drawRect: (NSRect) dirty
{
    (void) dirty;
    [self drawBackground];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform* faceT = [NSAffineTransform transform];
    [faceT translateXBy: kPanelFrame yBy: kPanelFrame];
    [faceT concat];
    [self drawFace];
    [NSGraphicsContext restoreGraphicsState];
}

// The controls, lamps, meters, presets and readout, in face coordinates
- (void) drawFace
{

    [self drawVU: vuRect (kChX) value: meter[kMeterVu] label: ""];
    [self drawOverloadLed: meter[kMeterOl] > 0.5f];
    [self drawLedAt: NSMakePoint (kChX - 38.0, kBypassY) lit: isOn (shown[kEqBypass])];

    for (int i = 0; i < kNumCtls; ++i)
    {
        const Ctl& c = kCtls[i];
        const NSPoint p = NSMakePoint (c.cx, c.cy);
        const float v = shown[c.param];
        switch (c.type)
        {
            case kCtlTrim:
                [self drawKnobAt: p radius: kKnobR skirt: rgb (96, 94, 90) skirtDark: rgb (34, 33, 31) angle: valueAngle (v)
                     ringPointer: false capR: kKnobR * 0.66 cap: trimRed() capDark: rgb (120, 18, 14) capAngle: valueAngle (v)
                         pointer: [NSColor whiteColor]];
                break;
            case kCtlEqRing:
            {
                // the ring is FREQUENCY; its cap (the previous entry) is BOOST / CUT
                const float gv = shown[kCtls[i - 1].param];
                [self drawKnobAt: p radius: kEqR skirt: rgb (250, 176, 90) skirtDark: rgb (184, 88, 14) angle: valueAngle (v)
                     ringPointer: true capR: kEqCapR cap: rgb (92, 90, 86) capDark: rgb (30, 29, 28) capAngle: valueAngle (gv)
                         pointer: [NSColor whiteColor]];
                break;
            }
            case kCtlEqCap:
                break;      // drawn with its ring
            case kCtlSlide3:
                [self drawSlide3At: p index: inputIndex (v)];
                break;
            case kCtlButton:
                [self drawButtonAt: p in: isOn (v)];
                break;
            case kCtlFader:
                [self drawFaderAt: c.cx value: v];
                break;
            case kCtlBypass:
                [self drawBypassAt: p in: isOn (v) title: "BYPASS"];
                break;
            default: break;
        }
    }
    [self drawPresets];
    [self drawReadout];
}

//------------------------------------------------------------------------------
// Mouse

- (int) ctlAtPoint: (NSPoint) p
{
    for (int i = 0; i < kNumCtls; ++i)
    {
        const Ctl& c = kCtls[i];
        const CGFloat dx = p.x - c.cx;
        switch (c.type)
        {
            case kCtlSlide3:
                if (std::fabs (dx) <= kSlideHalf + 18.0 && std::fabs (p.y - c.cy) <= 12.0) return i;
                break;
            case kCtlButton:
                if (std::fabs (dx) <= 15.0 && std::fabs (p.y - c.cy) <= 13.0) return i;
                break;
            case kCtlFader:
                if (std::fabs (dx) <= kCapW * 0.5 + 4.0 && p.y >= kFaderTop - kCapH && p.y <= kFaderBottom + kCapH) return i;
                break;
            case kCtlBypass:
                if (std::fabs (dx) <= kBypassHalfW + 3.0 && std::fabs (p.y - c.cy) <= kBypassHalfH + 3.0) return i;
                break;
            default:
            {
                const CGFloat dy = p.y - c.cy;
                const CGFloat reach = c.type == kCtlEqCap ? c.r : c.r + 5.0;   // the cap is listed before its ring, so it wins inside
                if (dx * dx + dy * dy < reach * reach) return i;
                break;
            }
        }
    }
    return -1;
}

- (void) setParam: (int) param value: (float) v
{
    if (! host) return;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    host->guiSetParam (param, v);
    shown[param] = host->getParam (param);
    readoutParam = param;
    [self setNeedsDisplay: YES];
}

//------------------------------------------------------------------------------
// Preset names: after a save, or a click on the readout while a preset is in
// use, the readout becomes a text box. Return keeps the name, Esc leaves the
// old one, a click elsewhere keeps what was typed.

- (void) showPreset: (int) slot verb: (const char*) verb
{
    char name[kMaxPresetName + 8] = { 0 };
    if (host) host->presetName (slot, name, (int) sizeof (name));
    if (name[0]) std::snprintf (status, sizeof (status), "%d   %s", slot + 1, name);
    else         std::snprintf (status, sizeof (status), "PRESET %d %s", slot + 1, verb);
    [self setNeedsDisplay: YES];
}

- (void) dropRetired
{
    if (! retiredField) return;
    [retiredField setDelegate: nil];
    [retiredField setTarget: nil];
    [retiredField removeFromSuperview];
    [retiredField release];
    retiredField = nil;
    if (! nameField && [self window]) [[self window] makeFirstResponder: self];
    [self setNeedsDisplay: YES];
}

- (void) startNaming: (int) slot
{
    if (! host || slot < 0) return;
    if (nameField) [self finishNaming: YES];
    namingSlot = slot;
    char name[kMaxPresetName + 8] = { 0 };
    host->presetName (slot, name, (int) sizeof (name));

    nameField = [[NSTextField alloc] initWithFrame: faceToView (NSInsetRect (kReadoutRect, 6.0, 8.0))];
    [nameField setBezeled: NO];
    [nameField setBordered: NO];
    [nameField setDrawsBackground: YES];
    [nameField setBackgroundColor: rgb (226, 204, 160)];
    [nameField setTextColor: [NSColor blackColor]];
    [nameField setFont: boldFont (14.0)];
    [nameField setAlignment: NSCenterTextAlignment];
    [nameField setFocusRingType: NSFocusRingTypeNone];
    [nameField setStringValue: [NSString stringWithUTF8String: name]];
    char hint[64];
    std::snprintf (hint, sizeof (hint), "NAME PRESET %d, THEN RETURN", slot + 1);
    [[nameField cell] setPlaceholderString: [NSString stringWithUTF8String: hint]];
    [[nameField cell] setScrollable: YES];
    [nameField setTarget: self];
    [nameField setAction: @selector (nameEntered:)];
    [nameField setDelegate: self];
    [self addSubview: nameField];
    status[0] = 0;
    readoutParam = -1;
    [[self window] makeFirstResponder: nameField];
    [self setNeedsDisplay: YES];
}

- (void) finishNaming: (BOOL) keep
{
    const int slot = namingSlot;
    if (slot < 0) return;
    namingSlot = -1;                       // only once (Return, then end of editing)
    if (keep && host && nameField)
    {
        const char* utf8 = [[nameField stringValue] UTF8String];
        host->renamePreset (slot, utf8 ? utf8 : "");
    }
    [self showPreset: slot verb: "SAVED"];
    // the field may be in the middle of sending its action: take it away afterwards
    [self dropRetired];
    retiredField = nameField;
    nameField = nil;
    [retiredField setDelegate: nil];
    [retiredField setTarget: nil];
    [self performSelector: @selector (dropRetired) withObject: nil afterDelay: 0.0];
}

- (void) nameEntered: (id) sender
{
    (void) sender;
    [self finishNaming: YES];
}

- (void) controlTextDidEndEditing: (NSNotification*) n
{
    (void) n;
    [self finishNaming: YES];
}

- (BOOL) control: (NSControl*) c textView: (NSTextView*) tv doCommandBySelector: (SEL) sel
{
    (void) c; (void) tv;
    if (sel == @selector (cancelOperation:)) { [self finishNaming: NO]; return YES; }
    return NO;
}

// SAVE button and preset slots. Returns YES if the click was handled here.
- (BOOL) presetClick: (NSPoint) p
{
    if (NSPointInRect (p, kSaveRect))
    {
        saveMode = ! saveMode;
        std::snprintf (status, sizeof (status), "%s", saveMode ? "SAVE: CLICK A SLOT" : "");
        [self setNeedsDisplay: YES];
        return YES;
    }
    for (int k = 0; k < kNumPresetSlots; ++k)
    {
        if (! NSPointInRect (p, slotRect (k))) continue;
        if (saveMode)
        {
            const bool ok = host->savePreset (k);
            saveMode = false;
            host->refreshPresets();
            for (int j = 0; j < kNumPresetSlots; ++j) presetUsed[j] = host->presetExists (j);
            if (ok)
            {
                activePreset = k;
                std::snprintf (status, sizeof (status), "PRESET %d SAVED", k + 1);
                [self setNeedsDisplay: YES];
                [self startNaming: k];
                return YES;
            }
            std::snprintf (status, sizeof (status), "COULD NOT SAVE PRESET %d", k + 1);
        }
        else
        {
            host->refreshPresets();
            for (int j = 0; j < kNumPresetSlots; ++j) presetUsed[j] = host->presetExists (j);
            if (presetUsed[k] && host->loadPreset (k))
            {
                for (int j = 0; j < kNumParams; ++j) shown[j] = host->getParam (j);
                activePreset = k;
                [self showPreset: k verb: "LOADED"];
            }
            else
                std::snprintf (status, sizeof (status), "PRESET %d IS EMPTY", k + 1);
        }
        [self setNeedsDisplay: YES];
        return YES;
    }
    return NO;
}

- (void) mouseDown: (NSEvent*) e
{
    const NSPoint p = viewToFace ([self convertPoint: [e locationInWindow] fromView: nil]);
    if (! host) return;
    if (nameField) [self finishNaming: YES];
    if (NSPointInRect (p, kReadoutRect) && activePreset >= 0)
    {
        [self startNaming: activePreset];
        return;
    }
    if (([e modifierFlags] & NSControlKeyMask) != 0) { [self showValuesAt: p]; return; }   // Control-click = right-click
    if ([self presetClick: p]) return;
    const int i = [self ctlAtPoint: p];
    if (i < 0) return;
    const Ctl& c = kCtls[i];
    shown[c.param] = host->getParam (c.param);   // the live value, even between timer ticks
    readoutParam = c.param;
    compare = false;
    status[0] = 0;
    activePreset = -1;     // settings are being changed away from the preset

    if (c.type == kCtlSlide3)
    {
        // click a position to move the lever there; a click on the lever steps it on
        int k = (int) std::floor ((p.x - c.cx) / kSlideHalf + 1.5);
        k = k < 0 ? 0 : (k > 2 ? 2 : k);
        if (k == inputIndex (shown[c.param])) k = (k + 1) % 3;
        host->guiBeginEdit (c.param);
        [self setParam: c.param value: inputValue (k)];
        host->guiEndEdit (c.param);
        return;
    }
    if (c.type == kCtlButton || c.type == kCtlBypass)
    {
        host->guiBeginEdit (c.param);
        [self setParam: c.param value: isOn (shown[c.param]) ? 0.0f : 1.0f];
        host->guiEndEdit (c.param);
        return;
    }

    host->guiBeginEdit (c.param);
    if ([e clickCount] == 2)
        [self setParam: c.param value: kDefaults[c.param]];   // double-click: back to default
    dragCtl = i;
    dragStartY = p.y;
    dragStartValue = shown[c.param];
    [self setNeedsDisplay: YES];
}

// Right-click: show the control's value, and the other channel's for the same
// control, in the readout. Nothing moves.
- (void) showValuesAt: (NSPoint) p
{
    if (! host) return;
    if (nameField) [self finishNaming: YES];
    const int i = [self ctlAtPoint: p];
    if (i < 0) return;
    const int param = kCtls[i].param;
    for (int j = 0; j < kNumParams; ++j) shown[j] = host->getParam (j);
    readoutParam = param;
    compare = false;
    status[0] = 0;
    [self setNeedsDisplay: YES];
}

- (void) rightMouseDown: (NSEvent*) e
{
    [self showValuesAt: viewToFace ([self convertPoint: [e locationInWindow] fromView: nil])];
}

- (void) mouseDragged: (NSEvent*) e
{
    if (dragCtl < 0 || ! host) return;
    const Ctl& c = kCtls[dragCtl];
    const NSPoint p = viewToFace ([self convertPoint: [e locationInWindow] fromView: nil]);
    const bool fine = ([e modifierFlags] & NSShiftKeyMask) != 0;
    // faders follow the hand; knobs take 200 px for the whole turn
    const CGFloat span = c.type == kCtlFader ? (kFaderBottom - kFaderTop) : 200.0;
    const CGFloat perPixel = (fine ? 0.2 : 1.0) / span;
    const CGFloat v = dragStartValue + (dragStartY - p.y) * perPixel;
    [self setParam: c.param value: (float) v];
}

- (void) mouseUp: (NSEvent*) e
{
    (void) e;
    if (dragCtl >= 0 && host) host->guiEndEdit (kCtls[dragCtl].param);
    dragCtl = -1;
}

- (void) scrollWheel: (NSEvent*) e
{
    const NSPoint p = viewToFace ([self convertPoint: [e locationInWindow] fromView: nil]);
    const int i = [self ctlAtPoint: p];
    if (i < 0 || ! host) return;
    const Ctl& c = kCtls[i];
    if (c.type == kCtlSlide3 || c.type == kCtlButton || c.type == kCtlBypass) return;
    const CGFloat d = [e deltaY];
    if (d == 0.0) return;
    status[0] = 0;
    activePreset = -1;
    host->guiBeginEdit (c.param);
    [self setParam: c.param value: (float) (shown[c.param] + d * 0.01)];
    host->guiEndEdit (c.param);
}

@end

//==============================================================================
namespace tbm50s
{

// Both calls use their own autorelease pool, so nothing of this plugin's is
// left waiting in the host's pool when the editor closes or the plugin unloads.
void* editorOpen (void* parentView, EditorHost* host)
{
    NSView* parent = (NSView*) parentView;
    if (! parent || ! host) return 0;
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    TBM50SingleChannelStripPanelView* v = [[TBM50SingleChannelStripPanelView alloc]
                                           initWithFrame: NSMakeRect (0, 0, kEditorWidth, kEditorHeight) host: host];
    if (v) [parent addSubview: v];
    [pool release];
    return (void*) v;    // retained until editorClose
}

void editorClose (void* handle)
{
    TBM50SingleChannelStripPanelView* v = (TBM50SingleChannelStripPanelView*) handle;
    if (! v) return;
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [v shutdown];
    [v removeFromSuperview];
    [v release];
    [pool release];
}

} // namespace tbm50s
