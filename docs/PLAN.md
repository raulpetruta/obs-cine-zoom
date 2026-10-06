# OBSCineZoom — implementation plan

Plan for (1) fixing and modernizing the original `obs-zoom-to-mouse.lua` (forked from BlankSourceCode v1.0.2) so it works on macOS with OBS 30–32, and (2) growing it into an open-source, Screen Studio–style auto-zoom add-on for OBS.

## A. Defects in the original script (line numbers refer to the original `obs-zoom-to-mouse.lua`)

1. **macOS mouse Y (L183–189).** Y is only computed when `monitor_info` exists. Even then it is flipped against the *captured* display's height. Cocoa `NSEvent.mouseLocation` uses bottom-left-of-*main*-display coordinates, so Y is wrong on secondary monitors even when the display lookup works.
2. **Display-name parse (L346–360).** The ScreenCaptureKit (`screen_capture`) display list names don't contain `WxH @ x,y`. The parse fails, `monitor_info` is nil, and Y stays 0. When it does parse on macOS, the origin is in Cocoa bottom-left space and the size is in points.
3. **Version check (L85–88, L214).** It parses `"30.1.2"` into the float `30.1`, and `"30.10"` also parses as `30.1`. Legacy `display_capture` sources can't be selected on OBS 30+.
4. **`is_display_capture` is inverted (L405–412).**
5. **Crop offset subtracted before scaling (L787–797).** This is wrong on Retina whenever the user has a crop filter.
6. **Source size can be 0 at load (L612–618).** An SCK source reports width 0 until its first frame. The fallback uses the size in points, so on Retina the zoom covers half the area. Nothing refreshes when the real size arrives.
7. **`obs_hotkey_unregister(on_toggle_zoom)` (L1435).** Passing a function instead of an id errors and aborts unload, which leaves the crop filter and the modified transform behind.
8. **Leaked globals.** `x11_lib` and every helper function are globals.
9. **Change check in `script_update` (L1547–1548).** It compares `monitor_override_w ~= old_dw` and `_h ~= old_dh`.
10. **Off-by-one property list loop (L325).**
11. **No `dc_info` nil check in `populate_zoom_sources`.**
12. **Errors are hidden.** WARN and ERROR lines only print when debug logging is on.
13. **Animation depends on frame rate** and is not a real ease curve (L884–897, L944).
14. **Dead code.** The `access()` cdef, `on_update_transform`, and `obs_sceneitem_release(nil)`.
15. **The fork's partial Retina fix (L626–640)** only touches the scale.

## B. Decision: structured rewrite, single-file release

- Rewrite the platform, geometry, camera and settings code.
- Port the proven scene-item and crop-filter management (`refresh_sceneitem` with its nested-scene BFS, transform-crop to crop-filter conversion, bounding-box conversion, and `release_sceneitem`) almost unchanged.
- Develop modules under `src/`. `tools/bundle.lua` wraps each one as `package.preload["cinezoom.x"] = function(...) <src> end` and ends the bundle with `require("cinezoom.main").install(_G)`.
- Ship and commit the generated `cinezoom.lua`.
- Don't rely on runtime `require` of sibling files.

## C. Repo layout

```
cinezoom.lua                     # generated bundle (what users load)
src/cinezoom/main.lua            # script_* globals, hotkeys, tick loop, wiring
src/cinezoom/log.lua             # info/warn/error (warn+error ALWAYS print), debug gated
src/cinezoom/version.lua         # parse_version("31.0.0-rc1") -> {31,0,0}; at_least(v,a,b,c)
src/cinezoom/geometry.lua        # pure coordinate math + name parsing
src/cinezoom/spring.lua          # critically damped spring integrator
src/cinezoom/camera.lua          # center+zoom springs -> crop rect
src/cinezoom/deadzone.lua
src/cinezoom/autozoom.lua        # pure state machine (Phase 2)
src/cinezoom/platform/init.lua   # picks backend by ffi.os; test override
src/cinezoom/platform/macos.lua | windows.lua | x11.lua | null.lua
src/cinezoom/obs/sources.lua     # capture-source ids, display lookup
src/cinezoom/obs/sceneitem.lua   # ported refresh/release + crop filter writes
src/cinezoom/diagnose.lua
tools/bundle.lua
tests/run.lua, tests/stub_obslua.lua, tests/test_*.lua
.github/workflows/ci.yml
README.md, LICENSE, CHANGELOG.md
```

- Delete the old file; git history keeps it.
- Keep the optional `ljsocket` UDP remote-mouse feature.

## D. Platform backends

Every backend returns the same interface:

```lua
{ name, ok, reason,
  mouse() -> x, y | nil,        -- global "mouse units"
  displays() -> { {id,x,y,w,h,px_w,px_h,uuid,main} } | nil,
  buttons() -> left_down:boolean, click_count:int|nil,
  key_activity() -> counter:int|nil }
```

Rules for every backend:
- Prefix every struct and typedef with `cz_`.
- Wrap each `ffi.cdef` and each symbol lookup in `pcall`.
- Resolve symbols with `resolve(name)`: try `ffi.C[name]` first, then each loaded library.

**macOS.** `pcall(ffi.load, path)` these frameworks:
- `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics`
- `CoreFoundation`
- `ColorSync` (exports `CGDisplayCreateUUIDFromDisplayID`)
- `ApplicationServices`

Do NOT check that the files exist on disk; they live in the dyld shared cache.

```c
typedef struct cz_CGPoint { double x, y; } cz_CGPoint;
typedef struct cz_CGSize { double width, height; } cz_CGSize;
typedef struct cz_CGRect { cz_CGPoint origin; cz_CGSize size; } cz_CGRect;
void* CGEventCreate(void* source);
cz_CGPoint CGEventGetLocation(void* event);
void CFRelease(const void* cf);
int32_t CGGetActiveDisplayList(uint32_t max, uint32_t* ids, uint32_t* count);
uint32_t CGMainDisplayID(void);
cz_CGRect CGDisplayBounds(uint32_t d);
size_t CGDisplayPixelsWide(uint32_t d);  size_t CGDisplayPixelsHigh(uint32_t d);
void* CGDisplayCopyDisplayMode(uint32_t d);
size_t CGDisplayModeGetPixelWidth(void* m); size_t CGDisplayModeGetPixelHeight(void* m);
void CGDisplayModeRelease(void* m);
void* CGDisplayCreateUUIDFromDisplayID(uint32_t d);
void* CFUUIDCreateString(void* alloc, void* uuid);
unsigned char CFStringGetCString(void* s, char* buf, long size, uint32_t enc); /* UTF8 = 0x08000100 */
bool CGEventSourceButtonState(int32_t state, uint32_t button);           /* state 1=HIDSystem, button 0=left */
uint32_t CGEventSourceCounterForEventType(int32_t state, uint32_t type);  /* 1=LeftMouseDown, 10=KeyDown */
```

- **`mouse()`**: `CGEventCreate(nil)`, then `CGEventGetLocation`, then `CFRelease`. Coordinates are global, top-left origin, in points.
- **Fallback**: the old objc `NSEvent` path, flipping Y against the main display height.
- **`displays()`**:
  - Bounds from `CGDisplayBounds`.
  - Pixel size from the display mode (fall back to `CGDisplayPixelsWide`).
  - UUID via `CGDisplayCreateUUIDFromDisplayID` → `CFUUIDCreateString` → `CFStringGetCString`. Release both CF objects and upper-case the result.
- **Clicks and keys**: use the event counters, with a fallback to `ButtonState` edges. Keyboard counters may need the Input Monitoring permission, and Diagnose must report whether they change.

**Windows.** `GetCursorPos`, `GetAsyncKeyState`, `GetSystemMetrics`.
- Left button: swapped buttons when `SM_SWAPBUTTON` (23) is set, so check `vk = 0x02`, otherwise `0x01`. Test bit `0x8000`.
- Key activity: poll VK `0x08, 0x0D, 0x20, 0x30–0x39, 0x41–0x5A` and count down-edges.
- `displays()` returns nil; the name parse is the primary lookup on Windows.

**X11.**
- Use `XOpenDisplay`, `XDefaultRootWindow`, `XQueryPointer` (`root_x`/`root_y`), `XCloseDisplay` and `XQueryKeymap`.
- Left button: `mask & 256`. Key activity: the keymap changing.
- If running under Wayland, set `reason`. If `ffi.load` fails, return `ok=false`.

**null.** Every function returns nil.

## E. Coordinate pipeline (`geometry.lua`, pure)

1. `to_display_local(m, d)` = `m - d.origin`.
2. `to_source_px(p, d, src_w, src_h)` = `p * (src_w/d.w, src_h/d.h)`, using the base size before filters. If the size is 0, fall back to `d.px_w/d.w`.
3. `to_camera_space(p, user_crop)` = `p - user_crop.xy`.
4. `view_rect(center, z, cam_w, cam_h)` → `w = cam_w/z`, `h = cam_h/z`, `x = clamp(cx - w/2, 0, cam_w - w)`, and the same for `y`. Only the crop write floors values.
5. `camera_to_canvas(p, view, item)` (for later overlays).

Also in this module:
- `parse_display_name(s)` with patterns `(%d+)x(%d+)` and `@%s*(-?%d+)%s*,%s*(-?%d+)`.
- `cocoa_rect_to_cg(r, main_h)`: `y = main_h - (r.y + r.h)`.
- `uuid_eq(a, b)`, case-insensitive.

## F. Display lookup per source (`obs/sources.lua`)

**Capture source ids**
- macOS: `screen_capture` and `display_capture`.
- Windows: `monitor_capture`.
- Linux: `xshm_input`, plus `pipewire-desktop-capture-source` flagged "no mouse".

**`resolve_display(source)` order**
1. Manual override (`x, y, w, h` in mouse units, `scale_x/scale_y`, where 0 means auto).
2. macOS `screen_capture` with `type == 0`: match `display_uuid` against the CG displays; if it's empty, use the main display. Window/app capture: warn and require the override.
3. macOS `display_capture`: use `display_uuid` if present, otherwise index into the active list by `display`.
4. Name parse (loop `0..count-1`), with `cocoa_rect_to_cg` on macOS.
5. Nothing found: log a WARN (always visible) and disable follow.

**Re-resolve** on source change, scene change, the Refresh button, and whenever the tick loop sees the base size change.

## G. Camera, tick loop and Diagnose

**`spring.lua`**
- Semi-implicit Euler with substeps of at most 1/240 s.
- Damping `c = 2*zeta*sqrt(k)`.
- Clamp `dt` to 0.25 s.

**`camera.lua`**
- Springs on `cx`, `cy` and `log(z)`.
- API: `set_target`, `step`, `rect`, `is_settled`.
- Presets: Slow k=60, Mellow k=120, Quick k=220, Rapid k=400 (all zeta=1), plus Custom.

**`deadzone.lua`**
- When the mouse is more than `frac*half` from the target center on an axis, move the target so the mouse sits on the deadzone edge.
- Keep "follow outside bounds".

**`main.lua`**
- Use `script_tick(seconds)` for the loop.
- Hotkeys: `cinezoom.toggle_zoom`, `cinezoom.toggle_follow`, `cinezoom.toggle_auto`.
- Unload:
  - Unregister hotkeys by **id**, disconnect transitions, remove the frontend callback, release the scene item, close X11.
  - Keep the "skip on ≤29.1.2" crash guard.
  - Wrap each step in `pcall`.
- No globals other than `script_*`.

**Settings groups**: Source (+ Refresh), Zoom, Motion, Follow, Auto-zoom, Display override, Remote socket. Buttons: Diagnose and Help, plus a Debug checkbox.

**`diagnose.lua`** (always logs)
- Environment: versions, `ffi.os/arch`, `jit.version`.
- Backend: status, plus which symbols resolved.
- Source: id, settings JSON, base size, filters, scene-item transform, canvas size.
- Displays: all displays, plus which one matched, the method and the scale.
- Live: mouse in global, source and camera space, plus button state and the click/key counters.
- Then a 5 s live probe of 10 samples.

## H. Phase 2, milestone 1: auto-zoom (Lua)

`autozoom.lua` is a pure state machine: `new(cfg)` and `update(az, now, input) -> {zoom, focus|nil}`.

**States**: `Out`, `In`, `ManualIn`.

- **Click inside the captured area**: Out → In at the click position. While In, a click refocuses on the new position.
- **Held button (drag)**: counts as continuous activity.
- **Key activity**: keeps In alive. With "zoom on typing" on, it zooms in at the last click if that was within 10 s, otherwise at the mouse. (The text-caret position is unknown.)
- **Auto zoom-out**: after the idle timeout (default 2.5 s), once the minimum hold (0.8 s) has passed. Optional: zoom out when the mouse travels fast.
- **Hotkeys**: toggle_zoom moves to ManualIn or Out and overrides auto. toggle_auto enables or disables the machine.
- **Clicks outside the display**: ignored.

## I. Tests (luajit)

Run with `luajit tests/run.lua`.

- **geometry**: Retina, secondary displays, the order of crop and scaling, clamping, name parsing, `cocoa_rect_to_cg`, UUID matching.
- **version**: `30.2.3`, `31.0.0-rc1`, `32.0.1`, `29.1.2`.
- **spring**: convergence, no overshoot, FPS independence (30 fps vs 144 fps within 1 px), no NaN at `dt=0` or `dt=5`.
- **camera/deadzone**: zooming out returns exactly to the full rect; the deadzone holds the target.
- **autozoom**: scripted timelines.
- **cdefs**: each backend's cdef string parses; `sizeof(cz_CGRect) == 32`.
- **smoke**: build the bundle and run it with a stub `obslua` under a strict `_G`. Drive it through defaults → load → update → properties → Diagnose → 300 ticks → unload, with no errors.
- **CI**: syntax-check every file, run the tests, and check the committed bundle is up to date.

## J. Order of work

1. Scaffold the layout and tests.
2. `version` and `geometry`.
3. `spring`, `camera` and `deadzone`.
4. The platform backends.
5. `sceneitem` and `sources`.
6. `main` and `diagnose`.
7. `bundle` and the smoke test.
8. `autozoom`.
9. Docs and CI.

## K. Acceptance criteria

- The tests pass, the bundle is reproducible, and no globals leak.
- Every defect in section A is addressed.
- Diagnose is complete.
- The README has a macOS test checklist. Nothing is claimed as verified on a Mac until the user reports back.

## L. Later milestones (not in this pass)

- **M2, Lua overlays**: hide the system cursor in the capture settings and drive a script-owned cursor image with smoothing and scale; add a click ripple (an image source animated by scale and opacity).
- **M3, Studio scene builder**: a background gradient or wallpaper, a padded nested "OBSCineZoom Canvas" scene, rounded corners via `mask_filter_v2` or obs-shaderfilter, and a drop shadow. Possibly a sub-pixel transform camera.
- **M4**: a JSON sidecar logging mouse, click and zoom events per recording, as input for a future editor.
- **Native plugin**: motion blur, real cursor shapes, caret tracking via Accessibility, the Wayland pointer via PipeWire, and an openscreen-style post-recording editor.

**Not now**: M2–M4, native code, shaders, Wayland, Accessibility, network calls, changing the crop-filter camera approach, or claiming macOS testing.

## M. License and README

- **License**: MIT. Credit upstream BlankSourceCode/obs-zoom-to-mouse (MIT) and add `Copyright (c) 2026 Raul Petruta and OBSCineZoom contributors`.
- **README sections**:
  1. What it is
  2. Install
  3. Quick start
  4. Settings
  5. Hotkeys
  6. Platform notes
  7. Diagnose
  8. Roadmap
  9. Credits and license
