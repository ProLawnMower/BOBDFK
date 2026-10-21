# BOBDFK

**B**etter**O**ne**B**it**D**ithering**F**or**K**OReader

为 KOReader 打造的 Floyd–Steinberg 抖动插件——在 1-bit / 2-bit 墨水屏设备上大幅改善图片观感，**文字零损伤**。

专为那些"设备自带抖动算法很粗糙（均匀网点/有序抖动）、或干脆没有抖动"的电纸书设计。实测设备：EEGO P4（RK3326, Android 11, KOReader v2024.07）。

## 功能特性

| 特性 | 说明 |
|---|---|
| EPUB 插图抖动 | 自动检测插图矩形，只抖图、不碰文字（同一页内泾渭分明） |
| 图片文档全支持 | JPG / PNG / CBZ 漫画、图片查看器、书籍封面 |
| 位深自动适配 | 读取系统属性自动判断当前屏幕模式：1-bit 档输出黑白网点，2-bit 档输出四级灰 |
| 性能 | JIT 编译的 FFI 内循环，插图页全流程 ~60ms（含检测+抖动），纯文字页零开销 |
| 立即生效 | 菜单切换后当前页立刻重绘，无需翻页 |
| 可调 | 误差扩散强度（60–100%）、抖动深度（自动/强制1bit/强制4级灰）、各项独立开关 |

## 工作原理

### 1. 为什么需要它

多数电纸书的显示管线里，图片灰度靠**抖动算法**模拟。厂商固件通常内置的是有序抖动（ordered dithering / Bayer 矩阵）——规律性网点，观感粗糙。Floyd–Steinberg 误差扩散（error diffusion）产生的不规则细腻网点在视觉上明显更好，但固件不会给你换算法。

**解法**：在应用侧（KOReader）渲染管线内完成抖动——输出纯黑白（或精确四级灰）像素后，设备管线对这些像素是完全透传的（纯黑/纯白不参与任何再量化），你的算法效果得以像素级保真上屏。

### 2. 渲染管线挂点

KOReader 中图片内容经过以下路径，插件全部拦截：

```
图片查看器 / 封面 / GIF、WebP
  └─ RenderImage:renderImageData()          ← 挂点 1

PicDocument 路径的逐页绘制
  └─ pic.openDocument()                     ← 挂点 2（实例级 wrap page:draw）

JPG/PNG/CBZ 文档（多数版本实际由 MuPDF 引擎打开）
  └─ Document:renderPage()                  ← 挂点 3（页面瓦片，最终尺寸）

EPUB（crengine 引擎，文字+插图整页渲染）
  └─ CreDocument:drawCurrentView()          ← 挂点 4
```

挂点 3、4 为模块级 monkey-patch（`rawset` 防重复包裹）；挂点 2 在 `openDocument` 返回的文档实例上影子化 `draw` 方法。同一页面只会走一条路径，不会重复抖动。

### 3. EPUB 插图区域检测（只动图、不动字）

crengine 把整页（文字+插图）渲染进一个缓冲，不告诉你插图在哪。插件的方案：

1. **快速门控**：`drawCurrentPage()` 的返回值 `_drawn_images_count` 直接给出本页图片数——纯文字页（=0）**零开销跳过**
2. **窗口化密度检测**：16×16 像素窗口网格，每窗口抽样 8×8 点，统计"中间灰"（40–215 亮度）占比，≥25% 判定为图像区（文字 AA 边缘的灰度占比通常 <15%，天然区分）
3. **连通域合并**：4 邻接 BFS 合并相邻窗口为矩形，过滤小于 6 窗口（约 64×96px）的噪声，矩形外扩 8px
4. **只对矩形内跑 FS**，抖动完把缓冲重新 blit 到屏幕

实测：混排页中插图带 0.0% 中间灰（纯 FS 网点），同页文字带 AA 灰阶完整保留。

### 4. Floyd–Steinberg 误差扩散

移植自 X4 converter 项目的 dither-worker.js（Floyd–Steinberg Web Worker 实现）：

- 亮度：`0.299R + 0.587G + 0.114B`
- 量化后误差按 `7/16 右、3/16 左下、5/16 正下、1/16 右下` 扩散
- 强度参数（60–100%）等比缩放各扩散系数

### 5. 位深自动适配（2-bit 屏福利）

插件通过 `__system_property_get` 读取 `sys.eink.mode` 系统属性（EEGO/维韬系设备的显示档位属性：`4` = 2-bit 四级灰档，其余 = 1-bit 档）：

- **1-bit 档** → 量化到纯黑白（127.5 阈值），输出网点
- **2-bit 档** → XTH 四级量化（`>212→白, >127→浅灰(170), >42→深灰(85), 其余→黑`），误差在 4 级间扩散——渐变平滑无色带，且输出值与面板物理灰阶精确对齐，不经受设备端再量化损伤

非 EEGO 设备读不到该属性时默认 1-bit（也可菜单强制指定）。

### 6. 性能工程

在 RK3326（4×Cortex-A35）+ LuaJIT 上的实测：

| 优化项 | 前 → 后 |
|---|---|
| 允许 JIT 编译抖动内循环（纯 FFI 数组运算） | 1900ms → 56ms（单次抖动） |
| 检测抽样（每窗口 8×8 代替 16×16） | 690ms → ~10ms |
| 循环按裁剪边界迭代（无逐像素分支）、误差缓冲按矩形局部宽度分配 | — |
| 插图页全流程 | 2800ms → **~60ms** |

> KOReader Android 端为 LuaJIT 预留了 512KB mcode（官方 patch），本插件的循环量级完全在预算内，长时间连续翻页无压力。

### 7. 切换立即生效

菜单切换后：`UIManager:setDirty(view.dialog, "partial")` 触发整窗重绘（EPUB 的 cre 每次绘制都重新渲染，新设置即刻可见）；图片文档（MuPDF）的瓦片缓存则通过提升 `tile_cache_validity_ts` 时间戳强制失效重渲染。

## 安装

### 方式一：AI Agent + ADB（推荐，全自动）

> 本节为 AI Agent（Claude Code / Cursor / 其他编码代理）编写。设备通过 USB 连接并已授权 USB 调试后，直接执行以下命令即可完成安装、验证与卸载。

**前置检查**（确认设备在线且为 KOReader Android）：

```bash
adb devices                          # 应列出状态为 device 的阅读器
adb shell pm list packages | grep koreader   # 应输出 org.koreader.launcher
```

**安装**（在仓库根目录执行）：

```bash
# 1. 推送插件到 KOReader 用户插件目录
adb push fsdither.koplugin /sdcard/koreader/plugins/

# 2. （可选但推荐）清理渲染缓存，避免旧页面瓦片干扰首次验证
adb shell rm -rf /sdcard/koreader/cache/*

# 3. 重启 KOReader 使插件加载
adb shell am force-stop org.koreader.launcher
adb shell monkey -p org.koreader.launcher -c android.intent.category.LAUNCHER 1
```

**验证安装**（等待启动完成后执行）：

```bash
adb logcat -d | grep fsdither
# 预期输出四行 "patched ..." 日志：
#   fsdither: patched RenderImage.renderImageData
#   fsdither: patched Pic.openDocument
#   fsdither: patched Document.renderPage
#   fsdither: patched CreDocument.drawCurrentView
```

**验证功能**（可选，打开一本含插图的 EPUB 翻到插图页后）：

```bash
adb logcat -d | grep "fsdither cre"
# 预期: fsdither cre: 1 rect(s), detect XXms, dither XXms
```

**卸载**：

```bash
adb shell rm -rf /sdcard/koreader/plugins/fsdither.koplugin
adb shell am force-stop org.koreader.launcher
```

**故障排查**：

- `adb devices` 无设备 → 检查 USB 连接与调试授权
- logcat 无 `patched` 日志 → 确认推送路径正确（`/sdcard/koreader/plugins/`），且 KOReader 版本 ≥ 2024.03（挂点依赖的模块接口此前版本未验证）
- 菜单中找不到 → KOReader 工具菜单或设置菜单中查找「FS 抖动 / BOBDFK」

### 方式二：手动安装

1. 将 `fsdither.koplugin` 整个目录拷贝到设备的 `/sdcard/koreader/plugins/`（用 USB 文件传输、读卡器或任何文件同步方式）
2. 完全退出并重新打开 KOReader
3. 打开任意书籍 → 顶部菜单 → 设置 → 「BOBDFK (FS 抖动)」

### 可选：把菜单项置顶

KOReader 支持用户自定义菜单顺序。创建 `/sdcard/koreader/settings/reader_menu_order.lua`：

```lua
return {
    setting = {
        "fsdither",                    -- 插到设置区第一位
        "----------------------------",
        "frontlight", "night_mode",
        "----------------------------",
        "network", "screen",
        "----------------------------",
        "taps_and_gestures", "navigation", "document",
        "----------------------------",
        "language", "device",
        "----------------------------",
        "status_bar",
    },
}
```

（列表即顺序，不存在的项自动跳过；重启 KOReader 生效。）

## 使用说明

菜单路径：**书籍内顶部菜单 → 设置 → BOBDFK (FS 抖动)**

| 菜单项 | 说明 |
|---|---|
| 启用抖动 | 总开关（复选框即状态） |
| EPUB 插图抖动 | EPUB 插图检测+抖动开关 |
| 对 PDF 也抖动(扫描漫画) | 默认关；扫描版 PDF 全页抖动 |
| 抖动深度 | 自动（跟随屏幕模式）/ 强制黑白 / 强制四级灰 |
| 抖动强度 | 60–100%，误差扩散比例；网点偏粗可下调 |

所有切换即时生效（当前页直接重绘），设置持久化保存。

## 兼容性与限制

- **实测**：KOReader v2024.07（Android/armeabi-v7a）+ EEGO P4（RK3326, Android 11）
- **理论兼容**：其他版本的 Android KOReader（挂点均为 KOReader 公开模块接口）；Kobo/Kindle 等其他平台未测试，`blitbuffer` FFI 接口一致，大概率可用
- 位深"自动"档依赖 `sys.eink.mode` 属性（EEGO 系固件）；其他设备自动回退 1-bit，或手动强制
- 细线条、大留白的线描类插图可能低于检测密度阈值而漏检（可调源码 `DENSITY`）
- EPUB 插图依赖 crengine 的 `_drawn_images_count` 统计（v2024.03+ 特性）

## 调参指南（源码常量）

| 常量 | 默认 | 说明 |
|---|---|---|
| `WIN` | 16 | 检测窗口边长（像素） |
| `DENSITY` | 0.25 | 窗口中间灰占比阈值；漏检插图调低，误检文字调高 |
| `MIN_WINDOWS` | 6 | 连通域最小窗口数；小图标被忽略时调低 |
| `PAD` | 8 | 检测矩形外扩像素 |

## 开发背景

本插件的算法移植自 X4 converter 项目的前端抖动 worker（Floyd–Steinberg + XTH 四级量化）。开发过程中对 EEGO P4 的 Android 固件做了渲染管线逆向（SurfaceFlinger 的 EPD 转换层、`/dev/ebc-dev` 驱动接口、`sys.eink.*` 属性体系），确认了"应用侧纯黑白输出可像素级透传上屏"这一关键前提——这部分逆向结论同样适用于其他 RK + SPI 墨水屏方案的固件。

## License

MIT
