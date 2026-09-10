# 自己画一只

Puppy 对形象没有任何预设:app 只认四个状态,画成什么样由皮肤说了算。往 `~/.puppy/skins/` 里丢一个目录,**右键 → 形象**里就会列出来
(每次拉开菜单都重扫,不用重启)。

## 最省事的做法:照着默认那套改

```bash
./.build/debug/Puppy --export-skin ~/.puppy/skins/my-cat   # 导出默认形象作模板
./.build/debug/Puppy --skins                               # 列出所有皮肤(读不了的会说原因)
./.build/debug/Puppy --render /tmp/px --skin my-cat        # 装上去之前先渲出来看
```

菜单里的「导出内置皮肤作模板…」是同一件事。

## 目录长这样

```
~/.puppy/skins/my-cat/
  skin.json
  sleeping.png       ← 帧条:宽 = 格子边长 × 帧数,高 = 格子边长
  working.png
  alert.png
  celebrating.png
```

帧横着拼成一条,而不是一帧一个文件 —— 帧数由图的宽度决定,不用在 json 里再报一遍,
也就不会出现「json 说 4 帧、目录里只有 3 个」这种对不上的情况。

缺哪个状态就退回 `sleeping`;某个皮肤读不了只会跳过它并在 stderr 说明原因,
不会连累整只宠物起不来。

## skin.json

```jsonc
{
  "name": "我的猫",
  "cell": 32,            // 一格的像素边长,帧条的高必须正好等于它
  "smooth": false,       // true = 平滑插值缩放(高分辨率卡通图用),缺省硬边像素
  "headRow": 16,         // 气泡尾巴对准的行:指向眼睛,不是窗口正中
  "bubbleCells": [7, 17],// 状态气泡摊在头顶的哪一段(挑一块空着的地方)
  "badgeCell": 25,       // ✓ 徽标的落点,要和气泡分开,两个会同时出现
  "states": {
    "sleeping":    { "fps": 1, "yOffsets": [0, 1],        "bubble": "z", "bubbleColor": "#a6a6a6" },
    "working":     { "fps": 5, "yOffsets": [-1, 0, -1, 0] },
    "alert":       { "fps": 4, "yOffsets": [-2, 1],       "bubble": "!", "bubbleColor": "#f2594c" },
    "celebrating": { "fps": 6, "yOffsets": [-2, 0],       "bubble": "✓", "bubbleColor": "#4cc773" }
  }
}
```

`yOffsets` 与帧一一对应,单位是**格**不是点 —— 起伏和跳动都靠它,所以换成 48 格的
美术时幅度会自己跟着放大。取整数格:半格会让放大后的像素行一会儿 3pt 一会儿 4pt,
边缘就毛了。画布上下各只有 8pt 余量,别跳过头。

## 默认那只是生成出来的

`make skin`(`make run` 会顺手跑)用 `scripts/gen-cartoon.py` 把矢量绘制的默认形象
(256 格 × 每状态 8 帧,平滑缩放)生成到 `~/.puppy/skins/cartoon/`,没手动选过
形象时就用这套。生成不了(要 Pillow)或目录被删,就退回编译进二进制的像素版。
改造型去改那个脚本重跑。
