#!/usr/bin/env python3
"""卡通风侦探皮卡丘皮肤生成器。

矢量图元(椭圆 / 贝塞尔 / 描边)在 4 倍超采样画布上画,再 LANCZOS 缩到 256,
边缘自带抗锯齿 —— 配合 skin.json 里的 "smooth": true,视图端走平滑插值。

和 gen-sprites.py 的关系:那边产的是内置像素版的字符位图,这边直接产
`~/.puppy/skins/cartoon/` 的成品磁盘皮肤(帧条 PNG + skin.json)。
改造型 = 改这里的参数重跑,`puppy --render <dir> --skin cartoon` 目视检查。

角色还是那只侦探皮卡丘:圆滚滚 chibi 比例 + 灰呢帽 + 皱眉 + 端在身前的放大镜,
黑尖耳 / 红脸蛋 / 闪电尾三个辨识信号照搬像素版的调色板。
"""

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

CELL = 256          # 一格边长(最终输出)
SS = 4              # 超采样倍数
N = CELL * SS       # 工作画布边长
GROUND = 252        # 脚底所在的 y —— 挤压拉伸都以这条线为锚,跳起来脚才不滑

# 调色板照搬像素版(Sprites.swift 的 Palette),两套皮肤才是同一只皮卡丘。
K = (28, 24, 20)        # 描边 / 眼睛 / 耳尖
Y = (252, 206, 62)      # 皮卡丘黄
O = (226, 158, 26)      # 黄的暗部
R = (232, 66, 60)       # 脸蛋红
r_ = (255, 92, 62)      # 放电时的亮红
W = (255, 255, 255)
B = (156, 96, 32)       # 尾巴根 / 镜柄的褐色
T = (236, 118, 130)     # 舌头
G = (176, 170, 164)     # 侦探帽暖灰
g_ = (122, 114, 108)    # 帽檐深灰 / 呢子斑点
L = (190, 222, 238)     # 镜片蓝

OUTLINE = 3.6           # 描边宽度(256 空间)


# ---------------------------------------------------------------- 几何小工具

def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(round(lerp(a, b, t)) for a, b in zip(c1, c2))


def rot(pts, cx, cy, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return [(cx + (x - cx) * ca - (y - cy) * sa,
             cy + (x - cx) * sa + (y - cy) * ca) for x, y in pts]


def bez(p0, p1, p2, n=24):
    """二次贝塞尔摊平成折线。"""
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                    u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
    return out


def ellipse_pts(cx, cy, rx, ry, a0=0.0, a1=360.0, n=64):
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
            for i in range(n + 1)]


class Canvas:
    """带全局「挤压拉伸」变换的画布。

    squash 以 GROUND 为锚:落地帧横向压扁、腾空帧纵向拉长,脚底始终贴地 ——
    卡通弹跳的那口气全在这一下。所有图元统一过这个变换,身体各部件才不会散架。
    """

    def __init__(self, sx=1.0, sy=1.0):
        self.img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        self.draw = ImageDraw.Draw(self.img)
        self.sx, self.sy = sx, sy

    def t(self, p):
        x, y = p
        return ((128 + (x - 128) * self.sx) * SS,
                (GROUND - (GROUND - y) * self.sy) * SS)

    def poly(self, pts, fill, outline=K, width=OUTLINE):
        q = [self.t(p) for p in pts]
        self.draw.polygon(q, fill=fill)
        if outline:
            self.stroke_raw(q + [q[0]], outline, width)

    def ellipse(self, cx, cy, rx, ry, fill, outline=K, width=OUTLINE):
        self.poly(ellipse_pts(cx, cy, rx, ry), fill, outline, width)

    def stroke(self, pts, color, width):
        self.stroke_raw([self.t(p) for p in pts], color, width)

    def stroke_raw(self, q, color, width):
        w = max(1, round(width * SS))
        self.draw.line(q, fill=color, width=w, joint="curve")
        rr = w / 2
        for p in (q[0], q[-1]):   # 圆头端帽,不然粗线两端是平茬
            self.draw.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=color)

    def clipped_poly(self, clip_pts, pts, fill):
        """只在 clip 形状内部上色 —— 耳朵的黑尖、镜片的高光都靠它。"""
        mask = Image.new("L", (N, N), 0)
        ImageDraw.Draw(mask).polygon([self.t(p) for p in clip_pts], fill=255)
        layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon([self.t(p) for p in pts], fill=fill)
        self.img.paste(layer, (0, 0), Image.composite(layer.split()[3], mask, mask).point(lambda v: v))
        # 上一行等价于「layer 的 alpha ∧ mask」:先把 mask 外的 alpha 归零再贴。

    def finish(self):
        return self.img.resize((CELL, CELL), Image.LANCZOS)


# ---------------------------------------------------------------- 身体部件
#
# 坐标全在 256 空间、对称轴 x=128。分层顺序:尾巴 → 脚 → 身子 → 头 → 耳朵 →
# 帽子 → 五官 → 脸蛋 → 手臂和放大镜。后画的盖前画的,放大镜永远在最前面。

def draw_tail(c: Canvas, wag=0.0):
    """右侧闪电尾。wag 是绕根部的摆动角(度)。"""
    base = (176, 214)
    bolt = [(182, 220), (208, 194), (197, 188), (222, 158), (211, 152),
            (238, 112), (250, 120), (234, 158), (244, 164), (219, 198),
            (229, 204), (194, 238), (181, 230)]
    root = [(166, 212), (186, 204), (194, 224), (176, 232)]
    if wag:
        bolt = rot(bolt, *base, wag)
        root = rot(root, *base, wag * 0.4)
    c.poly(root, B)
    c.poly(bolt, Y)


def draw_feet(c: Canvas):
    for cx in (98, 158):
        c.ellipse(cx, 243, 21, 9, O)


def draw_body(c: Canvas):
    c.ellipse(128, 206, 64, 44, Y)
    # 肚子下沿的暗部:一弯月牙,贴着轮廓内侧
    c.clipped_poly(ellipse_pts(128, 206, 64, 44),
                   ellipse_pts(128, 236, 54, 20), O)
    # 右手:身子里一段向外弯的弧,不顶轮廓(圆鼓鼓要的就是一条干净的圆边)
    c.stroke(bez((146, 198), (162, 202), (166, 214)), O, 4)


def draw_head(c: Canvas, dy=0.0):
    c.ellipse(128, 138 + dy, 76, 60, Y)


def ear_shape(side, droop=0.0):
    """side=-1 左耳 / +1 右耳。droop 往外倒的角度(睡觉时耷拉)。"""
    def m(p):
        return (256 - p[0], p[1]) if side > 0 else p
    base_out, base_in, tip = m((62, 108)), m((98, 82)), m((30, 16))
    ctrl_out = m((30, 66))     # 外沿弧的控制点:往外鼓
    ctrl_in = m((72, 40))      # 内沿弧:稍直
    pts = bez(base_out, ctrl_out, tip) + bez(tip, ctrl_in, base_in)
    if droop:
        pts = rot(pts, *m((80, 95)), -droop if side > 0 else droop)
    return pts


def draw_ear(c: Canvas, side, droop=0.0):
    pts = ear_shape(side, droop)
    c.poly(pts, Y)
    # 黑尖:耳朵形状内、靠尖端 42% 的那一段
    tip_i = len(pts) // 2          # 贝塞尔拼接处正是耳尖
    tip = pts[tip_i]
    base_mid = ((pts[0][0] + pts[-1][0]) / 2, (pts[0][1] + pts[-1][1]) / 2)
    cut = 0.42
    px = lerp(tip[0], base_mid[0], cut)
    py = lerp(tip[1], base_mid[1], cut)
    dx, dy = base_mid[0] - tip[0], base_mid[1] - tip[1]
    nx, ny = -dy, dx               # 切割线方向 = 耳轴的法线
    half = [(px + nx, py + ny), (px - nx, py - ny),
            (tip[0] - nx * 2, tip[1] - ny * 2), (tip[0] + nx * 2, tip[1] + ny * 2)]
    c.clipped_poly(pts, half, K)


def draw_hat(c: Canvas):
    dome = ellipse_pts(128, 104, 64, 42, 180, 360) + [(192, 104), (64, 104)]
    c.poly(dome, G)
    c.ellipse(128, 106, 76, 14, G)                     # 帽檐
    c.stroke(ellipse_pts(128, 106, 76, 14, 200, 340), g_, 3)   # 檐口压一道深灰
    for cx, cy, rr in ((104, 82, 4), (140, 74, 3.5), (122, 92, 3), (152, 90, 4)):
        c.ellipse(cx, cy, rr, rr, g_, outline=None)    # 呢子斑点


def draw_brows(c: Canvas, raise_=0.0):
    """皱眉:外高内低。raise_ 往上抬(瞪眼时)。"""
    c.stroke([(82, 128 - raise_), (108, 136 - raise_)], K, 5)
    c.stroke([(174, 128 - raise_), (148, 136 - raise_)], K, 5)


def draw_eyes(c: Canvas, mode="normal", dx=0.0, scale=1.0):
    for ex in (100, 156):
        cx, cy = ex + dx, 154
        if mode == "closed":
            c.stroke(bez((cx - 11, cy - 2), (cx, cy + 7), (cx + 11, cy - 2)), K, 5)
        elif mode == "happy":
            c.stroke(bez((cx - 11, cy + 3), (cx, cy - 9), (cx + 11, cy + 3)), K, 5)
        else:
            rr = 13 * scale
            c.ellipse(cx, cy, rr, rr, K, outline=None)
            c.ellipse(cx - rr * 0.32, cy - rr * 0.35, rr * 0.34, rr * 0.34, W, outline=None)
            c.ellipse(cx + rr * 0.22, cy + rr * 0.3, rr * 0.15, rr * 0.15, W, outline=None)


def draw_nose(c: Canvas, dx=0.0):
    c.poly([(124 + dx, 150), (132 + dx, 150), (128 + dx, 155)], K, outline=None)


def draw_mouth(c: Canvas, mode="w", dx=0.0):
    if mode == "open":
        c.poly(ellipse_pts(128 + dx, 174, 14, 11), K, outline=None)
        c.clipped_poly(ellipse_pts(128 + dx, 174, 14, 11),
                       ellipse_pts(128 + dx, 182, 10, 8), T)
    else:   # 小小的 w 嘴
        c.stroke(bez((117 + dx, 166), (122.5 + dx, 172), (128 + dx, 167)), K, 4)
        c.stroke(bez((128 + dx, 167), (133.5 + dx, 172), (139 + dx, 166)), K, 4)


def draw_cheeks(c: Canvas, glow=0.0):
    """glow 0~1:放电程度。涨大一圈并提亮,再冒两撮小电花。"""
    rr = 14 + 4 * glow
    color = mix(R, r_, glow)
    for cx in (72, 184):
        c.ellipse(cx, 178, rr, rr, color, outline=None)
    if glow > 0.55:
        for pts in ([(52, 166), (44, 158), (50, 152)], [(204, 166), (212, 158), (206, 152)],
                    [(58, 192), (48, 196), (52, 202)], [(198, 192), (208, 196), (204, 202)]):
            c.stroke(pts, r_, 3)


def draw_glass(c: Canvas):
    """左手端在身前的放大镜:镜柄斜伸向左脚边,褐色厚框,镜片一弯小高光。"""
    c.stroke_raw([c.t((84, 231)), c.t((97, 247))], K, OUTLINE * 2 + 8)   # 柄的黑描边
    c.stroke([(84, 231), (97, 247)], B, 8)                               # 褐柄
    c.ellipse(70, 216, 23, 23, B)                      # 褐框(带黑描边)
    c.ellipse(70, 216, 16, 16, L, outline=None)        # 镜片
    c.clipped_poly(ellipse_pts(70, 216, 16, 16),
                   rot(ellipse_pts(62, 209, 9, 4.5), 62, 209, -40), W)   # 高光月牙
    c.stroke(bez((104, 198), (94, 202), (92, 210)), O, 4)                # 左手臂弧


# ---------------------------------------------------------------- 每状态一套帧

def phase(k, n):
    return 2 * math.pi * k / n


def frame(sx=1.0, sy=1.0, *, wag=0.0, droop=0.0, brow_raise=0.0,
          eyes=("normal", 0.0, 1.0), mouth=("w", 0.0), face_dx=0.0,
          cheek_glow=0.0, hat=True):
    c = Canvas(sx, sy)
    draw_tail(c, wag)
    draw_feet(c)
    draw_body(c)
    draw_head(c)
    draw_ear(c, -1, droop)
    draw_ear(c, +1, droop)
    if hat:
        draw_hat(c)
    draw_brows(c, brow_raise)
    mode, edx, esc = eyes
    draw_eyes(c, mode, edx + face_dx, esc)
    draw_nose(c, face_dx)
    draw_mouth(c, mouth[0], mouth[1] + face_dx)
    draw_cheeks(c, cheek_glow)
    draw_glass(c)
    return c.finish()


def gen_sleeping(n=8):
    """闭眼呼吸:纵向 3% 的起伏,耳朵跟着轻轻耷拉。z 走 skin.json 的气泡。"""
    frames, offsets = [], []
    for k in range(n):
        s = math.sin(phase(k, n))
        frames.append(frame(1 - 0.018 * s, 1 + 0.028 * s,
                            droop=4 + 2 * s, eyes=("closed", 0, 1)))
        offsets.append(0.0)
    return frames, offsets, dict(fps=6, bubble="z", bubbleColor="#a6a6a6")


def gen_working(n=8):
    """左顾右盼 + 轻微起伏 + 尾巴慢摇。眼睛(带鼻子嘴)平滑地扫过去再扫回来。"""
    frames, offsets = [], []
    for k in range(n):
        s = math.sin(phase(k, n))
        frames.append(frame(wag=6 * math.sin(phase(k, n) + 1.2),
                            face_dx=8 * s))
        offsets.append(-4 * (0.5 - 0.5 * math.cos(2 * phase(k, n))))
    return frames, offsets, dict(fps=8)


def gen_alert(n=8):
    """瞪眼 + 脸蛋噼啪闪 + 蹦跳。腾空拉长、落地压扁,电花在跳到最高点时炸开。"""
    frames, offsets = [], []
    for k in range(n):
        hop = max(0.0, math.sin(phase(k, n)))     # 前半周期腾空,后半蹲在地上蓄力
        squash = 1 - 0.06 * (1 - hop) if k in (0, 4, 5, 6, 7) else 1 + 0.05 * hop
        frames.append(frame(1 / squash ** 0.5, squash,
                            wag=10 * math.sin(phase(k, n) * 2),
                            brow_raise=5, eyes=("normal", 0, 1.28),
                            cheek_glow=hop))
        offsets.append(-20 * hop)
    return frames, offsets, dict(fps=10, bubble="!", bubbleColor="#f2594d")


def gen_celebrating(n=8):
    """笑成 ^ ^ + 张嘴吐舌 + 蹦跶。和 alert 同款弹跳,幅度小一号、没有电花。"""
    frames, offsets = [], []
    for k in range(n):
        hop = abs(math.sin(phase(k, n)))
        squash = 1 + 0.05 * hop if math.sin(phase(k, n)) >= 0 else 1 - 0.04 * hop
        frames.append(frame(1 / squash ** 0.5, squash,
                            wag=12 * math.sin(phase(k, n)),
                            eyes=("happy", 0, 1), mouth=("open", 0)))
        offsets.append(-14 * abs(math.sin(phase(k, n))))
    return frames, offsets, dict(fps=10, bubble="✓", bubbleColor="#4cc773")


# ---------------------------------------------------------------- 拼帧条 + 落盘

def main():
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else Path.home() / ".puppy/skins/cartoon"
    out.mkdir(parents=True, exist_ok=True)

    states = {
        "sleeping": gen_sleeping(),
        "working": gen_working(),
        "alert": gen_alert(),
        "celebrating": gen_celebrating(),
    }

    manifest_states = {}
    for name, (frames, offsets, spec) in states.items():
        strip = Image.new("RGBA", (CELL * len(frames), CELL), (0, 0, 0, 0))
        for i, f in enumerate(frames):
            strip.paste(f, (i * CELL, 0))
        strip.save(out / f"{name}.png")
        manifest_states[name] = {"yOffsets": [round(v, 2) for v in offsets], **spec}

    manifest = {
        "name": "卡通侦探皮卡丘",
        "cell": CELL,
        "smooth": True,
        "headRow": 152,               # 眼睛那一行:气泡尾巴要对着脸说话
        "bubbleCells": [70, 160],     # 两耳之间的头顶空地
        "badgeCell": 238,             # 右耳尖再往外 —— 卡通版的耳朵比像素版张得开
        "states": manifest_states,
    }
    (out / "skin.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已生成 {out}(4 状态 × 8 帧,256px)")


if __name__ == "__main__":
    main()
