# 工具行为对照（2026-10-01）

参考为官方 Computer Use 26.928.31416 提供的公开 `sky` API。对照时使用官方 JavaScript 接口，逐项调用 13 个方法；DSH 使用自己的控制器和 MIT Windows 后端，测试全部 14 个工具。环境为 Windows、200% 显示缩放。测试窗口由本仓库原创 WinForms 应用提供，内容仅在内存中存在。

| 官方方法 | DSH 工具 | 本次验证 |
| --- | --- | --- |
| list_apps | computer_list_apps | 返回应用目录 |
| list_windows | computer_list_windows | 发现测试窗口 |
| launch_app | computer_launch_app | 明确的本地 exe 路径启动；获取唯一窗口 |
| get_window | computer_get_window | 绑定当前窗口；DSH 另外绑定 PID/启动时间 |
| get_window_state | computer_get_window_state | 截图、焦点、树；DSH 检查真实 PNG 宽高 |
| activate_window | computer_activate_window | 激活并重新观察 |
| click | computer_click | 控件点击、截图坐标点击、焦点变化 |
| type_text | computer_type_text | 中文普通控件回读；无 Edit/Value 的 Pane 视觉输入 |
| press_key | computer_press_key | Ctrl+A；DSH 额外测试 KP_1 小键盘别名 |
| set_value | computer_set_value | 整值替换；DSH 额外测试无 ValuePattern 控件的空值清除 |
| scroll | computer_scroll | 可见列表首行随向下滚动改变 |
| drag | computer_drag | 测试画布产生一条完整线段 |
| perform_secondary_action | computer_secondary_action | 官方 Raise；DSH 测试 Raise、Invoke、Toggle、Select、Expand、Collapse、Scroll Down |
| — | computer_stop | DSH 停止后拒绝操作，恢复后才可继续 |

普通控件测试以真实值回读为依据，自绘控件以操作后截图为依据。官方测试里的普通 TextBox 没有提供 `selected_text`；Ctrl+A 用截图确认。无障碍属性随框架和 provider 不同，不能将某个字段的缺失直接当成操作失败。

## 本次修复

- 自绘界面：先点击并检查截图，再允许视觉输入。保持窗口身份、原生输入焦点和鼠标位置；观察一次性使用。无法回读的输入仅报告 dispatched。
- 采集：有界遍历原始子节点并穿过非控件容器，避免过滤中间节点后丢失后代；补充属于目标窗口的直接焦点、选择和 provider 错误诊断。选中文字仅尝试已验证的经典 Edit provider；现代记事本的选择范围调用曾使原生进程退出，已跳过这一可选字段，保留文本回读与截图。
- 激活：正确区分 GetWindowThreadProcessId 的线程 ID 返回值与进程 ID 输出；已在前台时不重复激活。
- 辅助动作：支持 Raise 与控件 ScrollPattern；提供 patterns 供模型选择动作。
- 输入：物理按键处理小键盘、修饰键和标点；空文本替换使用选中后 Backspace；拖动生成连续轨迹，并检查输入投递失败。
- 结果：区分原生明确拒绝和可能已产生效果的异常，不自动重试。

## 源码调查与限制

本次查询了 [openai/codex](https://github.com/openai/codex) 的公开主分支完整文件树。找到 computer-use 配置、需求和测试文件，未找到 `@oai/sky` 或官方 Windows 原生后端可复用的实现。公开 CLI 仓库的许可不能推定适用于桌面插件后端。

本机运行时另有 `@oai/sky 0.7.5` 的可读编译 JavaScript：Windows 的 `computer_use_client_base.js`、`computer_use_client.js` 和 `helper_transport.js`。客户端层可核对参数、截图标识、辅助动作及停止/请求生命周期；`type_text` 在这一层校验文字类型后，将窗口与文字交给原生后端，没有要求 Edit/Document 控件。未发现源码映射、原始 TypeScript 或 Windows C++/C#/Rust 源文件，因此这里只获得了客户端层实现。

本机官方插件清单标注 `license: Proprietary`，客户端包中也未找到可据以复制分发这些实现的许可。本仓库使用公开接口和实测行为作为对照，保留独立实现。底层客户端还定义录音方法；这些方法未出现在本次技能文档提供的 13 个桌面操作入口中，也不属于本次已验证的对齐范围。

还找到 [OpenSky](https://github.com/tanishqkancharla/opensky) 等社区兼容实现；它们不能视作官方源码。本次没有引入这些代码或运行时，也没有复制或分发 OpenAI 插件、私有运行时或二进制。

此记录证明上述测试场景中的工具行为，不证明所有应用、模态窗口、显示器组合或模型都达到相同成功率。微信视觉路径的动机来自实测：官方同样只有 Window/Pane，无标准编辑节点，仍能在截图确认焦点后输入。微信没有进行消息发送测试。

新版 DSH 路径也已在真实微信主界面复测：按截图点击搜索框，中文测试文字完整显示，工具返回 dispatched / visual，而非 verified；随后清除测试文字并退出搜索。窗口尺寸变化曾被布局检查拒绝，重新观察后继续，未绕过检查。此项只证明搜索框输入，未测试聊天输入框、消息发送或录音。
