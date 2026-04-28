# xterm.dart Windows 高 CPU 问题分析与优化方案

## 1. 背景与现象

当前项目在 macOS 下体感正常，但在 Windows 生产模式下，只要终端持续输出文本，CPU 占用就会明显升高。

典型场景：

- 输入 `git`、`git help`、`git log` 等命令时，大量文档文本持续输出
- 终端空闲时 CPU 基本正常
- 一旦输出频繁，CPU 迅速上升

这个现象说明问题核心不是“终端静止时的空转”，而是“高频输出时，解析、状态更新、UI 通知、渲染之间的协作方式不够经济”。

## 2. 当前实现存在的主要问题

### 2.1 `Terminal.write()` 每次调用都会立刻触发监听通知

当前 [lib/src/terminal.dart](~/xterm.dart/lib/src/terminal.dart:250) 的逻辑是：

- `write(data)` 立即调用 parser
- parser 处理后立即 `notifyListeners()`

问题在于：

- PTY/进程输出往往不是一次性大块给出，而是很多个小 chunk
- 每个 chunk 都会触发一次通知
- 一帧内可能发生多次 parser + 多次 terminal 更新通知
- 对最终屏幕结果来说，这些中间态大多没有展示意义

结论：

- parser 可以多次执行
- 但 render 通知不应该无节制地跟着每个 chunk 立即执行

### 2.2 当前 render 侧把很多变化都提升成了 layout 级别

当前 [lib/src/ui/render.dart](~/xterm.dart/lib/src/ui/render.dart:185) 的 `onTerminalChange()` 会直接 `markNeedsLayout()`。

这意味着只要终端输出有变化，就不仅触发重绘，还会触发布局相关工作。

问题在于：

- 普通文本追加，绝大多数时候不需要重新布局整个终端
- 很多变化本质上只需要 repaint
- layout 频率过高会额外放大 CPU 消耗

### 2.3 当前绘制模型是“可见区全量逐 cell 重绘”

当前 painter 的主要特点：

- 逐行遍历
- 每行逐 cell 绘制
- 前景文本以单字符 `drawParagraph` 为主

这在功能上是正确的，但在 Windows 上成本偏高，尤其在下面这类场景会被放大：

- 连续新行不断追加
- 上方旧内容实际上没有变化
- 但每次 repaint 仍然重新遍历和绘制整个可见区域

### 2.4 存在一个无效但持续唤醒的 `Timer.periodic`

当前 [lib/src/terminal.dart](~/xterm.dart/lib/src/terminal.dart:420) 存在一个 `100ms` 的周期定时器。

它原本的意图是：

- 在输出稳定后扫描 buffer
- 推断“用户当前输入的命令”
- 回调 `onTypingCommand`

但当前 `_checkBuffer()` 已经是直接 `return`，这意味着：

- 定时器仍在持续唤醒
- 但没有实际业务价值
- 会给桌面平台，尤其是 Windows，带来额外的空成本

## 3. 问题本质

这不是单纯的“Flutter 在 Windows 上天生不行”，也不是“parser 本身一定很慢”。

更准确地说，当前 CPU 高主要来自以下叠加：

1. 输出 chunk 很密
2. 每个 chunk 都立即触发一次 terminal 监听通知
3. render 侧对变化的粒度判断过粗
4. 可见区域采用全量逐 cell 重绘
5. Windows 文本绘制成本相对更容易被放大

所以需要从“更新合并、变化分类、脏区传播、绘制缓存”这几个层面逐步处理。

## 4. 关于 parser 与 render 的正确关系

需要明确一个关键点：

- 不是“把 parser 也延迟到下一帧再做”
- 而是“parser 仍然立即处理输入，但 render 通知合并到一帧一次”

原因：

- parser 是终端状态机，应该尽量保持顺序、实时、完整
- escape sequence 可能跨 chunk，不能随意拖延内部状态推进
- 真正浪费 CPU 的，不是 parser 执行次数本身
- 而是 parser 每处理一点点内容，就立刻引发一轮 UI 更新链路

因此合理模型应该是：

1. `write(chunk)` 立即 parse 到 buffer
2. 这次变更只记录到 update/damage accumulator
3. 如果本帧还没调度过 flush，则调度一次
4. 到帧边界时，把这段时间累计的变化一次性交给 render

可以概括为：

- `parse many times`
- `flush render once per frame`

## 5. 为什么不是按“1000Hz 渲染”

即使进程一秒输出 1000 个 chunk，Flutter 也不会真的绘制 1000 帧。

Flutter 的实际屏幕渲染通常受显示器刷新率约束，例如：

- 60Hz
- 120Hz

但这不代表 Dart 层不会做 1000 次工作。

如果现在每个 chunk 都：

- parse
- 通知 listeners
- 触发 render 对象脏标记

那么即使屏幕只画 60 帧，CPU 仍然可能因为前面的高频状态变更而很高。

所以这里要优化的是：

- 更新通知频率
- 变化传播粒度
- repaint/layout 的触发方式

## 6. 终端渲染的特性与优化机会

终端和普通 UI 有一个很重要的不同：

- 很多时候内容是在底部持续追加
- 上面的旧行一旦形成，通常不会再变化

例如：

- `git help`
- `find .`
- `ls -R`
- 普通日志流

这意味着存在明显的优化机会：

- 没必要每次都把整个可见区当成“可能变了”
- 可以优先把变化描述为：
  - 当前行变化
  - 一段行范围变化
  - 滚动区域变化
  - buffer 切换
  - viewport 尺寸变化

但要注意：

- 仅仅有 dirty range 信息，不代表 Flutter 会自动复用上半部分像素
- 真正做到“只追加底部，复用上方画面”，往往还需要行级缓存、Picture 缓存或更细粒度 retained strategy

因此应分两层理解：

1. damage/update 事件可以减少不必要的 layout 和重复计算
2. 行级缓存或 run 级缓存，才能进一步减少旧内容重复绘制

## 7. 变化来源：按 parser 指令还是按 buffer diff

这里不建议走两个极端：

### 方案 A：完全按 buffer diff 推导变化

问题：

- 每次都要比较“这次 buffer”和“上次 buffer”
- 成本高
- 终端有很多结构性操作，diff 不好推断语义

### 方案 B：完全由 parser 指令直接驱动 render

问题：

- parser 知道语义，但不知道最终落在 buffer 的真实范围
- render 若直接消费 escape 指令，会耦合过深

### 更合适的方案：parser + buffer 混合驱动

推荐模型：

- parser/handler 负责识别“操作类型”
- buffer 在真正修改数据时，顺手记录受影响范围
- 最终汇总成一个 update/damage 对象，供 render 使用

优势：

- parser 提供语义
- buffer 提供真实落点
- render 消费的是稳定的变化摘要，而不是低层 escape 动作

## 8. 推荐的 update/damage 模型

第一版不必设计得太细，建议先有一个可扩展的结构，至少支持以下信息：

- `dirtyTop`
- `dirtyBottom`
- `fullRepaint`
- `scrollExtentChanged`
- `bufferSwitched`
- `viewportResized`
- `cursorDirty`

它的用途不是立刻做复杂局部绘制，而是：

1. 先把“裸 notify”升级成“带语义的 update”
2. 为后续 render 分级处理打基础

## 9. 优化方向总览

### 方向一：移除无效定时器

收益：

- 低风险
- 直接去掉无效轮询

代价：

- 几乎没有

适合优先级：

- 最高

### 方向二：合并多次 `write()` 的通知

核心思路：

- `write()` 内部仍然立即 parse
- 但不要每次都立刻 `notifyListeners()`
- 改成同帧合并一次 flush

收益：

- 直接减少高频输出时的 UI 更新次数
- 实现相对简单

代价：

- 需要引入 pending update / frame flush 机制

适合优先级：

- 最高

### 方向三：把 terminal 的变化类型显式化

核心思路：

- 不再只有“有变化了”
- 而是要知道“变化是什么”

收益：

- 为后续 render 优化打基础
- 可以逐步区分 `paint` 和 `layout`

代价：

- 需要修改 handler/buffer/terminal 三层协作方式

适合优先级：

- 高

### 方向四：render 侧区分 `markNeedsPaint` 与 `markNeedsLayout`

核心思路：

- 普通文本输出，不应默认进入 layout
- 能 paint 的尽量只 paint

收益：

- 对 CPU 降低会比较直接

代价：

- 需要 render 读懂 update 类型

适合优先级：

- 高

### 方向五：面向追加输出场景的 append fast path

核心思路：

- 如果最近这批输出只是普通字符追加、换行、样式变化
- 没有 cursor 回跳、擦除、插行、删行、切 alt buffer
- 则走“追加型更新”路径

收益：

- 对 `git help`、长文档输出、日志流很有效

代价：

- 需要 update 类型进一步完善

适合优先级：

- 中高

### 方向六：painter 优化为 run 级绘制

核心思路：

- 不再每个 cell 单独 `drawParagraph`
- 把连续样式一致的文本合并成 run 绘制

收益：

- 能显著减少 draw call

代价：

- 改动较大
- 要处理宽字符、下划线、背景色等细节

适合优先级：

- 中

### 方向七：行级缓存 / Picture 缓存

核心思路：

- 已稳定的旧行不重复生成绘制内容
- 仅重建变更行

收益：

- 对持续向下追加文本的场景收益非常大

代价：

- 架构改动较大
- 缓存失效策略要设计好

适合优先级：

- 中后期

## 10. 推荐的实施顺序

建议按以下阶段推进。

### 第一阶段：低风险减压

目标：

- 先降低无意义的更新频率
- 不改变现有渲染模型

具体事项：

1. 删除 `Timer.periodic`
2. 给 `Terminal.write()` 增加一次更新批次
3. 在 handler/buffer 中累计 damage
4. `write()` 结束后不再立刻裸 `notifyListeners()`
5. 改为：
   - 合并到 `pending update`
   - 若本帧未调度，则调度一次 frame flush

这一阶段的收益：

- 直接减少一帧内重复通知
- 为后续优化建立事件基础

### 第二阶段：render 分级消费 update

目标：

- 不再把所有变化都当成 layout 事件

具体事项：

1. `RenderTerminal` 开始读取 terminal 的 update 信息
2. 区分：
   - 只需 repaint
   - 需要 relayout
3. controller、scroll、cursor 相关变化进一步细分

这一阶段的收益：

- 对连续输出场景 CPU 有进一步改善

### 第三阶段：追加输出优化

目标：

- 优化最常见的“底部持续追加文本”场景

具体事项：

1. 识别 append-heavy 更新模式
2. 针对普通滚动输出设计更轻量的重绘路径
3. 尽量避免把整个可见区视为全量变化

### 第四阶段：绘制层重构

目标：

- 降低 Windows 下文本绘制成本

具体事项：

1. run 级文本绘制
2. 行级缓存 / Picture 缓存
3. 进一步减少旧内容重复绘制

## 11. 当前建议的取舍

结合当前项目状态，建议先做第一阶段，不要一次性扑到 painter 大改。

原因：

- 第一阶段改动小、风险低
- 能立刻减少“多次 write 对应多次 notify”的问题
- 能为后续 render 优化提供统一 update 入口
- 更容易先验证 Windows CPU 是否明显下降

当前最适合先落地的选择是：

1. 删除无效 `Timer.periodic`
2. 引入 `TerminalUpdate` / `TerminalDamage` 的基础结构
3. 实现同帧合并通知

后续再分会话继续做：

1. render 区分 `paint` / `layout`
2. append fast path
3. painter run 级与缓存优化

## 12. 结论

这个项目当前在 Windows 下的高 CPU，主要不是单个模块“写错了”，而是终端持续输出场景下，更新传播和绘制策略还比较粗。

第一阶段优化的目标，不是一次性把终端变成最优实现，而是先建立正确的更新骨架：

- parser 继续实时处理
- buffer 记录真实变化
- terminal 合并 update
- render 未来按 update 类型决定如何刷新

这条路线能保持改动可控，也最符合当前项目逐步演进的节奏。
