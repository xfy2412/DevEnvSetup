# DevEnvSetup

一键搭建开发桌面的窗口布局工具。双击 `WindowsLayout.bat`，把天气页 Edge、
右侧 Edge（dsh web + DeepSeek）和 Windows Terminal 三个窗口摆到固定位置、
固定层级，并把天气页调到 150% 缩放、滚动到固定位置，最后在终端里启动 `dsh web`。

```
┌───────────────────────────────────────────────┬──────────────────┐
│                                               │                  │
│   weather（全屏垫底）                          │  rightedge       │
│   weather.com.cn                              │  3080 (dsh web)  │
│                                               │  + DeepSeek 对话  │
│   ┌───────────────────────────────────────────┴──────────┐       │
│   │  terminal（最前）                                       │       │
│   │  tab1: D:\git-repo     tab2: ServerPluginCore         │       │
│   └───────────────────────────────────────────────────────┘       │
└───────────────────────────────────────────────┴──────────────────┘
                    z 序（前 → 后）：terminal > rightedge > weather
```

| 窗口 | 位置（物理像素） | 内容 |
|---|---|---|
| weather | `(-14,-14) 3868x2080`（最大化） | 天气页，自动 F5 → 150% → ↓×4 |
| rightedge | `(2488,0) 1367x2052` | `dsh web` 的 3080 页面 + DeepSeek 对话 |
| terminal | `(-15,0) 2557x1191` | 标签1 `D:\git-repo`，标签2 `D:\git-repo\ServerPluginCore` |

## 环境要求

- **PowerShell 7**（`pwsh`）——脚本用了 `-File`/`-EncodedCommand` 等 pwsh 特性
- **Windows Terminal**（`wt.exe`）
- **Microsoft Edge**
- 屏幕分辨率与配置一致（默认 **3840×2160**，任务栏 108px）。换分辨率不会崩，坐标会按比例缩放；但建议重跑 `-Save` 重存一次
- **管理员权限**：要移动的窗口若属于提权进程，脚本必须同样提权。脚本会检测到这种不匹配并请求 UAC 重启

## 快速开始

```bat
:: 双击即可，或在任意终端里运行
DevEnvSetup\WindowsLayout.bat
```

它会：生成一个临时 wrapper → 开一个**命名** Windows Terminal 窗口（两个标签）→
在标签 1 里运行布局脚本 → 布局完成后在**前台**启动 `dsh web`。

> `dsh web` 是开发服务器，会一直占用标签 1，这是预期行为。它自己会打开 3080 页面；
> 脚本不打开 3080。

## 只跑布局脚本

```powershell
cd D:\git-repo\DevEnvSetup

.\WindowsLayout.ps1 -WhatIf -Verbose   # 只诊断：认了哪些窗口、会做什么，不碰任何窗口（推荐先跑这个）
.\WindowsLayout.ps1                    # 摆好三个窗口（缺谁开谁，终端不由脚本开）
.\WindowsLayout.ps1 -WeatherView -Refresh -ZoomPercent 150 -ScrollTicks 4   # 附送天气页操作
.\WindowsLayout.ps1 -Save               # 手工摆好后，把当前布局存为配置
```

### 参数

| 参数 | 说明 |
|---|---|
| `-WeatherView` | 摆完窗口后，对天气页执行 F5 → 缩放 → 滚动（顺序固定） |
| `-Refresh` | 天气页按 F5。**必须排在缩放/滚动之前**——重载会重置滚动位置与页面缩放 |
| `-ZoomPercent` | 页面缩放，须是 Edge 预设值（100/110/125/150/175/200…），默认 150 |
| `-ScrollTicks` | 按 ↓ 键的次数，默认 4；设 0 则不滚动 |
| `-WhatIf` | 只诊断不动作。配合 `-Verbose` 打印宿主进程链、被排除的窗口、候选窗口 |
| `-Save` | 把当前窗口几何与层级写回 JSON。三个窗口必须都在，否则拒绝保存 |
| `-NoLaunch` | 只移动已有窗口，绝不启动新窗口 |
| `-NoElevate` | 不提权重启（会打印告警并放弃无法移动的窗口） |
| `-ProfilePath` | 使用其它配置文件，默认同目录 `WindowsLayout.json` |

## 配置文件 `WindowsLayout.json`

```jsonc
{
  "monitor": {                       // 记录测量时的显示器尺寸，用于跨分辨率换算
    "bounds": { "x": 0, "y": 0, "w": 3840, "h": 2160 },
    "work":   { "x": 0, "y": 0, "w": 3840, "h": 2052 }
  },
  "windows": [
    {
      "id": "weather",
      "match": {                     // 如何认出这个窗口
        "process": "msedge",
        "class": "Chrome_WidgetWin_1",
        "titleClass": "weather",     // 标题必须含"天气"
        "pick": "largest"            // 多个候选时取面积最大的
      },
      "rect": { "x": -14, "y": -14, "w": 3868, "h": 2080 },  // 目标矩形（物理像素）
      "launch": "https://…",         // 窗口不存在时用什么 URL 打开
      "launchOrder": 0,              // 启动顺序
      "zOrder": 0                    // 0 = 最底
    }
  ],
  "zOrderTopToBottom": [ "terminal", "rightedge", "weather" ],  // 前 → 后
  "terminal": { "tabs": [ { "dir": "…", "command": "dsh web" }, { "dir": "…" } ] }
}
```

要点：

- **坐标是物理像素**，且带最大化窗口那几像素的负外边距（`-14` / `3868`），不要"修正"成 `0` / `3840`
- `match` 支持 `process` / `class` / `titleClass` / `notTitleClass` / `pick`
  （`largest` / `widest` / `newest` / `oldest` / `first`）
- **`titleClass` 里的 `weather` 是脚本内的关键字**，展开为标题中的"天气"二字；
  两个 Edge 窗口正是靠它区分（天气页标题含"天气"，右侧窗口必须不含）
- `launch` 留空表示**不由脚本打开**该窗口（例如终端由 bat 负责开）
- `zOrderTopToBottom` 是**前 → 后**顺序，脚本会倒序压栈，使列表首项成为最前窗口

## 执行流程

**`WindowsLayout.bat`**

1. 校验 `pwsh` 与 `WindowsLayout.ps1` 存在
2. 生成 wrapper 到 `%TEMP%\WindowsLayout.wrap.ps1`（固定文件名，每次覆盖）
3. 用一条 `wt.exe` 命令开命名窗口：标签1 = wrapper，标签2 = `ServerPluginCore`
4. wrapper 先跑布局脚本，再在**前台**执行 `dsh web`

**`WindowsLayout.ps1`**

1. 收集上下文：从本进程沿父链找出宿主终端，据此判定哪些窗口**绝不能碰**
   （隐藏伪控制台、编辑器窗口），并把宿主终端窗口**认领**为布局对象
2. 匹配三个条目 → 生成计划
3. 提权预检：目标窗口提权而当前未提权时，带 UAC 重启自己
4. 补齐缺失窗口：只认"快照之后新出现"的窗口，并校验标题，防止天气/右侧窗口互串
5. 定位：读真实屏幕尺寸（不一致则按比例缩放 + 贴边）；最大化窗口先还原再移动；每次移动都回读校验
6. `-WeatherView` 时：激活天气窗口一次 → F5 → 等 1.5s → 缩放 → ↓×N
7. 压栈：先激活 rightedge（决定 `dsh web` 的标签页落点），再按 `weather → rightedge → terminal` 激活，最后校验真实栈序，不符则重试至多 3 轮

## 维护

- **改布局位置**：手工摆好 → `.\WindowsLayout.ps1 -Save`。它会重写 `rect`、
  `monitor` 与 `zOrderTopToBottom`；三个窗口缺一个就拒绝保存
- **换显示器/分辨率**：直接跑即可（坐标按比例换算），想要精确值就重跑 `-Save`
- **换工作目录**：改 `WindowsLayout.json` 里 `terminal.tabs[].dir` 与各 `launch` URL；
  bat 里的 `%HERE%` 自动跟随文件位置
- **不想自动开天气页**：删掉 weather 条目的 `launch`（脚本就不会开它，只负责摆位）

## 排错

先跑这个，它不碰任何窗口：

```powershell
.\WindowsLayout.ps1 -WhatIf -Verbose
```

输出会给出：宿主进程链、被排除的窗口及原因、候选窗口、以及"会启动 / 会认领"的计划。

常见现象：

| 现象 | 原因与处理 |
|---|---|
| `rightedge`/`weather` 显示 `WOULD LAUNCH` | 对应窗口不在（标题不含关键字也会如此）。先手工打开页面再跑，或让其 `launch` 生效 |
| `MOVE FAILED` + 提权告警 | 目标窗口属于提权进程而当前 shell 未提权。以管理员运行，或去掉 `-NoElevate` 接受 UAC |
| 天气缩放不到位 | F5 后页面仍在加载。把 `Set-WeatherView` 里 `Start-Sleep -Milliseconds 1500` 调大 |
| 栈序不一致（红色 `actual` 行） | 脚本已重试至多 3 轮；仍不一致说明窗口管理器吞掉了抬升，见下节 |
| 从终端里运行脚本，终端没被移动 | 预期行为：脚本把**承载自己的终端**视为宿主，不会另外开一个终端，也不会把它当"已就绪的终端"而跳过创建 |

## 本机（Windows）实测到的系统特性

这些是踩过的坑，写下来避免以后重复调试：

1. **`SetWindowPos(HWND_TOP)` 抬高窗口可能被静默忽略**——返回 `True` 但栈序不变；
   压低（`HWND_BOTTOM`）和**激活**（`BringWindowToTop` + `SetForegroundWindow`）
   则真实生效。脚本因此不依赖 `SetWindowPos` 压栈，而改用激活方式，
   并附带真实栈序自检与最多 3 轮重试。

   实测到的**能力矩阵**（同一个终端窗口，逐项单独调用）：

   | 操作 | 结果 |
   |---|---|
   | `HWND_TOP`（抬高） | ✗ 返回 True，rank 不变 |
   | `HWND_BOTTOM`（压低） | ✔ 生效 |
   | `HWND_TOPMOST`（置顶） | ✔ 升到最前 |
   | `HWND_NOTOPMOST`（清标记） | ✔ 留在最前 |
   | 激活（`BringWindowToTop`+`SetForegroundWindow`） | ✔ 生效 |

   **根因**：被抬的那个终端窗口是**发起进程自己的宿主控制台窗口**（ConPTY 宿主）。
   系统不允许进程用 `HWND_TOP` 抬高自己的宿主终端窗口，而 `HWND_TOPMOST`
   走的是另一条不受此限制的路径——所以压栈要用激活，或对终端用
   topmost 往返（`HWND_TOPMOST` → `HWND_NOTOPMOST`，代价是窗口闪一下）。

   注意：这条**与 ClassIsland / GrantUiAccess 无关**——关掉 ClassIsland 后
   终端依然抬不动，这是最直接的反证。ClassIsland 的问题另见下节。
2. **`GetSystemMetrics` 必须在声明 DPI 感知之后读**，否则拿到的是虚拟化尺寸
   （本机是 `1707x960` 而非 `3840x2160`）。
3. **`System.Windows.Forms` 的 `Screen.Bounds` 不能用作屏幕尺寸**：它在程序集加载时
   就缓存了 DPI 虚拟化结果，之后再声明 DPI 感知也不刷新。
4. **`EnumWindows` 的枚举顺序不是 z 序**，用它判断层级会得出错误结论；
   正确做法是 `GetTopWindow` + `GW_HWNDNEXT`。
5. **最大化的窗口会静默吞掉 `SetWindowPos` 移动**：返回成功、位置不变。
   判断是否最大化必须看 `WINDOWPLACEMENT.showCmd == 3`，
   不能用"尺寸是否等于屏幕"（最大化矩形比屏幕略小：`3868x2080` vs `3840x2160`）。
6. **Windows Terminal 的命令行解析器会按 `;` 切分，即使在引号内**，
   因此不要把含 `;` 的命令交给它（`wt` 会把它切成多个标签页）；
   `-EncodedCommand` 是可靠写法。`wt` 也没有向已存在标签页注入命令的参数。
7. **Windows Terminal 下 `GetConsoleWindow()` 返回的是 0×0 的隐藏伪控制台**
   （owner 是 shell 而非 `WindowsTerminal.exe`），不能据此判断"是否运行在终端里"。
8. **一个 `WindowsTerminal.exe` 进程拥有该实例的全部窗口**，所以排除宿主时
   只能按**窗口句柄**排除，不能按进程排除（否则会把脚本自己开的终端也排掉）。
9. **`wt.exe` 在窗口创建前就返回**，因此新建标签页还要读取的临时文件不能在 bat 里立刻删除。
10. **`timeout` 命令在输入被重定向时不可用**，延时需退回 `ping -n`。

## 已知干扰源：ClassIsland + GrantUiAccess（调查记录）

本机常驻 **ClassIsland**，并安装了 **GrantUiAccess** 插件。查证结论如下，供以后复用。

### 插件在做什么

源码：`D:\git-repo\GrantUiAccess`（`HelloWRC/GrantUiAccess`）

- `uiaccess/uiaccess.c` 的 `PrepareForUIAccess()`：复制同会话 `winlogon.exe` 令牌，
  临时 `SetThreadToken` 冒充 SYSTEM 取得 `SeTcbPrivilege`，用
  `SetTokenInformation(TokenUIAccess = TRUE)` 造出 UIAccess 令牌，再
  `CreateProcessAsUser` **重启自己**。
- `GrantUiAccess/Plugin.cs`：启动完成后把 **主窗口 `Topmost` 关-开一次**，钉进最顶层
  （插件自述：*"使 ClassIsland 可以置顶到全屏 UWP 应用和系统界面上"*）。

实测确认插件在生效：

```
ClassIsland.Desktop  pid=12520  window=ClassIsland  TOPMOST  elevated=1  uiAccess=1
explorer             pid=7676                                elevated=1  uiAccess=0   (对照)
```

### 影响

- ClassIsland 的挂件窗口是 **topmost**，会一直浮在所有普通窗口之上（设计如此）。
- 但**它并不是**"终端抬不动"的原因——关掉 ClassIsland 后终端依然抬不动，见上一节。

### 已知缺陷与上游修法（未合并）

任务栏残留：ClassIsland 2.0+ 下每次触发提醒，任务栏会出现无法关闭的"顶层效果窗口"。

- Issue：`HelloWRC/GrantUiAccess#16`（open）、`#12`（closed，同类现象）
- PR：`HelloWRC/GrantUiAccess#18`（**closed 未合并**，仅改 `Plugin.cs`，+60/−1）
  - 作者的因果分析：主窗口 `Topmost` 往返时，`TopmostEffectWindow` 的
    `WS_EX_TOOLWINDOW`（决定是否出现在任务栏）被刷新掉
  - 修法：重置 `Topmost` 后再遍历窗口，找到 `TopmostEffectWindow` 重设
    `Topmost` 并补回 `WS_EX_TOOLWINDOW` + `SWP_FRAMECHANGED`
  - 未合并原因：维护者实测**问题依旧**（用的是当时 CI 版本 `classisland@3f67e46`），
    而作者称在 ClassIsland 2.0.3.2 上已修复，两边版本不一致导致无法验证

**更优雅的本体修法（已验证可行性，尚未实施）**——在 ClassIsland 本体层面修，
不需要反射、也不需要改插件：

| 事实 | 位置 |
|---|---|
| `TopmostEffectWindow.Show()` 已在申请正确样式（`ShowInTaskbar=false` + `Topmost` + `Transparent\|ToolWindow\|Topmost\|SkipManagement`） | `ClassIsland/Views/TopmostEffectWindow.axaml.cs` |
| `WS_EX_TOOLWINDOW` 的生成本体已有（CsWin32） | `platforms/ClassIsland.Platforms.Windows/Services/WindowPlatformService.cs` 的 `ToolWindow` 分支 |
| **全解决方案没有一处 `SWP_FRAMECHANGED`** | 全仓搜索 = 0 命中 |

根因判断：`SetWindowLong(GWL_EXSTYLE, …)` **只改样式、不通知 shell**，
任务栏按钮只在 `SetWindowPos(..., SWP_FRAMECHANGED)` 时才被重新评估。

建议改动（两处都很小）：

1. 平台层：`WindowPlatformService` 修改 `WS_EX_TOOLWINDOW`（以及 `WS_EX_LAYERED`）后，
   追加一次带 `SWP_FRAMECHANGED` 的 `SetWindowPos` 刷新非客户区；
2. 本体层：`MainWindow.Topmost` 变化后，重放一次特效窗口的窗口特性，
   使被冲掉的样式立刻补回——在 CI 本体内部完成，比 PR #18 用反射遍历
   `AppBase.Current.Windows` 找窗口更稳。

> 以上仅为设计记录，**未实施**（用户选择先不动上游代码）。
> 若哪天要做：按 `ClassIslands/ClassIsland/AGENTS.md` 的流程先说明再改，
> 验证用 `dotnet build ClassIsland.Desktop/ClassIsland.Desktop.csproj -c Debug`。

## 文件

| 文件 | 作用 |
|---|---|
| `WindowsLayout.bat` | 一键入口：开承载终端、跑布局、启动 `dsh web` |
| `WindowsLayout.ps1` | 布局引擎：识别 / 启动 / 定位 / 压栈 / 天气页操作 |
| `WindowsLayout.json` | 配置：匹配规则、目标矩形、层级、终端标签页 |
