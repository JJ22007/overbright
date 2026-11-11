<h1 align="center">Overbright</h1>

<p align="center">
  <b>让 MacBook 的 XDR 屏幕亮过 100%。</b><br>
  一个能用脚本驱动、用一份文件配置、能交给 AI 助手改造的菜单栏 App。
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

Liquid Retina XDR 屏幕平时只在播放 HDR 视频时才会用到额外的亮度。Overbright 把这部分亮度放出来给所有内容用：最高到标准亮度的 160%，可以在菜单栏里调，可以用 F1/F2 调，也可以用一条命令调。全部代码约 4000 行 Swift，没有第三方依赖，也不需要 Xcode 工程。设置都在一份 JSON 里；JSON 改不了的，自己或者让 AI 编程助手改几行代码就行。

## 功能

- **亮度超过 100%**：滑杆从 100% 到 160%。实际增亮不会超过 macOS 当下报告的可用余量，不会向面板要它给不了的亮度。
- **一条刻度，一个指示框**：F1/F2 在同一条 0–160% 的刻度上移动，0–100% 是背光，100–160% 是增亮。整条刻度只有 Overbright 的一个指示框，每按一下，亮度在几十毫秒内就跟着变。
- **副屏也能调**：插上显示器，菜单里就自动出现它的亮度滑杆。Control+F1/F2 调暗或调亮，屏幕上会显示亮度指示。大多数显示器通过 DDC/CI 控制，效果和按显示器自己的按键一样；不支持的就用软件调暗。
- **不和系统抢控制权**：自动亮度、控制中心、睡眠都照常工作。Overbright 跟随它们，而不是对着干；关闭或退出时把屏幕恢复原样。
- **一份配置，保存即生效**：改完保存，一两秒内自动应用。写错了会在菜单里提示，不会把 App 搞坏。
- **预设**：给常用亮度起名字（「树荫」「户外」），在菜单或命令行里一键切换。
- **给脚本和 AI 助手用的命令行**：`overbright set 140`、`overbright status --json`。每条命令都返回真实结果和有意义的退出码。
- **中英文界面**，跟随系统语言。

## 运行要求

- macOS 13 或更新版本，Apple 芯片和 Intel 都支持。
- 内置屏幕需要有 EDR 亮度余量，实际上就是配备 Liquid Retina XDR 屏幕的 MacBook Pro。其他屏幕上 App 会提示不支持，并且不改动亮度。Overbright 不能让普通 LCD 变得更亮。

## 安装

### 下载

在[最新发布](https://github.com/JJ22007/overbright/releases/latest)里下载 `Overbright-universal.zip`，解压后把 `Overbright.app` 拖进「应用程序」。

下载版是临时签名，没有经过 Apple 公证。第一次打开会被 macOS 拦下：到 系统设置 → 隐私与安全性，选择 **仍要打开**。不需要关闭 Gatekeeper。

### 从源码构建

需要 Swift 编译器。没装过的话先运行 `xcode-select --install`。

```bash
git clone https://github.com/JJ22007/overbright.git
cd overbright
bash scripts/install.sh
```

脚本会跑测试、编译、把 `Overbright.app` 装到 `~/Applications`、把 `overbright` 命令链接到 `~/.local/bin`，然后启动。

### 打算反复重新编译？先跑一次这个

macOS 把「辅助功能」权限（F1/F2 需要）绑定在 App 的代码签名上。源码构建默认是临时签名，每次重新编译都像一个新 App：权限会失效，而系统设置里的开关可能看起来还是开着的。

```bash
bash scripts/setup-signing.sh
```

脚本会在你的登录钥匙串里创建一个自签名证书，只用来签你自己的构建，然后重新编译并安装。之后再授权一次，以后怎么重新编译都不会掉。如果你有 Apple Developer ID，可以改用 `SIGN_ID="Developer ID Application: You" bash scripts/install.sh`。

## 使用

1. 打开 **Overbright**，菜单栏会出现一个太阳图标。
2. 点开它，选择 **开启增亮**，或者直接把滑杆拖过 100%。
3. 选择 **恢复标准亮度** 或退出 App，屏幕会恢复成原来的样子。

**副屏**：插上就会出现在菜单里，有自己的滑杆；拔掉就消失。按 **Control+F1** 或 **Control+F2** 调节，步进和内置屏一样（Control+Option+Shift 是细调）。鼠标在副屏上时只调那一块；鼠标在 MacBook 屏幕上时，所有副屏一起调。

**比 0% 更暗**：显示器背光调到 0 也还是亮的。到 0% 之后继续按 Control+F1，数值会变成负数，最低到 −90%：背光保持最低，剩下的由 Overbright 把画面压暗，正好和内置屏超过 100% 对称。往回调时先撤掉额外调暗，再调背光。退出 Overbright 时会撤掉额外调暗，背光留在 0。

每块屏用什么方式控制，会自动判断：

| 方式 | 适用的显示器 | 效果 |
|---|---|---|
| DDC/CI | Dell、LG、三星、明基、华硕等大多数显示器 | 直接改显示器自己的背光，和按它的按键一样。亮度保存在显示器里。 |
| macOS | Apple Studio Display、LG UltraFine | 和 macOS 自己用的控制方式一样。 |
| 软件 | 不支持 DDC/CI 的：很多电视、部分扩展坞和转接头 | 通过 Gamma 表把画面调暗。只能调暗不能调亮，最低 10%，屏幕不会全黑；退出 Overbright 时自动恢复。 |

DDC/CI 需要 Apple 芯片的 Mac，Intel Mac 上所有副屏都走软件调暗。有些显示器在自己的屏幕菜单里把 DDC/CI 关掉了，去那里打开即可。

**F1 和 F2：一条 0 到 160% 的刻度**。内置屏的亮度是一条刻度。0–100% 是背光，和 macOS 自带按键一样分 16 档。超过 100% 后背光保持最亮，由增亮接手，最高到 160%（`maxLevel`）。每按一下变化 6.25%，按住 Option+Shift 是四分之一步进。整条刻度只有一个指示框，在屏幕顶部正中：一个太阳和 16 个等距的格子，每格 10%，最后 6 格是增亮部分。

接管按键需要「辅助功能」权限，因为 Overbright 必须赶在 macOS 之前接住按键：在菜单里选择 **授权 F1 / F2…**。不授权的话，按键和指示框都还是 macOS 自己的，增亮可以在菜单里调。

| 你按 | 会发生什么 |
|---|---|
| 100% 以下按 F1/F2 | 背光走一档，和 macOS 自带按键一样。 |
| 100% 时按 F2 | 开始增亮。屏幕闲置后的第一下大约要 0.3 秒，因为 macOS 要先把背光拉到峰值；之后每一下都是即时的。 |
| 106% 时按 F1 | 立刻回到 100%。macOS 之后会让背光在峰值再停约 15 秒，这期间 Overbright 一直把画面保持在标准亮度，直到背光降下来。 |
| Option+F1/F2 | 照常打开「显示器」设置。 |

## 改成你自己的

配置文件在 `~/.config/overbright/config.json`，可以从菜单的 **编辑配置文件…** 打开。只写你想改的，其余保持默认。

```json
{
  "maxLevel": 140,
  "showPercentage": true,
  "presets": [
    { "name": "树荫", "level": 115 },
    { "name": "户外", "level": 140 }
  ]
}
```

| 字段 | 默认值 | 含义 |
|---|---|---|
| `maxLevel` | `160` | 滑杆、按键和命令行能到的最高亮度，101 到 160。想要温和一点的上限就调低。 |
| `keyStep` | `6.25` | 每按一次 F1/F2 变化的百分比，作用于整条 0–160% 刻度（命令行的 `up`/`down` 也一样）。 |
| `fineKeyStep` | `1.5625` | 按住 Option+Shift 时每次变化的百分比。 |
| `brightnessKeys` | `true` | 让 F1/F2 在 100% 之后继续生效。设为 `false` 就只用菜单和命令行，App 也不会再请求「辅助功能」权限。 |
| `enableOnLaunch` | `false` | 启动时自动开启增亮，用上次的亮度。 |
| `showPercentage` | `false` | 增亮时在菜单栏图标旁显示当前百分比。 |
| `language` | `"auto"` | `"auto"` 跟随系统；`"en"` 或 `"zh"` 强制指定。 |
| `externalDisplays` | `true` | 在菜单里显示副屏并控制它们的亮度。 |
| `externalKeys` | `true` | 用 Control+F1/F2 调节副屏。需要 `brightnessKeys` 开启并授予「辅助功能」权限。 |
| `showHUD` | `true` | 调节副屏时在那块屏上显示亮度指示。 |
| `boostMethod` | `"auto"` | 增亮的实现方式：`"overlay"`（macOS 27.2 及以后）或 `"classic"`（更早的版本）。`"auto"` 按系统版本自动选择；只有增亮看起来不对时才需要手动指定。见[工作原理](#工作原理)。 |
| `extraDimming` | `true` | 允许副屏低于 0%（最低 −90%）：背光到最低后，再把画面压暗。 |
| `presets` | `[]` | 命名亮度：`name` 和 `level`（100 到 160）。会出现在菜单里，也能用 `overbright preset` 调用。 |

**写错了怎么办**：菜单里会出现 **配置问题**，指出具体哪一项有问题。那一项回退到默认值，其余照常生效。如果整个文件不是合法 JSON，会继续沿用之前的设置，直到你改好。也可以在终端里检查：

```bash
overbright check ~/.config/overbright/config.json
```

### 示例

从 [`examples/`](examples) 里复制：

| 文件 | 适合 |
|---|---|
| [`minimal.json`](examples/minimal.json) | 把上限降到 130% |
| [`presets.json`](examples/presets.json) | 三个命名亮度，菜单栏显示百分比 |
| [`fine-steps.json`](examples/fine-steps.json) | 更小的 F1/F2 步进，调得更细 |
| [`menu-only.json`](examples/menu-only.json) | 不拦截按键，不需要「辅助功能」权限 |
| [`always-on.json`](examples/always-on.json) | 启动即增亮，上限 140% |
| [`no-external.json`](examples/no-external.json) | 不管副屏 |

## 用脚本和 AI 助手驱动

`scripts/install.sh` 会把命令链接到 `~/.local/bin/overbright`。如果是下载安装的，同一个可执行文件在 `/Applications/Overbright.app/Contents/MacOS/Overbright`。

```bash
overbright status            # off 125%
overbright set 140           # on 140%（增亮）
overbright set 50            # 背光 50%，关闭增亮
overbright up                # 在 0–160% 刻度上亮一档
overbright key down          # 和按 F1 完全一样，包括指示框
overbright preset 户外        # 按名字或前缀匹配预设
overbright off               # 回到标准亮度
overbright displays          # 2  DELL P2723DE  ddc  100%
overbright display dell 60   # 按名字、编号或 all 指定副屏
overbright display all down
overbright display dell -40  # 背光为 0，画面压暗到 60%
overbright status --json
```

```json
{
  "brightnessKeys" : "on",
  "configProblems" : [],
  "externalDisplays" : [
    { "control" : "ddc", "id" : 2, "level" : 100, "minimum" : -90, "name" : "DELL P2723DE" }
  ],
  "edrHeadroom" : 1.26,
  "level" : 125,
  "maxLevel" : 160,
  "potentialEdrHeadroom" : 16,
  "presets" : [],
  "scale" : 125,
  "scaleTop" : 160,
  "boostMethod" : "overlay",
  "state" : "on",
  "supported" : true,
  "version" : "2.0"
}
```

App 必须在运行；命令会和它通信，等屏幕真的变了才返回。`state` 是 `off`、`engaging`、`on` 或 `unavailable`。任何命令加上 `--json` 都会返回这个状态对象。

| 退出码 | 含义 |
|---|---|
| `0` | 完成。 |
| `1` | App 拒绝了，或者增亮不可用（原因在 stderr）。 |
| `2` | App 没在运行，或者命令写错了。 |

## 做一个属于你自己的

配置不够用，就改代码。这个项目写得让人和 AI 编程助手都容易读懂。

1. **Fork** 这个仓库，克隆你的 Fork。
2. 用你的编程助手打开它（Claude Code、Cursor、Codex 等）。[`AGENTS.md`](AGENTS.md) 已经写好了代码结构、怎么构建、哪些能在没有硬件的情况下验证，以及哪些地方不能随便动。
3. **用大白话说你想要什么**。比如：
   - 「加一个配置项：电量低于 20% 时自动关闭增亮。」
   - 「加一个全局快捷键来开关增亮。」
   - 「菜单栏里用一个小进度条代替数字显示亮度。」
   - 「加一个 `schedule` 配置项：只在 10:00 到 16:00 之间增亮。」
   - 「把界面翻译成日语。」
4. 运行 `bash scripts/install.sh` 试试效果。

想自己动手？每个文件只管一件事：

| 文件 | 职责 | 想做这些时来这里 |
|---|---|---|
| [`Models/Config.swift`](Sources/Overbright/Models/Config.swift) | 读取和校验配置 | 加一个配置项 |
| [`Models/BoostLevel.swift`](Sources/Overbright/Models/BoostLevel.swift) | 亮度上下限和亮度曲线 | 改百分比到亮度的映射 |
| [`Models/DDC.swift`](Sources/Overbright/Models/DDC.swift) | DDC/CI 数据包和副屏亮度步进 | 支持显示器的其他功能 |
| [`Services/ExternalDisplayManager.swift`](Sources/Overbright/Services/ExternalDisplayManager.swift) | 发现副屏，选择 DDC、macOS 或软件方式 | 改副屏的控制方式 |
| [`Models/BrightnessKeyStep.swift`](Sources/Overbright/Models/BrightnessKeyStep.swift) | F1/F2 的步进计算 | 改按键的步进方式 |
| [`App/CLI.swift`](Sources/Overbright/App/CLI.swift) | `overbright` 命令和 App 内的服务端 | 加一条命令 |
| [`Views/StatusItemController.swift`](Sources/Overbright/Views/StatusItemController.swift) | 菜单栏图标和菜单 | 改菜单 |
| [`Support/L10n.swift`](Sources/Overbright/Support/L10n.swift) | 中英文文案 | 加一种语言 |
| [`App/AppDelegate.swift`](Sources/Overbright/App/AppDelegate.swift) | 启动、睡眠唤醒、应用配置 | 响应某个系统事件 |
| [`Controllers/BoostController.swift`](Sources/Overbright/Controllers/BoostController.swift) | 负责开启和恢复增亮的状态机 | 很少，而且要小心 |
| [`Services/`](Sources/Overbright/Services) | Gamma 表、EDR 图层、背光、按键监听 | 很少 |

## 工作原理

macOS 只有在屏幕上有 HDR 内容时，才会给 XDR 屏幕开放高于标准白的亮度「余量」。Overbright 在内置屏幕上放一个很小的、看不见的 HDR 图层来打开这部分余量。这时 macOS 会把背光拉到峰值（MacBook Pro 上是 1600 尼特），并且正常情况下会把普通内容按比例压回去，让它看起来不变。Overbright 让普通白色分到其中一部分光。具体做法取决于系统版本（`boostMethod`）：

- **overlay**（macOS 27.2 及以后）：Gamma 表已经改变不了面板实际发出的光，所以 Overbright 在内置屏幕上盖一层全屏 HDR 图层，把它下面的所有内容乘以增亮倍数：160% 就是乘 1.6。黑色仍然是黑色。这一层不会出现在截图和录屏里，也不会挡住点击。在 HDR 模式下，背光到达峰值后 macOS 会把普通白色画暗约 9%，图层会在背光到位时把这部分补回来，所以百分比是相对真正的标准白。不写任何 Gamma 表。
- **classic**（更早的 macOS）：macOS 在 Gamma 表之后才做压缩，所以表的值大于 1 就能把白色抬进余量里：160% 约等于表端点 1.6，上限是 macOS 报告的余量。

百分比是在标准白（背光最亮时 600 尼特）基础上的请求：160% 约等于 960 尼特。

改动任何东西之前，Overbright 会先记下屏幕原来的状态，并写下一个恢复标记。即使 App 崩溃或被强制退出，下次启动也会先把亮度恢复到标准状态。读取和设置系统背光用的是 macOS 的 DisplayServices 框架，这是一个私有接口，未来的系统版本可能会改动它。

## 限制与注意事项

- **百分比不是实测亮度**。160% 是请求的增亮幅度，不等于 1600 尼特。HDR 峰值亮度无法在全屏范围内长时间维持。
- **增亮是怎么测的**：在暗的房间里用 Mac 自带的摄像头，一边按真实按键一边测：`scripts/light-check.sh`（见 [AGENTS.md](AGENTS.md)）。摄像头看到的是屏幕照在房间里的光；各档位的比例用一个不依赖摄像头特性的「零差测试」来核对。测试机是 14 英寸 MacBook Pro、macOS 27.2.1；那 9% 的补偿在其他机型上可能不同。
- **退出增亮后约 13 秒略暗**：增亮结束后 macOS 还会自己保持 HDR 模式约 15 秒，这段时间普通白色比标准暗约 7%，之后 macOS 降下背光，白色在约 2 秒内回到标准。不让 HDR 模式一直开着的话，Overbright 没法修正这一点。
- **越亮越热**。更高的亮度更耗电、发热更多。macOS 可能会自己把屏幕调暗，Overbright 不会去对抗它。
- **不要同时运行两个同类工具**。BetterDisplay、BrightIntosh、Lunar、f.lux 等也会改 Gamma 表。Overbright 检测到 Gamma 表已经被增亮时会拒绝开启。
- **不适合对色彩要求严格的工作**。增亮可能会让 HDR 照片和视频的高光细节被压掉，做这类工作前请先恢复标准亮度。
- **副屏只能在它自己的范围内调**：超过 100% 需要 EDR 余量，只有内置 XDR 屏有。副屏最高就是它自己的最大亮度。
- **DDC/CI 要显示器配合**：大多数显示器会响应，有的响应慢，少数接在扩展坞或转接头后面的完全不响应，会退回软件调暗。Overbright 除了亮度不会写任何其他设置。
- **只在有限的机型上测过**。CI 会跑不依赖硬件的测试并构建两种架构，但测不了真实面板。

## 从 Display Boost 升级？

从 2.0 版开始，Display Boost 改名为 Overbright。App 的标识符变了，所以请退出并删除 `Display Boost.app`，然后在「辅助功能」里给 Overbright 授权一次。旧的仓库地址会自动跳转到这里。

## 致谢

结合 EDR 余量和 Gamma 表来增亮，是 [BrightIntosh](https://github.com/niklasr22/BrightIntosh)、[BetterDisplay](https://github.com/waydabber/BetterDisplay) 等工具已经在用的做法。如果你想要一个功能更多、更成熟的工具，请用它们。Overbright 的目标不一样：小到你可以把它完全改成自己的。

菜单栏图标来自 [Lucide](https://lucide.dev)(ISC 许可,见 [LICENSES/lucide.txt](LICENSES/lucide.txt))。

## 许可证

[MIT](LICENSE)
