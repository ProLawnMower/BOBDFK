--[[--
Floyd-Steinberg dithering for KOReader (1-bit e-ink panels)

挂钩点:
  * RenderImage.renderImageData -> 图片查看器 / 封面 / GIF、WebP
  * Pic.openDocument            -> PicDocument 路径的逐页绘制
  * Document.renderPage         -> 最终兜底: 图像类文档(JPG/PNG/CBZ...)的
                                   页面瓦片(此版本中这些格式实际由 MuPDF
                                   引擎打开, 走的是这条路), 可选扩展到扫描 PDF

移植自 dither-worker.js (X4 converter): 亮度 0.299R+0.587G+0.114B,
误差扩散 7/16 3/16 5/16 1/16, 强度可调, 输出纯黑白。
抖动在 BlitBuffer 物理坐标系(data/stride)进行, 兼容任意旋转。
--]]--

local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local logger = require("logger")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local FSDither = WidgetContainer:extend{
    name = "fsdither",
    is_doc_only = false,
}

local enabled = true      -- 总开关
local strength = 100      -- 误差扩散强度 %
local dither_pdf = false  -- 对 PDF(mupdf) 页面也抖动(扫描版漫画适用)
local epub_images = true  -- EPUB 插图抖动(只抖检测到的插图区域, 文字不动)
local dither_depth = "auto"  -- "auto" 跟随屏幕模式 | "bw" 强制1bit | "gray4" 强制4级灰

-- 读取系统属性 sys.eink.mode (P4 显示档位: 4=2bit灰度档, 其余=1bit档)
local prop_ok, prop_fn = pcall(function()
    ffi.cdef([[ int __system_property_get(const char *name, char *value); ]])
    return ffi.C.__system_property_get
end)
local propbuf = ffi.new("char[92]")
local function getEinkMode()
    if not prop_ok then return nil end
    local ok, n = pcall(prop_fn, "sys.eink.mode", propbuf)
    if not ok or n <= 0 then return nil end
    return tonumber(ffi.string(propbuf))
end

-- 解析本次抖动深度: 1=黑白两级, 4=四级灰
local function resolveDepth()
    if dither_depth == "bw" then return 1 end
    if dither_depth == "gray4" then return 4 end
    local m = getEinkMode()
    if m == 4 then return 4 end
    return 1
end
local STRENGTH_CHOICES = { 60, 70, 80, 90, 100 }
local debug_logged = {}

local IMAGE_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, bmp = true,
    tif = true, tiff = true, j2k = true, jp2 = true, jxr = true,
    pam = true, pbm = true, pgm = true, pnm = true, ppm = true,
    hdp = true, webp = true, cbz = true,
}

local function isImageDoc(doc)
    if doc.is_pic then return true end
    local file = doc.file or ""
    local ext = file:lower():match("%.([%w]+)$")
    if ext and IMAGE_EXTS[ext] then return true end
    if dither_pdf and doc.provider == "mupdf" then return true end
    return false
end

-- Android 上 LuaJIT mcode 有限, 关掉 JIT 走解释器, 避免 mcode 耗尽
local function fsDither(bb, clip)
    if not bb or bb.w <= 0 or bb.h <= 0 then return end
    local btype = bb:getType()
    local bpp
    if btype == BB.TYPE_BB8 then
        bpp = 1
    elseif btype == BB.TYPE_BBRGB24 then
        bpp = 3
    elseif btype == BB.TYPE_BBRGB32 then
        bpp = 4
    else
        local why = "unsupported type " .. tostring(btype)
        if not debug_logged[why] then debug_logged[why] = true; logger.warn("fsdither skip:", why) end
        return
    end
    if bb:getInverse() ~= 0 then
        if not debug_logged.inverse then debug_logged.inverse = true; logger.warn("fsdither skip: inverse") end
        return
    end

    -- 逻辑尺寸 w/h; 旋转 90/270 时物理宽高互换
    local rotation = bb:getRotation()
    local w, h = tonumber(bb.w), tonumber(bb.h)
    local pw, ph
    if rotation == 1 or rotation == 3 then
        pw, ph = h, w
    else
        pw, ph = w, h
    end
    local stride = tonumber(bb.stride)
    if stride < pw * bpp then
        if not debug_logged.stride then debug_logged.stride = true; logger.warn("fsdither skip: stride", stride, "pw*bpp", pw * bpp) end
        return
    end
    if not debug_logged.ran then
        debug_logged.ran = true
        logger.info(string.format("fsdither run: %dx%d type=%d rot=%d bpp=%d stride=%d", pw, ph, btype, rotation, bpp, stride))
    end

    -- 可选裁剪区域(物理坐标) -> 直接决定迭代边界, 无逐像素分支
    local x0, y0, x1, y1 = 0, 0, pw - 1, ph - 1
    if clip then
        x0 = math.max(0, clip.x); y0 = math.max(0, clip.y)
        x1 = math.min(pw - 1, clip.x + clip.w - 1); y1 = math.min(ph - 1, clip.y + clip.h - 1)
        if x0 > x1 or y0 > y1 then return end
    end
    local rw = x1 - x0 + 1
    local depth = resolveDepth()
    local base = ffi.cast("uint8_t*", bb.data)
    local factor = strength / 100
    local e7 = factor * 7 / 16
    local e5 = factor * 5 / 16
    local e3 = factor * 3 / 16
    local e1 = factor * 1 / 16
    local err = ffi.new("float[?]", rw * (y1 - y0 + 2)) -- +1 行余量

    local rowoff = 0
    for y = y0, y1 do
        local below = y < y1
        local rowbase = base + y * stride
        local broff = rowoff + rw
        for x = x0, x1 do
            local p = rowbase + x * bpp
            local lx = x - x0
            local old
            if bpp == 1 then
                old = p[0] + err[rowoff + lx]
            else
                old = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] + err[rowoff + lx]
            end
            local v
            if depth == 4 then
                if old > 212 then v = 255
                elseif old > 127 then v = 170
                elseif old > 42 then v = 85
                else v = 0 end
            else
                if old >= 127.5 then v = 255 else v = 0 end
            end
            local e = old - v
            if lx < rw - 1 then err[rowoff + lx + 1] = err[rowoff + lx + 1] + e * e7 end
            if below then
                if lx > 0 then err[broff + lx - 1] = err[broff + lx - 1] + e * e3 end
                err[broff + lx] = err[broff + lx] + e * e5
                if lx < rw - 1 then err[broff + lx + 1] = err[broff + lx + 1] + e * e1 end
            end
            if bpp == 1 then
                p[0] = v
            else
                p[0] = v; p[1] = v; p[2] = v
            end
        end
        rowoff = rowoff + rw
    end
end
-- fsDither 允许 JIT: FFI 数组循环, LuaJIT 编译后 ~10-30x; mcode 预算 512KB 足够

local function maybeDither(bb)
    if enabled and bb then
        local t0 = os.clock()
        local ok, err = pcall(fsDither, bb)
        if not ok then logger.warn("fsdither failed:", err) end
        logger.info(string.format("fsdither: pass %.0fms (%dx%d)", (os.clock()-t0)*1000, tonumber(bb.w) or 0, tonumber(bb.h) or 0))
    end
end

-------------------------------------------------------------------
-- Hook 1: RenderImage.renderImageData (图片查看器/封面/GIF/WebP)
-------------------------------------------------------------------
local function patchRenderImage()
    local RenderImage = require("ui/renderimage")
    if rawget(RenderImage, "fsdither_wrapped") then return end
    rawset(RenderImage, "fsdither_wrapped", true)
    local orig = RenderImage.renderImageData
    RenderImage.renderImageData = function(self, data, size, want_frames, width, height)
        local res = orig(self, data, size, want_frames, width, height)
        if not enabled or res == nil then return res end
        if type(res) == "table" then
            for i = 1, #res do
                local fn = res[i]
                res[i] = function(...)
                    local bb = fn(...)
                    maybeDither(bb)
                    return bb
                end
            end
        else
            maybeDither(res)
        end
        return res
    end
    logger.info("fsdither: patched RenderImage.renderImageData")
end

-------------------------------------------------------------------
-- Hook 2: Pic.openDocument (PicDocument 路径)
-------------------------------------------------------------------
local function patchPic()
    local ok, pic = pcall(require, "ffi/pic")
    if not ok or not pic or rawget(pic, "fsdither_wrapped") then return end
    rawset(pic, "fsdither_wrapped", true)
    local orig_open = pic.openDocument
    pic.openDocument = function(filename)
        local doc = orig_open(filename)
        if type(doc) ~= "table" then return doc end
        local orig_open_page = doc.openPage
        if not orig_open_page then return doc end
        doc.openPage = function(self, ...)
            local page = orig_open_page(self, ...)
            if type(page) == "table" and page.draw then
                local orig_draw = page.draw
                page.draw = function(pself, dc, bb)
                    orig_draw(pself, dc, bb)
                    maybeDither(bb)
                end
            end
            return page
        end
        return doc
    end
    logger.info("fsdither: patched Pic.openDocument")
end

-------------------------------------------------------------------
-- Hook 3: Document.renderPage —— 本版本 JPG/PNG/CBZ 实际由 MuPDF
--         (PdfDocument) 打开, 走这条路径, 在页面瓦片上抖动
-------------------------------------------------------------------
local function patchRenderPage()
    local ok, Document = pcall(require, "document/document")
    if not ok or not Document or rawget(Document, "fsdither_wrapped") then return end
    rawset(Document, "fsdither_wrapped", true)
    local orig = Document.renderPage
    if not orig then return end
    Document.renderPage = function(self, ...)
        local tile = orig(self, ...)
        if tile and tile.bb and enabled and isImageDoc(self) then
            logger.info("fsdither: renderPage dither", self.file)
            maybeDither(tile.bb)
        end
        return tile
    end
    logger.info("fsdither: patched Document.renderPage")
end


-------------------------------------------------------------------
-- Hook 5(主力): onReaderReady 时直接在文档实例上影子化方法
--         实例字段遮蔽, 与模块表/加载顺序无关, 物理上不可绕过
-------------------------------------------------------------------
function FSDither:onReaderReady()
    -- 图像文档抖动已由模块级 Hook 3 单次完成, 实例级不再重复处理
end

-------------------------------------------------------------------
-- EPUB 插图: 窗口化灰度密度检测(8x8抽样) + 连通域合并
-- (物理坐标系, 与 fsDither 一致)
-------------------------------------------------------------------
local WIN = 16          -- 检测窗口边长(物理像素)
local DENSITY = 0.25    -- 窗口内中间灰(40~215)抽样占比阈值
local MIN_WINDOWS = 6   -- 连通域最少窗口数
local PAD = 8           -- 矩形外扩像素

local function detectImageRects(bb)
    local btype = bb:getType()
    local bpp
    if btype == BB.TYPE_BB8 then bpp = 1
    elseif btype == BB.TYPE_BBRGB24 then bpp = 3
    elseif btype == BB.TYPE_BBRGB32 then bpp = 4
    else return {} end
    local rotation = bb:getRotation()
    local w, h = tonumber(bb.w), tonumber(bb.h)
    local pw, ph
    if rotation == 1 or rotation == 3 then pw, ph = h, w else pw, ph = w, h end
    local stride = tonumber(bb.stride)
    local base = ffi.cast("uint8_t*", bb.data)

    local nw = math.floor(pw / WIN)
    local nh = math.floor(ph / WIN)
    if nw < 1 or nh < 1 then return {} end
    local need = 64 * DENSITY  -- 抽样 8x8=64 点/窗口
    local dense = {}
    for gy = 0, nh - 1 do
        local acc = {}
        for gx = 0, nw - 1 do acc[gx] = 0 end
        for y = gy * WIN, gy * WIN + WIN - 2, 2 do
            local rowbase = base + y * stride
            for gx = 0, nw - 1 do
                local cnt = acc[gx]
                local xend = gx * WIN + WIN - 2
                for x = gx * WIN, xend, 2 do
                    local p = rowbase + x * bpp
                    local v
                    if bpp == 1 then v = p[0]
                    else v = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] end
                    if v > 40 and v < 215 then cnt = cnt + 1 end
                end
                acc[gx] = cnt
            end
        end
        local row = {}
        for gx = 0, nw - 1 do
            if acc[gx] >= need then row[gx] = true end
        end
        dense[gy] = row
    end
    -- 连通域(BFS, 4邻接)
    local rects = {}
    local visited = {}
    for gy = 0, nh - 1 do
        local row = dense[gy]
        if row then
            for gx = 0, nw - 1 do
                if row[gx] and not visited[gy * nw + gx] then
                    local minx, maxx, miny, maxy, count = gx, gx, gy, gy, 0
                    local stack = { {gx, gy} }
                    visited[gy * nw + gx] = true
                    while #stack > 0 do
                        local cur = table.remove(stack)
                        local cx, cy = cur[1], cur[2]
                        count = count + 1
                        if cx < minx then minx = cx end
                        if cx > maxx then maxx = cx end
                        if cy < miny then miny = cy end
                        if cy > maxy then maxy = cy end
                        local nb = { {1,0},{-1,0},{0,1},{0,-1} }
                        for k = 1, 4 do
                            local nx, ny = cx + nb[k][1], cy + nb[k][2]
                            if nx >= 0 and nx < nw and ny >= 0 and ny < nh
                                and dense[ny] and dense[ny][nx] and not visited[ny * nw + nx] then
                                visited[ny * nw + nx] = true
                                table.insert(stack, { nx, ny })
                            end
                        end
                    end
                    if count >= MIN_WINDOWS then
                        local x0 = math.max(0, minx * WIN - PAD)
                        local y0 = math.max(0, miny * WIN - PAD)
                        local x1 = math.min(pw, (maxx + 1) * WIN + PAD)
                        local y1 = math.min(ph, (maxy + 1) * WIN + PAD)
                        table.insert(rects, { x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
                    end
                end
            end
        end
    end
    return rects
end
-- detectImageRects 允许 JIT: 像素扫描段可编译, BFS 段 NYI 自动回退

-------------------------------------------------------------------
-- Hook 6: CreDocument.drawCurrentView (EPUB 插图)
--   原始渲染完成后, 若本页有插图(_drawn_images_count>0),
--   检测插图矩形, 仅对这些区域 FS 抖动, 再重新 blit
-------------------------------------------------------------------
local function ditherCreBuffer(doc, target, x, y, rect)
    local bb = doc.buffer
    if not bb or not enabled or not epub_images then return end
    local cnt = doc._drawn_images_count
    if not cnt or cnt == 0 then return end -- 纯文字页零开销跳过
    local t0 = os.clock()
    local rects = detectImageRects(bb)
    local t1 = os.clock()
    if #rects == 0 then
        logger.info("fsdither cre: images drawn but no region detected")
        return
    end
    for i = 1, #rects do
        fsDither(bb, rects[i])
    end
    logger.info(string.format("fsdither cre: %d rect(s), detect %.0fms, dither %.0fms", #rects, (t1-t0)*1000, (os.clock()-t1)*1000))
    if target then
        target:blitFrom(bb, x, y, 0, 0, rect.w, rect.h)
    end
end

local function patchCreDocument()
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok or not CreDocument or rawget(CreDocument, "fsdither_wrapped") then return end
    rawset(CreDocument, "fsdither_wrapped", true)
    local orig = CreDocument.drawCurrentView
    if not orig then return end
    CreDocument.drawCurrentView = function(self, target, x, y, rect, ...)
        orig(self, target, x, y, rect, ...)
        local ok2, err = pcall(ditherCreBuffer, self, target, x, y, rect)
        if not ok2 then logger.warn("fsdither cre failed:", err) end
    end
    logger.info("fsdither: patched CreDocument.drawCurrentView")
end

-------------------------------------------------------------------
-- 设置与菜单
-------------------------------------------------------------------
local function readSettings()
    if G_reader_settings then
        local e = G_reader_settings:readSetting("fsdither_enabled")
        if e ~= nil then enabled = e end
        local s = G_reader_settings:readSetting("fsdither_strength")
        if s then strength = s end
        local p = G_reader_settings:readSetting("fsdither_pdf")
        if p ~= nil then dither_pdf = p end
        local ep = G_reader_settings:readSetting("fsdither_epub")
        if ep ~= nil then epub_images = ep end
        local dp = G_reader_settings:readSetting("fsdither_depth")
        if dp == "bw" or dp == "gray4" or dp == "auto" then dither_depth = dp end
    end
end

local function writeSettings()
    if G_reader_settings then
        G_reader_settings:saveSetting("fsdither_enabled", enabled)
        G_reader_settings:saveSetting("fsdither_strength", strength)
        G_reader_settings:saveSetting("fsdither_pdf", dither_pdf)
        G_reader_settings:saveSetting("fsdither_epub", epub_images)
        G_reader_settings:saveSetting("fsdither_depth", dither_depth)
    end
end

function FSDither:init()
    readSettings()
    patchRenderImage()
    pcall(patchPic)
    pcall(patchRenderPage)
    pcall(patchCreDocument)
    self.ui.menu:registerToMainMenu(self)
end


function FSDither:addToMainMenu(menu_items)
    local self = self
    -- 切换后立即对当前页生效:
    -- EPUB(cre) 每次绘制都重新渲染, setDirty 重绘即生效;
    -- 图片文档(mupdf) 的瓦片缓存在 DocCache, 提升时间戳使其失效强制重渲染
    local function applyAndRepaint()
        writeSettings()
        local ui = self.ui
        if ui and ui.document then
            -- 图片文档的 DocCache 瓦片按 created_ts 判新旧, 提升时间戳即全部失效
            ui.document.tile_cache_validity_ts = os.time()
        end
        -- setDirty 必须打在窗口栈里的 dialog 上(ReaderUI), 打在 view 子组件上无效
        local UIManager = require("ui/uimanager")
        if ui.view and ui.view.dialog then
            UIManager:setDirty(ui.view.dialog, "partial")
        else
            UIManager:setDirty("all", "partial")
        end
    end

    local depth_item = {
        text = _("抖动深度"),
        sub_item_table = {
            {
                text = _("自动(跟随屏幕模式)"),
                checked_func = function() return dither_depth == "auto" end,
                callback = function()
                    dither_depth = "auto"
                    applyAndRepaint()
                end,
            },
            {
                text = _("强制黑白(1bit网点)"),
                checked_func = function() return dither_depth == "bw" end,
                callback = function()
                    dither_depth = "bw"
                    applyAndRepaint()
                end,
            },
            {
                text = _("强制四级灰(2bit)"),
                checked_func = function() return dither_depth == "gray4" end,
                callback = function()
                    dither_depth = "gray4"
                    applyAndRepaint()
                end,
            },
        },
    }

    local strength_item = {
        text = _("抖动强度"),
        sub_item_table = {},
    }
    for _, sv in ipairs(STRENGTH_CHOICES) do
        table.insert(strength_item.sub_item_table, {
            text = tostring(sv) .. "%",
            checked_func = function() return strength == sv end,
            callback = function()
                strength = sv
                applyAndRepaint()
            end,
        })
    end

    menu_items.fsdither = {
        text = _("FS 抖动"),
        sorting_hint = "setting",
        sub_item_table = {
            {
                text = _("启用抖动"),
                checked_func = function() return enabled end,
                callback = function()
                    enabled = not enabled
                    applyAndRepaint()
                end,
            },
            {
                text = _("EPUB 插图抖动"),
                checked_func = function() return epub_images end,
                callback = function()
                    epub_images = not epub_images
                    applyAndRepaint()
                end,
            },
            {
                text = _("对 PDF 也抖动(扫描漫画)"),
                checked_func = function() return dither_pdf end,
                callback = function()
                    dither_pdf = not dither_pdf
                    applyAndRepaint()
                end,
            },
            depth_item,
            strength_item,
            {
                text = _("说明"),
                callback = function()
                    local InfoMessage = require("ui/widget/infomessage")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(InfoMessage:new{
                        text = _("对图片文档(JPG/PNG/CBZ)、图片查看器、封面、EPUB 插图做 Floyd-Steinberg 抖动, 文字不受影响。\n深度=自动时跟随屏幕显示档位(2bit档用四级灰, 1bit档用黑白网点)。"),
                    })
                end,
            },
        },
    }
end

return FSDither
