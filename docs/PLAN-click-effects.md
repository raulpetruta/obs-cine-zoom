# OBSCineZoom click effects (sound and ripple): implementation plan

Five facts about the existing code shape the plan:

- **Clicks come from counters.** Every backend's `buttons()` returns `left_down, counter`. macOS uses `CGEventSourceCounterForEventType` with a fallback to counting edges; Windows and X11 count edges. Today `main.lua` only reads the change in that counter (`delta("clicks", …)`) inside the zoom path, and only once the source is ready.
- **`camera_to_canvas` is too simple for a real layout.** It assumes the item's on-canvas rectangle is already known. No code yet computes that rectangle from a scene item's bounds and alignment.
- **The stub has the wrong bounds constant.** `OBS_BOUNDS_SCALE_INNER = 1`, but in real OBS it is 2 (1 is `STRETCH`). Fix the stub before adding any bounds math, and always use the constant names, never numbers.
- **The stub fails on unknown names.** Its `__index` throws for any API name it doesn't define, while real `obslua` returns nil. Optional constants and functions must be read through a pcall helper:
  `local function opt(name) local ok, v = pcall(function() return obs[name] end); return ok and v or nil end`
- **The test environment is strict about globals.** Read `script_path` with `rawget(_G, "script_path")`.

## Decisions

**Assets: generated at runtime, with user-chosen files as overrides.**
- Generate them in pure Lua when an effect is enabled.
- Write them to a per-user temp directory, trying in order: `$TMPDIR` (macOS), `$TEMP`, `$TMP`, `/tmp`, then `script_path()` as a last resort. Use the first one where `io.open(path,"wb")` succeeds.
- Why temp first: the files are disposable and rebuilt on every load. Writing next to the script would litter a folder that may be read-only, synced to the cloud, or a git checkout. Never write anywhere inside `OBS.app`.
- File names encode their parameters, so a settings change produces a new file:
  - `cinezoom-click-v1.wav`
  - `cinezoom-ring-v1-<tex>-<thick>-<rrggbb>.png`
- Rewrite a file if it is missing or its size is wrong. Run `os.remove` on our own generated files on unload, inside a pcall.
- Custom files (`fx_sound_file`, `fx_ripple_file`) win when they are non-empty and readable. Otherwise log a WARN and fall back to the generated file.

**Sound: private `ffmpeg_source`s, round-robin pool of 2, each attached to a free output channel.**
- Private sources are never saved. Output channels from 7 up are not saved by the frontend.
- Sources on an output channel are part of the audio mix, so the click reaches the recording and stream.
- A pool of 2 means a new click restarts the idle source rather than the one still tearing down its last playback.

**Ripple: one private overlay scene plus one scene item for it.**
- Create a private scene, "OBSCineZoom click effects", with `obs_scene_create_private`. It holds a pool of 4 ripple slots. Each slot is a private `image_source` with a private `color_filter_v2` for opacity.
- Add exactly one scene item of the overlay scene to the scene that contains the capture item, directly above the capture item.
- Set that item to pos (0,0), scale 1, top-left alignment, no bounds, and lock it.
- Why this layout:
  - The user's Sources dock gains one locked row instead of four.
  - Inside the overlay scene, coordinates are the same as the host scene's (both are canvas-sized).
  - If the item is ever saved, it points at a private source that won't exist after a restart, so OBS drops it and nothing is left in the user's collection.
- Don't register a Lua source type.
- There is no confirmed hidden-item API. Protect the items with private sources, a locked item, a distinctive name, and removal on unload, scene-collection change and exit.

## Files

1. **`src/cinezoom/assets/checksum.lua`**: `crc32(s, [crc])` and `adler32(s, [a])`.
   - CRC32 is table-driven with polynomial `0xEDB88320`, built on LuaJIT `require("bit")`.
   - Return unsigned values: `if v < 0 then v = v + 2^32 end`.

2. **`src/cinezoom/assets/png.lua`**
   - `encode(w, h, rgba)`, where `rgba` is a string of length `w*h*4` (straight alpha):
     - Signature `89 50 4E 47 0D 0A 1A 0A`.
     - IHDR: 13 bytes, holding w and h as u32 big-endian, bit depth 8, colour type 6, then compression, filter and interlace all 0.
     - IDAT holds a zlib stream: header `0x78 0x01`, then stored deflate blocks over the raw scanlines (each row prefixed with filter byte 0).
       - Split into blocks of at most 65535 bytes.
       - Each block is `BFINAL|BTYPE=00` (one byte; 1 only on the last block), then `LEN` and `NLEN = LEN ~ 0xFFFF` (both u16 little-endian), then the data.
       - The stream ends with Adler-32 of the raw data, big-endian.
     - Then IEND.
     - Every chunk's CRC32 covers its type plus data, big-endian.
   - `ring_rgba(tex, thick, r, g, b)` builds the ring:
     - Centre `c = tex/2`, outer radius `R = tex/2 - 1`, inner radius `ri = R - thick`.
     - For each pixel centre at distance `d`: `a = clamp(R - d + 0.5, 0, 1) * clamp(d - ri + 0.5, 0, 1)`.
     - RGB is the chosen colour everywhere, including where alpha is 0.
     - `tex = 256`; `thick = max(1, round(thickness * 256 / size))`.

3. **`src/cinezoom/assets/wav.lua`**
   - `encode_pcm16(samples, rate)` writes mono 16-bit PCM:
     - `"RIFF"`, `36 + n*2`, `"WAVE"`
     - `"fmt "`, 16, format 1, channels 1, rate, byte rate `rate*2`, block align 2, bits 16
     - `"data"`, `n*2`, then the samples (little-endian)
   - `click_samples(rate)` synthesises the click:
     - Rate 48000; length `floor(rate * 0.040)` samples.
     - Envelope `env = (1 - exp(-t/0.0005)) * exp(-t/0.006)`.
     - Signal `env * (0.55*sin(2π·2400t) + 0.25*sin(2π·5200t) + 0.2*noise)`.
     - Noise is Park–Miller: `x = x*16807 % 2147483647`, seed 1 (exact in doubles, so deterministic).
     - Normalise the peak to 0.8, then convert to int16.

4. **`src/cinezoom/effects/ripple_anim.lua`** (pure)
   - `sample(age, duration, cfg)` returns `{scale, opacity, done}`.
   - `u = clamp(age/max(duration, 1e-3), 0, 1)`
   - `scale = s0 + (1 - s0) * (1 - (1-u)^3)` with `s0 = 0.25`
   - `opacity = max_op * (1 - smoothstep(0.3, 1, u))`
   - `done = age >= duration`

5. **`src/cinezoom/effects/pool.lua`** (pure)
   - `new(n)`
   - `acquire(now)` returns a free slot, or steals the oldest active one.
   - `release(slot)`
   - `each_active(fn)`

6. **`src/cinezoom/geometry.lua`**: add these and keep `camera_to_canvas` as it is.
   - `align_offset(align, w, h)`. The flags are `LEFT=1, RIGHT=2, TOP=4, BOTTOM=8`, and 0 means centre. The x offset is 0 for LEFT, `w` for RIGHT and `w/2` otherwise; y works the same way with TOP and BOTTOM.
   - `item_content_rect(info, src_w, src_h, B)` returns the scene-space rectangle `{x, y, w, h}` of the item's content, where `B` is the table of bounds constants:
     - `NONE`: size is `(src·scale)`; origin is `pos - align_offset(alignment, size)`.
     - Bounded types: box origin is `pos - align_offset(alignment, bounds)`. The content scale is:
       - `STRETCH`: `bx/sw` and `by/sh` separately
       - `SCALE_INNER`: `min`
       - `SCALE_OUTER`: `max`
       - `SCALE_TO_WIDTH`: `bx/sw`
       - `SCALE_TO_HEIGHT`: `by/sh`
       - `MAX_ONLY`: `min(1, inner)`

       The content sits inside the box at `align_offset(bounds_alignment, bounds - size)`.
     - Ignore rotation and flips; the caller warns about them.
   - `map_point(x, y, from_w, from_h, rect)` returns `(rect.x + x/from_w*rect.w, rect.y + y/from_h*rect.h)`.

7. **`src/cinezoom/effects/sound.lua`** (OBS)
   - `new()`, `configure(cfg_fx, asset_path)`, `play()`, `reattach()`, `destroy()`, `describe()`.
   - **Create** each source with `obs_source_create_private("ffmpeg_source", "OBSCineZoom click N", s)`, settings:
     - `local_file = path`, `is_local_file = true`, `looping = false`
     - `restart_on_activate = false`, `close_when_inactive = false`, `clear_on_media_end = true`, `hw_decode = false`
   - **Then call:**
     - `obs_source_set_audio_mixers(src, 0x3F)`
     - `obs_source_set_volume(src, (vol/100)^2)`
     - `obs_source_set_monitoring_type(src, monitor and OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT or OBS_MONITORING_TYPE_NONE)`
     - `obs_source_set_muted(src, true)`
   - **Pick channels:** scan from 63 down to 8 for a channel where `obs_get_output_source(ch) == nil`. Release any source it returns. Then `obs_set_output_source(ch, src)`.
   - **Why the sources start muted:** ffmpeg_source starts playing when it is created or activated, which would click at load. Keep each source muted until its first real `play()`.
   - **`play()`:** pick the next source round-robin, `obs_source_set_muted(src, false)`, then `obs_source_media_restart(src)`. If that function is nil, fall back to `obs_source_update(src, s)`.
   - **Changes:** a new file updates `local_file` through `obs_source_update`. Volume and monitoring apply directly.
   - **`reattach()`:** runs on `SCENE_COLLECTION_CHANGED`. If `obs_get_output_source(ch) ~= src`, set it again.
   - **`destroy()`:** `obs_set_output_source(ch, nil)`, then `obs_source_release(src)`.

8. **`src/cinezoom/effects/ripple.lua`** (OBS)
   - `new()`, `configure(cfg_fx, png_path, tex_w)`, `ensure_host(si)`, `detach_host()`, `spawn(cx, cy, now)`, `update(si, now, cam_w)`, `destroy()`, `describe()`.
   - **Overlay scene:** `obs_scene_create_private("OBSCineZoom click effects")`.
   - **Each of the 4 slots:**
     - `img = obs_source_create_private("image_source", "OBSCineZoom ripple N", {file = path, unload = false})`
     - `f = obs_source_create_private("color_filter_v2", "cz-ripple-opacity", {opacity = 0.0})`. If that returns nil, try `"color_filter"` with an int `opacity` from 0 to 100. If both fail, warn once and skip the fade.
     - `obs_source_filter_add(img, f)`
     - `it = obs_scene_add(overlay, img)`, then `obs_sceneitem_addref(it)` and `obs_sceneitem_set_visible(it, false)`.
   - **Host:**
     - `hs = obs_sceneitem_get_scene(si.item)`.
     - If `obs_scene_is_group(hs)`, the host is the scene containing `si.group_item`, and the anchor item is the group item.
     - `host_item = obs_scene_add(host, obs_scene_get_source(overlay))`, then addref.
     - Set it with `get_info2` and `set_info2`: pos 0, scale 1, `alignment = 5`, `bounds_type = OBS_BOUNDS_NONE`.
     - `obs_sceneitem_set_locked(host_item, true)`.
     - `obs_sceneitem_set_order_position(host_item, idx + 1)`, where `idx` is the anchor item's index in `obs_scene_enum_items(host)` (bottom = 0). Wrap this in pcall; on failure the overlay stays on top.
     - Before each spawn, check the host item still exists with `obs_scene_find_sceneitem_by_id(host, obs_sceneitem_get_id(host_item))`. If not, rebuild it.
   - **`spawn`:** acquire a slot and store the camera-space anchor and `t0`.
   - **`update`** runs every tick while any slot is active:
     1. `view = {x = si.written.l, y = si.written.t, w = si.written.w, h = si.written.h}`. This is the crop actually applied; check the actual field names in `sceneitem.lua` and adapt.
     2. `content = item_content_rect(info(si.item), view.w, view.h, B)`.
     3. `p = camera_to_canvas(ax, ay, view, content)`.
     4. If the capture item is in a group: `gc = item_content_rect(info(group_item), gw, gh, B)`, where `gw` and `gh` come from `obs_source_get_width` and `obs_source_get_height` of the group's source. Then `p = map_point(p, gw, gh, gc)` and `k = gc.w / gw`; otherwise `k = 1`.
     5. Diameter `D = size * k * (zoom_scale and cam_w/view.w or 1) * anim.scale`. Steps 1–3 run again every tick, so the ring follows the zoomed view.
     6. Set the slot item: `pos = p`, `alignment = 0` (centre), `scale = D/tex_w`. Set it visible only if `p` lies inside the content rectangle.
     7. Set `"opacity"` on the filter's data and call `obs_source_update(f, fs)`.
     8. When the animation is done, hide the item and release the slot.
   - If the capture or group item has `rot ~= 0`, warn once and turn off the ripple for that attach.
   - **`detach_host()`:** `obs_sceneitem_remove(host_item)`, then `obs_sceneitem_release`.
   - **`destroy()`:** `detach_host()`. Then for each slot: `obs_source_filter_remove`, release the filter, remove and release the slot item, release `img`. Finally `obs_scene_release(overlay)`.

9. **`src/cinezoom/effects/init.lua`**: controller `fx` that owns the asset directory, `sound` and `ripple`.
   - `configure(cfg.fx)` compares old and new settings and creates, rebuilds or destroys the parts that changed.
   - `on_click(n, inside, cam_pt, zoomed, si_ready, now)` plays at most one sound and spawns at most one ripple per tick.
   - It also exposes `tick`, `detach_host`, `on_collection_changing`, `on_collection_changed`, `destroy`, `test_click`, `describe`, and test hooks (e.g. an asset directory override).

10. **`src/cinezoom/obs/sceneitem.lua`** (small change that leaves zoom alone)
    - In the BFS, when enqueuing a group scene, remember its group item: `parent_item[group_scene] = item`.
    - When the target is found inside a group, store `self.group_item` (addref'd) and release it in `release()`.

11. **`main.lua`**
    - Rename the existing `tick` body to `zoom_tick` without changing it, except that it records `fx_proj = {mx, my, inside}`; reset that to nil at the start of each tick.
    - The new `tick` calls `zoom_tick`, then `pcall(fx_tick, seconds)`.
    - `fx_tick` computes `n = delta("fx_clicks", last_input.clicks)` (a separate counter key, so autozoom's counter is untouched) and applies the filters:
      - `fx_only_inside`: require `inside`.
      - `fx_only_zoomed`: check `zoomed` after the autozoom update, so a click that triggers an auto zoom-in still counts.
    - Then it calls `fx:on_click` and `fx:tick(si, clock)`.
    - After 3 consecutive `fx_tick` errors, turn effects off and log an ERROR.
    - Call `fx:detach_host()` at the start of `attach()` and in `on_transition_start`, before `si:release()`.
    - On `opt("OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING")` and `opt("OBS_FRONTEND_EVENT_EXIT")`, destroy the ripple (overlay and items).
    - On `SCENE_COLLECTION_CHANGED`, call `sound.reattach()`.
    - In unload, add `step("click effects", fx.destroy)` before the "scene item" step.
    - Pass `fx` to the Diagnose context.

12. **`settings.lua`**: add the keys below to defaults, `read` (into `cfg.fx`) and properties.
13. **`diagnose.lua`**: add a `== Click effects ==` section (see Diagnose additions below).
14. **`README.md` and `CHANGELOG.md`**: document the feature, then rebuild `cinezoom.lua`.

## Setting keys (all effects off by default)

| key | type and UI | default |
|---|---|---|
| `fx_sound_enabled` | checkable group "Click sound" | false |
| `fx_sound_volume` | int slider 0–100 | 50 |
| `fx_sound_monitor` | bool "Also play locally (monitor)" | false |
| `fx_sound_file` | `obs_properties_add_path(…, OBS_PATH_FILE, "Audio (*.wav *.mp3 *.ogg *.flac)", nil)` | "" |
| `fx_ripple_enabled` | checkable group "Click ripple" | false |
| `fx_ripple_color` | `obs_properties_add_color` (stored as 0xAABBGGRR: R is the low byte) | `0xFFFF8D4C` (#4C8DFF) |
| `fx_ripple_size` | int 20–400 (canvas px, diameter at zoom 1) | 72 |
| `fx_ripple_duration` | float 0.1–2.0 s | 0.5 |
| `fx_ripple_thickness` | int 1–40 px | 5 |
| `fx_ripple_opacity` | int slider 10–100 % | 85 |
| `fx_ripple_zoom_scale` | bool "Scale with zoom" | true |
| `fx_ripple_file` | path, images (`*.png *.webp *.gif *.jpg`); the colour setting is ignored for a custom image | "" |
| `fx_only_inside` | bool "Only clicks on the captured display" (group "Click effects") | true |
| `fx_only_zoomed` | bool "Only while zoomed in" | false |
| `fx_test_button` | button "Test click effects": plays the sound and spawns a ripple at the current mouse position | n/a |

- Use top-level groups only; it is not confirmed that OBS property groups can nest.
- Clicks outside the captured display never draw a ripple. They play the sound only when `fx_only_inside` is off.

## Diagnose additions

- Asset directory, plus each file's path, size and whether it is writable.
- Sound: whether the sources were created, their channels, `obs_source_media_get_state`, volume, muted state and monitoring type.
- Ripple:
  - Host scene name, and whether the capture item is in a group.
  - The overlay item's id and order index.
  - Which opacity filter is in use (v2, v1 or none).
  - The last click in camera space and on the canvas, with its view rect and content rect.
  - A cross-check: inside a pcall, build `obs.matrix4()`, call `obs_sceneitem_get_draw_transform(si.item, m)`, and log `m.t.x, m.t.y` and the content rect origin.
- A note that the monitoring device is set in Settings > Audio > Advanced.

## Tests

1. **`test_checksum`**
   - `crc32("123456789") == 0xCBF43926`
   - `crc32("") == 0`
   - `crc32("The quick brown fox jumps over the lazy dog") == 0x414FA339`
   - `adler32("Wikipedia") == 0x11E60398`
   - `adler32("") == 1`
   - Chunked results equal one-shot results.
2. **`test_png`**
   - Encode a 3×2 image and check: the signature; IHDR length 13 with the right w, h, 8, 6, 0, 0, 0; IHDR's CRC equals `crc32("IHDR"..data)`.
   - Parse the IDAT back: `(0x78*256 + 0x01) % 31 == 0`; the stored blocks reassemble the raw rows exactly; Adler-32 matches; the IEND CRC is `0xAE426082`.
   - A 256×256 image produces at least 5 blocks, every block has `LEN + NLEN == 0xFFFF`, and only the last block sets BFINAL.
   - Ring: alpha is 0 at the centre and in the corners, about 255 at radius `R - thick/2`, the image is symmetric, and RGB is constant.
3. **`test_wav`**
   - Every header field from the WAV spec in file 3.
   - `data` length equals `2 * floor(48000 * 0.04)`.
   - Peak is between 8000 and 32767; the first and last samples are small; two runs produce identical bytes.
4. **`test_ripple_anim`**: scale starts at `s0` and ends at 1 and only increases; opacity starts at max, ends at 0 and never increases; `done` is set when it should be; duration 0 doesn't produce NaN.
5. **`test_pool`**: acquire up to N; the next acquire steals the oldest; release works; iteration covers only active slots.
6. **`test_geometry` additions**
   - `item_content_rect` for:
     - SCALE_INNER with letterboxing (bounds_alignment centre and top-left)
     - NONE with centre alignment
     - STRETCH
     - SCALE_TO_WIDTH
   - A 2× zoom round trip: for a camera point inside the view, `camera_to_canvas` gives the hand-computed canvas point.
   - The same point at zoom 1 versus zoom 2 lands where expected.
7. **Smoke tests** (add to `test_smoke.lua`)
   - **Defaults:** with default settings, a click creates no private sources, sets no output channel and adds no scene item.
   - **Full run:**
     - Enable sound and ripple, with the asset directory overridden to a scratch path through `fx` test hooks.
     - Click once: one media restart, and an overlay item in the scene directly above the capture item, locked.
     - The ripple item's pos equals the hand-computed canvas point.
     - Zoom in with the hotkey, tick, and click again: the position is still correct.
     - Move the view while the ripple animates: its pos follows.
     - After the duration has passed, the ripple is hidden.
     - Fire `SCENE_CHANGED`: the overlay item is removed and later re-added.
     - Fire `SCENE_COLLECTION_CHANGING`: the overlay item is removed.
     - Unload. Then all of these hold:
       - Output channels are empty.
       - The user scene contains only the capture item.
       - Every private source has `refs == 0`.
       - `data_live` is back to baseline.
       - The capture source has no filters.
       - `leaks()` is empty.
       - No "Tick failed" lines were logged.
   - **`fx_only_inside`:** a click outside the display plays no sound.
   - **`fx_only_zoomed`:** clicks are suppressed until the view is zoomed in.
   - **Group case:** the capture item sits inside a group.
8. **Stub extensions**
   - Fix the bounds constants: `NONE` 0, `STRETCH` 1, `SCALE_INNER` 2, `SCALE_OUTER` 3, `SCALE_TO_WIDTH` 4, `SCALE_TO_HEIGHT` 5, `MAX_ONLY` 6.
   - `OBS_MONITORING_TYPE_NONE/MONITOR_ONLY/MONITOR_AND_OUTPUT` = 0/1/2, `OBS_PATH_FILE`, and the frontend events `SCENE_COLLECTION_CHANGING`, `SCENE_COLLECTION_CHANGED` and `EXIT`.
   - `obs_source_create_private` should return source-kind objects for non-filter ids and track them in `world.private`.
   - Scene functions: `obs_scene_create_private`, `obs_scene_release`, `obs_scene_add`, `obs_sceneitem_remove`, `obs_sceneitem_get_scene`, `obs_scene_is_group`, `obs_sceneitem_set_locked`, `obs_sceneitem_set_visible`, `obs_sceneitem_set_order_position`, `obs_sceneitem_get_id`, `obs_scene_find_sceneitem_by_id`.
   - Source functions: `obs_source_media_restart` (count calls), `obs_source_media_get_state`, `obs_source_set_volume`, `obs_source_set_muted`, `obs_source_set_monitoring_type`, `obs_source_set_audio_mixers`, `obs_source_get_width` for images.
   - `obs_set_output_source` and `obs_get_output_source` backed by `world.channels`.
   - Properties: `obs_properties_add_path`, `obs_properties_add_color`.
   - Relax the `obs_source_update` assertion so it accepts sources as well as filters.
   - Extend `leaks()` to cover channels, private-source refs and stray scene items.

## Order of work

1. Fix the stub constants and run the tests (they should stay green).
2. `checksum`, `png`, `wav` and their tests.
3. `ripple_anim`, `pool`, the geometry additions and their tests.
4. Extend the stub.
5. `effects/sound.lua`, then `effects/ripple.lua`, then `effects/init.lua`.
6. The `sceneitem.lua` group-item change.
7. Wire `main.lua` and `settings.lua`.
8. Diagnose.
9. Smoke tests.
10. Rebuild the bundle, then update README and CHANGELOG.

## Acceptance criteria

- All existing tests pass unchanged. With effects off, the zoom crop values are byte-identical to today's.
- With defaults, the script creates no sources or items at all.
- No globals leak. The bundle `--check` passes.
- Unload, scene-collection change and exit leave nothing behind in the user's scenes or on output channels.
- An error in the effects code never stops the zoom from ticking.
- Nothing is claimed as verified on a Mac until the user reports back.
- Out of scope: cursor replacement, other M2/M3 items, and any change to the zoom camera, autozoom or crop approach.

## Uncertain OBS APIs: verify on the Mac, guard with pcall

1. **`color_filter_v2` opacity:** believed to be a double from 0 to 1. Fall back to `color_filter` with an int from 0 to 100.
2. **Startup click from ffmpeg_source:** believed to auto-start on create or activate. Mute-until-first-play covers this either way.
3. **Mixer visibility:** private sources on output channels probably don't appear in the Audio Mixer, so our volume setting is the only control.
4. **`obs_scene_add` reference:** believed to return a borrowed item, which is why we addref.
5. **Constants that may be missing:** `OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING` and `EXIT`. Read them with `opt()`.
6. **Bindings that may be missing:** `obs.matrix4` and `obs_sceneitem_get_draw_transform`.
7. **Clearing on collection change:** whether OBS clears output channels when the scene collection changes. `reattach()` covers it either way.
8. **Color property format:** the 0xAABBGGRR byte order.

Wrap these in pcall:
- Every create, add, remove or release call into OBS in `effects/*`.
- `set_order_position`.
- `media_restart`.
- The Diagnose draw-transform check.
- File writes and `os.remove`.
- The whole `fx_tick`.

## Verify on Mac (OBS 33.0.0-beta, `screen_capture` in "Desktop")

1. Load the script with defaults. No new rows appear in the Sources dock and Diagnose shows effects off.
2. Turn on the sound. There is no click at load. Each left click is audible in a test recording, and through headphones only when "monitor" is on. The volume slider works.
3. Fast double-clicks give two clicks. The click lags the mouse by less than about 50 ms.
4. Turn on the ripple. One locked row appears in Sources, directly above the capture. The ring is centred on the cursor tip at zoom 1.
5. Zoomed in (hotkey and auto-zoom): the ring is centred on the click and stays there while the view pans. It is larger when "Scale with zoom" is on.
6. Try a capture with an existing bounding box with letterboxing, a crop filter, a nested scene and a group. The ring lands correctly each time.
7. Switch scenes and run a transition. Switch the scene collection, then switch back: no "not found" warnings, nothing stale left.
8. Reload the script and quit OBS. On the next start the scene collection is clean.
9. Diagnose shows the asset paths (under `$TMPDIR`), the channel numbers, "opacity filter: v2", and the draw-transform cross-check matching within 1 px.
10. Custom WAV and PNG files work. A bad path logs a WARN and falls back to the generated file.
