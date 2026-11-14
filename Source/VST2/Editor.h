// Editor.h
// Plain C++ interface between the VST wrapper and the Cocoa editor
// (PanelView.mm), so the wrapper itself stays free of Objective-C.
// The editor only exists on the Mac; elsewhere the plugin reports no editor.

#ifndef TBM50S_EDITOR_H
#define TBM50S_EDITOR_H

namespace tbm50s
{

// A tall narrow strip: the face (kFaceWidth x kFaceHeight) inside a mahogany
// frame kPanelFrame wide
enum { kFaceWidth = 320, kFaceHeight = 980, kPanelFrame = 24,
       kEditorWidth = kFaceWidth + 2 * kPanelFrame, kEditorHeight = kFaceHeight + 2 * kPanelFrame };

// What the panel shows from the running console
enum Meter
{
    kMeterVu = 0,                   // the channel's VU, in VU (0 = nominal), -60 when silent
    kMeterOl,                       // OVERLOAD LED: 1 when lit
    kNumMeters
};

// What the editor needs from the plugin.
class EditorHost
{
public:
    virtual ~EditorHost() {}
    virtual float getParam (int index) const = 0;
    virtual void  getParamDisplay (int index, char* text8) const = 0;   // up to 8 chars + NUL
    virtual void  guiBeginEdit (int index) = 0;
    virtual void  guiSetParam (int index, float value) = 0;           // also notifies the host
    virtual void  guiEndEdit (int index) = 0;
    virtual float getMeter (int which) const = 0;

    // User presets (slots 0..kNumPresetSlots-1), stored in a file shared by every instance
    virtual void  refreshPresets() = 0;                 // re-read the file
    virtual bool  presetExists (int slot) const = 0;
    virtual bool  savePreset (int slot) = 0;            // current settings -> slot
    virtual bool  loadPreset (int slot) = 0;            // slot -> every parameter (host is told)
    virtual void  presetName (int slot, char* text, int size) const = 0;   // "" if none
    virtual bool  renamePreset (int slot, const char* name) = 0;           // saved to the file
};

#if defined(__APPLE__)
// parentView is the host's NSView*. Returns an opaque handle, or 0 on failure.
void* editorOpen (void* parentView, EditorHost* host);
void  editorClose (void* handle);
#endif

} // namespace tbm50s

#endif
