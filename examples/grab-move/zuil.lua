-- ZUIL Lua face (LuaJIT FFI) — a thin, love-shaped wrapper over the C ABI.
-- The only glue between a Lua UI script and libzuil; widgets stay user-space.
-- Run examples from the project root so the relative .so path resolves.
local ffi = require("ffi")

ffi.cdef([[
  int  zuil_sdl_version(void);

  int  zuil_window_open(const char *title, int w, int h);
  void zuil_window_close(void);
  int  zuil_frame_begin(void);
  void zuil_frame_end(void);

  void zuil_set_color(float r, float g, float b, float a);
  void zuil_clear(void);
  void zuil_fill_rect(float x, float y, float w, float h);
  void zuil_draw_rect(float x, float y, float w, float h);
  void zuil_draw_line(float x1, float y1, float x2, float y2);

  void  zuil_set_font_scale(float s);
  void  zuil_draw_text(float x, float y, const char *utf8);
  float zuil_text_width(const char *utf8);
  float zuil_text_height(void);
  float zuil_font_advance(void);

  int  zuil_mouse_x(void);
  int  zuil_mouse_y(void);
  int  zuil_mouse_down(int button);
  int  zuil_mouse_pressed(int button);
  int  zuil_mouse_released(int button);
  int  zuil_key_pressed(int scancode);
  int  zuil_should_quit(void);

  void zuil_clip_push(float x, float y, float w, float h);
  void zuil_clip_pop(void);
  void zuil_push(void);
  void zuil_pop(void);
  void zuil_translate(float dx, float dy);
]])

-- Resolve libzuil across build flows: the gcc hedge and Linux `zig build` emit
-- zig-out/lib/libzuil.so; Windows `zig build` emits a self-contained
-- zig-out/bin/zuil.dll. Try each so either build runs the demo (cwd = root).
local candidates = {
  "./zig-out/lib/libzuil.so",
  "./zig-out/bin/zuil.dll",
  "./zig-out/lib/libzuil.dylib",
}
local C
for _, path in ipairs(candidates) do
  local ok, lib = pcall(ffi.load, path)
  if ok then C = lib; break end
end
if not C then
  error("zuil: no library found — build it first (zig build, or the gcc hedge). Tried: "
        .. table.concat(candidates, ", "))
end

local zuil = {}

-- window / loop --------------------------------------------------------------
function zuil.open(title, w, h)
  if C.zuil_window_open(title, w, h) ~= 0 then
    error("zuil: could not open window")
  end
end
function zuil.close() C.zuil_window_close() end

-- run a love-style frame fn every frame until the window closes / Escape.
-- max_frames (optional) caps the loop for headless/automated smokes.
function zuil.run(frame, max_frames)
  local n = 0
  while C.zuil_frame_begin() ~= 0 do
    frame()
    C.zuil_frame_end()
    n = n + 1
    if max_frames and n >= max_frames then break end
  end
  C.zuil_window_close()
end

-- draw -----------------------------------------------------------------------
function zuil.color(r, g, b, a) C.zuil_set_color(r, g, b, a or 1) end
function zuil.clear() C.zuil_clear() end
function zuil.fill(x, y, w, h) C.zuil_fill_rect(x, y, w, h) end
function zuil.rect(x, y, w, h) C.zuil_draw_rect(x, y, w, h) end
function zuil.line(x1, y1, x2, y2) C.zuil_draw_line(x1, y1, x2, y2) end

-- text (built-in bitmap font; mechanism only — rich text is user-space runs)
function zuil.font_scale(s) C.zuil_set_font_scale(s) end
function zuil.text(s, x, y) C.zuil_draw_text(x, y, s) end
function zuil.text_width(s) return C.zuil_text_width(s) end
function zuil.text_height() return C.zuil_text_height() end
function zuil.font_advance() return C.zuil_font_advance() end

-- input ----------------------------------------------------------------------
function zuil.mouse_x() return C.zuil_mouse_x() end
function zuil.mouse_y() return C.zuil_mouse_y() end
function zuil.mouse() return C.zuil_mouse_x(), C.zuil_mouse_y() end
function zuil.down(button) return C.zuil_mouse_down(button or 1) ~= 0 end
function zuil.pressed(button) return C.zuil_mouse_pressed(button or 1) ~= 0 end
function zuil.released(button) return C.zuil_mouse_released(button or 1) ~= 0 end
function zuil.key(scancode) return C.zuil_key_pressed(scancode) ~= 0 end

-- clip + transform -----------------------------------------------------------
function zuil.clip(x, y, w, h) C.zuil_clip_push(x, y, w, h) end
function zuil.unclip() C.zuil_clip_pop() end
function zuil.push() C.zuil_push() end
function zuil.pop() C.zuil_pop() end
function zuil.translate(dx, dy) C.zuil_translate(dx, dy) end

return zuil
