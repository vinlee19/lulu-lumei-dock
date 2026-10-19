# 预设形象

这里的每个子文件夹就是一个预设形象，会出现在 设置 → 通用 → 桌面伙伴 →「预设形象」里，
排在内置的噜噜 & 噜妹后面（按文件夹名排序）。用户可以直接点选，不能在界面里修改或删除。

## 新增一个预设

1. 新建文件夹，名字就是预设的 id，只用小写字母、数字和 `-`，例如 `shiba/`。
   一旦发布不要改名：用户的选择按这个 id 保存（`preset:shiba`），改名后会退回噜噜。
2. 放入图片，建议正方形、长边 512px 左右、**透明底 PNG**（GIF / APNG 动图也行）。
3. 写一个 `manifest.json`，格式与用户自定义动画包一致：

```json
{
  "name": "柴犬",
  "fps": 2,
  "states": {
    "idle": "idle.png",
    "working": ["working-1.png", "working-2.png"],
    "waiting": "waiting.png",
    "success": "success.png",
    "error": "error.png",
    "sleeping": "sleeping.png"
  }
}
```

- 只有 `idle` 是必需的；其余状态缺图时沿回退链复用（night → sleeping → idle，
  success / error / relax → working → idle，poke / wake → idle）。
- 也支持 `captions`（各状态的英文艺术字）和 `variants`（同一状态的多个行为），
  写法见用户动画包文件夹里的 `如何制作动画包.txt` / `manifest.example.json`。

4. 重新构建即可（`Package.swift` 以 `.copy("Resources/mascots")` 打包整个目录）。
   `swift run eureka --render-mascot` 目前只渲染内置噜噜，预设请在设置页里直接预览。
