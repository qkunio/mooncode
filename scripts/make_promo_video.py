#!/usr/bin/env python3
"""App 宣传短片「月亮绕着电脑转」：一个不靠字幕讲的小故事。竖版 1080×1920 + 横版 1920×1080，60fps，无声。

用法：python3 scripts/make_promo_video.py [输出目录] [--fps 60] [--only vertical|landscape] [--frame 秒 输出.png]
默认输出到 marketing/video/。画面全部是矢量现画的，不需要截图。

分镜（秒）：
  0.0–2.6   一台电脑，终端里敲下 `kimi rc`，屏幕上弹出 bot 的脸，眨一下眼
  2.6–4.9   手机滑进来，bot 从电脑屏幕里蹦出去、落进手机，身后拉出一条虚线把两台设备连起来
  4.9–14.6  出门：电脑缩到角落（一颗「星球」），手机成了主角。背景街景往后退，太阳落下，天色从白到晚霞到夜；
            手机里：输入「修复启动崩溃」→ 发送 → 思考 → 读文件 / 跑命令 → 弹出确认卡片 → 手指点「允许」→ 修好了，测试通过。
            每一步都有光点沿虚线来回，远处电脑屏幕上跟着滚动
  14.6–18.0 入夜，镜头拉远：电脑在中间，手机缩小，沿轨道绕着它转 —— Moon
  18.0–21.5 电脑收成 bot 的脸，手机收成一颗小月亮继续绕；逐字弹出「Moon Code」和一行副标题
全片的字只有：终端里的命令、手机里的对话、片尾的字标与副标题。
"""
import math
import random
import subprocess
import sys
from functools import lru_cache
from multiprocessing import Pool
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_header import KIMI, sf  # noqa: E402
from make_rename_video import (  # noqa: E402
    INK, PF_MEDIUM, PF_REGULAR, PF_SEMIBOLD, clamp, ease_in_out, ease_out, ease_out_back, lerp, phase,
)
from make_screenshots import PINGFANG  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MONO = "/System/Library/Fonts/Menlo.ttc"
DURATION = 21.5
SS = 2  # 整张画布按 2 倍画，最后缩回去

GRAY = (142, 142, 147)
GREEN = (52, 199, 89)
AMBER = (255, 159, 10)
PURPLE = (168, 84, 247)
NIGHT = (12, 16, 40)
SKY = [(0.0, (255, 255, 255)), (5.5, (255, 255, 255)), (9.0, (255, 245, 232)), (11.5, (252, 216, 200)),
       (13.2, (112, 104, 158)), (14.8, NIGHT)]

# 关键时间点
T_ENTER, T_JUMP, T_LAND = 1.75, 3.6, 4.4
T_TYPE, T_SEND = 6.1, 7.4
T_THOUGHT, T_ROW2, T_ROW3 = 9.0, 9.0, 9.5
T_CARD, T_TAP, T_CARD_OUT = 9.9, 11.05, 11.25
T_ANSWER, T_DONE = 12.0, 13.0
T_ORBIT, T_MORPH, T_WORD = 16.0, 17.5, 18.7
PROMPT = "修复启动崩溃"
ANSWER = "修好了，启动不再崩溃。"
# 沿虚线跑的光点：(出发时间, 方向 1 = 电脑→手机 / -1 = 手机→电脑)
PULSES = [(T_SEND, -1), (7.9, 1), (8.4, 1), (8.9, 1), (9.4, 1), (T_CARD - 0.35, 1), (T_TAP + 0.05, -1),
          (11.6, 1), (12.0, 1), (12.4, 1), (12.8, 1)]

# 各画幅的站位（输出像素）：电脑 = (中心 x, 中心 y, 宽)，手机 = (中心 x, 中心 y, 高)
LAYOUTS = {
    "landscape": dict(
        size=(1920, 1080), sc=1.0,
        lap_open=(960, 520, 900), lap_duo=(540, 540, 640), lap_walk=(330, 300, 290), lap_orbit=(960, 500, 380),
        ph_off=(2300, 560, 760), ph_duo=(1400, 540, 760), ph_walk=(1120, 540, 940), ph_orbit_h=190,
        ground=930, sun=(1620, 250), orbit=(620, 200),
        bot=(960, 370), word=(150, 640), tag=(44, 716)),
    "vertical": dict(
        size=(1080, 1920), sc=1.15,
        lap_open=(540, 900, 820), lap_duo=(540, 500, 600), lap_walk=(270, 290, 270), lap_orbit=(540, 880, 330),
        ph_off=(540, 2500, 900), ph_duo=(540, 1320, 900), ph_walk=(540, 1150, 1280), ph_orbit_h=170,
        ground=1710, sun=(880, 330), orbit=(410, 150),
        bot=(540, 760), word=(150, 1040), tag=(44, 1120)),
}


@lru_cache(maxsize=None)
def pf(size, index=PF_REGULAR):
    return ImageFont.truetype(PINGFANG, max(1, round(size)), index=index)


@lru_cache(maxsize=None)
def mono(size):
    return ImageFont.truetype(MONO, max(1, round(size)))


@lru_cache(maxsize=None)
def sfw(size, weight):
    return sf(max(1, round(size)), weight)


def mix(a, b, x):
    return tuple(round(lerp(p, q, x)) for p, q in zip(a, b))


def rgba(color, alpha=1.0):
    return tuple(color[:3]) + (round(255 * clamp(alpha)),)


def track(keys, t):
    """关键帧之间缓入缓出。keys = [(时间, 元组)]。"""
    if t <= keys[0][0]:
        return keys[0][1]
    for (t0, a), (t1, b) in zip(keys, keys[1:]):
        if t <= t1:
            x = ease_in_out(phase(t, t0, t1))
            return tuple(lerp(p, q, x) for p, q in zip(a, b))
    return keys[-1][1]


def draw_face(d, cx, cy, u, eye=1.0, squash=1.0):
    """Kimi bot 的脸（KimiFace 几何：24×16、圆角 2.3、眼 3×4.5、偏移 (2.7, -2.8)）。squash 压扁时底边不动。"""
    if u <= 0.05:
        return
    hw, hh = 12 * u / squash ** 0.5, 8 * u * squash
    bottom = cy + 8 * u
    top = bottom - 2 * hh
    d.rounded_rectangle((cx - hw, top, cx + hw, bottom), 2.3 * u, fill=KIMI)
    for side in (-1, 1):
        ex, ey = cx + (2.7 + 4.5 * side) * u, top + hh - 2.8 * u * squash
        ew, eh = 1.5 * u, 2.25 * u * eye * squash
        d.rectangle((ex - ew, ey - eh, ex + ew, ey + eh), fill=(255, 255, 255))


def blink(t, period=2.4, offset=0.0):
    cyc = ((t + offset) % period) / period
    return 0.15 if 0.9 < cyc < 0.96 else 1.0


class Film:
    def __init__(self, spec):
        self.spec = spec
        self.ow, self.oh = spec["size"]
        self.w, self.h = self.ow * SS, self.oh * SS
        self.sc = spec["sc"] * SS  # 街景、线宽等装饰元素的缩放
        g = lambda v: tuple(x * SS for x in v)  # noqa: E731
        self.lap_keys = [(0, g(spec["lap_open"])), (2.6, g(spec["lap_open"])), (3.5, g(spec["lap_duo"])),
                         (4.9, g(spec["lap_duo"])), (6.0, g(spec["lap_walk"])), (14.6, g(spec["lap_walk"])),
                         (T_ORBIT, g(spec["lap_orbit"]))]
        self.orbit_c = g(spec["lap_orbit"])[:2]
        self.orbit_r = g(spec["orbit"])
        self.tilt = math.radians(-12)
        self.theta0 = 0.35
        self.ph_orbit_h = spec["ph_orbit_h"] * SS
        ox, oy = self.orbit_point(self.theta0, self.orbit_c, self.orbit_r)
        self.ph_keys = [(2.7, g(spec["ph_off"])), (3.5, g(spec["ph_duo"])), (4.9, g(spec["ph_duo"])),
                        (6.0, g(spec["ph_walk"])), (14.6, g(spec["ph_walk"])), (T_ORBIT, (ox, oy, self.ph_orbit_h))]
        self.ground = spec["ground"] * SS
        self.sun = g(spec["sun"])
        self.bot_c = g(spec["bot"])
        self.bot_u = 11 * SS
        self.word_size, self.word_base = spec["word"][0] * SS, spec["word"][1] * SS
        self.tag_size, self.tag_y = spec["tag"][0] * SS, spec["tag"][1] * SS

        # 手机贴图按主角时的大小画，其它时候缩小
        self.pk = spec["ph_walk"][2] * SS / 864
        pw, phh = round(410 * self.pk), round(864 * self.pk)
        self.phone_mask = Image.new("L", (pw, phh), 0)
        ImageDraw.Draw(self.phone_mask).rounded_rectangle((0, 0, pw - 1, phh - 1), 62 * self.pk, fill=255)

        rng = random.Random(26)
        self.stars = [(rng.random() * self.w, rng.random() * self.h * 0.9, rng.uniform(1.2, 3.2) * SS,
                       rng.uniform(0, 6.28), rng.uniform(1.2, 3.0)) for _ in range(90)]
        # 街景：一串沿地面排开的东西
        kinds = ["tree", "lamp", "building", "tree", "bench", "building", "lamp", "tree", "building"]
        self.props, x = [], self.w * 0.15
        for i in range(60):
            kind = kinds[i % len(kinds)]
            self.props.append(dict(kind=kind, x=x, a=rng.uniform(0.75, 1.25), b=rng.random(),
                                   lit=[rng.random() < 0.45 for _ in range(40)]))
            x += rng.uniform(230, 400) * self.sc + (160 * self.sc if kind == "building" else 0)
        self.bars = [(rng.uniform(40, 150), rng.choice([(110, 116, 128), (110, 116, 128), KIMI, PURPLE, GREEN]),
                      rng.choice([0, 0, 12])) for _ in range(40)]

    # MARK: 环境

    def sky(self, t):
        for (t0, a), (t1, b) in zip(SKY, SKY[1:]):
            if t <= t1:
                return mix(a, b, ease_in_out(phase(t, t0, t1)))
        return NIGHT

    def night(self, t):
        return ease_in_out(phase(t, 12.2, 14.6))

    def draw_world(self, d, t, bg):
        n = self.night(t)
        for x, y, r, ph, sp in self.stars:
            a = n * (0.45 + 0.55 * math.sin(t * sp + ph) ** 2)
            if a > 0.02:
                d.ellipse((x - r, y - r, x + r, y + r), fill=rgba((255, 255, 255), a * 0.85))
        show = ease_out(phase(t, 5.0, 5.9)) * (1 - ease_in_out(phase(t, 14.6, 15.6)))
        if show <= 0:
            return
        sc = self.sc
        # 太阳：慢慢落到地平线下
        sx, sy0 = self.sun
        sy = lerp(sy0, self.ground + 110 * sc, ease_in_out(phase(t, 6.0, 13.2)))
        sa = show * (1 - phase(t, 12.6, 13.4))
        if sa > 0:
            col = mix((255, 206, 96), (255, 138, 92), phase(t, 8.0, 12.5))
            for k, al in ((2.1, 0.10), (1.5, 0.16), (1.0, 1.0)):
                r = 62 * sc * k
                d.ellipse((sx - r, sy - r, sx + r, sy + r), fill=rgba(col, al * sa))
        # 地面：盖住落下去的太阳
        line = mix(mix(bg, (60, 72, 96), 0.26), mix(bg, (255, 255, 255), 0.3), n)
        line = mix(bg, line, show)
        d.rectangle((0, self.ground, self.w, self.h), fill=mix(bg, line, 0.22))
        lw = max(2, round(2.2 * sc))
        d.line((0, self.ground, self.w, self.ground), fill=line, width=lw)
        # 往后退的街景
        tau = t - 5.2
        speed = 400 * sc
        scroll = speed * (max(0.0, tau) - 0.7 * (1 - math.exp(-max(0.0, tau) / 0.7))) if tau > 0 else 0
        glow = (255, 214, 120)
        gy = self.ground
        for P in self.props:
            x = P["x"] - scroll
            if x < -400 * sc or x > self.w + 400 * sc:
                continue
            a = P["a"]
            if P["kind"] == "tree":
                th, r = 64 * sc * a, 40 * sc * a
                d.line((x, gy, x, gy - th), fill=line, width=lw)
                d.ellipse((x - r, gy - th - 2 * r + 6 * sc, x + r, gy - th + 6 * sc), outline=line, width=lw, fill=bg)
            elif P["kind"] == "lamp":
                hgt, arm = 200 * sc, 34 * sc
                d.line((x, gy, x, gy - hgt), fill=line, width=lw)
                d.line((x, gy - hgt, x + arm, gy - hgt), fill=line, width=lw)
                bx, by, r = x + arm, gy - hgt + 9 * sc, 9 * sc
                if n > 0.05:
                    for k, al in ((4.5, 0.10), (2.6, 0.18)):
                        d.ellipse((bx - r * k, by - r * k, bx + r * k, by + r * k), fill=rgba(glow, al * n * show))
                d.ellipse((bx - r, by - r, bx + r, by + r), fill=mix(line, glow, n * show))
            elif P["kind"] == "building":
                bw, bh = (150 + 70 * P["b"]) * sc, (210 + 170 * P["b"]) * sc * a
                d.rectangle((x, gy - bh, x + bw, gy), outline=line, width=lw, fill=bg)
                cols, rows = 3, max(2, int(bh / (58 * sc)))
                cw, ch = bw / (cols * 2 + 1), 22 * sc
                for r_ in range(rows):
                    for c in range(cols):
                        wx, wy = x + cw * (1 + 2 * c), gy - bh + 30 * sc + r_ * 56 * sc
                        if wy + ch > gy - 20 * sc:
                            continue
                        lit = P["lit"][(r_ * cols + c) % 40]
                        fill = mix(bg, glow, n * show * 0.95) if lit else None
                        d.rectangle((wx, wy, wx + cw, wy + ch), outline=line, width=max(1, lw - 1), fill=fill)
            else:  # bench
                bw, sh = 96 * sc, 30 * sc
                d.line((x, gy - sh, x + bw, gy - sh), fill=line, width=lw)
                d.line((x, gy - sh * 2, x + bw, gy - sh * 2), fill=line, width=lw)
                for lx in (x + 10 * sc, x + bw - 10 * sc):
                    d.line((lx, gy, lx, gy - sh * 2), fill=line, width=lw)

    # MARK: 站位

    def lap_pose(self, t):
        return track(self.lap_keys, t)

    def orbit_now(self, t):
        """轨道中心与半径：片尾跟着 bot 收到字标上方，缩成绕着脸转的小轨道。"""
        m = ease_in_out(phase(t, 18.0, 18.9))
        c = (lerp(self.orbit_c[0], self.bot_c[0], m), lerp(self.orbit_c[1], self.bot_c[1], m))
        r = (lerp(self.orbit_r[0], 21.5 * self.bot_u, m), lerp(self.orbit_r[1], 6.5 * self.bot_u, m))
        return c, r

    def orbit_point(self, theta, c, r):
        x, y = r[0] * math.cos(theta), r[1] * math.sin(theta)
        ca, sa = math.cos(self.tilt), math.sin(self.tilt)
        return c[0] + x * ca - y * sa, c[1] + x * sa + y * ca

    def theta(self, t):
        tau = max(0.0, t - T_ORBIT)
        return self.theta0 + 2.1 * (tau - 0.4 * (1 - math.exp(-tau / 0.4)))

    def phone_pose(self, t):
        if t < T_ORBIT:
            x, y, hgt = track(self.ph_keys, t)
            if 5.2 < t < 14.8:  # 走路时轻轻上下晃
                amp = 7 * self.sc * ease_out(phase(t, 5.2, 6.2)) * (1 - phase(t, 14.0, 14.8))
                y += math.sin((t - 5.2) * 2 * math.pi * 1.5) * amp
            return x, y, hgt
        th = self.theta(t)
        c, r = self.orbit_now(t)
        x, y = self.orbit_point(th, c, r)
        shrink = 1 - ease_in_out(phase(t, T_MORPH, T_MORPH + 0.7))
        return x, y, self.ph_orbit_h * (1 + 0.14 * math.sin(th)) * shrink

    def curve(self, a, b, bulge=0.22):
        """连接两点的弧线（二次贝塞尔，往上拱）。"""
        dx, dy = b[0] - a[0], b[1] - a[1]
        dist = math.hypot(dx, dy) or 1
        px, py = dy / dist, -dx / dist
        if py > 0:
            px, py = -px, -py
        m = ((a[0] + b[0]) / 2 + px * dist * bulge, (a[1] + b[1]) / 2 + py * dist * bulge)
        return lambda p: ((1 - p) ** 2 * a[0] + 2 * p * (1 - p) * m[0] + p * p * b[0],
                          (1 - p) ** 2 * a[1] + 2 * p * (1 - p) * m[1] + p * p * b[1])

    def link_ends(self, t, lap, ph):
        """连线的两个端点落在设备可见的边缘上，别从机身下面穿过去。"""
        lx, ly, lw = lap
        px, py, phh = ph
        dx, dy = px - lx, py - ly
        dist = math.hypot(dx, dy) or 1
        ux, uy = dx / dist, dy / dist
        disc = 0.76 * lw * ease_out(phase(t, 4.9, 5.9))
        a = (lx + ux * disc * 0.86, ly + uy * disc * 0.86)
        hw, hh = phh * 410 / 864 / 2, phh / 2
        edge = min(hw / max(abs(ux), 1e-6), hh / max(abs(uy), 1e-6))
        b = (px - ux * edge * 1.02, py - uy * edge * 1.02)
        return a, b

    # MARK: 连线

    def draw_tether(self, d, t, bg, curve):
        reveal = ease_in_out(phase(t, T_JUMP, T_LAND))
        fade = 1 - phase(t, 14.3, 15.0)
        if reveal <= 0 or fade <= 0:
            return
        col = mix(bg, mix((70, 84, 110), (255, 255, 255), self.night(t)), 0.42 * fade)
        r = 3.2 * self.sc
        count = 46
        flow = (t * 0.35) % 1
        for i in range(count):
            p = (i + flow) / count
            if p > reveal:
                continue
            x, y = curve(p)
            d.ellipse((x - r, y - r, x + r, y + r), fill=col)
        for t0, direction in PULSES:
            x = phase(t, t0, t0 + 0.55)
            if 0 < x < 1:
                p = ease_in_out(x)
                p = p if direction > 0 else 1 - p
                cx, cy = curve(p)
                for k, al in ((3.2, 0.16), (2.0, 0.28), (1.0, 1.0)):
                    rr = 8 * self.sc * k
                    d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=rgba(KIMI, al * fade))

    # MARK: 电脑

    def draw_laptop(self, d, t, bg):
        cx, cy, w = self.lap_pose(t)
        body = 1 - ease_in_out(phase(t, T_MORPH, T_MORPH + 0.5))
        s = w / 300 * ease_out_back(phase(t, 0.05, 0.6), 1.2) * body
        if s <= 0.01:
            return
        # 身后的圆盘：出门之后它是一颗「星球」
        da = ease_out(phase(t, 4.9, 5.9))
        if da > 0:
            r = 0.76 * w * body * (0.9 + 0.1 * da)
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=mix(bg, mix(bg, KIMI, lerp(0.13, 0.34, self.night(t))), da))

        def X(v):
            return cx + (v - 150) * s

        def Y(v):
            return cy + (v - 95) * s

        d.rounded_rectangle((X(8), Y(166), X(292), Y(179)), 6 * s, fill=(206, 206, 212))
        d.rounded_rectangle((X(126), Y(166), X(174), Y(170.5)), 2 * s, fill=(168, 168, 174))
        d.rounded_rectangle((X(30), Y(8), X(270), Y(167)), 11 * s, fill=(30, 30, 32), outline=(84, 84, 90),
                            width=max(1, round(1.2 * s)))
        screen = (15, 17, 24)
        d.rounded_rectangle((X(37), Y(15), X(263), Y(160)), 5 * s, fill=screen)

        # 终端：敲命令
        f = mono(15 * s)
        typed = "kimi rc"[:max(0, int((t - 0.7) / 0.12) + 1)] if t >= 0.7 else ""
        d.text((X(50), Y(38)), "$", font=f, fill=GREEN, anchor="lm")
        tx = X(50) + f.getlength("$ ")
        d.text((tx, Y(38)), typed, font=f, fill=(240, 240, 245), anchor="lm")
        if t < T_ENTER and (t * 2.2) % 1 < 0.6:
            cx0 = tx + f.getlength(typed) + 1.5 * s
            d.rectangle((cx0, Y(30), cx0 + 8 * s, Y(46)), fill=(240, 240, 245))
        # bot 走了之后：已连接的小绿点
        if t >= T_LAND:
            a = phase(t, T_LAND, T_LAND + 0.3)
            d.ellipse((X(50), Y(56), X(58), Y(64)), fill=mix(screen, GREEN, a))
            d.rounded_rectangle((X(64), Y(57.5), X(118), Y(62.5)), 2.5 * s, fill=mix(screen, (110, 116, 128), a))
        # 干活时一行行滚出来的输出
        work_fade = 1 - phase(t, 14.4, 14.9)
        if t >= 7.7 and work_fade > 0:
            n1 = min(8, int((t - 7.7) / 0.27) + 1)
            n2 = min(7, int((t - 11.25) / 0.25) + 1) if t >= 11.25 else 0
            total = n1 + n2
            rows = list(range(max(0, total - 6), total))
            dim = lerp(1.0, 0.35, phase(t, T_DONE, T_DONE + 0.3)) * work_fade
            for slot, i in enumerate(rows):
                length, color, indent = self.bars[i]
                y = 76 + slot * 13
                d.rounded_rectangle((X(50 + indent), Y(y), X(50 + indent + length), Y(y + 6)), 3 * s,
                                    fill=mix(screen, color, dim))
            if T_CARD <= t < T_TAP + 0.1:  # 等确认：一小块琥珀色在闪
                y = 76 + len(rows) * 13
                a = 0.45 + 0.55 * abs(math.sin((t - T_CARD) * 4.2))
                d.rounded_rectangle((X(50), Y(y), X(72), Y(y + 6)), 3 * s, fill=mix(screen, AMBER, a))
            p = phase(t, T_DONE, T_DONE + 0.35)
            if p > 0:  # 跑完：绿色对勾
                r = 27 * s * max(0.0, ease_out_back(p)) * work_fade
                ox, oy = X(150), Y(104)
                if r > 1:
                    d.ellipse((ox - r, oy - r, ox + r, oy + r), fill=GREEN)
                    pts = [(ox - 0.45 * r, oy + 0.02 * r), (ox - 0.12 * r, oy + 0.34 * r), (ox + 0.46 * r, oy - 0.3 * r)]
                    d.line(pts, fill=(255, 255, 255), width=max(2, round(0.2 * r)), joint="curve")
        # 屏幕上的脸：敲完命令弹出来，跳走之前一直在
        if T_ENTER < t < T_JUMP:
            u = 3.4 * s * max(0.0, ease_out_back(phase(t, T_ENTER + 0.1, T_ENTER + 0.45)))
            eye = 0.12 if 2.55 < t < 2.67 else 1.0
            draw_face(d, X(150), Y(100), u, eye)

    def home_face(self, t):
        """入夜后回到电脑屏幕上的脸，随后长大成片尾的 bot。返回 (cx, cy, u)。"""
        if t < 15.2:
            return None
        lx, ly, w = self.lap_pose(t)
        ls = w / 300
        pop = max(0.0, ease_out_back(phase(t, 15.2, 15.6)))
        grow = ease_in_out(phase(t, T_MORPH, T_MORPH + 0.6))
        u = lerp(3.4 * ls * pop, self.bot_u, grow)
        m = ease_in_out(phase(t, 18.0, 18.9))
        cx = lerp(lx, self.bot_c[0], m)
        cy = lerp(lerp(ly + 5 * ls, ly, grow), self.bot_c[1], m)
        return cx, cy, u

    # MARK: 手机

    def phone_sprite(self, t):
        k = self.pk
        W, H = self.phone_mask.size
        img = Image.new("RGB", (W, H), (18, 18, 20))
        d = ImageDraw.Draw(img, "RGBA")
        white = (255, 255, 255)

        def X(v):
            return (v + 10) * k

        Y = X

        def rr(x0, y0, x1, y1, r, **kw):
            d.rounded_rectangle((X(x0), Y(y0), X(x1), Y(y1)), r * k, **kw)

        def circle(cx, cy, r, **kw):
            d.ellipse((X(cx) - r * k, Y(cy) - r * k, X(cx) + r * k, Y(cy) + r * k), **kw)

        def text(x, y, s, size, color, index=PF_REGULAR, anchor="lm", alpha=1.0, font=None):
            d.text((X(x), Y(y)), s, font=font or pf(size * k, index), fill=rgba(color, alpha), anchor=anchor)

        def line(pts, color, width):
            d.line([(X(x), Y(y)) for x, y in pts], fill=color, width=max(1, round(width * k)), joint="curve")

        d.rounded_rectangle((0, 0, W - 1, H - 1), 62 * k, fill=(18, 18, 20), outline=(96, 96, 104),
                            width=max(2, round(1.3 * k)))
        rr(0, 0, 390, 844, 52, fill=white)
        rr(140, 13, 250, 46, 16.5, fill=(0, 0, 0))
        d.text((X(56), Y(30)), "9:41", font=sfw(16 * k, 600), fill=INK, anchor="mm")
        # 顶栏：菜单；上下文环 + 文件夹
        chip = (242, 242, 247)
        circle(36, 86, 20, fill=chip)
        for dy in (-5, 0, 5):
            line([(28, 86 + dy), (44, 86 + dy)], INK, 1.7)
        rr(300, 66, 374, 106, 20, fill=chip)
        circle(321, 86, 8.5, outline=(199, 199, 204), width=max(1, round(2.2 * k)))
        used = lerp(18, 96, ease_in_out(phase(t, T_SEND, T_DONE)))
        d.arc((X(321) - 8.5 * k, Y(86) - 8.5 * k, X(321) + 8.5 * k, Y(86) + 8.5 * k), -90, -90 + used, fill=KIMI,
              width=max(1, round(2.2 * k)))
        rr(344, 79, 362, 93, 3, outline=INK, width=max(1, round(1.6 * k)))
        line([(344, 82), (344, 78), (351, 78), (353, 80.5)], INK, 1.6)

        # 输入卡片
        rr(12, 712, 378, 824, 28, fill=(247, 247, 248), outline=(232, 232, 236), width=max(1, round(k)))
        typed = PROMPT[:max(0, int((t - T_TYPE) / 0.16) + 1)] if T_TYPE <= t < T_SEND else ""
        f16 = pf(16 * k)
        if typed:
            text(30, 744, typed, 16, INK)
        elif t < T_TYPE or t >= T_SEND:
            text(30, 744, "让 Kimi 做点什么…", 16, (174, 174, 178))
        if T_TYPE - 0.5 <= t < T_SEND and (t * 2) % 1 < 0.6:
            cx0 = X(30) + f16.getlength(typed) + 1.5 * k
            d.rectangle((cx0, Y(734), cx0 + 2 * k, Y(754)), fill=KIMI)
        circle(40, 794, 17, fill=(236, 236, 240))
        line([(33, 794), (47, 794)], INK, 1.8)
        line([(40, 787), (40, 801)], INK, 1.8)
        circle(82, 794, 17, fill=(236, 236, 240))
        d.polygon([(X(x), Y(y)) for x, y in ((84.5, 785), (77, 795.5), (81.5, 795.5), (79.5, 803), (87, 792.5), (82.5, 792.5))],
                  fill=INK)
        f15 = pf(15 * k)
        text(320, 794, "High", 15, GRAY, anchor="rm")
        d.text((X(320) - f15.getlength(" High"), Y(794)), "K3", font=pf(15 * k, PF_MEDIUM), fill=INK, anchor="rm")
        busy = T_SEND <= t < T_DONE + 0.1
        press = phase(t, T_SEND - 0.14, T_SEND - 0.04) * (1 - phase(t, T_SEND - 0.04, T_SEND + 0.12))
        r = 17 * (1 - 0.16 * press)
        circle(350, 794, r, fill=INK if busy else KIMI)
        if busy:
            rr(345, 789, 355, 799, 2, fill=white)
        else:
            line([(350, 801.5), (350, 787)], white, 2.2)
            line([(343.5, 793), (350, 786.5), (356.5, 793)], white, 2.2)

        # 对话
        if t >= T_SEND:
            a = ease_out(phase(t, T_SEND, T_SEND + 0.3))
            lift = (1 - a) * 26
            fm = pf(16 * k, PF_MEDIUM)
            bw = fm.getlength(PROMPT) / k + 34
            rr(374 - bw, 124 + lift, 374, 166 + lift, 21, fill=rgba((245, 245, 245), a))
            text(374 - bw / 2, 145 + lift, PROMPT, 16, INK, PF_MEDIUM, "mm", a)

        def row(y, s, t0, color=GRAY, x=20, size=14.5, index=PF_REGULAR):
            a = ease_out(phase(t, t0, t0 + 0.3))
            if a > 0:
                text(x, y + (1 - a) * 10, s, size, color, index, alpha=a)

        if t >= T_SEND + 0.5:
            if t < T_THOUGHT:
                dots = "·" * (1 + int((t - T_SEND) / 0.3) % 3)
                row(198, "思考中 " + dots, T_SEND + 0.5, x=54)
            else:
                row(198, "已思考 2 秒", T_THOUGHT - 0.3, x=54)
        row(228, "读取了 3 个文件", T_ROW2)
        if t < T_CARD_OUT + 0.1:
            row(258, "运行了 1 条命令", T_ROW3)
        else:
            row(258, "运行了 2 条命令", T_CARD_OUT - 0.2)

        # 确认卡片
        ca = ease_out(phase(t, T_CARD, T_CARD + 0.3)) * (1 - ease_in_out(phase(t, T_CARD_OUT, T_CARD_OUT + 0.25)))
        if ca > 0:
            pop = ease_out_back(phase(t, T_CARD, T_CARD + 0.35), 1.4)
            oy = (1 - pop) * 28
            for grow, al in ((10, 0.025), (6, 0.035), (3, 0.045)):
                rr(16 - grow, 286 + oy - grow + 5, 374 + grow, 424 + oy + grow + 5, 22 + grow, fill=(20, 30, 60, round(255 * al * ca)))
            rr(16, 286 + oy, 374, 424 + oy, 22, fill=rgba(white, ca), outline=rgba((229, 229, 234), ca), width=max(1, round(k)))
            rr(32, 303 + oy, 54, 321 + oy, 5, fill=rgba(INK, ca))
            line([(37, 308 + oy), (41.5, 312 + oy), (37, 316 + oy)], rgba(white, ca), 1.6)
            line([(44, 316.5 + oy), (49, 316.5 + oy)], rgba(white, ca), 1.6)
            text(64, 312 + oy, "运行命令", 15.5, INK, PF_SEMIBOLD, alpha=ca)
            rr(30, 332 + oy, 360, 366 + oy, 9, fill=rgba((244, 244, 247), ca))
            text(42, 349 + oy, "xcodebuild test", 14, INK, alpha=ca, font=mono(13.5 * k))
            hit = phase(t, T_TAP, T_TAP + 0.06) * (1 - phase(t, T_TAP + 0.1, T_TAP + 0.22))
            rr(30, 376 + oy, 190, 412 + oy, 18, fill=rgba((236, 236, 240), ca))
            text(110, 394 + oy, "拒绝", 15, INK, PF_MEDIUM, "mm", ca)
            rr(200, 376 + oy, 360, 412 + oy, 18, fill=rgba(mix(KIMI, (10, 80, 170), hit * 0.6), ca))
            text(280, 394 + oy, "允许", 15, white, PF_MEDIUM, "mm", ca)

        # 回答
        if t >= T_ANSWER:
            shown = ANSWER[:max(0, int((t - T_ANSWER) / 0.07) + 1)]
            text(20, 300, shown, 16.5, INK)
        p = phase(t, T_DONE, T_DONE + 0.35)
        if p > 0:
            a = clamp(p * 2)
            s = max(0.01, ease_out_back(p))
            circle(30, 336, 10 * s, fill=rgba(GREEN, a))
            line([(25.5, 336.2), (28.8, 339.5), (34.8, 332.6)], rgba(white, a), 1.9)
            text(48, 336, "12 项测试全部通过", 15.5, (36, 160, 70), PF_MEDIUM, alpha=a)

        # bot：落进手机 → 发出消息后缩成对话里的小标记
        if t >= T_LAND:
            m = ease_in_out(phase(t, T_SEND, T_SEND + 0.55))
            bx, by, bu = lerp(195, 33, m), lerp(400, 198, m), lerp(4.6, 0.92, m)
            land = phase(t, T_LAND, T_LAND + 0.45)
            squash = 1 - 0.3 * math.exp(-land * 5) * math.cos(land * 13) if land < 1 else 1.0
            hop = phase(t, T_DONE, T_DONE + 0.4)
            by -= 9 * math.sin(hop * math.pi) if 0 < hop < 1 else 0
            eye = 0.15 if 0 < hop < 1 else blink(t, 2.4, 0.9)
            draw_face(d, X(bx), Y(by), bu * k, eye, squash)

        # 手指：点「允许」
        fa = phase(t, T_TAP - 0.75, T_TAP - 0.5) * (1 - phase(t, T_TAP + 0.3, T_TAP + 0.6))
        if fa > 0:
            m = ease_in_out(phase(t, T_TAP - 0.7, T_TAP - 0.1))
            fx, fy = lerp(330, 286, m), lerp(600, 400, m)
            down = phase(t, T_TAP - 0.05, T_TAP + 0.03) * (1 - phase(t, T_TAP + 0.12, T_TAP + 0.25))
            ring = phase(t, T_TAP, T_TAP + 0.4)
            if 0 < ring < 1:
                r = lerp(18, 46, ease_out(ring))
                circle(280, 394, r, outline=rgba(KIMI, (1 - ring) * 0.7), width=max(1, round(2.5 * k)))
            r = 21 * (1 - 0.18 * down)
            circle(fx, fy, r, fill=(60, 60, 70, round(95 * fa)), outline=(255, 255, 255, round(210 * fa)),
                   width=max(1, round(2 * k)))

        img.putalpha(self.phone_mask)
        return img

    def paste_phone(self, canvas, sprite, x, y, hgt):
        if hgt < 6:
            return
        w = hgt * sprite.width / sprite.height
        img = sprite.resize((max(1, round(w)), max(1, round(hgt))), Image.LANCZOS)
        canvas.paste(img, (round(x - img.width / 2), round(y - img.height / 2)), img)

    # MARK: 片尾

    def draw_orbit(self, d, t, bg, front):
        a = ease_out(phase(t, 15.5, 16.3)) * lerp(1.0, 0.7, phase(t, 18.0, 18.9))
        if a <= 0:
            return
        c, r = self.orbit_now(t)
        col = mix(bg, (255, 255, 255), 0.36 * a)
        steps = 80
        start = 0 if front else math.pi
        pts = [self.orbit_point(start + math.pi * i / steps, c, r) for i in range(steps + 1)]
        d.line(pts, fill=col, width=max(2, round(1.6 * self.sc)), joint="curve")

    def draw_moon(self, d, t):
        p = phase(t, T_MORPH + 0.25, T_MORPH + 0.8)
        if p <= 0:
            return
        c, r = self.orbit_now(t)
        th = self.theta(t)
        x, y = self.orbit_point(th, c, r)
        rad = 1.75 * self.bot_u * max(0.0, ease_out_back(p)) * (1 + 0.14 * math.sin(th))
        for k, al in ((2.6, 0.10), (1.7, 0.18)):
            d.ellipse((x - rad * k, y - rad * k, x + rad * k, y + rad * k), fill=(255, 244, 214, round(255 * al)))
        d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=(255, 246, 222))

    def draw_lockup(self, d, t):
        if t < T_WORD:
            return
        f = sfw(self.word_size, 860)
        word = "Moon Code"
        x = self.w / 2 - f.getlength(word) / 2
        for i, ch in enumerate(word):
            p = phase(t, T_WORD + i * 0.06, T_WORD + i * 0.06 + 0.32)
            if ch != " " and p > 0:
                rise = (1 - ease_out_back(p, 2.2)) * self.word_size * 0.35
                col = KIMI if i < 4 else (255, 255, 255)
                d.text((x + f.getlength(word[:i]), self.word_base + rise), ch, font=f, fill=rgba(col, clamp(p * 2.2)),
                       anchor="ls")
        a = ease_out(phase(t, T_WORD + 0.9, T_WORD + 1.4))
        if a > 0:
            d.text((self.w / 2, self.tag_y + (1 - a) * 24 * SS), "KimiCode 的远程控制客户端",
                   font=pf(self.tag_size, PF_MEDIUM), fill=rgba((255, 255, 255), a * 0.82), anchor="mm")

    # MARK: 合成

    def frame(self, t):
        bg = self.sky(t)
        canvas = Image.new("RGB", (self.w, self.h), bg)
        d = ImageDraw.Draw(canvas, "RGBA")
        self.draw_world(d, t, bg)

        lap = self.lap_pose(t)
        ph_pose = self.phone_pose(t)
        px, py, ph = ph_pose
        a, b = self.link_ends(t, lap, ph_pose)
        curve = self.curve(a, b, 0.3)
        orbiting = t >= T_ORBIT
        behind = orbiting and math.sin(self.theta(t)) < 0
        sprite = self.phone_sprite(min(t, T_ORBIT)) if t >= 2.7 and ph >= 6 else None

        self.draw_orbit(d, t, bg, front=False)
        if behind:
            if sprite:
                self.paste_phone(canvas, sprite, px, py, ph)
            self.draw_moon(d, t)
        self.draw_tether(d, t, bg, curve)
        self.draw_laptop(d, t, bg)
        home = self.home_face(t)
        if home:
            draw_face(d, home[0], home[1], home[2], blink(t, 2.4, 0.3))
        self.draw_orbit(d, t, bg, front=True)
        if not behind:
            if sprite:
                self.paste_phone(canvas, sprite, px, py, ph)
            self.draw_moon(d, t)

        # bot 从电脑屏幕蹦进手机：沿着那条连线飞
        if T_JUMP <= t < T_LAND:
            p = ease_in_out(phase(t, T_JUMP, T_LAND))
            x, y = self.curve((lap[0], lap[1]), (px, py))(p)
            u = lerp(3.4 * lap[2] / 300, 4.6 * ph / 864, p)
            stretch = 1 + 0.22 * math.sin(p * math.pi)
            draw_face(d, x, y + 8 * u * (stretch - 1), u, 1.0, stretch)
        self.draw_lockup(d, t)
        return canvas.reduce(SS)


_film = None


def _init(name):
    global _film
    _film = Film(LAYOUTS[name])


def _render(t):
    return _film.frame(t).tobytes()


def main():
    args = sys.argv[1:]
    fps = int(args[args.index("--fps") + 1]) if "--fps" in args else 60
    only = args[args.index("--only") + 1] if "--only" in args else None
    still = (float(args[args.index("--frame") + 1]), args[args.index("--frame") + 2]) if "--frame" in args else None
    skip = set()
    for flag, n in (("--fps", 1), ("--only", 1), ("--frame", 2)):
        if flag in args:
            i = args.index(flag)
            skip.update(range(i, i + n + 1))
    positional = [a for i, a in enumerate(args) if i not in skip]
    out_dir = Path(positional[0]) if positional else ROOT / "marketing/video"
    out_dir.mkdir(parents=True, exist_ok=True)

    for name, spec in LAYOUTS.items():
        if only and name != only:
            continue
        w, h = spec["size"]
        if still:
            Film(spec).frame(still[0]).save(still[1])
            continue
        out = out_dir / f"promo-{name}-{w}x{h}.mp4"
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(fps), "-i", "-",
            "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "17",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", str(out),
        ]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        with Pool(initializer=_init, initargs=(name,)) as pool:
            for data in pool.imap(_render, [i / fps for i in range(round(DURATION * fps))], chunksize=4):
                proc.stdin.write(data)
        proc.stdin.close()
        proc.wait()
        Film(spec).frame(DURATION - 0.1).save(out_dir / f"promo-{name}-{w}x{h}.png", optimize=True)
        print("wrote", out, flush=True)


if __name__ == "__main__":
    main()
