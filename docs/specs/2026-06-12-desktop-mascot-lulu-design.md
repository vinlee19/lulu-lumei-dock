# 设计:常驻桌面吉祥物「水豚噜噜」

> 由 brainstorming 整理（2026-06-12）。这是「放松提醒」三连功能（今日战报卡 / 放松动画 / subagent 呈现）里的第一个,独立成 spec→plan→实现。

## Context（为什么做）

Eureka 现在靠灵动岛 + 关怀卡（`WellnessAdvisor` → `IslandNotice`）提醒用户「跑太久了歇一下」,但表达克制、纯文字。用户希望加一个**有陪伴感的桌面吉祥物**——一只原创水豚「噜噜」,常驻桌面、随 agent 状态变表情、在该歇时做放松动作并冒气泡,把「提醒放松」从一句文案升级成一个会卖萌的小伙伴。参考 `clawd-on-desk`(Electron 桌宠,12 个动画态、可导入动画包),但要落在 Eureka 的约束里:**零第三方依赖、全本地、不抢焦点、中文 UI**,且不打包受版权保护的素材。

## 范围 / 非目标

- **范围**:一个独立常驻小窗里的动画吉祥物,与灵动岛并存;内置原创矢量水豚 + 可导入 GIF/APNG 动画包;状态随 agent/关怀/空闲推导;放松气泡;基础互动。
- **非目标**:不替代灵动岛(岛给信息,吉祥物给情绪);不做移动端/远程;不内置任何受版权保护的角色(默认角色为原创水豚,用户可自带动画包);不引入第三方库(Lottie 等)。
- **版权**:默认角色「噜噜」为原创水豚形象,非特定 IP;具体 IP 素材由用户以动画包形式自备。

## 形态与定位

- 独立 `NSPanel`:无边框、`.nonactivatingPanel`、浮于桌面、不抢焦点;透明背景,仅角色区域可点(其余穿透),镜像灵动岛的 hitTest 思路。
- 与灵动岛**并存**:岛=任务信息,噜噜=情绪/陪伴/放松提醒。
- **默认关闭,设置页 opt-in**(符合「不打扰」调性)。位置可拖拽、独立持久化(`UserDefaults` 键独立于岛,如 `mascotOriginX/Y`)。
- 右键菜单:隐藏吉祥物 / 勿扰 / 选择动画包 / 打开设置。

## 默认角色:水豚噜噜 &amp; 噜妹（内置图片包,用户提供的原创美术）

用户提供了 10 张 3D 渲染 PNG(噜噜橙色、噜妹粉蝴蝶结),= **5 场景 × 2 帧**,正好做 2 帧循环。降采样到 480px、按状态命名打包进 `Sources/EurekaApp/Resources/mascots/lulu/`,作为**内置图片包**(取代原矢量方案——有真实美术更好)。映射:

| 帧文件 | 场景 | 状态 |
|---|---|---|
| `working-{1,2}` | 噜噜盯代码屏敲键盘(认真) | `working` |
| `success-{1,2}` | 噜噜笔记本前·✨·「今天也要超棒喔!」 | `success` |
| `sleeping-{1,2}` | 噜噜粉床睡觉·Z | `sleeping` |
| `night-{1,2}` | 噜噜桌前打盹·鼻涕泡·ZZZ | `night`(深夜困倦) |
| `relax-{1,2}` | 噜妹趴云朵慵懒 | `relax` / `idle`(临时复用) |

**缺图(用户可后补,丢进包即换,零代码改)**:`idle`(噜噜清醒待命)、`waiting`(招手期待)、`error`(沮丧)。一期临时方案:`idle`→复用 relax 慵懒帧;`waiting`/`error`→复用 working 帧 + 气泡文案区分。

**渲染:圆角贴纸卡片,不抠图**。原图纯白底(#fefefe)+ 白描边 + 床品大片白,抠白会破洞;故显示在小圆角白卡 + 柔影里(像桌面动图贴纸)。平滑渐变转 256 色 GIF 会色带,故**内置包用 PNG 帧、app 内按帧循环**(全彩)。二期再考虑透明精修。

## 动画包格式（可导入,像 clawd;同时支持 GIF/APNG 与 PNG 帧）

- 内置包:`Sources/EurekaApp/Resources/mascots/lulu/`(随 app 打包),映射在代码里硬编码(免解析)。
- 自定义包:`~/Library/Application Support/Eureka/mascots/<包名>/` + `manifest.json`:
  ```json
  {
    "name": "我的噜噜",
    "fps": 2,
    "states": {
      "idle": "idle.gif",                       // 单文件:gif/apng → NSImageView 原生播放
      "working": ["work-1.png", "work-2.png"],  // 帧数组:png/jpg → app 内按 fps 循环
      "waiting": "wait.apng", "success": "yay.gif", "error": "oops.gif",
      "sleeping": "sleep.gif", "relax": "stretch.gif", "night": "sleepy.gif"
    }
  }
  ```
- 每状态值 = 字符串(gif/apng 自播放,或单 png 静帧)**或** 帧文件数组(按 `fps` 循环)。
- 缺失状态回退 `idle`;`idle` 缺失则包无效 → 回退内置。
- 渲染后端:`MascotAnimation` 枚举(`.frames([URL], fps)` 走 SwiftUI 帧循环 / `.animatedImage(URL)` 走 `NSImageView`)。
- 设置页列出 `mascots/` 下的包 + 「噜噜&噜妹(内置)」,选当前包写入 `mascotPack`。

## 状态机（= 动画包要支持的状态套件）

纯函数 `MascotStateResolver`(EurekaKit,可单测):输入「活跃任务摘要 + 最近一条关怀通知 + 空闲时长 + 当前时钟」→ 输出 `MascotState`。

- **基础态(循环播放)**:`idle`(平静呼吸)/ `working`(有任务在跑,专注)/ `sleeping`(空闲超 `mascotIdleSleepSeconds`,或深夜无活跃任务)
- **瞬时态(播一次回到基础态)**:`waiting`(有任务等确认·招手)/ `success`(刚完成·庆祝)/ `error`(刚出错/中断·沮丧)/ `relax`(关怀触发·伸懒腰)/ `night`(深夜还在跑·困倦)/ `poke`(被点)/ `wake`(睡眠时鼠标移动惊醒)
- **优先级**(并发时取最高):`waiting > error > success > relax/night > working > sleeping > idle`
- 瞬时态播放 `~2–3s` 后回落到当前应有的基础态。

> `waiting`(有任务等你授权/输入)在桌宠语境是"招手喊你",优先级最高——和灵动岛橙卡同源(`AgentTask.phase == .waiting`)。

## 四类行为如何落地

1. **随 agent 状态变表情**:复用喂灵动岛的同一套 `TaskStore` 副作用(`AppDelegate.applyToUI` 已有 `taskFinished`/`taskWaiting`/`activeTasksChanged`)→ 映射 working/waiting/success/error,并用 `store.sortedActiveTasks/idleTasks` 维持基础态。
2. **关怀时动作 + 气泡台词**:`WellnessMonitor` 现产出的 `IslandNotice` 同时分发给吉祥物 → 进 `relax`(或深夜 `night`)动作 + 冒气泡显示该 notice 的 `headline`(必要时带 `body`),**复用现有文案池**,不另写。
3. **宠物式空闲**:`MascotViewModel` 起空闲计时,超 `mascotIdleSleepSeconds`(默认 60s)→ `sleeping`;二期:`NSEvent.addGlobalMonitorForEvents(.mouseMoved)` → `wake`;点击角色 → `poke`。
4. **深夜模式**:23:00–06:00 且有活跃任务 → `night` 困倦表情 + 催睡气泡(夜里那条文案);二期。

## 模块与分层（沿用灵动岛的分层与模式）

- `EurekaKit`
  - `MascotState`(枚举)
  - `MascotStateResolver`(纯逻辑:输入摘要 → 状态 + 优先级;瞬时/基础判定。**单测目标**)
- `EurekaApp`
  - `MascotPanelController`:镜像 `IslandPanelController`——`NSPanel` 创建、拖拽 + 位置持久化(独立 `MascotPositionStore`)、右键菜单、显隐随 `mascotEnabled`。
  - `MascotViewModel`(`@MainActor ObservableObject`):当前 `MascotState`、气泡文本、空闲计时、瞬时→基础回落。
  - `MascotView`(SwiftUI):根据当前包选渲染后端——`VectorMascotView`(默认噜噜)/ `ImagePackMascotView`(`NSImageView` 包一层);叠加气泡 `SpeechBubble`。
  - `MascotPackLoader`:扫描 `mascots/` + 解析 `manifest.json` + 缺状态回退(**manifest 解析可单测**)。
- `AppSettings`:`mascotEnabled`(默认 `false`)、`mascotPack`(默认 `"built-in"`)、`mascotDND`(二期)、`mascotIdleSleepSeconds`(默认 60,二期可调)。
- 接线:`AppDelegate` 持有 `MascotPanelController`,把现有 `TaskStore` 副作用 + `WellnessMonitor` 通知**同时**分发给岛和吉祥物(现在只发岛)。

## 交互

- 拖拽移动(位置独立持久化);右键菜单:隐藏 / 勿扰 / 选动画包 / 设置。
- 二期:点击=`poke` 反应;鼠标移动从睡眠 `wake`;勿扰=暂停动画与提醒(省电)。

## 测试

- `MascotStateResolver`:优先级取舍、瞬时→基础回落、空闲→`sleeping` 边界、深夜判定(复用 `WellnessAdvisor` 同款时钟注入便于测)。
- `MascotPackLoader`:`manifest.json` 解析、缺状态回退到 idle、无效包(缺 idle)回退内置。
- 进自建 runner(`Tests/EurekaTestsRunner`),在 `main.swift` 注册。

## 分期

**一期(核心,可用)**
- `AppSettings`:`mascotEnabled`(默认关)、`mascotPack`。
- `EurekaKit`:`MascotState` + `MascotBaseResolver`(基础态 `idle/working/waiting/sleeping/night`,纯函数);瞬时态 `success/error/relax` 由 ViewModel 按事件叠加 + 计时回落。
- `MascotPanelController`(面板/`isMovableByWindowBackground` 拖拽/位置持久化/SwiftUI `.contextMenu`:隐藏·设置)。
- `MascotViewModel` + `MascotView`(贴纸卡 + 气泡 + 帧循环/`NSImageView` 双后端) + `MascotPack`/`MascotPackLoader`。
- 内置图片包(噜噜&噜妹,已打包进 Resources;`night` 因素材已到一并纳入一期)。
- `AppDelegate` 接线(TaskStore 副作用 + 关怀通知 → 吉祥物);关怀/完成/出错气泡。
- 设置页:开关 + 动画包选择。
- 测试:`MascotBaseResolver` + `MascotPackLoader`(manifest 解析/回退)。

**二期(打磨)**
- `poke`(点击)/ `wake`(全局鼠标移动)互动态 + 表情;补 `idle`/`waiting`/`error` 专属美术。
- `mascotDND` 勿扰(暂停动画与提醒)、`mascotIdleSleepSeconds` 可调。
- 透明抠图(去白底)、更多表情打磨。

## 验证

- `make test` 含新 resolver / manifest 测试。
- `make run`:设置页开启吉祥物 → 桌面出现噜噜;跑 claude/codex 任务看 working/waiting/success/error 切换;`defaults write com.vinlee.eureka wellnessDemo -bool true` 触发关怀看 relax 动作 + 气泡;空闲 60s 看 sleeping;拖动位置重启后保留;放一个测试动画包到 `mascots/` 看导入生效。
- 离屏渲染:为噜噜各状态加预览(扩展 `--render-previews`)肉眼核对表情。
