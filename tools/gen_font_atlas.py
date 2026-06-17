#!/usr/bin/env python3
"""Generate ZUIL's built-in font atlas: src/font_atlas.h and src/font_atlas.bin.

DEV-ONLY tool. It is NOT shipped and NOT on any build path (the gcc no-Zig hedge
and `zig build` consume only the committed src/font_atlas.{h,bin} it emits).
Because it never ships, it is free to depend on a real font + rasterizer -- here
Pillow (FreeType-backed ImageFont) over the DejaVu Sans Mono faces -- without
putting any font lib near the ZUIL runtime, which stays strictly bitmap-only.

What it bakes: four STYLE PAGES (regular / bold / italic / bold-italic) of the
printable-ASCII range U+0020..U+007E, each rendered from the matching DejaVu Sans
Mono face and thresholded to 1-bit (monochrome). The last cell of each page
(U+007F) is a drawn fallback box, also used for any non-ASCII / out-of-range byte.
DejaVu Sans Mono is permissively licensed and we commit only the rendered 1-bit
BITMAPS (typeface bitmap renderings, not the font program), which is clean for
ZUIL's Unlicense. Mono => fixed-width / uniform spacing, ZUIL's invariant.

Container format (one canonical little-endian byte layout, emitted twice -- as
raw bytes in .bin for the Zig impl's @embedFile, and as an identical C byte blob
in .h for the C impl's #include, so neither impl needs a build step):

    header (8 bytes):  'Z','F','0','1' | n_pages:u8 | reserved:u8 x3
    per page:          cell_w:u8 | cell_h:u8 | first:u16 | count:u16 |
                       depth:u8 (1=mono RLE-able, 32=RGBA raw) | enc:u8 (0=raw,1=RLE) |
                       data_len:u32 | data[data_len]

Pages are concatenated; positional index == style bits (page i = style i). The
header is forward-shaped: more pages, a richer codepoint directory (Unicode), and
depth=32 color pages (emoji, which bypass RLE) all slot in later.

Encodings (1-bit, depth=1):
  * raw  -- per glyph, cell_h rows of ceil(cell_w/8) bytes; bit b (LSB) within a
            byte = column (byte*8+b) from the LEFT; 1 = ink.
  * RLE  -- toggle run-length over the per-pixel bitstream (all glyphs, row-major,
            column 0..cell_w-1, no byte padding) starting from color 0 (off):
            a byte 0..254 ends a run (add it, toggle color); 255 adds 255 and
            CONTINUES the same color (next byte continues). Decoders mirror this.
The generator packs each page both ways and keeps the smaller (sets `enc`); at
this high-detail cell RLE wins on the sparse glyphs, but raw ships if it ever
doesn't. RLE is for the 1-bit case specifically -- color (emoji) would be raw.

Run from anywhere:  python3 tools/gen_font_atlas.py
"""
import os
import struct
from PIL import Image, ImageDraw, ImageFont

# --- knobs (dev-time only) --------------------------------------------------
# Quality strategy: bake the atlas OVERSAMPLED (the "native" cell) and let the
# runtime draw it DOWNSCALED with linear filtering. Minifying an oversampled
# 1-bit glyph averages on/off texels into gray edges -- i.e. antialiasing -- so
# storage stays 1-bit/RLE while the on-screen result is smooth. font_scale=1.0
# maps to the "em" (nominal) cell; native = em * OVERSAMPLE. OVERSAMPLE=3 gives
# clearly smoother edges than 1:1 1-bit; it's the main quality knob.
NOMINAL_PIXEL = 16          # em (design) size that font_scale=1.0 maps to
OVERSAMPLE = 3              # atlas baked at NOMINAL_PIXEL*OVERSAMPLE, shown downscaled
NATIVE_PIXEL = NOMINAL_PIXEL * OVERSAMPLE
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
# page index == style bits: 0=regular, 1=bold, 2=italic, 3=bold+italic
FACES = [
    "DejaVuSansMono.ttf",            # ZUIL_FONT_REGULAR (0)
    "DejaVuSansMono-Bold.ttf",       # ZUIL_FONT_BOLD    (1)
    "DejaVuSansMono-Oblique.ttf",    # ZUIL_FONT_ITALIC  (2)
    "DejaVuSansMono-BoldOblique.ttf",  # BOLD|ITALIC     (3)
]
FIRST = 0x20
COUNT = 96  # U+0020..U+007F (last cell is the fallback box)
MAGIC = b"ZF02"  # v2: per-page record now carries the em (nominal) cell too
DEPTH_MONO = 1


def render_page(face_path, nw, nh):
    """Return COUNT glyph bitmaps as lists of 0/1 ints (row-major, nw*nh) at NATIVE_PIXEL."""
    font = ImageFont.truetype(face_path, NATIVE_PIXEL)
    glyphs = []
    for i in range(COUNT):
        cp = FIRST + i
        img = Image.new("L", (nw, nh), 0)
        draw = ImageDraw.Draw(img)
        if cp == 0x7F:  # fallback box (outline scales with the native cell)
            draw.rectangle([OVERSAMPLE, OVERSAMPLE, nw - 1 - OVERSAMPLE, nh - 1 - OVERSAMPLE],
                           outline=255, width=OVERSAMPLE)
        else:
            # default anchor "la" puts the ascender line at y=0, left side at x=0
            draw.text((0, 0), chr(cp), font=font, fill=255)
        px = img.load()
        bits = [1 if px[x, y] >= 128 else 0 for y in range(nh) for x in range(nw)]
        glyphs.append(bits)
    return glyphs


def cell_metrics():
    """Em (nominal) cell from the regular face; native = em * OVERSAMPLE (mono => shared)."""
    font = ImageFont.truetype(os.path.join(FONT_DIR, FACES[0]), NOMINAL_PIXEL)
    ascent, descent = font.getmetrics()
    advance = font.getlength("M")  # mono: constant across glyphs
    # +2 px horizontal slack so the oblique faces' slant overhang isn't clipped.
    em_w = int(round(advance)) + 2
    em_h = ascent + descent
    native_w = em_w * OVERSAMPLE
    native_h = em_h * OVERSAMPLE
    assert native_w <= 255 and native_h <= 255, "native cell must fit u8 fields"
    return native_w, native_h, em_w, em_h


def pack_raw(glyphs, cell_w, cell_h):
    row_bytes = (cell_w + 7) // 8
    out = bytearray()
    for bits in glyphs:
        for row in range(cell_h):
            for byte in range(row_bytes):
                v = 0
                for b in range(8):
                    col = byte * 8 + b
                    if col < cell_w and bits[row * cell_w + col]:
                        v |= 1 << b
                out.append(v)
    return bytes(out)


def pack_rle(glyphs, cell_w, cell_h):
    stream = [bit for bits in glyphs for bit in bits]  # row-major, all glyphs
    out = bytearray()
    color, i, n = 0, 0, len(stream)
    while i < n:
        run = 0
        while i < n and stream[i] == color:
            run += 1
            i += 1
        while run >= 255:
            out.append(255)
            run -= 255
        out.append(run)
        color ^= 1
    return bytes(out)


def rle_decode(data, nbits):
    bits = bytearray(nbits)
    color, pos, i = 0, 0, 0
    while pos < nbits:
        run = 0
        while True:
            b = data[i]
            i += 1
            run += b
            if b != 255:
                break
        for k in range(run):
            bits[pos + k] = color
        pos += run
        color ^= 1
    return bits


def build_page_record(glyphs, nw, nh, em_w, em_h):
    nbits = COUNT * nw * nh
    raw = pack_raw(glyphs, nw, nh)
    rle = pack_rle(glyphs, nw, nh)
    # round-trip self-check on the RLE path
    flat = bytes(bit for bits in glyphs for bit in bits)
    assert bytes(rle_decode(rle, nbits)) == flat, "RLE round-trip mismatch"
    if len(rle) < len(raw):
        enc, data = 1, rle
    else:
        enc, data = 0, raw
    # per page: native cell_w,cell_h | em_w,em_h | first | count | depth | enc | data_len
    rec = struct.pack("<BBBBHHBBI", nw, nh, em_w, em_h, FIRST, COUNT, DEPTH_MONO, enc, len(data)) + data
    return rec, len(raw), len(rle), enc


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = os.path.join(root, "src")
    nw, nh, em_w, em_h = cell_metrics()

    blob = bytearray(MAGIC + bytes([len(FACES), 0, 0, 0]))
    print("native cell = %dx%d (%dx oversampled), em cell = %dx%d, %d pages (U+%04X..U+%04X)" %
          (nw, nh, OVERSAMPLE, em_w, em_h, len(FACES), FIRST, FIRST + COUNT - 1))
    for idx, face in enumerate(FACES):
        glyphs = render_page(os.path.join(FONT_DIR, face), nw, nh)
        rec, raw_len, rle_len, enc = build_page_record(glyphs, nw, nh, em_w, em_h)
        blob += rec
        print("  page %d %-28s raw=%5d  rle=%5d  -> %s" %
              (idx, face, raw_len, rle_len, "RLE" if enc else "raw"))

    blob = bytes(blob)
    with open(os.path.join(src, "font_atlas.bin"), "wb") as f:
        f.write(blob)

    out = []
    out.append("/* GENERATED by tools/gen_font_atlas.py - do not edit by hand.")
    out.append(" *")
    out.append(" * ZUIL font atlas: 4 style pages (regular/bold/italic/bold-italic) of the")
    out.append(" * printable-ASCII range, rendered 1-bit from the DejaVu Sans Mono faces by")
    out.append(" * the dev-only generator. Only the rendered bitmaps are committed (not the")
    out.append(" * font program), which is clean for ZUIL's Unlicense. The C impl #includes")
    out.append(" * this blob; the Zig impl @embedFile's the identical src/font_atlas.bin.")
    out.append(" * See tools/gen_font_atlas.py for the container + RLE format. */")
    out.append("#ifndef ZUIL_FONT_ATLAS_H")
    out.append("#define ZUIL_FONT_ATLAS_H")
    out.append("")
    out.append("#define ZUIL_FONT_ATLAS_BLOB_LEN %d" % len(blob))
    out.append("")
    out.append("static const unsigned char zuil_font_atlas_blob[ZUIL_FONT_ATLAS_BLOB_LEN] = {")
    for i in range(0, len(blob), 16):
        chunk = blob[i:i + 16]
        out.append("    " + ", ".join("0x%02x" % b for b in chunk) + ",")
    out.append("};")
    out.append("")
    out.append("#endif /* ZUIL_FONT_ATLAS_H */")
    with open(os.path.join(src, "font_atlas.h"), "w") as f:
        f.write("\n".join(out) + "\n")

    print("wrote src/font_atlas.bin (%d bytes) and src/font_atlas.h" % len(blob))


if __name__ == "__main__":
    main()
