# Plan: M3 Studio scene builder

## 0. Key finding: use a different design from both (a) and (b)

I recommend option (a) with one change: put the mask on a **nested frame scene**, not on the capture source. The script builds two real, saved scenes and never touches the user's "Desktop" scene:

```
"OBSCineZoom Studio"        (scene; the user switches to this one)
  [0] "OBSCineZoom Background"   color_source_v3 | image_source (gradient PNG or the user's image)
  [1] "OBSCineZoom Shadow"       image_source (generated soft-shadow PNG)
  [2] "OBSCineZoom Studio Frame" (nested scene), bounds NONE, uniform scale, positioned
"OBSCineZoom Studio Frame"  (scene, canvas-sized)
  - the capture source (the same source, a second item): pos 0,0, align 5, SCALE_INNER bounds = canvas, bounds_alignment 0
  - filter "OBSCineZoom Rounded Corners" (mask_filter_v2), a canvas-aspect mask PNG, stretch=true
```

Why this is better than (b), and better than putting the mask on the capture source:
- **Layout safety.** The Desktop scene and its items are never touched, so nothing can break the user's layout. Undo means deleting what the script created.
- **`sceneitem.lua`.** BFS goes Studio → Frame (nested) → capture item. The capture item already has SCALE_INNER bounds, so `setup()` does not convert it. `info_orig` is the script's own fixed transform, so restoring it on release is harmless. Padding, radius and shadow changes only touch the **frame item in the Studio scene**, never the capture item, so the baseline never goes stale and no re-attach is needed when sliders move. Re-attach only after Apply and Remove.
- **Crop and mask order.** The zoom crop stays the only extra filter on the capture source. The mask runs on the frame scene, after the capture's whole filter chain. Corner radius stays constant at any zoom, because the zoomed picture always fills the same content rect inside the frame scene. There is no fight over `OBS_ORDER_MOVE_BOTTOM`, and the Desktop scene never gets rounded corners.
- **Ripple.** `ripple.host_for` puts the overlay in the frame scene, the capture's own scene. `item_content_rect` with SCALE_INNER maps into frame-scene coordinates, and the frame item's transform carries that onto the canvas. No ripple code changes. Ripples get the corner mask, which is desirable. They render at frame scale (about 0.85), which is acceptable.
- **Persistence.** Everything is a real, saved source. "Applied" means `obs_get_source_by_name(STUDIO)` is a scene containing an item whose source is the frame scene. No flag is stored, so this works across collections and restarts.

**UX: a hybrid.**
- Buttons: **Apply studio look** (create or rebuild) and **Remove studio look**.
- While applied, changes to `studio_*` settings update live, debounced 0.3 s in `script_tick`, because PNG regeneration costs roughly 20–150 ms.
- At startup, only repair missing files. Do not overwrite transforms the user changed by hand.
- Items are locked as a hint that the script manages them; the user can unlock and edit them.

## 1. Files

New:
- `src/cinezoom/studio/layout.lua`: pure math.
- `src/cinezoom/assets/raster.lua`: `gradient_rgba`, `rounded_mask_rgba`, `shadow_rgba`. Pure; it uses `png.encode`.
- `src/cinezoom/studio/init.lua`: the controller.
- `tests/test_studio_layout.lua`, `tests/test_raster.lua`, `tests/test_studio_smoke.lua`.

Edited:
- `settings.lua`, `main.lua`, `diagnose.lua`, `tests/stub_obslua.lua`, `tests/run.lua` (if tests are listed there).
- `README.md` (new Studio section; drop the roadmap line), `CHANGELOG.md`, `docs/PLAN.md` (M3 status).
- Rebuild `cinezoom.lua`. If `tools/bundle.lua` uses a module list rather than a glob, add the new modules to it.

## 2. Layout math: `studio/layout.lua` (all values in canvas pixels, fractional)

- `fit(sw, sh, bw, bh) -> w, h`: scale inner, `s = min(bw/sw, bh/sh)`.
- `frame_content(cw, ch, sw, sh) -> {x,y,w,h}`: where the capture lands inside the canvas-sized frame scene. Fit, then centre. The source size is `si.cam_w/cam_h` (after the user's crop) when attached; otherwise the base size; otherwise the canvas size (mark `pending_resize`). Check the actual field names in `sceneitem.lua`.
- `target_rect(cw, ch, sw, sh, pad_pct) -> {x,y,w,h}`: `pad = pad_pct/100 · min(cw,ch)`, the available area is the canvas minus `2·pad` on each axis, fit, then centre.
- `frame_transform(content, target) -> {scale, pos_x, pos_y}`: `scale = target.w/content.w`, `pos = target.xy − content.xy·scale`. This is for the frame item with alignment 5 (top-left) and bounds NONE.
- `shadow_rect(target, blur, off_x, off_y)`: the target grown by `blur` on every side, then offset.
- `mask_spec(cw, ch, content, scale, radius_px) -> {w, h, rect, r}`:
  - `ms = min(1, 960/max(cw,ch))`.
  - `w,h = round(cw·ms), round(ch·ms)`.
  - `rect = content·ms`.
  - `r = min(radius_px/scale·ms, rect.w/2, rect.h/2)`. The radius is given in output pixels; dividing by `scale` converts it to frame-scene pixels.
- `shadow_spec(target, blur, radius_px, q=0.25) -> {w, h, inner, r, box}`:
  - `w = ceil((target.w+2·blur)·q)`, and the same for `h`.
  - `inner = {blur·q, blur·q, target.w·q, target.h·q}`.
  - `r = radius_px·q`.
  - `box = max(1, round(blur·q/3))`.
- `canvas_point(frame_pt, tf)`: `tf.pos + pt·tf.scale`. Used by tests to check ripple placement.

## 3. Images: `assets/raster.lua`

All functions return an RGBA string with straight alpha.

- **`gradient_rgba(w, h, c1, c2, angle_deg)`**
  - Size: longest side 512, at canvas aspect.
  - Linear gradient: `d = (cos a, sin a)`, `t = (p·d − min)/(max − min)` over the four corners. Interpolate RGB and add ±0.5 ordered (Bayer 4×4) dither to hide banding.
  - Alpha 255.
  - The item uses STRETCH to canvas bounds.
- **`rounded_mask_rgba(w, h, rect, r)`**
  - Signed distance to the rounded rect: `q = |p−c| − (half−r)`, `d = len(max(q,0)) + min(max(qx,qy),0) − r`.
  - `a = clamp(0.5 − d, 0, 1)`.
  - Write **RGB = A = a·255**: white inside, black and transparent outside. This works whether the mask type reads alpha or colour.
- **`shadow_rgba(spec, opacity, rgb=0,0,0)`**
  - Fill a float array with the rounded-rect coverage.
  - Run 3 passes of a separable box blur (horizontal, then vertical) with radius `spec.box`, using running sums.
  - Write alpha `= v·opacity·255` and RGB = the colour.
- Use table.concat or a string buffer efficiently. These run in LuaJIT inside OBS, so avoid per-pixel string concatenation.

## 4. Asset storage (persistent)

`studio.asset_dir()` tries these in order, by writing a probe file:
1. `opt("os_get_config_path_ptr")("obs-studio/plugin_config")`. On a Mac this is `~/Library/Application Support/obs-studio/plugin_config`. Files use the prefix `obscinezoom-studio-`.
2. `script_path()` (via `rawget(_G, "script_path")`).
3. `$HOME` (or `%APPDATA%`).
4. `M.asset_dir` is a test hook that overrides everything.

Do **not** use `obs_module_config_path`.

Filenames are content-addressed: `obscinezoom-studio-{gradient|mask|shadow}-v1-<crc32 of params, hex>.png`. Use `checksum.crc32` over a `string.format` of the parameters.

If a file is missing because the user deleted it or moved machines:
- `Studio:repair(cfg, si)` runs on `FINISHED_LOADING`, `SCENE_COLLECTION_CHANGED`, and in `script_load` when OBS is already loaded. It regenerates any missing file at the same path and re-points the sources.
- When live sync stops using a generated file, delete it. Remove deletes all of them. Never delete the user's image.

## 5. Controller: `studio/init.lua`

Constants: `SCENE = "OBSCineZoom Studio"`, `FRAME = "OBSCineZoom Studio Frame"`, `BG = "OBSCineZoom Background"`, `SHADOW = "OBSCineZoom Shadow"`, `MASK = "OBSCineZoom Rounded Corners"`.

- **`M.new()`**: holds `{last_cfg, dirty_at, assets, prev_scene_name, warned}`. Holds no OBS references between calls; it looks sources up by name every time, then releases them.
- **`Studio:is_applied()`**
- **`Studio:apply(cfg, ctx)`**, where `ctx = {si, fx, attach, canvas()}`:
  1. Check that `cfg.source` exists. Read the canvas from `obs_video_info`/`obs_get_video_info`.
  2. If a name exists with the wrong kind (for example `SCENE` is not a scene), abort with `log.warn`.
  3. `fx:detach_host()`, then `si:release()`. Remember the name of the current scene as `prev_scene_name`, unless it is the Studio scene.
  4. Frame scene: reuse it, or create it with `obs_scene_create(FRAME)`.
     - Capture item: `obs_scene_find_source(frame, cfg.source)`, or `obs_scene_add`.
     - Set its transform with `obs_sceneitem_set_info2` (fallback `set_info`): pos 0,0, `alignment=5`, `rot=0`, `scale=1`, `bounds_type=OBS_BOUNDS_SCALE_INNER`, `bounds=(cw,ch)`, `bounds_alignment=0`.
     - Zero crop with `obs_sceneitem_set_crop`. Call `obs_sceneitem_set_locked(item, true)`.
  5. Mask filter on the frame scene's source: `obs_source_get_filter_by_name(frame_src, MASK)`, or `obs_source_create_private("mask_filter_v2", MASK, s)` (fallback `"mask_filter"`), then `obs_source_filter_add`. Settings:
     - `type` = `"mask_alpha_filter.effect"` (verify).
     - `image_path` = the mask path.
     - `stretch` = true.
     - `color` = 0xFFFFFFFF (int).
     - `opacity`: v2 = `obs_data_set_double(...,1.0)`, v1 = `set_int(...,100)`.
     - If radius is 0, call `obs_source_set_enabled(mask, false)`.
  6. Studio scene: reuse it, or `obs_scene_create(SCENE)`.
     - Background: create by id (`color_source_v3` → `color_source`, with keys `color`, `width`, `height`; or `image_source` with `file` and `unload=false`) via **`obs_source_create`** (public, saved), then `obs_scene_add`, then `obs_source_release`.
     - Shadow: `image_source` the same way.
     - Frame item: `obs_scene_add(studio, frame_source)`.
     - Order: `obs_sceneitem_set_order_position` to 0, 1 and 2, so that items the user added stay above. Lock all three.
  7. `sync_layout(cfg)`.
  8. Release the creation references: `obs_scene_release` on both scenes (the frontend holds its own reference). Release every `obs_get_source_by_name` result.
  9. `obs_frontend_set_current_scene(studio_src)`, then `ctx.attach()`. The event may not fire if the scene was already current.
- **`sync_layout(cfg, si)`**:
  - Compute `content`, `target`, `tf`, the shadow rect and the specs.
  - Frame item: bounds NONE, alignment 5, `scale=(tf.scale,tf.scale)`, `pos`.
  - Shadow item: `bounds_type=STRETCH`, `bounds=shadow_rect w/h`, `pos=shadow_rect xy`, and `obs_sceneitem_set_visible(shadow_on)`.
  - Background item: pos 0,0, `bounds=(cw,ch)`. Use SCALE_OUTER for an image and STRETCH for the gradient or a colour.
  - If the background type changed, the source id changes: remove the old background with `obs_source_remove` and create a new one.
  - Write the asset files and update the sources with `obs_source_update`.
- **`Studio:on_settings(cfg, now)`**: if the studio part of the config differs from `last_cfg` and `is_applied()`, set `dirty_at = now`. The first call after load only records the baseline. **`Studio:tick(now, si)`**: if dirty for more than 0.3 s, run `sync_layout` inside a pcall.
- **`Studio:on_source_resized(si)`**: called from `main` when the capture size changes while applied, or when `pending_resize` is set. It recomputes the content rect, the mask and the frame transform. The capture item is unchanged, so no re-attach.
- **`Studio:remove(ctx)`**:
  1. `fx:detach_host()`, `si:release()`.
  2. If the Studio scene is current, `obs_frontend_set_current_scene` to `prev_scene_name`. Otherwise use the first other scene from `obs_frontend_get_scenes` and release the list with `source_list_release`.
  3. Remove our items: background and shadow sources with `obs_source_remove`, and the frame item with `obs_sceneitem_remove`.
  4. If the Studio scene is now empty, call `obs_source_remove` on it. Otherwise keep it and log that items added by the user were kept.
  5. Frame scene: remove the mask filter (`obs_source_filter_remove`) and the capture item. If it is then empty, `obs_source_remove` it.
  6. Delete the generated files, then `ctx.attach()`.
- **Unload**: the studio stays by design.
- **`Studio:describe(si)`**: see §8.

## 6. Settings (`settings.lua`)

Add a group `grp_studio`, "Studio look", `OBS_GROUP_NORMAL`. Read the values into `cfg.studio`.

| key | type | default | UI |
|---|---|---|---|
| `studio_bg_type` | string | `"gradient"` | list: Gradient / Solid colour / Image |
| `studio_bg_color1` | int ABGR | `0xFFFC5D6D` (#6D5DFC) | color |
| `studio_bg_color2` | int ABGR | `0xFFDBC81F` (#1FC8DB) | color (gradient only) |
| `studio_bg_angle` | int | 135 | int slider, 0–360 |
| `studio_bg_image` | string | `""` | path (images filter) |
| `studio_padding` | double | 6 | float slider, 0–30 (% of the shorter canvas side) |
| `studio_radius` | int | 18 | int, 0–200 (output px) |
| `studio_shadow_enabled` | bool | true | bool |
| `studio_shadow_blur` | int | 40 | int, 0–200 px |
| `studio_shadow_offset` | int | 12 | int, −100 to 100 px (vertical) |
| `studio_shadow_opacity` | int | 45 | int slider, 0–100 % |

Buttons:
- `studio_apply_button`, "Apply studio look". Its long description says it creates the "OBSCineZoom Studio" scene and switches to it.
- `studio_remove_button`, "Remove studio look".

A modified callback on `studio_bg_type` shows or hides colour 2, angle and image. Nothing is created until Apply is pressed.

## 7. `main.lua` wiring

- Create `local studio = studio_mod.new()`.
- In `properties`, add `on_studio_apply` and `on_studio_remove`. Each runs inside a pcall, logs the result, and returns true.
- `script_update`: call `studio:on_settings(cfg.studio, clock)`.
- `tick`: call `studio:tick(clock, si)` inside a pcall. Also call `on_source_resized` when the capture size changes.
- Frontend events:
  - `FINISHED_LOADING` and `COLLECTION_CHANGED`: run `pcall(studio.repair, ...)`.
  - `COLLECTION_CHANGING`: clear the remembered `prev_scene_name`.
- Diagnose context: add `studio`.

## 8. Diagnose: "== Studio ==" section

- Whether it is applied, and the names found.
- The canvas size.
- The source size used and the content rect.
- The target rect, the frame scale and position, and the shadow rect.
- Each of our items: id, order index, locked, visible, transform.
- Background id. Show whether `color_source_v3` was used or fell back.
- The mask filter: id, enabled, and its settings JSON.
- The order of filters on the capture source.
- The asset directory and how it was chosen.
- For each image path: whether it exists, its size, and whether it is writable.
- Whether `os_get_config_path_ptr` is present.
- Whether the current scene is the Studio scene, and whether `si.item`'s scene is the frame scene.

## 9. Stub extensions (`tests/stub_obslua.lua`)

- **`obs_scene_create(name)`**: a public scene in `world.sources`. Its reference count is 2: one for the frontend, one returned.
- **`obs_source_create(id, name, settings)`**: public, starting at 1 reference. Return nil for ids in `world.unavailable_ids`.
- **`obs_source_remove(s)`**:
  - Remove every item that uses `s` from all scenes, releasing each item's reference.
  - Drop the frontend reference and mark the source `removed`.
- **Frontend scene functions**:
  - `obs_frontend_set_current_scene(src)`: set `world.current_scene` and fire `SCENE_CHANGED`.
  - `obs_frontend_get_scenes`: returns a list with references.
- **Source helpers**: `obs_source_set_enabled`/`obs_source_enabled`, `os_get_config_path_ptr` (absent by default; tests set it), and `obs_sceneitem_set_order_position`, which must actually reorder `scene.items`.
- **`world.leaks(opts)`**:
  - A public source must hold exactly 1 reference, or 0 if `removed`.
  - `opts.allow_filters` allowlists `"OBSCineZoom Rounded Corners"` on the frame scene.

## 10. Tests

**`test_studio_layout.lua`**
1. `frame_content`, 1920×1080 canvas with a 3024×1964 source: w≈1662.9, h=1080, x≈128.5.
2. A same-aspect source fills the canvas.
3. `target_rect` with pad 6%: the inset equals 64.8 on the limiting axis, and the result is centred.
4. `frame_transform` maps the content corners exactly onto the target corners.
5. `shadow_rect`: grown by blur, then offset.
6. `mask_spec`: the radius conversion, clamping, and radius 0.
7. Ripple composition: a camera-centre point, through `item_content_rect` (SCALE_INNER), then `canvas_point`, lands at the target centre. Repeat with zoom 2 and a `view_rect` near a corner.

**`test_raster.lua`**
8. Gradient: dimensions; angle 0 has the left column ≈ c1 and the right ≈ c2; angle 90 runs top to bottom.
9. Mask: dimensions; outside-corner alpha 0; centre 255; edge midpoint 255; RGB equals alpha everywhere.
10. Mask with r=0 has an opaque corner pixel.
11. Shadow: edges and corners alpha 0, centre ≈ opacity·255 (±1), monotonic non-increasing from the centre outward on both axes, and symmetric left to right.
12. `png.encode` output has the right IHDR width and height.

**`test_studio_smoke.lua`**, using the bundle and the stub:
13. Default state: no studio sources and no files.
14. Apply:
    - The Studio scene holds bg, shadow and frame at order 0, 1 and 2, locked.
    - The frame holds the capture with SCALE_INNER canvas bounds.
    - The mask filter is on the frame with the expected keys.
    - The files exist, the current scene is Studio, and `si.item.scene` is the frame scene.
15. Zoom in after Apply: the crop filter on the capture is written. The capture's filters are only the crop filter (plus the user's own).
16. Ripple: with the ripple on, a click places the overlay in the frame scene, and the slot position composed with the frame transform matches the expected canvas point.
17. Live update: change padding and tick 0.4 s.
    - The frame scale changes and the mask path changes.
    - The old file is deleted.
    - The capture item's transform and `si.info_orig` are unchanged.
18. Background type: switching to colour creates `color_source_v3`; with it unavailable, it falls back to `color_source`. Image mode uses the user's path and SCALE_OUTER.
19. Remove:
    - The scene switches back to Desktop.
    - Desktop items are deep-equal to their state before Apply.
    - All studio sources and items are removed, the files are deleted, and there are no leaks.
20. Remove with a user item in Studio: the scene is kept with that item only.
21. Unload while applied:
    - No leaks, apart from the allowlisted mask filter.
    - The studio scenes are still present.
    - No ripple overlay item is left in the frame scene, and the crop filter is gone.
22. Reload into the same world with the gradient file deleted: the studio is detected as applied and the file is regenerated at the same path.
23. Collection changing while applied: the ripple overlay is removed from the frame scene.
24. Apply with a source size of 0 (ScreenCaptureKit before its first frame): the size becomes known later and the layout is recomputed.

## 11. Order of work

1. `layout.lua` and its tests.
2. `raster.lua` and its tests.
3. Stub extensions.
4. The studio controller: apply, sync, remove, repair.
5. Settings and `main.lua` wiring.
6. Smoke tests.
7. Diagnose.
8. README, CHANGELOG and PLAN.
9. Run `luajit tools/bundle.lua`, `luajit tools/bundle.lua --check` and `luajit tests/run.lua`. All 93 existing tests plus the new ones must pass.

## 12. Acceptance criteria

- With Apply never pressed, behaviour and created objects are identical to today.
- Apply produces the inset look and switches to the Studio scene. The Desktop scene is untouched.
- Zoom, follow, auto-zoom and ripples stay correct in the Studio scene, and the corners stay rounded while zoomed.
- Slider changes show up within about 0.5 s with no tick errors.
- After an OBS restart the Studio scene looks the same. Missing PNGs are regenerated when the script loads.
- Remove deletes everything the script created, but keeps any items the user added.
- No changes to the camera, crop or zoom.

## 13. Out of scope

Motion blur, cursor replacement, obs-shaderfilter detection, native code, editor and timeline features, alignment options, and the "inset when zoomed out only" toggle.

## 14. Verify on the Mac (each wrapped in a pcall and logged)

1. `os_get_config_path_ptr` exists in obslua and returns the Application Support path. Writing into `plugin_config` works, including with the space in the path.
2. `mask_filter_v2`:
   - The `type` value `"mask_alpha_filter.effect"` gives rounded corners.
   - Opacity as a double 1.0 is accepted.
   - `stretch` works on a scene source.
   - A missing mask file shows unmasked rather than black.
3. A filter on a scene source renders correctly, and performance is fine at the canvas size.
4. A scene made by `obs_scene_create` and then `obs_scene_release` appears in the Scenes dock and survives a restart.
5. `obs_source_remove` on a scene removes it from the dock with no crash.
6. `obs_frontend_set_current_scene` from a button callback switches the scene (including in Studio Mode).
7. The `screen_capture` source in two scenes at once has no glitches.
8. The ripple is correct at the centre and at the corners, zoomed in and zoomed out.
9. Zoom in and then switch scenes: the frame item's layout is untouched, and the Desktop scene is unchanged.
10. `color_source_v3` is available.
11. Dragging sliders does not stutter.
12. A scene collection switch, and switching back, with the studio applied.
13. Transitions into and out of the Studio scene.
