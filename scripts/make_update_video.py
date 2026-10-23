#!/usr/bin/env python3
"""更新宣传短片：这一版的新东西逐个出场。白底，竖版 1080×1920 + 横版 1920×1080，60fps，无声。
片子里不出现版本号，只说「更新」。

用法：python3 scripts/make_update_video.py <原始截图目录> [输出目录] [--fps 60] [--only vertical|landscape]
原始截图目录与 make_screenshots.py 相同，另用 iphone/seq/ 下按操作顺序拍的模拟器截图（见 FLOWS：m1–m5 模型面板、
f1–f6 文件浏览，体验模式里一步步点过去用 xcrun simctl io <udid> screenshot 拍）。默认输出到 marketing/video/。

分镜（秒）：
  0.0–2.6   开场：Kimi 小 bot 弹出、眨眼，下面逐字打出「Moon Code 更新啦」（同 App 欢迎页的逐字出现），
            打完从两个下角喷彩条；bot 往上一跳出画面
  2.6–6.0   思考强度：大号分档滑杆。手指按住滑块，一档一档推到最右：
            轨道变紫、气泡往左飘、迸一圈星星（App 里拉到顶档的彩蛋）
  6.0–11.4  模型面板：手机滑入，手指一步步点：模型名 → 面板首页 → 模型列表 → 切到 K2.5 → 齿轮进模型配置
            （停在配置页）；标题下的说明跟着每一步换
  11.4–17.4 文件浏览：同样点过去：文件夹按钮 → 目录 → 进 src → 点 main.ts 预览 → ⋯ 菜单 → 添加到会话，
            文件卡片出现在输入框
  17.4–20.4 用量：三张卡片，进度条与百分比一起涨
  20.4–24.0 长按选字：一段正文，选区逐字拉开，弹出菜单「拷贝 | 添加到会话框 | 搜索网页」，
            点「添加到会话框」后选中的字飞进下方输入框
  24.0–26.8 接入引导：「Kimi Code 桌面端」「Kimi Code CLI」两张卡片，bot 在两张之间来回跳
  26.8–31.2 细节打磨：bot 当发射台，把胶囊一个个抛上去：转着圈飞到位、落地 Q 弹、迸星星、勾一笔画上，
            身后光环一圈圈扩散；全部落定后整排起浪，bot 蹦起来
  31.2–35.2 收尾：bot + 字标，「现已更新」，App Store 卡片「更新」→ 下载圈 → 「打开」，彩条
每段之间整屏横推（进来的从右边推入，出去的往左推出）。
"""
import math
import random
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_header import KIMI, sf  # noqa: E402
from make_rename_video import (  # noqa: E402
    CARD, CARD_BORDER, CONFETTI, FILL, GRAY, ICON, INK, PAPER, PF_MEDIUM, PF_REGULAR, PF_SEMIBOLD, SYSTEM_BLUE,
    clamp, ease_in_out, ease_out, ease_out_back, lerp, phase, squircle_icon, with_alpha,
)
from make_screenshots import PINGFANG, framed  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "KimiCode/Assets.xcassets"
# 拉到顶档的紫色渐变与星星，取自 ThinkingSlider.swift
PURPLE = [(79, 69, 230), (140, 92, 245), (168, 84, 247)]
STAR = (255, 199, 64)
TRACK = (229, 229, 234)
DURATION = 35.2

# 段落起止（秒）。每段进场 / 出场都是 0.5s 的整屏横推，与相邻段重叠
SEGMENTS = {
    "opening": (0.0, 2.6),
    "thinking": (2.6, 6.0),
    "models": (6.0, 11.4),
    "files": (11.4, 17.4),
    "usage": (17.4, 20.4),
    "select": (20.4, 24.0),
    "onboard": (24.0, 26.8),
    "polish": (26.8, 31.2),
    "finale": (30.8, DURATION),
}
PUSH = 0.5

# 手机里的操作演示：每步一张模拟器截图（seq/ 下）+ 这一步的说明 + 点哪（设备点坐标，440×956；None = 最后一屏不点）。
# 每步 STEP 秒：先停一会儿，手指按下 → 涟漪 → 淡入下一屏
FLOWS = {
    "models": [
        ("m1", "点输入框上的模型名", (330, 883)),
        ("m2", "当前模型、思考强度，一屏看全", (200, 720)),
        ("m3", "全部模型按来源分组", (110, 763)),
        ("m4", "点一下就切换，不用「完成」", (389, 615)),
        ("m5", "齿轮进模型配置：默认值、供应商一页管", None),
    ],
    "files": [
        ("f1", "点右上角的文件夹", (393, 84)),
        ("f2", "会话目录，一目了然", (120, 549)),
        ("f3", "一层层点进去", (120, 601)),
        ("f4", "点文件，直接预览", (390, 492)),
        ("f5", "下载，或添加到会话", (271, 535)),
        ("f6", "文件卡片进了输入框，发给 Kimi", None),
    ],
}
FLOW_START, STEP = 1.0, 0.8

TITLES = {
    "thinking": ("思考强度，一拉到顶", "大号分档滑杆，拖到哪档就是哪档"),
    "models": ("模型面板，焕然一新", None),
    "files": ("项目文件，随手翻看", None),
    "usage": ("用量，一目了然", "上下文、5 小时、每月限额都在这"),
    "select": ("长按，随心选字", "想选几个字就选几个字"),
    "onboard": ("桌面端、CLI 都能接入", "跟着引导动画，一步打开远程控制"),
    "polish": ("还有好多细节打磨", None),
}

POLISH = ["思考过程改版", "用户气泡更清爽", "启动小脸动画", "切换会话不闪", "滚动更跟手",
          "侧栏一点换设备", "骨架屏加载", "系统界面中文"]

# 两种画幅：标题区（中心 x、标题基线 y、对齐方式）、画面区（中心）、矢量元素缩放、手机宽度
LAYOUTS = {
    "vertical": dict(size=(1080, 1920), title=(0.5, 0.15), align="center", title_size=84, sub_size=40,
                     visual=(0.5, 0.53), u=1.0, phone_w=600, phone_top=0.255, zoom=1.32, phone_clip=0.205, opening_u=11),
    "landscape": dict(size=(1920, 1080), title=(0.07, 0.47), align="left", title_size=68, sub_size=34,
                      visual=(0.71, 0.5), u=0.78, phone_w=420, phone_top=None, zoom=1.2, phone_clip=None, opening_u=9),
}


def pf(size, index=PF_SEMIBOLD):
    return ImageFont.truetype(PINGFANG, max(1, round(size)), index=index)


def ss_layer(size, ss=3):
    """超采样画布：返回 (图层, 画笔)，画完用 down() 缩回去，边缘才不发毛。"""
    layer = Image.new("RGBA", (size[0] * ss, size[1] * ss), (0, 0, 0, 0))
    return layer, ImageDraw.Draw(layer)


def down(layer, size):
    return layer.resize(size, Image.LANCZOS)


def face(canvas, cx, cy, u, eye=1.0, squash=1.0):
    """Kimi bot 的脸（KimiFace 几何：24×16、圆角 2.3、眼 3×4.5、眼距 9、偏移 (2.7, -2.8)）。squash 压扁（落地用）。"""
    ss, pad = 3, 4
    hw, hh = 12 * u / squash ** 0.5, 8 * u * squash
    x0, y0 = math.floor(cx - hw) - pad, math.floor(cy + 8 * u - 2 * hh) - pad  # 压扁时底边不动
    lw, lh = math.ceil(2 * hw) + pad * 2 + 1, math.ceil(2 * hh) + pad * 2 + 1
    if lw <= 0 or lh <= 0:
        return
    layer, d = ss_layer((lw, lh), ss)
    top = cy + 8 * u - 2 * hh
    d.rounded_rectangle(((cx - hw - x0) * ss, (top - y0) * ss, (cx + hw - x0) * ss, (top + 2 * hh - y0) * ss),
                        2.3 * u * ss, fill=KIMI + (255,))
    mx, my = cx - x0, top + hh - y0
    for side in (-1, 1):
        ex, ey = mx + (2.7 + 4.5 * side) * u, my - 2.8 * u * squash
        ew, eh = 1.5 * u * min(eye, 1.2), 2.25 * u * eye * squash
        if ew > 0 and eh > 0:
            d.rectangle(((ex - ew) * ss, (ey - eh) * ss, (ex + ew) * ss, (ey + eh) * ss), fill=(255, 255, 255, 255))
    canvas.alpha_composite(down(layer, (lw, lh)), (x0, y0))


def blink_at(t, period=2.4, offset=0.0):
    cyc = ((t + offset) % period) / period
    return 0.15 if 0.9 < cyc < 0.96 else 1.0


def shadow_card(size, radius, fill=(255, 255, 255), blur=None):
    """白卡片 + 柔和投影（白底上用浅灰底卡片太素，加一圈影子更像 App 里的面板）。"""
    from PIL import ImageFilter
    w, h = size
    m = round(radius * 0.9)
    img = Image.new("RGBA", (w + m * 2, h + m * 2), (0, 0, 0, 0))
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((m, m + radius * 0.25, m + w, m + h + radius * 0.25), radius, fill=(20, 30, 60, 34))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur or radius * 0.5)))
    layer, d = ss_layer(img.size)
    d.rounded_rectangle((m * 3, m * 3, (m + w) * 3, (m + h) * 3), radius * 3, fill=fill + (255,))
    img.alpha_composite(down(layer, img.size))
    return img, m


def gradient(w, h, stops):
    """横向多段渐变。"""
    row = Image.new("RGB", (max(1, w), 1))
    n = len(stops) - 1
    for x in range(row.width):
        p = x / max(1, row.width - 1) * n
        i = min(n - 1, int(p))
        f = p - i
        row.putpixel((x, 0), tuple(round(lerp(a, b, f)) for a, b in zip(stops[i], stops[i + 1])))
    return row.resize((max(1, w), max(1, h)))


def wrap(text, font, width):
    """按字宽折行：中文逐字可断，连续的英文 / 路径（如 Sources/）不拆开。返回 [(行文本, 起始字符下标)]。"""
    tokens, i = [], 0
    while i < len(text):
        j = i + 1
        if text[i].isascii() and not text[i].isspace():
            while j < len(text) and text[j].isascii() and not text[j].isspace():
                j += 1
        tokens.append((text[i:j], i))
        i = j
    lines, cur, start = [], "", 0
    for tok, idx in tokens:
        if font.getlength(cur + tok) > width and cur.strip():
            lines.append((cur, start))
            cur, start = "", idx
            if tok == " ":
                start = idx + 1
                continue
        cur += tok
    lines.append((cur, start))
    return lines


class Confetti:
    """与 App 的 ConfettiBurst 同一套物理：两个下角往里斜上方喷，空气阻力 + 重力 + 左右摆。"""

    def __init__(self, w, h, seed, count=64):
        rng = random.Random(seed)
        self.w, self.h = w, h
        k = h / 874
        self.k = k
        self.items = []
        for i in range(count):
            side = i % 2
            angle = math.radians(rng.uniform(6, 42))
            speed = rng.uniform(2400, 3400) * k
            inward = 1 if side == 0 else -1
            self.items.append(dict(
                side=side, vx=inward * math.sin(angle) * speed, vy=-math.cos(angle) * speed,
                w=rng.uniform(9, 13) * k, h=rng.uniform(20, 30) * k, color=rng.choice(CONFETTI),
                spin=rng.uniform(-9, 9), rot=rng.uniform(0, 2 * math.pi), flip=rng.uniform(6, 14),
                wobble=rng.uniform(6, 16) * k, phase=rng.uniform(0, 2 * math.pi), delay=rng.uniform(0, 0.12),
            ))

    def draw(self, canvas, t, life=3.6):
        if t <= 0 or t >= life:
            return
        d = ImageDraw.Draw(canvas)
        kd, g = 3.0, 900 * self.k
        for P in self.items:
            tt = t - P["delay"]
            if tt <= 0:
                continue
            decay = (1 - math.exp(-kd * tt)) / kd
            x = P["side"] * self.w + P["vx"] * decay + math.sin(tt * 4 + P["phase"]) * P["wobble"] * min(tt, 1)
            y = self.h + P["vy"] * decay + g / kd * (tt - decay)
            fade = clamp((life - P["delay"] - tt) / 0.6)
            if fade <= 0:
                continue
            ang = P["rot"] + P["spin"] * tt
            sx = max(0.08, abs(math.cos(P["flip"] * tt + P["phase"])))
            hw, hh = P["w"] / 2 * sx, P["h"] / 2
            ca, sa = math.cos(ang), math.sin(ang)
            pts = [(x + px * ca - py * sa, y + px * sa + py * ca) for px, py in ((-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh))]
            col = tuple(round(255 - (255 - c) * fade) for c in P["color"])
            d.polygon(pts, fill=col)


def star(d, cx, cy, r, color, ss=1):
    pts = []
    for k in range(10):
        a = -math.pi / 2 + k * math.pi / 5
        rr = r if k % 2 == 0 else r * 0.45
        pts.append(((cx + rr * math.cos(a)) * ss, (cy + rr * math.sin(a)) * ss))
    d.polygon(pts, fill=color)


class Video:
    def __init__(self, spec, shots):
        self.spec = spec
        self.w, self.h = spec["size"]
        self.u = spec["u"]
        self.vx, self.vy = spec["visual"][0] * self.w, spec["visual"][1] * self.h
        u = self.u
        self.title_font = pf(spec["title_size"])
        self.sub_font = pf(spec["sub_size"], PF_REGULAR)
        self.body_font = pf(38 * u, PF_REGULAR)
        self.label_font = pf(34 * u, PF_MEDIUM)
        self.small_font = pf(28 * u, PF_REGULAR)
        self.confetti_open = Confetti(self.w, self.h, 3)
        self.confetti_end = Confetti(self.w, self.h, 11)

        # 手机：截图套边框（同 App Store 截图的边框）
        pw = spec["phone_w"]
        self.bezel = round(pw * 0.028)
        self.screen_scale = pw / 440  # 设备点 → 画布像素
        self.phones = {}
        for flow in FLOWS.values():
            for name, _, _ in flow:
                shot = shots[name]
                screen = shot.convert("RGB").resize((pw, round(shot.height * pw / shot.width)), Image.LANCZOS)
                self.phones[name] = framed(screen, pw, corner=168 * pw / shot.width, bezel=self.bezel)

        self.icons = {
            "desktop": squircle_icon(ASSETS / "KimiCodeDesktopIcon.imageset/KimiCodeDesktopIcon@3x.png", round(104 * u)),
            "cli": squircle_icon(ASSETS / "KimiCodeCLIIcon.imageset/KimiCodeCLIIcon@3x.png", round(104 * u)),
            "app": squircle_icon(ICON, round(144 * u)),
        }

        # 长按选字那段的正文：折好行，记下每个字的位置
        self.para = "这是一个用 SwiftUI 写的 iOS 客户端：Sources/ 是 App 主体代码，Tests/ 是单元测试。想深入哪一块，跟我说一声就行。"
        self.para_w = round(780 * u)
        self.para_lines = wrap(self.para, self.body_font, self.para_w)
        self.sel_from = self.para.index("SwiftUI")
        self.sel_to = self.para.index("客户端") + 3

        # 收尾 App Store 卡片
        self.name_font = pf(46 * u)
        self.card_sub_font = pf(31 * u, PF_REGULAR)
        self.btn_font = pf(32 * u)

    # MARK: 公共

    def seg(self, t, name):
        """段内时间与整屏横推偏移：返回 (段内秒数, x 偏移, 不透明度)，不在场返回 None。"""
        s, e = SEGMENTS[name]
        if t < s or t > e + PUSH:
            return None
        local = t - s
        dx = 0.0
        if name != "opening" and local < PUSH:
            dx = (1 - ease_in_out(local / PUSH)) * self.w
        if name != "finale" and t > e:
            dx = -ease_in_out((t - e) / PUSH) * self.w
        if abs(dx) >= self.w:
            return None
        return local, dx

    def title(self, canvas, name, local, dx):
        title, sub = TITLES[name]
        tx, ty = self.spec["title"][0] * self.w + dx, self.spec["title"][1] * self.h
        a = ease_out(phase(local, 0.15, 0.55))
        d = ImageDraw.Draw(canvas)
        anchor = "ms" if self.spec["align"] == "center" else "ls"
        lift = (1 - a) * 30
        col = tuple(round(lerp(255, c, a)) for c in INK)
        d.text((tx, ty + lift), title, font=self.title_font, fill=col, anchor=anchor)
        if sub:
            b = ease_out(phase(local, 0.3, 0.7))
            col = tuple(round(lerp(255, c, b)) for c in (110, 110, 115))
            d.text((tx, ty + self.spec["sub_size"] * 1.9 + (1 - b) * 30), sub, font=self.sub_font, fill=col, anchor=anchor)

    def flow(self, canvas, name, local, dx):
        """手机里一步步点过去：当前屏 → 手指按下、涟漪 → 淡入下一屏；标题下面的说明跟着换。"""
        steps = FLOWS[name]
        k = clamp(int((local - FLOW_START) // STEP), 0, len(steps) - 1) if local >= FLOW_START else 0
        within = local - FLOW_START - k * STEP
        phone = self.phones[steps[k][0]]
        tap = steps[k][2]
        if tap and within > 0.6 and k + 1 < len(steps):
            phone = Image.blend(phone, self.phones[steps[k + 1][0]], ease_in_out(phase(within, 0.6, 0.8)))

        p = ease_out(phase(local, 0.2, 0.9))
        x = round(self.vx - phone.width / 2 + dx)
        top = self.spec["phone_top"]
        y = round(lerp(self.h + 40, top * self.h if top else (self.h - phone.height) / 2, p))

        # 手指：灰色半透明圆点按下缩一下，松开时一圈涟漪往外散（画在手机上，跟着一起放大）
        phone = phone.copy()
        if tap and local >= FLOW_START:
            px = self.bezel + tap[0] * self.screen_scale
            py = self.bezel + tap[1] * self.screen_scale
            r0 = 20 * self.screen_scale
            down_p = phase(within, 0.3, 0.42)
            up_p = phase(within, 0.5, 0.8)
            if down_p > 0 and up_p < 1:
                ss = 3
                size = round(r0 * 6)
                layer, d = ss_layer((size, size), ss)
                c = size * ss / 2
                a = ease_out(down_p) * (1 - up_p)
                rr = r0 * (1 - 0.15 * ease_out(down_p) * (1 - up_p)) * ss
                d.ellipse((c - rr, c - rr, c + rr, c + rr), fill=(60, 60, 67, round(110 * a)),
                          outline=(255, 255, 255, round(230 * a)), width=round(2.5 * ss))
                if up_p > 0:
                    ring = r0 * (1 + 1.6 * ease_out(up_p)) * ss
                    d.ellipse((c - ring, c - ring, c + ring, c + ring), outline=KIMI + (round(200 * (1 - up_p)),),
                              width=round(3 * ss))
                phone.alpha_composite(down(layer, (size, size)), (round(px - size / 2), round(py - size / 2)))

        # 镜头：手机进场后推近，焦点跟着这一步要点的地方走（点完往下一步的点挪），焦点在画面上的位置不动
        z = lerp(1, self.spec["zoom"], ease_in_out(phase(local, 0.9, 1.5)))
        def focus(i):
            t_ = steps[i][2] or steps[i - 1][2]
            return clamp(t_[1], 240, 760) * self.screen_scale + self.bezel
        fy = focus(k)
        if k + 1 < len(steps):
            fy = lerp(fy, focus(k + 1), ease_in_out(phase(within, 0.55, 0.8)))
        fx = phone.width / 2
        if z > 1.001:
            big = phone.resize((round(phone.width * z), round(phone.height * z)), Image.BICUBIC)
            bx, by = x + fx - fx * z, y + fy - fy * z
            phone, x, y = big, round(bx), round(by)
        clip = self.spec["phone_clip"]
        if clip and y < clip * self.h:
            # 竖版：手机顶到标题区时，上沿柔和地淡出
            cut = round(clip * self.h) - y
            fade = round(0.04 * self.h)
            mask = Image.new("L", (1, phone.height), 255)
            for i in range(min(phone.height, cut + fade)):
                mask.putpixel((0, i), round(255 * ease_in_out(clamp((i - cut) / fade))))
            a = phone.getchannel("A")
            phone.putalpha(Image.composite(a, Image.new("L", a.size, 0), mask.resize(a.size)))
        canvas.alpha_composite(phone, (x, y))

        # 标题下面的步骤说明：换步时旧的淡出、新的从下面浮上来
        caption = steps[k][1]
        fade_in = ease_out(phase(within, 0, 0.3) if k else phase(local, 0.3, 0.7))
        fade_out = phase(within, 0.65, 0.8) if tap and k + 1 < len(steps) else 0
        a = fade_in * (1 - fade_out)
        if a > 0:
            tx, ty = self.spec["title"][0] * self.w + dx, self.spec["title"][1] * self.h
            anchor = "ms" if self.spec["align"] == "center" else "ls"
            col = tuple(round(lerp(255, c, a)) for c in KIMI)
            ImageDraw.Draw(canvas).text((tx, ty + self.spec["sub_size"] * 1.9 + (1 - fade_in) * 18), caption,
                                        font=self.sub_font, fill=col, anchor=anchor)

    # MARK: 各段

    def opening(self, canvas, t):
        r = self.seg(t, "opening")
        if r is None:
            return
        local, dx = r
        u = self.spec["opening_u"]
        cx, cy = self.w / 2 + dx, self.h * 0.42
        pop = ease_out_back(phase(local, 0.0, 0.35))
        # 打完字，bot 往上一跳出画面
        jump = phase(local, 2.15, 2.6)
        cy -= (self.h * 0.6) * jump ** 2 - 60 * math.sin(math.pi * min(1, jump * 2)) * (1 - jump)
        if pop > 0.01:
            face(canvas, cx, cy, u * pop, eye=blink_at(local, 1.3, 0.4), squash=1 + 0.12 * math.sin(local * 9) * math.exp(-local * 3))
        # 逐字打出，每个字带一下小弹
        text_a, text_b = "Moon Code", " 更新啦"
        full = text_a + text_b
        f_lat = sf(round(92 if self.spec["align"] == "center" else 120), 860)
        f_cjk = pf(f_lat.size * 0.92)
        widths = [f_lat.getlength(c) if i < len(text_a) else f_cjk.getlength(c) for i, c in enumerate(full)]
        total = sum(widths)
        x = cx - total / 2
        base = self.h * 0.42 + 16 * u + f_lat.size * 1.25
        out = ease_in_out(phase(local, 2.25, 2.6))
        d = ImageDraw.Draw(canvas)
        for i, ch in enumerate(full):
            ct = 0.45 + i * 0.075
            p = phase(local, ct, ct + 0.18)
            if p > 0 and ch != " ":
                s = ease_out_back(p, 2.6)
                f = f_lat if i < len(text_a) else f_cjk
                col = KIMI if i < 4 else INK
                col = tuple(round(lerp(c, 255, out)) for c in col)
                fs = f if abs(s - 1) < 0.02 else (sf(max(1, round(f_lat.size * s)), 860) if i < len(text_a) else pf(f_cjk.size * s))
                d.text((x + widths[i] / 2, base), ch, font=fs, fill=col, anchor="ms")
            x += widths[i]
        self.confetti_open.draw(canvas, local - (0.45 + len(full) * 0.075 + 0.1))

    def thinking(self, canvas, t):
        r = self.seg(t, "thinking")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "thinking", local, dx)
        u = self.u
        cw, ch = round(860 * u), round(330 * u)
        cx, cy = self.vx + dx, self.vy
        card, m = shadow_card((cw, ch), 48 * u)
        canvas.alpha_composite(card, (round(cx - cw / 2 - m), round(cy - ch / 2 - m)))

        # 滑块位置：Low → Medium（带回弹吸附）→ High
        stops = [(0.0, 0), (1.15, 0), (1.5, 0.5), (1.95, 0.5), (2.3, 1.0)]
        pos = 0.0
        for (t0, p0), (t1, p1) in zip(stops, stops[1:]):
            if local >= t1:
                pos = p1
            elif local > t0:
                pos = lerp(p0, p1, ease_out_back(phase(local, t0, t1), 1.4))
                break
        level = 0 if pos < 0.25 else (1 if pos < 0.75 else 2)
        top = local >= 2.3
        names = ["Low", "Medium", "High"]

        tw, th = round(740 * u), round(72 * u)
        tx0, ty = cx - tw / 2, cy + 50 * u
        ss = 3
        layer, d = ss_layer((tw + 4, th + 4), ss)
        d.rounded_rectangle((2 * ss, 2 * ss, (tw + 2) * ss, (th + 2) * ss), th / 2 * ss, fill=TRACK + (255,))
        canvas.alpha_composite(down(layer, (tw + 4, th + 4)), (round(tx0 - 2), round(ty - th / 2 - 2)))
        knob = th * 1.12
        kx = tx0 + th / 2 + (tw - th) * clamp(pos, 0, 1.08)
        # 已拖过的一段：蓝色；顶档变紫色渐变，里面白色小气泡往左飘
        fill_w = max(th, round(kx - tx0 + th / 2))
        purple = ease_in_out(phase(local, 2.15, 2.45))
        bar = Image.new("RGBA", (fill_w, th), KIMI + (255,))
        if purple > 0:
            g = gradient(fill_w, th, PURPLE).convert("RGBA")
            bar = Image.blend(bar, g, purple)
            bd = ImageDraw.Draw(bar)
            rng = random.Random(5)
            for _ in range(18):
                bx = (rng.uniform(0, 1) - (local - 2.3) * rng.uniform(0.25, 0.5)) % 1 * fill_w
                by = rng.uniform(0.2, 0.8) * th
                br = rng.uniform(2, 5) * u
                bd.ellipse((bx - br, by - br, bx + br, by + br), fill=(255, 255, 255, round(150 * purple)))
        mask, md = ss_layer((fill_w, th), ss)
        md.rounded_rectangle((0, 0, fill_w * ss - 1, th * ss - 1), th / 2 * ss, fill=(255, 255, 255, 255))
        bar.putalpha(down(mask, (fill_w, th)).getchannel("A"))
        canvas.alpha_composite(bar, (round(tx0), round(ty - th / 2)))
        # 档位小点
        d2 = ImageDraw.Draw(canvas)
        for k in range(3):
            px = tx0 + th / 2 + (tw - th) * k / 2
            if px > kx + knob / 2:
                d2.ellipse((px - 5 * u, ty - 5 * u, px + 5 * u, ty + 5 * u), fill=(174, 174, 178))
        # 滑块：白圆 + 投影
        kn, km = shadow_card((round(knob), round(knob)), knob / 2, blur=knob * 0.18)
        canvas.alpha_composite(kn, (round(kx - knob / 2 - km), round(ty - knob / 2 - km)))

        # 档位名：换档时弹一下；顶档变紫
        change = max([phase(local, a, a + 0.3) if local >= a else 0 for a in (1.5, 2.3)] + [0])
        bump = 1 + 0.25 * math.sin(math.pi * change) if 0 < change < 1 else 1
        lab_col = PURPLE[2] if top else KIMI
        lf = pf(64 * u * bump)
        d2.text((cx, cy - 72 * u), names[level], font=lf, fill=lab_col, anchor="ms")
        d2.text((cx, cy - 22 * u), "K3", font=self.small_font, fill=GRAY, anchor="ms")

        # 星星：到顶迸一圈
        b = phase(local, 2.3, 3.1)
        if 0 < b < 1:
            for k in range(12):
                a = k / 12 * 2 * math.pi + 0.3
                dist = (40 + 150 * ease_out(b)) * u
                sr = (16 if k % 2 else 11) * u * (1 - b) ** 0.6
                star(d2, kx + math.cos(a) * dist, ty + math.sin(a) * dist, sr, STAR if k % 3 else PURPLE[2])

        # 手指：按住滑块一路拖到顶，松手时荡开一圈涟漪（同手机演示里的点击样式）
        down_p = phase(local, 0.85, 1.0)
        up_p = phase(local, 2.4, 2.75)
        if down_p > 0 and up_p < 1:
            r0 = knob * 0.42
            ss = 3
            size = round(r0 * 6)
            layer, dd = ss_layer((size, size), ss)
            c = size * ss / 2
            a = ease_out(down_p) * (1 - up_p)
            rr = r0 * (1 - 0.12 * ease_out(down_p) * (1 - up_p)) * ss
            dd.ellipse((c - rr, c - rr, c + rr, c + rr), fill=(60, 60, 67, round(90 * a)),
                       outline=(255, 255, 255, round(230 * a)), width=round(2.5 * ss))
            if up_p > 0:
                ring = r0 * (1 + 1.6 * ease_out(up_p)) * ss
                dd.ellipse((c - ring, c - ring, c + ring, c + ring), outline=PURPLE[2] + (round(200 * (1 - up_p)),),
                           width=round(3 * ss))
            canvas.alpha_composite(down(layer, (size, size)), (round(kx - size / 2), round(ty - size / 2)))

    def models(self, canvas, t):
        r = self.seg(t, "models")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "models", local, dx)
        self.flow(canvas, "models", local, dx)

    def files(self, canvas, t):
        r = self.seg(t, "files")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "files", local, dx)
        self.flow(canvas, "files", local, dx)

    def usage(self, canvas, t):
        r = self.seg(t, "usage")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "usage", local, dx)
        u = self.u
        rows = [("此对话上下文", "上下文", 0.37, "97K / 262K tokens"), ("5 小时使用限额", "所有模型", 0.42, "2小时14分钟后重置"),
                ("每月使用限额", "所有模型", 0.63, "9天后重置")]
        cw, ch = round(820 * u), round(170 * u)
        gap = 92 * u
        total = len(rows) * ch + (len(rows) - 1) * gap
        top = self.vy - total / 2 + 30 * u
        d = ImageDraw.Draw(canvas)
        for i, (caption, name, value, foot) in enumerate(rows):
            p = ease_out(phase(local, 0.25 + i * 0.15, 0.75 + i * 0.15))
            if p <= 0:
                continue
            cx = self.vx + dx
            y = top + i * (ch + gap) + (1 - p) * 60 * u
            card, m = shadow_card((cw, ch), 36 * u)
            canvas.alpha_composite(with_alpha(card, p), (round(cx - cw / 2 - m), round(y - m)))
            x0 = cx - cw / 2 + 36 * u
            d.text((x0 - 8 * u, y - 22 * u), caption, font=self.small_font, fill=GRAY, anchor="ls")
            d.text((x0, y + 56 * u), name, font=self.label_font, fill=INK, anchor="ls")
            fillp = ease_in_out(phase(local, 0.7 + i * 0.2, 1.8 + i * 0.2)) * value
            d.text((cx + cw / 2 - 36 * u, y + 56 * u), f"已使用 {round(fillp * 100)}%", font=self.small_font,
                   fill=(110, 110, 115), anchor="rs")
            bw, bh = cw - 72 * u, 16 * u
            by = y + 84 * u
            d.rounded_rectangle((x0, by, x0 + bw, by + bh), bh / 2, fill=(214, 232, 255))
            if fillp > 0:
                d.rounded_rectangle((x0, by, x0 + max(bh, bw * fillp), by + bh), bh / 2, fill=KIMI)
            d.text((x0, y + 142 * u), foot, font=pf(24 * u, PF_REGULAR), fill=GRAY, anchor="ls")

    def select(self, canvas, t):
        r = self.seg(t, "select")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "select", local, dx)
        u = self.u
        f = self.body_font
        lh = 62 * u
        n = len(self.para_lines)
        pw = self.para_w
        cx = self.vx + dx
        x0 = cx - pw / 2
        y0 = self.vy - 230 * u
        d = ImageDraw.Draw(canvas)
        a = ease_out(phase(local, 0.2, 0.6))

        # 选区：长按落在 SwiftUI 上，然后结束手柄一路往后拖
        sel_a = phase(local, 0.8, 1.0)
        grow = ease_in_out(phase(local, 1.05, 1.9))
        start = self.sel_from
        end = round(lerp(self.sel_from + len("SwiftUI"), self.sel_to, grow))

        def pos(idx):
            for k, (line, s) in reversed(list(enumerate(self.para_lines))):
                if idx >= s:
                    return k, x0 + f.getlength(line[:idx - s])
            return 0, x0

        # 被添加到会话框后，选区淡掉
        sent = phase(local, 2.55, 2.75)
        if sel_a > 0 and sent < 1:
            hl = with_alpha(Image.new("RGBA", canvas.size, (0, 0, 0, 0)), 1)
            hd = ImageDraw.Draw(hl)
            la, xa = pos(start)
            lb, xb = pos(end)
            col = (KIMI[0], KIMI[1], KIMI[2], round(60 * sel_a * (1 - sent)))
            for k in range(la, lb + 1):
                line, s = self.para_lines[k]
                left = xa if k == la else x0
                right = xb if k == lb else x0 + f.getlength(line)
                ly = y0 + k * lh
                hd.rectangle((left, ly - 8 * u, right, ly + lh - 14 * u), fill=col)
            canvas.alpha_composite(hl)
        for k, (line, s) in enumerate(self.para_lines):
            d.text((x0, y0 + k * lh), line, font=f, fill=tuple(round(lerp(255, c, a)) for c in INK), anchor="lt")
        if sel_a > 0 and sent < 1:
            la, xa = pos(start)
            lb, xb = pos(end)
            hc = KIMI + (round(255 * sel_a * (1 - sent)),)
            hd = ImageDraw.Draw(canvas)
            for (lk, xx, up) in ((la, xa, True), (lb, xb, False)):
                ly = y0 + lk * lh
                hd.rectangle((xx - 2 * u, ly - 8 * u, xx + 2 * u, ly + lh - 14 * u), fill=hc)
                r0 = 8 * u
                cyh = ly - 8 * u - r0 if up else ly + lh - 14 * u + r0
                hd.ellipse((xx - r0, cyh - r0, xx + r0, cyh + r0), fill=hc)

        # 编辑菜单：白色胶囊三格
        menu_p = phase(local, 2.0, 2.25) * (1 - phase(local, 2.6, 2.75))
        items = ["拷贝", "添加到会话框", "搜索网页"]
        mf = pf(32 * u, PF_MEDIUM)
        mw = sum(mf.getlength(s) for s in items) + 3 * 2 * 34 * u
        mh = 84 * u
        la, xa = pos(start)
        my = y0 + la * lh - 40 * u - mh
        if menu_p > 0:
            s = ease_out_back(menu_p, 1.6)
            menu, m = shadow_card((round(mw), round(mh)), mh / 2)
            if abs(s - 1) > 0.01:
                menu = menu.resize((max(1, round(menu.width * s)), max(1, round(menu.height * s))), Image.BICUBIC)
            canvas.alpha_composite(with_alpha(menu, clamp(menu_p * 2)),
                                   (round(cx - menu.width / 2), round(my + mh / 2 - menu.height / 2)))
            if s > 0.6:
                xx = cx - mw / 2
                for i, item in enumerate(items):
                    iw = mf.getlength(item) + 68 * u
                    press = phase(local, 2.35, 2.45) * (1 - phase(local, 2.5, 2.6))
                    if i == 1 and press > 0:
                        d.rounded_rectangle((xx + 6 * u, my + 8 * u, xx + iw - 6 * u, my + mh - 8 * u), (mh - 16 * u) / 2,
                                            fill=(228, 238, 255))
                    d.text((xx + iw / 2, my + mh / 2), item, font=mf, fill=KIMI if i == 1 else INK, anchor="mm")
                    if i < 2:
                        d.line((xx + iw, my + 24 * u, xx + iw, my + mh - 24 * u), fill=(220, 220, 225), width=max(1, round(2 * u)))
                    xx += iw

        # 输入框：选中的字飞进来变成引用条
        comp_p = ease_out(phase(local, 2.45, 2.85))
        if comp_p > 0:
            bw_, bh_ = round(820 * u), round(190 * u)
            by_ = self.vy + 150 * u + (1 - comp_p) * 120 * u
            box, m = shadow_card((bw_, bh_), 44 * u)
            canvas.alpha_composite(with_alpha(box, comp_p), (round(cx - bw_ / 2 - m), round(by_ - m)))
            quote = "“" + self.para[self.sel_from:self.sel_to] + "”"
            fly = ease_in_out(phase(local, 2.6, 3.1))
            qf = pf(30 * u, PF_REGULAR)
            qw = qf.getlength(quote) + 48 * u
            qx = lerp(xa, cx - bw_ / 2 + 28 * u, fly)
            qy = lerp(y0 + la * lh, by_ + 26 * u, fly)
            if fly > 0:
                d.rounded_rectangle((qx, qy, qx + qw, qy + 56 * u), 16 * u, fill=(238, 244, 255))
                d.rectangle((qx, qy + 10 * u, qx + 5 * u, qy + 46 * u), fill=KIMI)
                d.text((qx + 24 * u, qy + 28 * u), quote, font=qf, fill=INK, anchor="lm")
            d.text((cx - bw_ / 2 + 30 * u, by_ + 130 * u), "让 Kimi 做点什么…", font=pf(32 * u, PF_REGULAR),
                   fill=(174, 174, 178), anchor="lm")
            sr = 34 * u
            sx, sy = cx + bw_ / 2 - 30 * u - sr, by_ + 130 * u
            d.ellipse((sx - sr, sy - sr, sx + sr, sy + sr), fill=KIMI)
            d.line((sx, sy + 14 * u, sx, sy - 14 * u), fill=(255, 255, 255), width=round(5 * u))
            d.line((sx - 12 * u, sy - 2 * u, sx, sy - 14 * u, sx + 12 * u, sy - 2 * u), fill=(255, 255, 255),
                   width=round(5 * u), joint="curve")

    def onboard(self, canvas, t):
        r = self.seg(t, "onboard")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "onboard", local, dx)
        u = self.u
        cw, ch = round(800 * u), round(170 * u)
        gap = 44 * u
        cx = self.vx + dx
        tops = [self.vy - ch - gap / 2 + 40 * u, self.vy + gap / 2 + 40 * u]
        names = [("Kimi Code 桌面端", "desktop"), ("Kimi Code CLI", "cli")]
        # bot 落点：0 → 1 → 0 → 1，每次落下按一下卡片
        hops = [0.85, 1.45, 2.05, 2.6]
        d = ImageDraw.Draw(canvas)
        nf = pf(40 * u, PF_MEDIUM)
        presses = []
        for k, ht in enumerate(hops):
            presses.append((k % 2, ht))
        for i, (name, icon) in enumerate(names):
            p = ease_out(phase(local, 0.2 + i * 0.12, 0.7 + i * 0.12))
            if p <= 0:
                continue
            press = 0
            for idx, ht in presses:
                if idx == i:
                    press = max(press, math.exp(-max(0, local - ht) * 10) if local >= ht else 0)
            s = 1 - 0.04 * press
            w, h = round(cw * s), round(ch * s)
            y = tops[i] + (1 - p) * 80 * u + (ch - h) / 2
            fill = tuple(round(lerp(255, c, press)) for c in (236, 243, 255))
            card, m = shadow_card((w, h), h / 2, fill=fill)
            canvas.alpha_composite(with_alpha(card, p), (round(cx - w / 2 - m), round(y - m)))
            ic = self.icons[icon]
            canvas.alpha_composite(ic, (round(cx - w / 2 + 34 * u), round(y + (h - ic.height) / 2)))
            d.text((cx - w / 2 + 34 * u + ic.width + 30 * u, y + h / 2), name, font=nf, fill=INK, anchor="lm")
            ax = cx + w / 2 - 50 * u
            d.line((ax - 8 * u, y + h / 2 - 14 * u, ax + 6 * u, y + h / 2, ax - 8 * u, y + h / 2 + 14 * u),
                   fill=(174, 174, 178), width=round(5 * u), joint="curve")
        # bot 在两张卡片的右上角之间来回跳
        bu = 3.6 * u
        spots = [(cx + cw / 2 - 150 * u, tops[0] - 8 * bu), (cx + cw / 2 - 150 * u, tops[1] - 8 * bu)]
        start = (cx + cw / 2 - 150 * u, -self.h * 0.1)
        seq = [start] + [spots[i % 2] for i in range(len(hops))]
        times = [0.35] + hops
        bx, by = seq[-1]
        for k in range(len(times) - 1):
            if times[k] <= local < times[k + 1]:
                x = phase(local, times[k], times[k + 1])
                a, b = seq[k], seq[k + 1]
                bx = lerp(a[0], b[0], ease_in_out(x))
                by = lerp(a[1], b[1], x * x) if k == 0 else lerp(a[1], b[1], ease_in_out(x)) - 140 * u * 4 * x * (1 - x)
                break
        if local >= 0.35:
            last = max([ht for ht in hops if ht <= local] + [0])
            sq = 1 - 0.22 * math.exp(-(local - last) * 10) if last else 1
            face(canvas, bx, by, bu, eye=blink_at(local, 1.6), squash=sq)

    def polish_layout(self):
        """细节胶囊：按行排好（相对画面中心），每个胶囊预先画成贴图（不带勾 / 带勾两版），飞行时只做旋转缩放。"""
        u = self.u
        f = pf(46 * u, PF_MEDIUM)
        maxw, gap, h, pads, rr = 1000 * u, 26 * u, 112 * u, 52 * u, 19 * u
        rows, cur, cw = [], [], 0
        for text in POLISH:
            w = f.getlength(text) + pads * 2 + 40 * u
            if cur and cw + w + gap > maxw:
                rows.append((cur, cw))
                cur, cw = [], 0
            cur.append((text, w))
            cw += w + (gap if cw else 0)
        rows.append((cur, cw))
        total = len(rows) * h + (len(rows) - 1) * 32 * u
        chips = []
        y = -total / 2 - 70 * u
        for items, rw in rows:
            x = -rw / 2
            for text, w in items:
                color = CONFETTI[len(chips) % len(CONFETTI)]
                card, m = shadow_card((round(w), round(h)), h / 2)
                d = ImageDraw.Draw(card)
                ox, oy = m + pads * 0.8, m + h / 2
                d.ellipse((ox - rr, oy - rr, ox + rr, oy + rr), fill=color)
                d.text((ox + rr + 18 * u, oy), text, font=f, fill=INK, anchor="lm")
                check = [(ox - 9 * u, oy), (ox - 2.5 * u, oy + 7.5 * u), (ox + 10 * u, oy - 7.5 * u)]
                done = card.copy()
                ImageDraw.Draw(done).line(check, fill=(255, 255, 255), width=round(5 * u), joint="curve")
                chips.append(dict(cx=x + w / 2, cy=y + h / 2, w=w, h=h, base=card, done=done, check=check,
                                  color=color, spin=(-1) ** len(chips) * (18 + 9 * (len(chips) % 3))))
                x += w + gap
            y += h + 32 * u
        return chips, -total / 2 - 70 * u + total

    def polish(self, canvas, t):
        """bot 站在下面当发射台：一个个把胶囊抛上去，胶囊转着圈飞到位、落地 Q 弹、迸星星、勾一笔画上；
        身后一圈圈光环往外扩。全部落定后整排从左到右起一道浪，bot 开心地蹦一下。"""
        r = self.seg(t, "polish")
        if r is None:
            return
        local, dx = r
        self.title(canvas, "polish", local, dx)
        u = self.u
        if not hasattr(self, "_chips"):
            self._chips, self._chips_bottom = self.polish_layout()
        chips = self._chips
        ox, oy = self.vx + dx, self.vy
        bu = 4.6 * u
        bx, by = ox, oy + self._chips_bottom + 220 * u
        launch0, every, fly = 0.7, 0.16, 0.55
        d = ImageDraw.Draw(canvas)

        # 光环：每发射一个胶囊，从 bot 身上扩出一圈淡蓝色的环
        ring_layer = None
        for k in range(len(chips)):
            q = phase(local, launch0 + k * every, launch0 + k * every + 0.9)
            if 0 < q < 1:
                if ring_layer is None:
                    ring_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
                    rd = ImageDraw.Draw(ring_layer)
                rad = (40 + 520 * ease_out(q)) * u
                col = chips[k]["color"]
                rd.ellipse((bx - rad, by - rad, bx + rad, by + rad), outline=col + (round(70 * (1 - q)),),
                           width=max(1, round(5 * u * (1 - q) + 1)))
        if ring_layer is not None:
            canvas.alpha_composite(ring_layer)

        wave0 = launch0 + len(chips) * every + fly + 0.25
        for k, c in enumerate(chips):
            t0 = launch0 + k * every
            p = phase(local, t0, t0 + fly)
            if p <= 0:
                continue
            ex, ey = ox + c["cx"], oy + c["cy"]
            if p < 1:
                # 抛物线飞过去，边飞边转边变大
                e = ease_out(p)
                x = lerp(bx, ex, e)
                y = lerp(by - 20 * u, ey, e) - 300 * u * 4 * p * (1 - p)
                scale = lerp(0.25, 1.0, e)
                sx = sy = scale
                ang = c["spin"] * (1 - e) * 3
                sprite = c["base"]
            else:
                # 落地：横竖反相的阻尼回弹（Q 弹），勾一笔画上
                tau = local - (t0 + fly)
                wob = 0.2 * math.exp(-7 * tau) * math.cos(22 * tau)
                sx, sy = 1 + wob, 1 - wob
                x, y, ang = ex, ey, 0
                # 浪：全部落定后从左到右依次抬一下
                wq = phase(local, wave0 + k * 0.07, wave0 + k * 0.07 + 0.4)
                if 0 < wq < 1:
                    lift = math.sin(math.pi * wq)
                    y -= 22 * u * lift
                    sx *= 1 + 0.07 * lift
                    sy *= 1 + 0.07 * lift
                cq = phase(tau, 0.05, 0.3)
                if cq >= 1:
                    sprite = c["done"]
                else:
                    sprite = c["base"].copy()
                    if cq > 0:
                        a, b, e2 = c["check"]
                        L1 = math.dist(a, b)
                        L = L1 + math.dist(b, e2)
                        reach = L * ease_in_out(cq)
                        pts = [a, b] if reach >= L1 else [a, (lerp(a[0], b[0], reach / L1), lerp(a[1], b[1], reach / L1))]
                        if reach > L1:
                            f2 = (reach - L1) / (L - L1)
                            pts.append((lerp(b[0], e2[0], f2), lerp(b[1], e2[1], f2)))
                        ImageDraw.Draw(sprite).line(pts, fill=(255, 255, 255), width=round(5 * u), joint="curve")
                # 星星：落地一瞬间从胶囊四周迸出去
                sq = phase(tau, 0, 0.5)
                if 0 < sq < 1:
                    for j in range(8):
                        a = j / 8 * 2 * math.pi + k
                        rx = c["w"] / 2 + 60 * u * ease_out(sq)
                        ry = c["h"] / 2 + 46 * u * ease_out(sq)
                        star(d, ex + math.cos(a) * rx, ey + math.sin(a) * ry, (11 if j % 2 else 7) * u * (1 - sq),
                             c["color"] if j % 2 else STAR)
            w2 = max(1, round(sprite.width * sx))
            h2 = max(1, round(sprite.height * sy))
            img = sprite if (w2, h2) == sprite.size else sprite.resize((w2, h2), Image.BICUBIC)
            if abs(ang) > 0.3:
                img = img.rotate(ang, resample=Image.BICUBIC, expand=True)
            canvas.alpha_composite(img, (round(x - img.width / 2), round(y - img.height / 2)))

        # bot：进场弹出；每抛一个往下一蹲（后坐力）；最后一个落定后高高蹦起
        pop = ease_out_back(phase(local, 0.3, 0.65))
        if pop > 0.01:
            squash, hop = 1.0, 0.0
            for k in range(len(chips)):
                q = local - (launch0 + k * every)
                if 0 <= q < 0.16:
                    squash = min(squash, 1 - 0.22 * math.sin(math.pi * q / 0.16))
            jq = phase(local, wave0 - 0.1, wave0 + 0.55)
            if 0 < jq < 1:
                hop = 100 * u * 4 * jq * (1 - jq)
            elif jq >= 1:
                squash = 1 - 0.2 * math.exp(-(local - wave0 - 0.55) * 9) * math.cos((local - wave0 - 0.55) * 24)
            face(canvas, bx, by - hop, bu * pop, eye=blink_at(local, 1.4), squash=squash)

    def finale(self, canvas, t):
        r = self.seg(t, "finale")
        if r is None:
            return
        local, dx = r
        u = self.u
        vertical = self.spec["align"] == "center"
        wsize = round((150 if vertical else 170) * u)
        wf = sf(wsize, 860)
        width = wf.getlength("Moon Code")
        bu = wsize / 24
        gapx = wsize * 0.22
        gx = self.w / 2 + dx
        gy = self.h * (0.36 if vertical else 0.34)
        left = gx - (24 * bu + gapx + width) / 2
        a = ease_out_back(phase(local, 0.25, 0.75), 1.4)
        d = ImageDraw.Draw(canvas)
        if a > 0:
            bx = left + 12 * bu
            face(canvas, bx, gy - wsize * 0.02, bu * a, eye=blink_at(local, 2.0, 0.5))
            x0 = left + 24 * bu + gapx
            ta = ease_out(phase(local, 0.4, 0.8))
            base = gy + wsize * 0.36 + (1 - ta) * 30
            col1 = tuple(round(lerp(255, c, ta)) for c in KIMI)
            col2 = tuple(round(lerp(255, c, ta)) for c in INK)
            d.text((x0, base), "Moon", font=wf, fill=col1, anchor="ls")
            d.text((x0 + wf.getlength("Moon"), base), " Code", font=wf, fill=col2, anchor="ls")
        na = ease_out(phase(local, 0.8, 1.2))
        if na > 0:
            nf = pf(64 * u)
            col = tuple(round(lerp(255, c, na)) for c in INK)
            d.text((gx, gy + wsize * 0.36 + 120 * u + (1 - na) * 24), "现已更新", font=nf, fill=col, anchor="ms")
        self.confetti_end.draw(canvas, local - 0.5)
        # App Store 卡片：更新 → 下载圈 → 打开
        ca = ease_out(phase(local, 1.3, 1.9))
        if ca > 0:
            cw, ch = round(880 * u), round(200 * u)
            card, m = shadow_card((cw, ch), 40 * u, fill=(255, 255, 255))
            y = gy + wsize * 0.36 + 230 * u + (1 - ca) * 90 * u
            x = gx - cw / 2
            canvas.alpha_composite(with_alpha(card, ca), (round(x - m), round(y - m)))
            ic = self.icons["app"]
            pad = 28 * u
            canvas.alpha_composite(ic, (round(x + pad), round(y + (ch - ic.height) / 2)))
            tx = x + pad * 2 + ic.width
            d.text((tx, y + ch / 2 - 8 * u), "Moon Code", font=self.name_font, fill=INK, anchor="ls")
            d.text((tx, y + ch / 2 + 12 * u), "KimiCode远程控制客户端", font=self.card_sub_font, fill=GRAY, anchor="lt")
            btn = self.button(local)
            canvas.alpha_composite(btn, (round(x + cw - pad - btn.width), round(y + (ch - btn.height) / 2)))

    def button(self, t):
        u, ss = self.u, 4
        bw, bh = round(132 * u), round(58 * u)
        img = Image.new("RGBA", (bw * ss, bh * ss), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        t_press, t_load, t_done = 2.3, 2.55, 3.4
        if t < t_load:
            press = phase(t, t_press, t_press + 0.12) * (1 - phase(t, t_press + 0.12, t_load))
            s = 1 - 0.1 * ease_in_out(press)
            w2, h2 = bw * ss * s, bh * ss * s
            x0, y0 = (bw * ss - w2) / 2, (bh * ss - h2) / 2
            d.rounded_rectangle((x0, y0, x0 + w2, y0 + h2), h2 / 2, fill=FILL + (255,))
            label = "更新"
        elif t < t_done:
            p = ease_in_out(phase(t, t_load + 0.1, t_done - 0.1))
            r = bh * ss * 0.46
            cx, cy = bw * ss / 2, bh * ss / 2
            lw = round(5 * u * ss)
            d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=FILL + (255,), width=lw)
            if p > 0:
                d.arc((cx - r, cy - r, cx + r, cy + r), -90, -90 + 360 * p, fill=SYSTEM_BLUE + (255,), width=lw)
            q = r * 0.32
            d.rounded_rectangle((cx - q, cy - q, cx + q, cy + q), q * 0.25, fill=SYSTEM_BLUE + (255,))
            label = None
        else:
            s = clamp(ease_out_back(phase(t, t_done, t_done + 0.3)), 0, 1.2)
            w2, h2 = bw * ss * s, bh * ss * s
            x0, y0 = (bw * ss - w2) / 2, (bh * ss - h2) / 2
            d.rounded_rectangle((x0, y0, x0 + w2, y0 + h2), max(1, h2 / 2), fill=FILL + (255,))
            label = "打开" if s > 0.5 else None
        img = img.resize((bw, bh), Image.LANCZOS)
        if label:
            ImageDraw.Draw(img).text((bw / 2, bh / 2), label, font=self.btn_font, fill=SYSTEM_BLUE + (255,), anchor="mm")
        return img

    def frame(self, t):
        canvas = Image.new("RGBA", (self.w, self.h), PAPER + (255,))
        for part in (self.opening, self.thinking, self.models, self.files, self.usage, self.select, self.onboard,
                     self.polish, self.finale):
            part(canvas, t)
        return canvas.convert("RGB")


def main():
    args = sys.argv[1:]
    fps = int(args[args.index("--fps") + 1]) if "--fps" in args else 60
    only = args[args.index("--only") + 1] if "--only" in args else None
    flags = {"--fps", "--only"}
    positional = [a for i, a in enumerate(args) if a not in flags and (i == 0 or args[i - 1] not in flags)]
    raw = Path(positional[0]) / "iphone"
    out_dir = Path(positional[1]) if len(positional) > 1 else ROOT / "marketing/video"
    out_dir.mkdir(parents=True, exist_ok=True)
    shots = {n: Image.open(raw / "seq" / f"{n}.png") for flow in FLOWS.values() for n, _, _ in flow}

    for name, spec in LAYOUTS.items():
        if only and name != only:
            continue
        video = Video(spec, shots)
        w, h = spec["size"]
        out = out_dir / f"update-{name}-{w}x{h}.mp4"
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(fps), "-i", "-",
            "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "17",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", str(out),
        ]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        for i in range(round(DURATION * fps)):
            proc.stdin.write(video.frame(i / fps).tobytes())
        proc.stdin.close()
        proc.wait()
        video.frame(DURATION - 0.1).save(out_dir / f"update-{name}-{w}x{h}.png", optimize=True)
        print("wrote", out, flush=True)


if __name__ == "__main__":
    main()
