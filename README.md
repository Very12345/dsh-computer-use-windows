# DSH Windows Computer Use

为 DeepSeek Harness 0.2 系列提供 Windows 桌面应用操作。参照 Codex 的窗口选择、观察后操作、操作后刷新和错误恢复流程，独立实现 DSH 原生控制层。不包含浏览器 DOM、标签页、扩展或浏览器输入，也不分发 OpenAI 的程序。

## 安装

```powershell
dsh plugin --profile desktop add github:Very12345/dsh-computer-use-windows --ignore-scripts
```

安装后重启 DSH。在设置 → Windows Computer Use 开启插件；添加需要始终允许的应用，例如 `notepad.exe`。不在列表中的应用通过 DSH 请求当前会话授权。DSH 审批策略为 `never` 时，未授权应用会被拒绝。设置页有立即停止按钮。

推荐卸载旧 `dsh-computer-use-win`，避免两套控制器。新插件开启时通过 DSH 工具守卫拒绝旧 `mcp__wincu__*` 调用。它不修改其他插件、模型、预设或 PowerShell/Git Bash 工具。

## 行为

- 窗口 id 由真实枚举产生，绑定 HWND、PID 和进程启动时间；标题变化保留绑定，关闭或重建后须重新选择。
- 截图与 UIA 状态生成一次性 `observation_id`。默认 60 秒有效，其他输入会使旧观察失效。控件索引属于对应观察，不能跨会话使用。
- 点击坐标使用返回截图中的像素。插件处理缩放和窗口移动，窗口尺寸变化则要求重新观察。遮挡兜底截图禁止坐标操作。
- 所有桌面任务共用串行队列。每次输入后返回新截图和 UIA 状态，不自动重试输入。
- 文本输入使用剪贴板；只允许向刚观察到且仍有焦点的编辑控件输入。空控件输入及整值替换在有限等待内回读完整值。既有文本中的插入或无法回读的控件要求模型检查实际状态。
- `verified` 表示预期值已回读；`dispatched` 表示已投递并刷新，须检查界面；`outcome_unknown` 表示可能已产生效果，先观察再决定是否重试。
- 截图作为 DSH 附件保存并发送给支持图像的模型，JSON 不携带 base64。文本模型仍可读取无障碍树，不能凭没有收到的截图猜坐标。
- 原生系统提示及 `windows-desktop` 技能包含选择窗口、焦点检查、逐步操作、失败恢复及确认要求。

## 工具

`computer_list_apps`、`computer_list_windows`、`computer_launch_app`、`computer_get_window`、`computer_get_window_state`、`computer_click`、`computer_type_text`、`computer_press_key`、`computer_scroll`、`computer_drag`、`computer_set_value`、`computer_secondary_action`、`computer_activate_window`、`computer_stop`。

原生工具模式可直接调用。PTC 模式通过宿主生成的 SDK 调用这些工具；截图沿用宿主附件投影。先获取状态，查看结果，再发出下一次动作。

## 范围与限制

Windows 10/11 交互桌面、PowerShell 5.1、Node ≥22。不要求安装 Python、浏览器扩展或第三方 npm 运行依赖。后台 STA 工作进程使用 UI Automation、Win32 输入及截图；C# P/Invoke/WGC 帮助代码首次编译后缓存。

实际输入占用 Windows 前台。锁屏、UAC、提权窗口、失效焦点或遮挡可能拒绝操作。浏览器、终端、认证、密码管理器和安全应用不接受授权；不允许 Win 键。删除、对外发送、权限修改、支付等动作必须声明 `requires_confirmation:true` 并通过 DSH 当次审批。通用像素点击不能自动识别所有业务语义，这部分还依赖模型遵循操作技能，并非完整的系统沙箱。

应用目录来自常见系统应用和 Windows App Paths，不声称覆盖所有 UWP/商店应用；运行中的其他允许应用可通过窗口列表发现。UIA 很弱的画布需要模型视觉理解。相同工具设计不保证不同模型具有相同成功率。

## 开发与验证

```powershell
npm ci --ignore-scripts
npm test
npm pack --dry-run
npm run smoke
```

`npm test` 覆盖状态隔离、句柄更换、缩放、窗口移动/尺寸变化、输入不重放、验证延迟、取消、并发串行、审批、图像投影和 DSH SDK 注册。SDK 集成检查需要宿主提供 peer 包。

`npm run smoke` 在 Windows 上用记事本打开专用空白测试文件，验证选择、截图、点击、输入、完整回读和整值替换。只编辑脚本创建的测试文件，测试后保存其空白原值并关闭测试标签页，不关闭其他文档或进程。截图和本地验证记录放入忽略的 `.tmp/`，不进入发布包。

## 架构与来源

```text
DSH 原生工具 / 设置 / 审批 / 技能 / 附件
  → DesktopController：窗口绑定、观察、串行、验证、取消
  → WindowsBackend：插件拥有的持久 STA 子进程
  → Windows UIA / user32 输入 / PrintWindow、WGC 截图
```

Windows 后端基于 MIT 项目 [Yu-tao-Li/dsh-computer-use-win](https://github.com/Yu-tao-Li/dsh-computer-use-win) 的 0.2.3 版本，保留其及 cgissing 的许可，修改了目标身份、控件作用域、焦点、坐标和输入路径。详见 [NOTICE](NOTICE)、[native/LICENSE](native/LICENSE)。DSH 控制层与测试是本仓库代码。主许可证为 MIT。
