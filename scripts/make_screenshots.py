#!/usr/bin/env python3
"""App Store 宣传图：把模拟器原始截图套上设备边框，配蓝底大标题。

用法：python3 scripts/make_screenshots.py <原始截图目录> <输出目录>
原始截图用体验模式在模拟器里拍（xcrun simctl io <udid> screenshot xxx.png），文件名见下方 SHOTS。
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

PINGFANG = (
    "/System/Library/AssetsV2/com_apple_MobileAsset_Font7/"
    "3419f2a427639ad8c8e139149a287865a90fa17e.asset/AssetData/PingFang.ttc"
)
SC_SEMIBOLD = 11

# 纯色蓝底：App 的 AccentColor 浅色值 (23, 131, 255) 掺 15% 白，稍淡一些；白字标题
KIMI = (58, 150, 255)
TITLE = (255, 255, 255)

# (原始截图文件名, 标题)
SHOTS = {
    "iphone": [
        ("chat.png", "随时随地 指挥 Agent"),
        ("devices.png", "多台电脑 一手掌握"),
        ("model.png", "多款模型 随心切换"),
        ("thinking.png", "思考强度 一拉到顶"),
        ("usage.png", "上下文与用量 一目了然"),
        ("files.png", "项目文件 随手翻看"),
        ("welcome.png", "桌面端、CLI 都能接入"),
    ],
}
SHOTS["ipad"] = SHOTS["iphone"]

# 输出名 → 用哪组原始截图、画布尺寸（App Store Connect 要求）、设备屏幕在画布里的宽度、
# 屏幕圆角（按原始截图像素）、标题字号
DEVICES = {
    # iPhone 6.5 英寸栏
    "iphone": dict(raw="iphone", canvas=(1284, 2778), screen_w=984, corner=168, bezel=26, title=107),
    # iPhone 6.1 / 6.3 英寸栏（只收 1206×2622 或 1179×2556）
    "iphone-6.3": dict(raw="iphone", canvas=(1206, 2622), screen_w=924, corner=168, bezel=24, title=100),
    # iPad 13 英寸栏
    "ipad": dict(raw="ipad", canvas=(2064, 2752), screen_w=1584, corner=72, bezel=40, title=132),
}


def font(size, index):
    return ImageFont.truetype(PINGFANG, size, index=index)


def background(size):
    return Image.new("RGB", size, KIMI)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def hide_resize_grip(shot):
    """iPadOS 26 模拟器截图右下角带窗口缩放把手，用旁边的底色盖掉。"""
    shot = shot.convert("RGB")
    w, h = shot.size
    # 逐行取把手左边的底色往右延，保留输入框阴影的渐变，不留方块
    draw = ImageDraw.Draw(shot)
    for y in range(h - 58, h):
        draw.line((w - 66, y, w, y), fill=shot.getpixel((w - 70, y)))
    return shot


def framed(shot, screen_w, corner, bezel):
    scale = screen_w / shot.width
    screen = shot.convert("RGB").resize((screen_w, round(shot.height * scale)), Image.LANCZOS)
    r = round(corner * scale)
    w, h = screen.width + bezel * 2, screen.height + bezel * 2
    frame = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, w - 1, h - 1), r + bezel, fill=(18, 18, 20, 255))
    # 边框外沿一圈细高光，像金属中框
    ImageDraw.Draw(frame).rounded_rectangle(
        (1, 1, w - 2, h - 2), r + bezel - 1, outline=(90, 90, 96, 255), width=3
    )
    frame.paste(screen, (bezel, bezel), rounded_mask(screen.size, r))
    return frame


def compose(kind, raw_dir, out_dir):
    spec = DEVICES[kind]
    cw, ch = spec["canvas"]
    title_font = font(spec["title"], SC_SEMIBOLD)
    for i, (name, title) in enumerate(SHOTS[spec["raw"]], 1):
        canvas = background((cw, ch)).convert("RGBA")
        draw = ImageDraw.Draw(canvas)
        title_y = round(ch * 0.075)
        # 苹方最粗就是 Semibold；别用描边假加粗，笔画端头会变圆、发糊
        draw.text((cw / 2, title_y), title, font=title_font, fill=TITLE, anchor="mt")

        shot = Image.open(raw_dir / name)
        if spec["raw"] == "ipad":
            shot = hide_resize_grip(shot)
        device = framed(shot, spec["screen_w"], spec["corner"], spec["bezel"])
        x = (cw - device.width) // 2
        y = title_y + title_font.size + round(ch * 0.045)
        # 阴影
        shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            (x, y + 30, x + device.width, y + device.height + 30), 180, fill=(0, 30, 90, 110)
        )
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(50)))
        canvas.alpha_composite(device, (x, y))

        out = out_dir / f"{kind}-{i}.png"
        canvas.convert("RGB").save(out)
        print(out, canvas.size, "device bottom", y + device.height)


def main():
    raw_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for kind, spec in DEVICES.items():
        if (raw_dir / spec["raw"]).is_dir():
            compose(kind, raw_dir / spec["raw"], out_dir)


if __name__ == "__main__":
    main()
