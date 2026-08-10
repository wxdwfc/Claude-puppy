#!/usr/bin/env python3
"""32×32 皮卡丘精灵生成器 —— Sprites.swift 里那几坨字符位图的来源。

轮廓在这里是按「行区间 + 自动描边」算出来的,不是一格一格手抠的:改脑袋宽一格
只要动 head 里的一行数字,描边、五官裁剪、左右对称会自己跟上。手改 Swift 里
那 32 行字符串的话,这些约束全得靠眼睛盯。

    python3 scripts/gen-sprites.py /tmp/out     # 出 base.png 和九个姿势的对比图 sheet.png

造型调满意了再生成 Swift:每个姿势都对着 base 求一次差,只输出变了的行。
输出的 `base` / 各姿势补丁贴回 Sources/Puppy/UI/Sprites.swift 对应的位置。
注意补丁之间**不能叠加**(脸蛋和嘴共用 y17–y19),所以像「张嘴 + 笑眼」这种组合
在 POSES 里就得先合成好,而不是在 Swift 里 pose(a, b)。
"""
import struct, zlib, sys

S = 32
PAL = {
    'K': (28, 24, 20),      # 描边 / 眼睛 / 耳尖
    'Y': (252, 206, 62),    # 皮卡丘黄
    'O': (226, 158, 26),    # 黄的暗部
    'R': (232, 66, 60),     # 脸蛋红
    'r': (255, 92, 62),     # 脸蛋放电时的亮红 —— 只提亮度不掉饱和,掉了就成粉的
    'W': (255, 255, 255),   # 眼里的反光 / 放大镜的高光
    'B': (156, 96, 32),     # 尾巴根的褐色
    'T': (236, 118, 130),   # 舌头
    'G': (176, 170, 164),   # 侦探帽的暖灰 —— 电影里是人字呢,取个中间调
    'g': (122, 114, 108),   # 帽檐的深灰,也当帽身上的呢子斑点
    'L': (190, 222, 238),   # 放大镜的镜片蓝
}

# ---- 轮廓(填充区,描边由 outline() 自动吃掉最外一圈)-----------------------
#
# 走 chibi 比例 —— 「圆鼓鼓」不是把某一块画胖,是整套比例都要换:
#   脑袋 19 宽 × 15 高,占身高一半(第一版只占四成,读出来是「站着的老鼠」);
#   脑袋横着比竖着宽,才是圆的,不是鹅蛋的;
#   身子 17 宽 × 7 高,宽度追到脑袋的九成 —— 差得多就有脖子,有脖子就不是玩偶;
#   腿收成 3 行小短脚,只从身子底下露一点。第一版是 15 宽的身子配 7 宽 3 行的长脚,
#   两条腿之间还空着 3 格,那个缝是「腿长」的主要来源。
#
# 角色中轴 x=12(比第一版又左移一格),镜像关系是 a + b == 24。
# 左移是给尾巴腾地方:身子从 15 宽涨到 17 宽,右边留给闪电尾的就只剩 x21 往后了。
EAR_TIP_ROWS = 5   # 耳尖涂黑的行数 —— 这是「是皮卡丘」最强的一个信号,少一行都发虚
AXIS = 24          # 镜像:x -> AXIS - x

def spans():
    g = {}
    def add(y, a, b):
        g.setdefault(y, []).append((a, b))
    def sym(rows):
        for y, a, b in rows:
            add(y, a, b); add(y, AXIS-b, AXIS-a)

    # 耳朵 y0-y10,7 格宽 —— 描边吃掉两侧后里头还剩 5 格黄。
    # 拉到 11 行、并且明显往外斜:配 15 行的大脑袋,9 行的短耳朵读成两只猫耳,
    # 「长耳朵斜着支出去」这个剪影本身就是皮卡丘一半的辨识度。
    # 顶上那一行收成 3 格,尖才是尖的 —— 拉平 5 格顶到 y0 的时候,耳朵读成
    # 两根从画布上沿伸进来的黑棍子。左沿也从 x0 退到 x1,给描边留出站的地方。
    ear = [(0,2,4),(1,1,5),(2,1,5),(3,1,6),(4,1,6),(5,2,7),
           (6,2,7),(7,3,8),(8,3,8),(9,4,9),(10,4,9)]
    sym(ear)

    # 脑袋 y9-y23,19 宽 × 15 高。行宽一律取奇数,让 a + b == 24。
    # 上半张脸的收口要比「画个圆」更快张开:耳根落在 y9-y10,那两行的轮廓宽度
    # 是耳朵给的(x4-x20)。脑袋自己在 y11 只走到 x5-x19 的话,剪影会在耳根正下方
    # 凹进去一格,像被掐了一下 —— 所以 y11 直接撑到和耳根同宽。
    head = [(9,8,16),(10,6,18),(11,4,20),(12,3,21),(13,3,21),(14,3,21),(15,3,21),
            (16,3,21),(17,3,21),(18,3,21),(19,3,21),(20,4,20),(21,5,19),
            (22,6,18),(23,8,16)]
    for y,a,b in head: add(y,a,b)

    # 身子 y24-y28,17 宽 × 5 高。脑袋往下挪之后身子只剩 5 行 —— 正好,
    # 又矮又宽的一块比之前 7 行的更像个坐着的团子。
    body = [(24,5,19),(25,4,20),(26,4,20),(27,4,20),(28,6,18)]
    for y,a,b in body: add(y,a,b)

    # 小短脚:两只之间只留 3 格缝
    sym([(29,5,10),(30,5,10),(31,6,9)])

    # 闪电尾:细杆从身子右下往右上走,y17-y19 往左甩出一面旗 = 折角,再收成尖。
    # 起点压到 y27 那么低,是为了从手臂下面绕出去 —— 身子变宽以后,右边同一段高度
    # 已经被身子和手臂占满,尾巴只能从下面起。
    # 杆和旗都要够粗:描边会从四面各吃掉一格,4 格宽的杆只剩 2 格芯,
    # 一路下来读成一根描了边的细管子,不是一道闪电。旗给到 9 格、杆给到 5 格。
    # 左沿分三级往外张(27 → 25 → 23),右沿在 y19→y20 一口气从 x31 收到 x29,
    # 这一步台阶就是「闪电」的全部 —— 脑袋占到 x21,左边再想甩得更开也没地方了。
    #
    # 根部压到 y27-y28 并且**压进身子里两三格**,不是挨着放。挨着放的时候两边
    # 各自描一圈边,中间那条双黑边在 96pt 下直接读成一道缝,尾巴像是飘在旁边的。
    tail = [(14,27,31),(15,27,31),(16,25,31),(17,25,31),
            (18,23,31),(19,23,31),
            (20,23,29),(21,23,28),(22,23,27),(23,23,27),
            (24,22,26),(25,22,26),(26,22,26),(27,20,24),(28,18,22)]
    for y,a,b in tail: add(y,a,b)
    brown = {(y,x) for y,a,b in tail[-2:] for x in range(a,b+1)}
    tips = {(y,x) for y,a,b in ear if y < EAR_TIP_ROWS
            for x in list(range(a,b+1)) + list(range(AXIS-b, AXIS-a+1))}
    return g, brown, tips


def build_fill():
    g, brown, tips = spans()
    grid = [['.'] * S for _ in range(S)]
    for y, runs in g.items():
        for a, b in runs:
            for x in range(a, b + 1):
                if 0 <= x < S and 0 <= y < S:
                    grid[y][x] = 'Y'
    return grid, brown, tips


def outline(grid):
    """填充区最外一圈换成描边色 —— 黄底加黑边,压在任何壁纸上都读得出。"""
    out = [row[:] for row in grid]
    for y in range(S):
        for x in range(S):
            if grid[y][x] == '.':
                continue
            for dy, dx in ((1,0),(-1,0),(0,1),(0,-1)):
                ny, nx = y+dy, x+dx
                if not (0 <= ny < S and 0 <= nx < S) or grid[ny][nx] == '.':
                    out[y][x] = 'K'
                    break
    return out


def stamp(grid, cells, ch, mask_to_body=True, body=None):
    for y, x in cells:
        if not (0 <= x < S and 0 <= y < S):
            continue
        if mask_to_body and body[y][x] == '.':
            continue
        grid[y][x] = ch


def blob(y0, x0, w, h, cut_corners=True):
    """圆角矩形:四角削掉一格,低分辨率下才读得出是圆的。"""
    cells = []
    for dy in range(h):
        for dx in range(w):
            if cut_corners and dy in (0, h-1) and dx in (0, w-1):
                continue
            cells.append((y0+dy, x0+dx))
    return cells


# ---- 五官 -----------------------------------------------------------------
# 五官分两层排,不并排:眼睛在上、脸蛋在下且更靠外,纵向完全错开。
#
# 眼睛涨到 5×5 并且压低到脑袋的下半部(脑袋 y7-y21,眼睛落在 y12-y16)。
# 大脑门 + 低眼位 + 大眼睛是最讨喜的三件套,少哪件都会显得「精明」而不是「憨」。
EYE_W, EYE_H = 5, 5
EYE_Y = 14
EYE_LX, EYE_RX = 5, 15          # 镜像:24-9=15 ✓
CHEEK_Y = 19
# 脸蛋比第一版往里挪一格。贴着 x4 画的时候,下面两行正好撞上收窄的下颌,
# 被裁成两道贴边的红丝 —— 圆脸的代价就是靠边的东西没地方站。
CHEEK_LX, CHEEK_RX = 5, 16      # 镜像:24-8=16 ✓
NOSE_Y, NOSE_X = 19, 12         # 鼻子就一格,3 格宽的鼻子会跟嘴糊成一个吻部黑块
MOUTH_Y = 21

# 手臂只在身子里画一段内描边,不去顶轮廓。
# 试过在轮廓上鼓两个小包:身子已经宽到 x20,右边留给闪电尾的通道只剩一格,
# 鼓包一出来就和尾巴连上了;而且「圆鼓鼓」要的就是一条干净的圆边,鼓两个包正好反着来。
# 离轮廓要留两格:贴一格画的话,这道弧会和身子的描边并成一条粗边,等于白画。
ARM_L = [(24,7), (25,6), (26,6), (27,7)]


# ---- 侦探三件套(照着电影版:灰呢帽 + 皱眉 + 放大镜)---------------------------
# 三样都直接盖在成品上,不走 mask —— 帽子和放大镜本来就该压在轮廓外/身体前。
# 帽子不能用 outline() 自动描边:帽檐一共两行,上下沿一描,整条帽檐就全黑了,
# 所以这几行是手抠的。帽身 y5-y9 收成圆顶,y10 外扩一圈 + y11 换深灰 = 帽檐,
# 「比帽身宽出一截再压一档暗」两个信号叠在一起,两行也读得出是檐。
# 帽子盖掉耳根(y9-y11),耳朵只从帽子两侧露出尖 —— 电影里正是这个关系,
# 而且黑耳尖整段保住了,辨识度不掉。
def stamp_cap(grid):
    grid[4][12] = 'K'                                    # 顶上的小扣子
    for x in range(10, 15): grid[5][x] = 'K'             # 圆顶的上沿
    crown = [(6,9,15), (7,8,16), (8,7,17), (9,6,18), (10,4,20)]
    for y, a, b in crown:
        grid[y][a] = 'K'; grid[y][b] = 'K'
        for x in range(a+1, b): grid[y][x] = 'G'
    grid[11][3] = 'K'; grid[11][21] = 'K'
    for x in range(4, 21): grid[11][x] = 'g'             # 帽檐:压一档暗
    for y, x in ((7,11), (8,14), (9,9)):                 # 呢子的斑点,故意不对称
        grid[y][x] = 'g'


# 皱眉:外高内低的两小段斜杠,搭在眼睛正上方。电影版皮卡丘的「严肃脸」主要就是
# 这两道眉 —— 眼睛照旧用 5×5 的憨版,凶一分是侦探,凶两分就成反派了。
# 眉毛不跟着 lookLeft/lookRight 的 dx 走,和脸蛋同理:长在脸上不动的东西。
BROWS = [(12,5), (12,6), (13,7), (13,8),
         (12,18), (12,19), (13,16), (13,17)]


# 放大镜端在身前左下,镜柄横着接到左手的弧上 —— 照片里就是这个拿法。
# 整只画在 x0-x6 的空地上:下巴(y23 收到 x8)和身子(x5 起)的左边正好空出一块,
# 镜圈整个落在透明背景上,镜片的蓝才有对比。第一版把镜圈举到脸旁(y17-y21),
# 圈的右半压在脸的左沿上,和脸的描边并成一体,整只镜子只剩一粒白点。
# 镜片里给一格反光,不给的话 3×3 的纯蓝块像贴了片创可贴。
# 镜柄用尾巴根的褐色,不用黑:柄的落点(y23-y24, x5-x7)四邻全是黑 ——
# 镜圈的右沿、身子的描边、手臂的弧 —— 黑柄画上去就融进这坨黑里,
# 镜圈立刻读成「粘在身上的球」。褐柄从黑块里跳出来,「圈 + 柄」才成立。
def stamp_glass(grid):
    ring = [(21,1),(21,2),(21,3),(22,0),(22,4),(23,0),(23,4),
            (24,0),(24,4),(25,1),(25,2),(25,3)]
    for y, x in ring: grid[y][x] = 'K'
    for y in range(22, 25):
        for x in range(1, 4): grid[y][x] = 'L'
    grid[22][1] = 'W'
    for y, x in ((23,5),(23,6)):                         # 镜柄,末端接到 (24,7) 的手
        grid[y][x] = 'B'


def eyes_normal(dx=0):
    # 反光给到 2×2。一格的反光在 5×5 的眼睛里太小,读不出「亮」,只像脏了一点。
    cells, hi = [], []
    for bx in (EYE_LX + dx, EYE_RX + dx):
        cells += blob(EYE_Y, bx, EYE_W, EYE_H)
        hi += [(EYE_Y+1, bx+1), (EYE_Y+1, bx+2), (EYE_Y+2, bx+1)]
    return cells, hi


def eyes_wide():
    """瞪眼:吃掉反光 + 往下长一格,是最扎眼的状态。
    只能往下长,而且上沿的角必须照旧削掉 —— 眼睛左右各只离脑袋的描边一格,
    一旦把角补满,眼珠就和侧脸的描边连成一条横杠,远看是「戴了个眼罩」而不是瞪眼。"""
    cells = []
    for bx in (EYE_LX, EYE_RX):
        cells += [(EYE_Y, bx+1), (EYE_Y, bx+2)]
        for dy in range(1, EYE_H + 1):
            cells += [(EYE_Y+dy, bx+dx) for dx in range(EYE_W)]
    return cells, []


def eyes_closed():
    cells = []
    for bx in (EYE_LX, EYE_RX):
        cells += [(EYE_Y+3, bx+i) for i in range(EYE_W)]
        cells += [(EYE_Y+2, bx), (EYE_Y+2, bx+EYE_W-1)]
    return cells, []


def eyes_happy():
    """`^ ^`。5 格宽的眼睛可以画出真正的尖角,不再是两道折线。"""
    cells = []
    for bx in (EYE_LX, EYE_RX):
        cells += [(EYE_Y+3, bx), (EYE_Y+2, bx+1), (EYE_Y+1, bx+2),
                  (EYE_Y+2, bx+3), (EYE_Y+3, bx+4)]
    return cells, []


def mouth_closed(dx=0):
    """`w` 形嘴:三个尖 + 两个谷,中间那个尖正对鼻子下方。"""
    y = MOUTH_Y
    return [(y, 9+dx), (y, 12+dx), (y, 15+dx),
            (y+1, 10+dx), (y+1, 11+dx), (y+1, 13+dx), (y+1, 14+dx)]


def mouth_open():
    """张嘴:在鼻子下面另开一块,不动鼻子 —— 挨着画会糊成一坨黑。"""
    ring = blob(MOUTH_Y - 1, 9, 7, 4)
    inner = [(y, x) for y in range(MOUTH_Y, MOUTH_Y+2) for x in range(10, 15)]
    tongue = [(MOUTH_Y+1, x) for x in range(11, 14)]
    return ring, inner, tongue


def cheeks(bright=False, big=False):
    ch = 'r' if bright else 'R'
    w = 5 if big else 4
    cells = []
    for bx in (CHEEK_LX - (1 if big else 0), CHEEK_RX):
        cells += blob(CHEEK_Y - (1 if big else 0), bx, w, w)
    return cells, ch


def compose(eye='normal', mouth='closed', cheek_bright=False, cheek_big=False, dx=0):
    fill, brown, tips = build_fill()
    body = [row[:] for row in fill]
    grid = outline(fill)
    for y, x in brown:
        if grid[y][x] == 'Y':
            grid[y][x] = 'B'
    for y, x in tips:            # 耳尖整块涂黑,连描边一起
        grid[y][x] = 'K'

    # 肚子和脚面压一档暗黄,不然整只是一块平黄
    for y in range(26, 29):
        for x in range(S):
            if grid[y][x] == 'Y' and y >= 27:
                grid[y][x] = 'O'
    for y in (30,):
        for x in range(S):
            if grid[y][x] == 'Y':
                grid[y][x] = 'O'

    # 手臂:身子两侧各一段内描边,画成向外弯的弧,读成两只揣着的小手。
    # 第一版是两条笔直的竖线,在圆身子上直接读成桶箍。
    for y, x in ARM_L:
        for xx in (x, AXIS - x):
            if grid[y][xx] in 'YO':
                grid[y][xx] = 'K'

    cheek_cells, cheek_ch = cheeks(cheek_bright, cheek_big)
    stamp(grid, cheek_cells, cheek_ch, body=body)

    if eye == 'normal':
        cells, hi = eyes_normal(dx)
    elif eye == 'wide':
        cells, hi = eyes_wide()
    elif eye == 'closed':
        cells, hi = eyes_closed()
    else:
        cells, hi = eyes_happy()
    stamp(grid, cells, 'K', body=body)
    stamp(grid, hi, 'W', body=body)

    stamp(grid, [(NOSE_Y, NOSE_X + dx)], 'K', body=body)

    if mouth == 'open':
        ring, inner, tongue = mouth_open()
        stamp(grid, ring, 'K', body=body)
        stamp(grid, inner, 'K', body=body)
        stamp(grid, tongue, 'T', body=body)
    else:
        stamp(grid, mouth_closed(dx), 'K', body=body)

    stamp_cap(grid)
    for y, x in BROWS:
        grid[y][x] = 'K'
    stamp_glass(grid)

    return [''.join(r) for r in grid]


# ---- 输出 -----------------------------------------------------------------
def png(rows, path, scale=10):
    w = h = S * scale
    raw = b''
    for y in range(h):
        line = b'\x00'
        for x in range(w):
            c = rows[y // scale][x // scale]
            if c in PAL:
                r, g, b = PAL[c]; line += bytes((r, g, b, 255))
            else:
                line += b'\x00\x00\x00\x00'
        raw += line
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))
    open(path, 'wb').write(data)


def sheet(variants, path, scale=8):
    """把多个姿势横排成一张对比图。"""
    n = len(variants)
    w, h = S * scale * n, S * scale
    raw = b''
    for y in range(h):
        line = b'\x00'
        for x in range(w):
            rows = variants[x // (S * scale)]
            c = rows[y // scale][(x % (S * scale)) // scale]
            if c in PAL:
                r, g, b = PAL[c]; line += bytes((r, g, b, 255))
            else:
                line += b'\x2e\x2e\x32\xff'
        raw += line
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))
    open(path, 'wb').write(data)


POSES = {
    'base':        dict(),
    'closed':      dict(eye='closed'),
    'happy':       dict(eye='happy'),
    'wide':        dict(eye='wide'),
    'lookLeft':    dict(dx=-1),
    'lookRight':   dict(dx=1),
    'open':        dict(mouth='open'),
    'openHappy':   dict(mouth='open', eye='happy'),
    'spark':       dict(eye='wide', cheek_bright=True, cheek_big=True),
}

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    base = compose()
    png(base, f'{out}/base.png')
    sheet([compose(**POSES[k]) for k in POSES], f'{out}/sheet.png')
    # 直接吐 Swift 语法:base 全量 + 每个姿势对 base 的行 diff,贴回 Sprites.swift。
    print('    private static let base: [String] = [')
    for line in base:
        print(f'        "{line}",')
    print('    ]')
    for name, kw in POSES.items():
        if name == 'base':
            continue
        rows = compose(**kw)
        diff = [(i, r) for i, (r, b) in enumerate(zip(rows, base)) if r != b]
        print(f'    private static let {name}: [Int: String] = [')
        for i, r in diff:
            print(f'        {i}: "{r}",')
        print('    ]')
