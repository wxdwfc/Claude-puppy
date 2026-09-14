# Codex CLI 接入

Puppy 支持 iTerm2 中的本地交互式 Codex CLI，包括 `codex`、`codex resume` 和
`codex fork`。与 Claude session 共用列表、气泡、动画和 PID → tty → iTerm 跳转。
已核对 Codex CLI 0.154.0 的 hooks 功能；旧版若没有这些事件，需要先升级。

## 安装

```sh
make codex-hook
make run
```

安装器将可执行文件复制到 `~/.puppy/bin/puppy-codex`，并合并
`$CODEX_HOME/hooks.json`（默认 `~/.codex/hooks.json`）。已有配置会先备份为
`hooks.json.puppy-<UUID>.bak`，其他 hooks 和未知字段会保留。重复安装不会添加重复项。

在 Codex 的 `/hooks` 中审阅并信任 Puppy 的命令，然后新开或恢复 CLI 会话。
Codex 自己管理 hook 信任；Puppy 不修改信任记录，不启用跳过信任或跳过审批的选项。
已经打开但没有运行这些 hooks 的会话不会自动补入。

```sh
make list          # 来源标记为 [Claude] / [Codex]
make watch         # 观察状态变化
make codex-unhook  # 只移除 Puppy 自己的 Codex hook 命令
```

卸载后重启仍在运行的 Codex CLI，使其停止使用内存中的旧配置。
后续 `make app` 会更新已经安装的 hook 二进制。

## 数据来源

使用 Codex 的[生命周期 hooks](https://learn.chatgpt.com/docs/hooks)，不读取历史对话、
Codex 私有数据库、桌面 IPC 或终端屏幕。每个 hook 无输出并退出 0，不返回审批决定。
同步执行并设置 1 秒超时，避免异步 hook 乱序；每次只更新一个很小的状态文件。

| 事件 | Puppy 状态 |
|---|---|
| SessionStart | 新会话空闲；已有会话的 compact 事件保持原状态 |
| UserPromptSubmit | 运行中，记录主线程 turn ID |
| PermissionRequest | 审批请求 |
| PreToolUse(request_user_input) | 等待输入（限走此 hook 路径的工具） |
| PostToolUse | 清除相同工具输入对应的等待记录 |
| Stop | 刚完成，保存一行回答摘要 |
| Interrupt | 已中断，不冒完成气泡 |
| SessionEnd / 进程退出 | 从列表移除 |

状态保存在 `~/.puppy/codex-sessions/<pid>.json`。文件锁串行化并行工具的更新，
原子替换避免半写；FSEvents 触发刷新，沿用 30 秒进程存活兜底。
同时核对 PID 和进程启动时间，避免 PID 重用把旧会话认成新会话。
仅通过 hook 的祖先进程定位本地 CLI；没有终端或属于 headless 命令的事件不入列。
不同 turn 的工具和完成事件不会覆盖当前主线程状态。

## 精度和范围

- **审批通过没有独立 hook。** 审批气泡可能一直保留到对应工具返回。
  若其他 hook 自动批准，Puppy 也可能短暂显示审批请求。
  因此 Codex 的等待状态是 hook 观察值，不等同于 Claude 的实时注册表。
- 审批请求没有统一的工具调用 ID，使用工具名和输入摘要匹配结束事件。
  参数被其他 hook 改写、特殊工具未触发结束 hook 等情况，可能要等整轮结束才能清除等待。
- `Stop` 之后其他 hook 仍可要求继续；后续提交事件会恢复运行状态，期间可能短暂显示完成。
- 未触发 hook 的异常、模型错误或失去连接可能留下上次状态，直到下一次事件或 CLI 退出。
  Puppy 重启可以恢复已落盘的状态，但无法补回 Codex 没有投递的事件。
- 桌面版、`codex exec`、远程 `--remote`、共享 daemon 会话不在本次范围。
  非 iTerm、tmux、SSH 的跳转仍受现有 tty 匹配方式限制。

测试使用临时目录，不更改用户配置：`make test`。
