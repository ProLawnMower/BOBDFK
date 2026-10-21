local _ = require("gettext")
return {
    name = "fsdither",
    fullname = _("BOBDFK (FS 抖动)"),
    description = _([[Floyd-Steinberg dithering for images on 1-bit/2-bit e-ink panels.
Covers: EPUB illustrations (text untouched), image documents (JPG/PNG/CBZ),
image viewer, book covers. Auto depth: 1-bit halftone or 4-level grayscale.]]),
}
