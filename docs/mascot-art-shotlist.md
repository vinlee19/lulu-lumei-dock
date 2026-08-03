# 噜噜 & 噜妹 行为与出图清单

内置包现在由三层素材共同组成：

- 原始场景贴纸：保留工作、睡眠、放松等单人完整场景。
- v2 双人精灵图：8×11 图集，保留原有循环动作和 16 向视线。
- v3 表情精灵图：4×12 图集、共 48 帧，增加协作、安慰、互动与作息表情。

v3 不替换 v2，而是作为更高权重的行为变体混入现有状态。当前内置包共 41 个
状态变体；成功、失败安慰、戳脸与起床等短反应只播放一次并停在末帧，日常动作循环。

## v3 动作表

| 行 | 状态 | 角色与动作 | 艺术字 | FPS | 播放 |
|---:|---|---|---|---:|---|
| 0 | `idle` | 噜噜和噜妹分享小零食 | `SNACK?` | 2 | 循环 |
| 1 | `working` | 两人围着笔记本结对工作 | `PAIRING` | 4 | 循环 |
| 2 | `working` | 噜妹从思考到灵光一现 | `GOT IT!` | 3 | 循环 |
| 3 | `waiting` | 噜噜查看清单并温和提醒 | `YOUR TURN` | 3 | 循环 |
| 4 | `success` | 两人击掌庆祝 | `HIGH FIVE!` | 5 | 单次 |
| 5 | `error` | 噜妹安慰失落的噜噜 | `I'M HERE` | 2.5 | 单次 |
| 6 | `error` | 噜噜鼓励失落的噜妹 | `ONE MORE` | 3 | 单次 |
| 7 | `relax` | 两人伸懒腰、喝茶休息 | `TEA BREAK` | 2 | 循环 |
| 8 | `sleeping` | 两人盖同一张粉色毯子入睡 | `COZY` | 1.5 | 循环 |
| 9 | `night` | 噜妹带困倦的噜噜去休息 | `BEDTIME` | 2 | 循环 |
| 10 | `poke` | 噜噜轻轻戳噜妹脸颊 | `BOOP!` | 6 | 单次 |
| 11 | `wake` | 两人打哈欠、伸展并清醒 | `MORNING!` | 4 | 单次 |

## 动画运行规则

- 动画时钟最高 20 FPS，各动作仍按自己的 FPS 取帧。
- 桌面伙伴隐藏或系统休眠时暂停取帧，显示或唤醒时重置播放起点。
- 重复点击伙伴会重新触发 `poke`，不会因为状态值相同而忽略。
- 空闲轮换包含睡眠与夜间动作；鼠标唤醒后重新计算空闲时间。
- 16 向视线继续使用 v2 图集，不受 v3 影响。

暂停、唤醒重锚和离线接触表的思路参考了 CodeIsland 的动画运行机制；这里只复用
机制设计，没有复制代码，也没有把桌面伙伴接入灵动岛视图。

## 最终出图提示词

生成工具使用 Codex 内置 `imagegen`，模式为 `stylized-concept`。每组都使用同一套
锁定提示，只替换动作描述：

> Create one production-ready 2x2 animation sprite sheet with exactly four equal square cells.
> Preserve the supplied Lulu and Lumei character identity exactly: Lulu is an orange-yellow
> capybara with a small tangerine on his head and beige fruit-print shorts; Lumei is the matching
> capybara with a pink polka-dot bow, blush, and pink floral pajamas. Use the existing soft,
> restrained 3D mascot style, fixed front three-quarter camera, consistent scale and lighting.
> The four cells must be consecutive keyframes of one controlled action, changing only pose and
> expression. Use a perfectly flat #00ff00 chroma background in every cell. No captions, letters,
> borders, grid lines, props not named in the action, watermark, cast shadow, or cropped body parts.

12 个动作替换项依次是：分享零食、结对编程、噜妹灵感、噜噜清单提醒、双人击掌、
噜妹安慰噜噜、噜噜鼓励噜妹、伸懒腰喝茶、共盖毛毯入睡、噜妹陪噜噜去睡、轻戳脸颊、
双人哈欠伸展。睡眠图额外要求不出现 `Z` 字符，夜间图不出现设备品牌标识，起床图保持
原角色脚部与服装，不增加拖鞋或衣领。

## 素材处理与视觉走查

每张 2×2 源图先用 `remove_chroma_key.py` 的 border 自动取色、soft matte 与 despill
转为透明 PNG，再用项目内置命令按固定白名单打包：

```bash
eureka --pack-mascot-v3 tmp/imagegen/mascot-v3/alpha \
  Sources/EurekaApp/Resources/mascots/lulu/lulu-lumei-duo-v3.png
```

打包器只读取规定的 12 个直接子文件，拒绝软链接、非 PNG、非正方形、奇数尺寸和
四角不透明素材，并拒绝覆盖已有输出。最终图集固定为 1024×3072，每格 256×256。

完整接触表可离屏生成：

```bash
eureka --render-mascot /tmp/eureka-mascot
```

该命令会遍历 10 个状态的全部内置变体，不再只渲染旧贴纸的首帧。

## 自定义动画包

把自定义素材放进“设置 → 桌面伙伴 → 打开动画包文件夹”，按
`manifest.example.json` 配置。旧的单动画状态继续兼容；可选 `variants` 可以为同一
状态增加多个行为，并分别设置 `caption`、`motion` 和 `weight`。
