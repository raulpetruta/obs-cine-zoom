# Changelog

## 0.2.0

### Added
- Studio look (off until you press **Apply studio look**): builds the saved scenes
  "OBSCineZoom Studio" and "OBSCineZoom Studio Frame" with a gradient, solid colour or image background,
  padding, rounded corners (`mask_filter_v2` on the frame scene) and a soft drop shadow, without touching
  your own scene. Settings update live, **Remove studio look** deletes what was created, and missing
  generated images are rebuilt at load. Diagnose has a Studio section. Confirmed on macOS (OBS 33 beta).

### Fixed
- Switching the background between Gradient and Solid colour could leave a second background item on
  top of the picture, hiding the screen. The background is now always one image source (a solid colour
  is a small generated image), and leftover copies are removed.

## 0.1.0


First OBSCineZoom release, a rewrite of obs-zoom-to-mouse 1.0.2 aimed at macOS with OBS 30 to 32.
**Not yet verified on a Mac**: see the checklist in the README.

### Fixed (compared with obs-zoom-to-mouse 1.0.2)
- macOS: the mouse Y coordinate is read from CoreGraphics (top-left origin, global), so it is correct
  on secondary displays and no longer depends on parsing a display name.
- macOS: ScreenCaptureKit (`screen_capture`) displays are matched by UUID (main display when empty);
  legacy `display_capture` by UUID or index. Window/application capture asks for a manual position.
- OBS version is parsed as integers (`30.10` is no longer `30.1`).
- Display-capture detection was inverted when "Allow any zoom source" was off.
- The user's crop is subtracted after scaling to source pixels (was wrong on Retina with a crop).
- A source that reports size 0 until its first frame is set up when the size arrives, and the display
  is looked up again when the size changes. The Retina scale no longer falls back to point sizes.
- Unload used `obs_hotkey_unregister(callback)`, which errors and aborted cleanup; it now passes the id,
  so the crop filter and transform are always restored.
- No leaked globals (the original defined every helper globally).
- Settings change check compared the override width/height to the monitor width/height.
- Off-by-one in the display list loop; missing nil check when listing zoom sources.
- Warnings and errors always print; only debug lines depend on the Debug checkbox.
- Animation no longer depends on the frame rate: critically damped springs on `script_tick`.
- Removed dead code (`access()` cdef, `on_update_transform`, `obs_sceneitem_release(nil)`).

### Added
- Motion presets (Slow, Mellow, Quick, Rapid, Custom), deadzone follow, auto-zoom on click or typing.
- Diagnose button with a live 5 second probe.
- Windows, X11 and null mouse backends behind one interface; every FFI load and lookup is guarded.
- Optional click effects, both off by default: a click sound (generated, or your own file) mixed into
  the recording and stream, and a click ripple that follows the zoomed view. Both are private OBS
  objects removed on scene change, scene collection change and unload. Diagnose has a Click effects
  section.
- Test suite (`luajit tests/run.lua`), single-file bundle (`tools/bundle.lua`), CI.
