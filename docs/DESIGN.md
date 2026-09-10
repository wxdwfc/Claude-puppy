# 它是怎么工作的

README 只说它做什么,这份文档说它为什么这么做 —— 主要是几个走过弯路才定下来的选择。

- [状态是从哪来的](#状态是从哪来的)
- [Stop hook 干的那件事](#stop-hook-干的那件事)
- [park 到后台的那一轮](#park-到后台的那一轮)
- [跳回 iTerm2](#跳回-iterm2)
- [省电](#省电)
- [边界与已知的坑](#边界与已知的坑)
- [配图和内置美术](#配图和内置美术)
- [没做进 v1](#没做进-v1)

## 状态是从哪来的

Claude Code CLI 自己维护一份实时注册表:`~/.claude/sessions/<pid>.json`,每个运行中的
CLI 进程一个文件,进程退出文件就没了。Puppy 只读这个,**不碰** `~/.claude/projects/`
下的 transcript(那些能有十几 MB)。

注册表里没有「完成」这个状态,Puppy 自己推导:**status 是 `idle`、而且刚变成 `idle`
(`statusUpdatedAt` 在 60s 内)= 一轮任务刚跑完**;刚开出来的新 session 也是 idle,
但它的 `statusUpdatedAt` 紧贴 `startedAt`,据此摘掉。这是唯一推导出来的状态,其余全部直读文件。

早先是 diff 出 `busy → idle` 这条边来判定的,漏一次事件就永远补不回来 —— 而一轮任务收尾在
`waiting → idle`(答完权限询问那一下就结束了)非常常见,于是「有时候跑完了不冒气泡」。
改成只看文件字段的无状态判定后,漏事件、app 重启、pid 复用都不再影响结论。

同一个道理决定了气泡栈的语义。它是**当前状态的直接映射**,不是一串会过期的通知:

```
栈 ≡ { session | 在等你 } ∪ { session | 刚跑完(60 秒内) }
```

因为是集合而不是事件流,三个 session 同时等你就是三条,不轮播、不排队、不互相覆盖;
你在那个终端敲了回车,那一条自己消失。没有「已读」按钮,所以不可能出现「关掉了但其实忘了处理」。

session 跑完顺手退出 claude 也没关系:完成记录只按时间窗淘汰,不跟着进程走。

## Stop hook 干的那件事

注册表只说得出「现在是什么状态」,说不出「刚才那轮做完了什么」—— 那句话只在 CLI
进程内存里。唯一的出口是 Claude Code 的 `Stop` hook,它的 payload 带着
`last_assistant_message`。

装上之后(`make hook`),每轮任务收尾时 Claude Code 会拉起 `~/.puppy/bin/puppy --hook`,
它把回答的第一段提炼成一句话,写到 `~/.puppy/events/<session-id>.json`。Puppy 用第二个
FSEvents 监听那个目录,按 `sessionId` 配到对应的行上。**新开的 session 才生效**,已经开着的要重启。

几个刻意的选择:

- **`async: true`。** 少了这个,Claude 每次说完话都要等这个进程退出才算收尾 ——
  为一句气泡文案拖慢真正的工作,不值。
- **hook 那一端永远 exit 0、永远不写 stdout/stderr。** 它挂在别人每一轮任务的收尾上,
  一只桌面宠物的装饰功能没资格在那儿打印错误。
- **命令指向 `~/.puppy/bin/puppy` 这份拷贝**,不是 `.build/` 里的那个。否则
  `make clean` 一下,每个 session 每一轮都会去执行一个不存在的文件。`make app` 会
  顺手刷新这份拷贝(没装过就不动)。

**为什么状态判定不搬过来用 hook。** 试过就知道这是个坑:

- hook 是**边沿触发**的,而栈的语义是个集合 —— 电平量。app 没开、重启、hook 失败,
  任何一次丢失都变成永久错误状态。注册表则是「现在是什么」,冷启动就是对的。
  上面那段 `busy → idle` 的教训就是同一个坑。
- hook 的 payload 里**没有 pid**(官方文档明说)。而这个 app 从列表行到 iTerm 跳转
  全是 pid 寻址的,还得回去读注册表才能还原。
- 延迟也不是瓶颈:hook 到 app 之间总得走一次 IPC,最省事的 IPC 就是写文件到被监听的
  目录 —— 绕回原地,只是中间多插一次 fork/exec。

所以 hook 只干注册表干不了的那一件事,**并且被关在纯装饰层里**:摘要配不上
(没装 hook / 没赶上 / 时间戳对不上 `noteSlop`)就退回「跑完了」,状态永远不受影响。

## park 到后台的那一轮

Ctrl-B 把一轮任务丢到后台之后,CLI 就**不再更新这个 session 的文件了** ——
`status` 会永久冻结在 park 那一刻的 `busy`,直到你下次在这个终端里敲字。
只读这一个文件的话,活早干完了它还显示「运行中」。

真实状态在替它干活的那个进程身上:park 的一方留下 `parkedJobId`,接手的 bg session
带着同名的 `jobId`。所以 Puppy 整个目录读完、认全 `jobId`,再把 bg 那边的
`status` / `waitingFor` / `statusUpdatedAt` 整套镜像到 owner 那一行上。
bg session 自己**不进列表**(它没有终端,点了也无处可跳),它只是 owner 那一行的真身。

镜像过来之后,parked 的活跑完照样冒「刚完成」,卡在等权限照样让小狗跳起来。
找不到对应的 bg 记录 = 那个进程已经退出 = 活必然结束了,按空闲算;
时间戳仍旧留在 park 那一刻,免得凭空冒出一个假的「刚完成」。

## 跳回 iTerm2

链路是 `pid → ps -o tty= → iTerm2 AppleScript 里匹配 session 的 tty`。
tmux / ssh / 非 iTerm 终端里的 session 拿不到匹配的 tty,这时候只把 iTerm 提到前台。

第一次点某个 session 行时系统会弹一次 Automation 授权。如果误点了拒绝,
Puppy 会把你送到「系统设置 → 隐私与安全性 → 自动化」。

## 省电

这是个 24 小时挂在桌面上的窗口,所以一律事件驱动,不轮询:

- **FSEvents** 监听 `~/.claude/sessions/`(装了 hook 的话还有 `~/.puppy/events/`),
  `latency=0.3s` 让内核合并连续写入。回调不解析事件内容,只当作「该重扫了」——
  目录里全是几百字节的小 JSON,整个重读是幂等的,原子写 / rename / 事件合并这些
  边缘情况因此全都不用管。
- 只监听 `sessions/` 这一层。FSEvents 是递归的,往上监听 `~/.claude` 会把
  transcript 的疯狂写入变成唤醒风暴。
- 30s 低频兜底重扫,配大 leeway 让系统能把唤醒合并掉。
- 「完成」徽标和庆祝动画的到期时刻各排一发**一次性**定时器,不是每秒轮询。
- 列表里「已等待 X 分钟」的 1s 时钟只在面板打开时存在;气泡上的「已等 40m」是
  分钟级的,免得为一行文字养一个 1Hz 时钟。
- 吉祥物窗口被完全遮挡时停掉动画。
- 吉祥物动画由 Core Animation 播,进程不逐帧参与。

实测:全空闲时 **0% CPU**;有 session 在跑、它在动时约 3%(和帧率无关,
是 SwiftUI 动画循环的固定开销)。

## 边界与已知的坑

- **注册表 schema 没有文档**(`peerProtocol:1`),可能随 CLI 版本漂移。所以解码全字段
  Optional、未知 status 降级成中性态、单个文件坏掉不影响其余、目录不存在就显示
  「无 session」。已经见过计划里没列的 `shell` 状态。
- 文件被截断重写的瞬间可能读不出来。这时短暂沿用上一次的好数据(3s),否则列表会闪
  一下 —— 这是实测踩到的。
- nonactivating panel 永远拿不到键盘焦点,所以面板是纯点击交互。
- 某个皮肤读不了只会跳过它并在 stderr 说明原因,不会连累整只宠物起不来;缺哪个状态
  就退回 `sleeping`。

## 配图和内置美术

README 那张图是 `make shot` **离屏渲**出来的,不是截屏:摆进画布的就是真的
`BubbleStackView` / `SessionListView` / 皮肤的某一帧,坐标照抄两个 panel 的 `layout()`,
所以它跟真窗口逐点一致 —— 既不用 Screen Recording 授权,也不会把桌面上碰巧开着的
东西拍进去,换台机器还能重跑。

编译进二进制的兜底像素形象出自 `scripts/gen-sprites.py`,按「行区间 + 自动描边」算出来,
不是一格格手抠的;默认那套矢量贴图出自 `scripts/gen-cartoon.py`。改造型去改那两个
脚本 —— 描边、五官裁剪、左右对称在那边是自动保证的。

## 没做进 v1

开机自启(`SMAppService`)、基于 Claude Code hooks 的推送更新
(hooks 通道目前只用来送那一句摘要,如果哪天注册表 schema 变了,它是更稳的契约)。
