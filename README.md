# 一个小输入法 / A Little Input Method

将 [Fcitx5-Android](https://github.com/fcitx5-android/fcitx5-android) 及其 Rime 插件移植到 **HarmonyOS NEXT（API 26.0.0）**。

当前仓库已经可以构建出一个**包含真实 Rime 引擎的输入法 HAP**，同时 **fcitx5 core 5.1.23 及其 lua / rime 插件也已成功交叉编译为 OHOS `arm64-v8a` 库**。

---

## 声明：关于 AI 参与与安全性

作者目前为**高三在读学生**。受学业时间限制，本项目在开发过程中**大量使用了 AI 辅助生成**——包括C++ 原生层、UI界面、构建脚本与文档，整体代码架构由人工完成。并且作者只会Java，几乎不会C++（不嘻嘻）。

由此带来的实际情况：

- **代码可靠性与安全性未经系统性审计，存疑。**
- 学习与借鉴时请自行甄别。**不建议直接用于生产环境，也不建议用于处理敏感信息。**
- 尤其注意：**本项目是一个输入法。启用后它会接触到您在其他所有应用中的按键输入。** 请充分评估这一风险后，再决定是否安装、启用。

承诺：2027 年高考结束后，将对项目中所有涉及 AI 生成的内容进行审查或重构，以保证其安全性。在此之前，请把本项目视为**学习与实验用途**。

本声明同样展示在应用内首页。

文档的生成有AI参与，AI标注分为以下类型：

| 标注类型 | 编写方式 |
| --- | --- |
| 无标注 | 该标题下内容完全由人工完成编写工作，可信度最高 |
| 由AI辅助生成 | 该标题下内容由AI阅读代码及我的简述后先行生成，经人工检查并修正，可信度较高 |
| 由AI生成 | 该标题下内容完全由AI阅读代码及我的简述后生成，烦请自行斟酌准确性 |

注释由AI阅读代码后生成，请自行斟酌准确性。***作者比较懒且高三比较忙，懒！***

---

## 反馈与联系

**邮箱：blueberry_xia@qq.com**

- 发现**侵权**内容（包括无意间引入的、许可证不兼容的代码或资源），请邮件告知，会尽快处理
- **问题反馈、功能建议**：邮件或在本仓库提交 issue 均可
- 感谢每一份反馈，尤其是具体的复现步骤和日志，它们比笼统的描述有用得多（人话：反馈时请尽量提供复现步骤和日志）

**关于 Pull Request 的致歉**：作者目前高三在读，时间与精力有限，**无法保证及时审阅和合并 PR**。如果您提交了 PR 而迟迟没有回应，并非不重视——请见谅。改动建议先发 issue ，以免您的工作白费。

---

## 许可证

本项目以 **GNU Affero General Public License v3.0 or later** 发布，全文见 [`LICENSE`](LICENSE)。

选择它的原因：需求是「可以被学习和借鉴，但不允许商业性质的二次分发」。**OSI 认可的许可证不可能禁止商业使用**（[开源定义](https://opensource.org/osd)第 6 条禁止限制特定领域用途），而 AGPL-3.0 实现了最接近的效果——商业使用允许，但只要**分发衍生作品或通过网络提供服务**，就必须以 AGPL 提供完整源码。因此没人能把本项目改一改闭源卖钱。

***小声：做这个其实是因为老父亲给我买了Pura90，但是没注意国行和国际版的芯片不一样，刷不了安卓。然而应用市场里面那个基于rime的输入法收费太贵了，买不起。又非常喜欢Rime，同时先前手机和电脑同时使用积攒了大量的Userdb，并不想抛弃。因此打算自己改一个用。***

第三方组件的许可证审计、兼容性分析以及合规做法见 [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。所有许可证全文随 HAP 分发，应用内首页「开源许可」卡片可逐条阅读。

每个自研源文件带 SPDX 标识：

```
SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (C) 2026 Haochen Xia
```


## 1. 当前状态(由AI生成)

| 组件 | 状态 | 产物 |
| --- | --- | --- |
| OHOS 交叉编译工具链 | ✅ 完成 | 封装官方 `ohos.toolchain.cmake`，支持 arm64-v8a |
| librime 第三方依赖 | ✅ 完成 | marisa、yaml-cpp、leveldb、glog、boost.regex、opencc |
| **librime 1.17** | ✅ 完成 | `librime.a`（aarch64，14.5 MB） |
| **fcitx5 core 5.1.23** | ✅ 完成 | `libFcitx5Core.a` / `libFcitx5Utils.a` / `libFcitx5Config.a` |
| **fcitx5-lua** | ✅ 完成 | `libluaaddonloader.so` + `liblua.a`（Lua 5.4.7） |
| **fcitx5-rime** | ✅ 完成 | `librime.so`（fcitx5 插件，aarch64） |
| fcitx5 内置模块 | ✅ 完成 | quickphrase / unicode / clipboard / spell / imselector |
| NAPI 桥接层 `libentry.so` | ✅ 完成 | 30+ 个接口，含部署通知回调 |
| ArkTS 输入法扩展 | ✅ 完成 | `InputMethodExtensionAbility` + 软键盘面板 + 候选栏 |
| Rime 方案数据 | ✅ 完成 | 内置朙月拼音 / 仓颉五代（librime `data/minimal`） |
| HAP 打包 | ✅ 完成 | `hvigorw assembleHap` 通过，产物含 `libentry.so` 与方案数据 |
| **fcitx5 引擎接入 NAPI** | ⏳ 待做 | 库已就绪，尚未在 `libentry.so` 中实例化 `FcitxInstance` |
| **更多功能的加入** | ⏳ 待做 | 剪贴板，颜文字，灵动字体，九键支持，输入控制，物理键盘支持，平板支持…… |


---

## 2. 架构(由AI生成)

```
┌──────────────────────────────────────────────────────────────┐
│ ArkTS 层                                                     │
│                                                              │
│  RimeInputMethodExtension.ets   InputMethodExtensionAbility  │
│         │  创建面板 / 监听 inputStart·inputStop               │
│         ▼                                                    │
│  KeyboardHub.ets  ──单例──▶ RimeEngineService.ets            │
│         │                        │ 配置·部署·会话·按键        │
│         ▼                        ▼                           │
│  InputConnection.ets        (LocalStorage 状态发布)           │
│  预览文本·提交文本               │                            │
│         │                        ▼                           │
│         │                 pages/KeyboardPanel.ets（软键盘）    │
└─────────┼────────────────────────────────────────────────────┘
          │ NAPI（同步调用）
┌─────────▼────────────────────────────────────────────────────┐
│ 原生层  libentry.so                                          │
│                                                              │
│  napi_init.cpp   ←→  rime_engine.cpp                         │
│  参数校验 / 类型转换     互斥锁保护、通知队列                   │
│                              │                               │
│                              ▼                               │
│  librime.a（whole-archive 链接，保证模块构造器不被丢弃）        │
│    ├── boost_regex     ├── opencc（含内置 marisa）             │
│    ├── glog            ├── leveldb                            │
│    ├── marisa          └── yaml-cpp                           │
└──────────────────────────────────────────────────────────────┘
```

### 按键数据流(由AI生成)

1. 软键盘按钮 → `KeyboardHub.onKey(keyCode, unicodeChar, modifiers)`
2. `RimeKeys` 把鸿蒙键码翻译成 **X11 keysym**（librime 的键码约定）
3. `rime.processKey(session, keysym, mask)`
4. `rime.getCommit()` 取提交文本、`rime.getContext()` 取候选与预编辑
5. 提交文本 → `InputConnection.commitText()`；预编辑由键盘自己显示（见 §6 相关条目）
6. 状态写入 `LocalStorage`，`KeyboardPanel` 通过 `@LocalStorageLink` 自动刷新

---

## 3. 目录结构(由AI生成)

> **`test_file/` 不参与构建，已被 `.gitignore` 排除。** 里面是从上游克隆的参考项目（`fcitx5-android`、`fcitx5-harmony`）与测试用配置（`test_config`）。它们对阅读和本地验证有用，但不是项目源码的一部分。


```
entry/src/main/
├── cpp/
│   ├── CMakeLists.txt              # 模块原生构建（只编译 NAPI 桥接层）
│   ├── ohos.toolchain.cmake        # OHOS 交叉编译工具链封装
│   ├── librime/                    # librime 源码（已克隆）
│   ├── rime_napi/
│   │   ├── rime_engine.h/.cpp      # librime 封装（线程安全）
│   │   └── napi_init.cpp           # NAPI 导出
│   ├── types/libentry/Index.d.ts   # 原生模块类型声明
│   └── thirdparty/                 # 依赖源码 + build/ + install/
├── ets/
│   ├── entryability/EntryAbility.ets
│   ├── entrybackupability/EntryBackupAbility.ets
│   ├── inputmethod/
│   │   ├── RimeInputMethodExtension.ets   # 输入法扩展（生命周期）
│   │   ├── RimeEngineService.ets          # 引擎单例、部署、状态
│   │   ├── KeyboardHub.ets                # 按键入口（UI ↔ 引擎）
│   │   ├── InputConnection.ets            # 编辑器读写
│   │   └── RimeKeys.ets                   # 键码映射
│   └── pages/
│       ├── Index.ets                      # 设置 / 状态页
│       └── KeyboardPanel.ets              # 软键盘 UI
└── resources/
    ├── rawfile/rime/                      # 内置 Rime 方案数据
    └── base/profile/input_method_config.json

scripts/
├── fetch_sources.sh    # 拉取全部第三方源码
├── build_thirdparty.sh # 交叉编译依赖
├── build_engine.sh     # 交叉编译 librime / fcitx5
└── build_all.sh        # 一键全流程
```

---

## 4. 环境要求(由AI生成)

- **DevEco Studio**（自带 HarmonyOS SDK API 26 与 OHOS NDK）
  - 本仓库在 `/opt/devecostudio` 下验证通过
  - 原生工具链：`sdk/default/openharmony/native`（clang 15.0.4，target `aarch64-linux-ohos`）
- **CMake ≥ 3.16**、**Ninja/Make**、`bash`
- 磁盘：约 3 GB（依赖源码 + 中间产物 + Boost 头文件）

---

## 5. 构建

```bash
# 一键全流程
scripts/build_all.sh

# 或者分步执行（便于定位问题）
scripts/fetch_sources.sh                 # 拉取源码
scripts/build_thirdparty.sh              # 编译依赖
scripts/build_engine.sh                  # 编译 librime
hvigorw assembleHap --no-daemon          # 打包 HAP
```

生成的HAP包位置：`entry/build/default/outputs/default/entry-default-unsigned.hap`

参数：

```bash
scripts/build_thirdparty.sh --only glog       # 只编译某个依赖
scripts/build_thirdparty.sh --clean           # 清理构建树
scripts/build_engine.sh --only librime
JOBS=8 OHOS_ARCH=arm64-v8a scripts/build_all.sh
```

### 国内网络(由AI生成)

GitHub 直连经常失败，`fetch_sources.sh` 默认通过 **gh-proxy.com** 加速所有 `github.com` 的 clone 与 release 下载：

```bash
GH_PROXY=https://gh-proxy.com scripts/fetch_sources.sh   # 默认值
GH_PROXY= scripts/fetch_sources.sh                       # 关闭加速，直连
```

脚本对每个组件都会重试，单个组件失败不影响其他组件；下载支持断点续传。

### 关于 Boost

librime 只需要 Boost 的**头文件**，以及唯一需要编译的组件 **Boost.Regex**。

- **首选**：`scripts/fetch_sources.sh --only boost` 下载完整源码包（约 95 MB）。
- **回退**：完整包难以下载时，`build_thirdparty.sh` 会自动改用「构建机上的 Boost 头文件 + `boostorg/regex` 源码」。脚本会打印警告。两部分的 Boost 版本必须一致，`fetch_sources.sh` 会根据 `/usr/include/boost/version.hpp` 自动选择对应 tag。
- Boost 1.84+ 起 Regex 基本已头文件化，实际只需编译 `posix_api.cpp`、`wide_posix_api.cpp`。

### 关于 libuv

OHOS sysroot 自带 `libuv.so`（1.44.1）与 `uv.h`。上游 libuv 在 musl 上因 `sched_getaffinity`/`cpu_set_t` 不可用而编译失败，因此 fcitx5 阶段应直接使用**系统 libuv**，而不是自行编译。

---

## 6. 移植过程中的关键技术(由AI生成)

| 问题 | 处理方式 |
| --- | --- |
| `--gcc-toolchain` 被 clang 判为 unused，遇到 `-Werror` 直接报错 | 工具链中清空 `CMAKE_*_COMPILER_EXTERNAL_TOOLCHAIN`（SDK 内并无 GCC） |
| `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` 会让 `check_library_exists` 等**负向探测全部误判成功** | 保持默认值，让 try_compile 正常链接 |
| librime 强依赖 `<X11/keysym.h>`，OHOS 无 X11 | 从 xorgproto 引入纯常量头文件（`keysym.h`、`keysymdef.h` 等） |
| marisa-trie 0.2.6 只有 autotools 构建 | 编写 overlay CMakeLists（9 个编译单元） |
| librime 的模块通过 `__attribute__((constructor))` 自注册，静态库链接时会被丢弃 | `libentry.so` 用 `-Wl,--whole-archive` 链接 `librime.a` |
| 静态库之间存在互相依赖 | 所有静态库包在 `-Wl,--start-group … --end-group` 中 |
| librime 的 `deploy()` 会阻塞等待维护线程，而维护线程又要回调通知 → 死锁风险 | 引擎锁与通知锁分离；通知在 sink 未就绪时进入队列 |
| 会话 ID 是 `uintptr_t`（对象地址） | 通过 `napi_create_int64` 以 JS number 传递；48 位地址空间远小于 2^53，无精度损失 |
| `@LocalStorageLink` 需要字面量键 | 面板页面使用字符串字面量，并用 `RimeStateKey` 注释对应关系 |

### 6.0 运行时踩坑（输入法框架）(由AI生成)

| 问题 | 现象 | 处理方式 |
| --- | --- | --- |
| `Panel` 创建后必须显式 `show()` | 点输入框键盘不弹 | 文档规定 `show()` 只能在输入法绑定到编辑框后调用，因此放在 `inputStart` 里；`inputStop` 里 `hide()` |
| 固定软键盘面板必须 `resize()` | 面板高度为 0，页面 `height('100%')` 渲染成空 | 创建后 `resize(屏宽, 屏高 × 0.42)`（文档限制不超过屏高 0.7）；页面另加 `minHeight` 兜底 |
| **`deleteForward` / `deleteBackward` 命名与语义相反** | 退格键只能删预编辑、删不掉文本框内容 | 官方文档：`deleteForward(n)` 删光标**前**，`deleteBackward(n)` 删光标**后**。退格必须用 `deleteForwardSync`。`getForward`/`getBackward` 同样相反 |
| 用 `setPreviewText()` 把拼音内联显示在输入框里 | 不支持预上屏的应用会**一直不回应**，每次按键都占住 IPC 通道直到超时，表现为**选了候选词要过很久才上屏**。对比：微信输入法等在对同一应用输入时毫无延迟，因为它们根本不用预上屏 | **放弃预上屏**，改由键盘自己在候选词上方画一行拼音（`KeyboardPanel.PinyinRow`），完全不需要应用配合 |
| `InputMethodSubtype.mode` 只接受 `'upper' \| 'lower'` | 配置写入 `"pinyin"`/`"latin"` 属非法值 | 移除 `mode`，用 `locale` + `id` 区分中英 |
| `input_method_config.json` 必须严格 JSON | 加注释后 `CompileResource` 直接失败（错误码 11203002） | 该 profile 文件不接受 `//` 注释 |
| 用 `insertTextSync()` 等同步接口提交文本 | 向不响应的应用（如在兼容层里运行的应用）输入时，主线程会**停在阻塞式 IPC 上**，约 6 秒后被系统判为 `THREAD_BLOCK_6S` 而冻结进程 | 改用异步版本（`insertText()` 等），经 `InputConnection` 内的一条 Promise 队列串行化；每个调用再用 `settleWithin()` 加上限时——因为异步调用只是不阻塞线程，遇到**永不回应**的应用时它的 Promise 永不 settle，一条单纯等待的队列会被永久堵死 |
| 键位行用固定高度、而面板顶部又加了内容 | 底部按键被挤出可视区域 | 与符号/Emoji 网格同理：键位行改用 `layoutWeight(1)` 平分顶部剩余的空间，新增的拼音行（16vp）与临时提示行都不会再裁掉底行 |
| 按键行 `Row` 未设 `.width('100%')` | 每个字母键宽度都不同 | `layoutWeight` 需要父容器有确定的主轴尺寸；否则 ArkUI 退化为按内容宽度排布。每个键行必须显式 `width('100%')` |
| 页面根节点用 `height('100%')` | 底部一行离屏幕底部过远 | 根节点改为固定 vp 高度，与 `panel.resize()` 用同一套几何常量（`KeyboardMetrics.ets`），面板尺寸即内容尺寸 |
| 收起键盘按钮放在独立状态栏 | 按钮位置与其它键错位 | 移到候选词栏右上角，不参与按键行的等分布局；有未确认输入时同一位置显示为 ✕，按下清空拼音与预上屏（见 §7） |
| `copyDir` 与 `copyFile` 的 `mode` 约定**相反** | 覆盖导入时大量文件失败 | `copyDir`：0 冲突即抛异常、1 强制覆盖；`copyFile`：0 就是覆盖（且是唯一支持值）。本项目的文件夹导入按文件逐个复制，用的是后者 |
| 文件 API 文档写"沙箱路径"，而选择器返回的是文档 URI | 某些文件提供方 `stat()` 失败，目录判定错误 | 先 `statSync()`，失败则回退用 `listFile()` 探测（对目录成功、对普通文件失败） |
| ArkTS 模块间循环 import | 运行时取到 undefined | `RimePaths` 与 `RimeConfigStore` 拆成单向依赖（前者不引用后者） |
| 硬编码 Settings 的 bundle/ability 跳转输入法设置 | 打开后页面空白 | 改用 `inputMethod.getSystemInputMethodConfigAbility()` 取回真实的 `ElementName`；失败再回退到输入法选择器 |
| 文件夹选择返回的是文档 URI，`fs.listFile` 文档要求沙箱路径 | 枚举不到内容，表现为"未选择文件夹" | URI 与 `fileUri.FileUri(uri).path` 两种形式都尝试，取能列出内容者；并区分"选择器没返回"与"读不到内容"两种报错 |

### 6.2 ArkUI `@Builder` 的参数陷阱(由AI生成)

用 `@Builder` 封装按键时，**只要带了参数就是按值传递**，状态变化时 ArkUI 不会重新执行它。这直接造成了两个可见 bug：

| 现象 | 原因 |
| --- | --- |
| 中/英 切换后标签和配色不变，看起来"没生效" | `ActionKey(label, weight, active, action)` 把 `state.asciiMode` 当参数传入，值被冻结在首次渲染 |
| 向左翻页点了没反应 | `PageArrow(glyph, active, action)` 的 `active` 冻结在首帧（此时 `pageNo === 0`），点击处理器里的 `if (active)` 永远为假 |

处理方式：**凡内容依赖组件状态的 UI 一律不用带参 `@Builder`**——要么直接内联（字母键），要么写成无参 `@Builder` 直接读 `this.state`（中/英、翻页、收起、回车）。唯一保留的带参 `PlainKey` 只承载常量标签，且传入的闭包是**晚绑定**的（点击时才求值 `this.firstVisibleIndex()`），因此不受影响。

### 6.3 候选词分页(由AI辅助生成)

分页改由前端负责，不再依赖 librime 的 `menu/page_size`：

* 原生侧新增 `getCandidateList()`，通过 `candidate_list_begin/next/end` 遍历**全部**候选。librime 的 `Menu::GetCandidateAt()` 会按需从 translation 拉取，所以迭代器确实能走完整个列表，而不是只到当前页。
* 前端按候选文本的**估算宽度**（中日韩字符按 18vp、其余按 9.5vp）贪心切页，因此每页数量随候选长度自适应；短候选每页更多，长候选更少。
* 每页至少放一个候选，避免超长候选产生空页导致翻页卡死。
* 选中回调使用候选在**完整列表中的全局索引**，与 `select_candidate(session, index)` 的语义一致。

可用宽度通过 `onAreaChange` 在布局时实测，而不是写死。

### 6.4 由 Rime 配置驱动的设置面板(由AI生成)

键盘左上角的三点按钮打开「方案设置」，内容**全部来自 Rime 配置**，没有任何硬编码的开关列表：

* **方案**：`getSchemaList()`，点击切换当前方案。
* **选项**：`getSchemaSwitches(schemaId)` 读取当前方案 YAML 的 `switches:` 段。

原生侧用 `schema_open()` 打开方案配置——它会**连带应用用户的 `<方案>.custom.yaml` 补丁**，再用 `config_begin_list/next` 遍历，因此面板反映的是用户实际生效的配置。

需要注意方案里 `switches` 的两种写法：

```yaml
# 普通开关：name + states（states 的下标即值）
- name: ascii_mode
  reset: 0
  states: [ 中文, ABC ]

# 单选组：options + states（同一时刻只有一个为真）
- options: [ zh_trad, zh_simp, zh_hk, zh_tw ]
  states: [ 傳統漢字, 简化字, 香港字形, 臺灣字形 ]
```

内置的朙月拼音正是用**后者**表达字形切换。只读 `name` 会导致这类开关被静默丢弃，所以两种形式都要处理：普通开关取反，单选组则是「关掉当前项、打开下一项」。

面板每次打开和每次改动都会**重新从引擎读取**（`getOption`），而不是用本地推断——Rime 自己也会翻动选项（例如按下 Shift 会切换 `ascii_mode`），缓存必然与实际脱节。

### 6.5 配置变更后的重载(由AI生成)

设置面板读取的内容（方案列表、方案 `switches`）全部来自 Rime 配置，因此**任何部署或方案切换都会让这些数据过期**。处理方式分两个层次：

**同一进程内**：`RimeEngineService` 维护一个 `configGeneration` 计数器，在以下时机自增并随状态一起发布：

* `deploy` 通知的 `success` / `failure`（部署可能部分改写了用户数据）
* `schema` 通知（切换方案会整组换掉 `switches`）
* `selectSchema()` 调用

面板监听 `configGeneration`，一旦变化就重新读取方案与选项。

**跨进程**：输入法扩展与应用主界面**可能不在同一进程**，此时两边各有一份 `RimeEngineService` 实例，计数器互不可见。因此部署完成时会在用户目录写入一个时间戳文件：

```
<filesDir>/rime/user/.deploy-stamp
```

没有执行部署的一方在**键盘获得焦点（`inputStart`）**和**打开设置面板**时读取该文件，发现与上次记录不同就：自增 `configGeneration` → 销毁会话（会话里缓存着编译好的方案数据）→ 发布状态。这样下一次按键就会用新配置重建会话。

> 前缀点号让该文件不会被 `RimeConfigStore.list()` 当成用户配置列出来。

### 6.6 librime 会缓存配置文件（重要）

librime 的 `ConfigComponentBase::GetConfigData()` 按 `config_id` 缓存解析结果：

```cpp
weak<ConfigData>& wp(cache_[config_id]);
if (wp.expired()) {          // 只有缓存失效才重新读文件
    auto data = LoadConfig(config_id);
    wp = data;
    return data;
}
return wp.lock();            // 否则直接返回缓存副本
```

`ConfigComponent` 挂在 `Service` 单例上，**存活整个进程周期**，而被缓存的数据同时被 Schema 等对象强引用，所以缓存永远不会过期。结果是：**配置文件只被读取一次，之后改写磁盘文件对 `schema_open()` 完全不可见**——这正是"换掉配置后设置面板仍是默认方案的选项"的原因。

唯一的解决办法是**整体重建引擎**：`RimeFinalize()` 销毁组件图（连同缓存），`RimeInitialize()` 再按新文件重建。原生侧因此提供了 `restart()`，它等价于 `finalize()` + `setup()` + `initialize()`。

重启刻意做成**惰性**的：只在需要会话时（`ensureSession()`）执行，而不是在 `deploy/success` 回调里直接做——那个回调虽然终于 JS 线程，但此时 librime 的维护线程可能尚未收尾，`finalize()` 内部会 `JoinMaintenanceThread()`。

### 6.7 必须打包 OpenCC 数据（否则简繁转换静默失效）

`luna_pinyin.schema.yaml` 里：

```yaml
filters:
  - simplifier@zh_simp          # opencc_config: t2s.json
  - simplifier@zh_tw            # opencc_config: t2tw.json
```

librime 解析这个路径时（`src/rime/gear/simplifier.cc`）：

```cpp
(user_config_path /= "opencc") /= opencc_config_path;
(shared_config_path /= "opencc") /= opencc_config_path;
// 即 <shared_data_dir>/opencc/t2s.json
```

**OpenCC 数据不在 Rime 数据里面，必须单独打进包里**（fcitx5-android 也是靠一条 `symlinks.put("usr/share/rime-data/opencc", "usr/share/opencc")` 解决的）。缺了它的后果不是报错，而是**静默失效**：

1. `Config::NewFromFile()` 读不到文件 → 内容为空串
2. OpenCC 1.1.9 的 `NewFromString("")` 抛 `InvalidFormat`（`Config.cpp`：`doc.HasParseError()` → throw）
3. librime 的 `catch (...)` 吞掉异常，`converter_` 保持 null
4. `Opencc::ConvertWord()` 见 `converter_ == nullptr` 返回 false
5. `Simplifier::Convert()` 于是把**原候选原样放回**

结果就是：`set_option('zh_simp', true)` 成功、`get_option` 也返回 1，但输出的**仍然是繁体**——看起来完全像"开关不生效"。

数据量只有 1.2 MB，放在 `entry/src/main/resources/rawfile/rime/opencc/`。因为 `extractSharedData()` 只在全新安装时解压，`RimePaths.repairSharedData()` 会在每次启动时**只补齐缺失的**内置文件（绝不覆盖或删除），这样老安装也能拿到新增的 `opencc/`，同时不会动用户导入的配置。

### 6.8 配置替换后必须清掉旧的部署产物(由AI生成)

部署是**增量**的：librime 只有在方案源文件看起来比 `<user>/build` 下的产物更新时才重建。整体替换配置会让这个时间戳比较失去意义，残留的 `*.table.bin` / `*.prism.bin` 会被当成新方案的产物加载。

因此 `redeploy()` 会先调 `clearDeployedArtifacts()` 删掉 `<user>/build`，再发起全量部署。所有 `redeploy()` 调用点都发生在配置变更之后，所以这个语义是一致的。

另外，如果在部署进行中请求再次部署，`redeploy()` 不再静默忽略，而是记下 `pendingDeploy`，等当前部署结束再补跑一次。

### 6.8.1 配置变更的两个检测信号(由AI生成)

| 信号 | 覆盖场景 |
| --- | --- |
| `.deploy-stamp` 时间戳文件 | 由完成部署的一方写入；另一方（可能是不同进程）据此感知配置变化 |
| 文件指纹（数量 + 总大小 + 最新 mtime） | 直接改文件、没有触发任何部署的情况 |

指纹扫描会跳过 `build/`、`sync/`、`*.userdb/` 这些每次部署都会变化的生成目录，并限制深度与条目数。文件变了但部署戳没变时，说明是绕过应用的直接替换，此时会额外触发一次 `startMaintenance(false)` 重新编译方案表。

### 6.9 librime 的 Lua 插件必须显式拉取(由AI生成)

librime 的 `plugins/CMakeLists.txt` 用 `file(GLOB)` 把 `plugins/` 下的**每个子目录**当作插件，而发行版里 `plugins/` 只有 `CMakeLists.txt`、`plugin.cc`、`plugins_module.cc` 三个文件——**没有任何子目录，因此默认不构建任何插件**。

Lua 脚本支持（`lua_translator` / `lua_filter` / `lua_processor` / `lua_segmentor`）在独立仓库 `hchunhui/librime-lua` 中，必须：

1. 拉取到 `thirdparty/librime-lua`
2. 由 `build_engine.sh` 复制到 `librime/plugins/lua`（`BUILD_MERGED_PLUGINS=ON` 会把它合进 `librime.a`）
3. 模块的 `CMakeLists.txt` **额外链接 `liblua.a`**——插件合入后留下 186 个 `lua_*` 未定义符号

librime-lua 通过 pkg-config 找 Lua（依次尝试 `lua`、`lua54`……），而 Lua 官方发行版不带 `.pc` 文件，所以 overlay 里生成了一个 `lua.pc`。

缺了插件的后果**不是报错而是静默失败**：引用了 `lua_translator@*` 的方案无法加载 → `select_schema` 失败 → 键盘停留在旧方案上，看起来就像"换了配置但键盘还用默认的"。

验证方式见 `scripts/build_host_probe.sh` 的 C 组：一个只含 `lua_translator@test_lua` 的方案，脚本产出 `LUA_WORKS` 候选即为通过。

### 6.10 文件夹导入必须逐条解析（子目录陷阱）(由AI生成)

选择器返回的是**文档 URI**（`file://docs/...`），它**不是普通路径**。把子项拼接到 URI 后面再交给 `fs`，在多数 provider 上会失败：

```
file://docs/storage/Users/currentUser/Download/rime-ice
  + "/cn_dicts"  →  fs.statSync / fs.listFile / fs.openSync 全部失败
```

失败后 `isDirectoryUri()` 返回 false，于是**子目录被当成文件**去复制，复制又失败——整棵子树被静默丢弃，导入看起来却"成功"了。

这对雾凇拼音是致命的：它的词典在 `cn_dicts/`、`en_dicts/`，脚本在 `lua/`。顶层 YAML 进去了、词典没进去，于是：

* 应用界面能列出方案（只是读 `default.yaml`）
* 但方案无法部署（词典缺失）→ 键盘加载不了 → 停留在旧方案

处理方式：

1. `resolveListable()` **优先取路径形式**（若 provider 允许）；根是路径，后代就都是普通路径，递归自然可用
2. 每个条目仍用 `resolveEntry()` **独立解析**，URI 与路径两种形式都试
3. `canAccess()` 用三重探测：`statSync` → `openSync`（provider 拒绝 stat 的文件）→ `listFile`（目录）
4. 无法解析的条目**单独计数**，并在导入结果里明确报出，不再静默丢弃

导入完成后摘要会列出**实际到达的目录**，例如：

```
已导入 75 个文件（52.0 MB），含目录 cn_dicts、en_dicts、lua、opencc，正在重新部署…
```

出现「N 个条目无法读取」就说明 provider 拒绝了某些子树，配置不完整。

### 6.11 语法模型（grammar）需要额外插件

雾凇拼音的 `rime_ice.custom.yaml` 通过 patch 引入：

```yaml
patch:
  grammar:
    language: wanxiang-lts-zh-hans
```

`grammar` 在 librime 里只有抽象接口 `src/rime/gear/grammar.h`，**实现来自独立插件 librime-octagram**（`gears_module.cc` 里没有注册 `grammar`）。未安装该插件时 `Grammar::Require("grammar")` 返回空，`poet.cc` 有判空保护，因此**语法功能静默失效但输入法仍可正常使用**，只是长句的语法择优不生效。

配置里的 `wanxiang-lts-zh-hans.gram`（约 410 MB）就是给它用的。目前未打包 octagram 插件。

### 6.12 版本号与诊断窗口(由AI生成)

**版本号**：`entry/src/main/ets/common/AppInfo.ets` 里的 `BUILD` 常量，每交付一次 +1，版本号显示为 `1.0.<BUILD>`；`VERSION_CODE` 由它推导，保证系统认可升级。`AppScope/app.json5` 的 `versionName` / `versionCode` 需同步修改（JSON 无法引用常量）。应用标题下方会显示完整版本串。

**诊断窗口**：应用首页顶部常驻。收起时只显示「诊断」和错误计数徽标；展开后列出全部日志，带「复制全部」「清空」按钮，日志文本也可手动选中复制。这解决的是 **hilog 无法由用户读回** 的问题——没有它，任何失败都只能靠猜。

日志缓冲在 `common/AppLog.ets`，每个进程各持一份（应用页与输入法扩展可能不同进程），同时镜像到 hilog。

**键盘侧诊断**：输入法面板的「方案设置」里也有一个「诊断」区块，展开后显示**扩展进程自己**的 `shared` / `user` 路径、当前方案、可用方案列表、部署戳与指纹，并提供「重新加载配置」按钮。

这两处路径的对比是判断问题的关键：

* **路径相同** → 两个组件共享沙箱，配置可以互通
* **路径不同** → 扩展有独立沙箱，应用侧导入的配置**永远到不了键盘**，需要改用共享沙箱机制

「重新加载配置」按钮同时具备诊断价值：手动重载后正常 ⇒ 自动变更检测有问题；手动重载后依旧 ⇒ 两个进程读的根本不是同一份数据。

### 6.13 输入法扩展是独立沙箱（关键约束）(由AI生成)

**HarmonyOS 的输入法扩展运行在独立进程、且拥有独立数据沙箱。** 应用页与键盘报告的 `shared` 路径字符串相同，但内容是两份：

| 组件 | 看到的内容 |
| --- | --- |
| 应用设置页 | 导入的 76 个文件 / 474 MB（rime-ice） |
| 键盘扩展 | 内置的 40 个文件 / 5.75 MB |

所以**应用页导入的配置永远到不了键盘**——这与刷新时机、缓存、部署都无关。相关佐证：

* 华为开发者问答：*如何通过 ExtensionAbility 获取输入法扩展**独立沙箱**文件的路径？*
* 华为开发者问答：*app 和输入法获取的 preferences 数据不一致*
* IME Kit 文档中的「共享沙箱」章节

**因此配置导入必须由扩展自己完成。** 键盘「方案设置」里新增了「导入配置文件夹」按钮，它用 `DocumentViewPicker(this.context)` 在**扩展进程内**打开选择器，并把文件写进扩展自己的 `rime/shared`，随后触发部署。应用页的导入入口保留（沙箱若共享仍然有效），但界面上已注明两者区别。

诊断面板里的 `[live]` 段是**实时**读取的，用于区分两种失败：`sharedEntries` 若列出 `cn_dicts`、`lua` 等，说明沙箱共享、问题在变更检测；若只有内置文件，说明沙箱隔离。

### 6.14 跨进程传递配置文件（无共享存储可用）(由AI生成)

沙箱隔离之后还有两个硬约束，它们共同决定了导入方案：

1. **键盘不能自己选文件夹**：`InputMethodExtensionContext` 只有 `destroy()` 与 `startAbility()`，**没有 `startAbilityForResult`**，而 `DocumentViewPicker` 需要它取回结果。键盘里点导入会报 `13900042`（未知错误）。
2. **公共事件不能粘性**：SDK 明确写着「粘性公共事件……**只有系统应用或服务**可以发送」。

唯一能跨过去的是**文档 URI 字符串**：选择器把权限授予整个应用（扩展共享同一 token），所以扩展能读那份文件，只是需要先知道 URI。

于是流程是：

```
设置页选文件夹 ──publish(IMPORT_URI, data=uri)──▶ 键盘（若在运行则立即收到）
键盘启动 ──publish(IMPORT_REQUEST)──▶ 设置页（若还活着）──▶ 重发 IMPORT_URI
键盘收到 URI ──▶ 复制进自己的 sharedDataDir ──▶ 部署 ──▶ publish(IMPORT_DONE)
```

「键盘启动后主动索取」这一步是必需的，正好弥补公共事件不能粘性的问题。

**导入的复制动作永远在扩展进程里做**——因为不管沙箱是否共享，写入扩展自己的 `sharedDataDir` 都是正确的：共享时那本来就是设置页看到的目录，隔离时那正是 librime 读取的目录。

URI 放在事件的 `data` 字段而不是 `parameters`：后者类型是索引签名 `{[key: string]: any}`，ArkTS 不允许用对象字面量构造。

### 6.15 根因：输入法的「安全模式」（基础模式 / 完整体验模式）(由AI生成)

这是整个问题的最终答案。鸿蒙把输入法分两种运行模式：

| 模式 | 限制 |
| --- | --- |
| **基础模式**（`SecurityMode.BASIC`） | 禁止调用可能泄露隐私的系统能力——**不能联网、不能读文件**，只是纯打字工具 |
| **完整体验模式**（`SecurityMode.FULL`） | 无上述限制 |

**基础模式下输入法扩展读不了沙箱外的任何文件**，于是：

* 应用页写进自己沙箱的配置，键盘读不到
* 选择器返回的文档 URI，键盘也读不到
* 两者路径字符串相同、内容却是两份

这个开关**属于用户**（设置 → 系统 → 输入法 → 本输入法 → 完整体验模式），开发者只能检测与适配。相关文档：

* [输入法安全模式介绍（IME Kit）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/ime-kit-security-V14)
* [基础模式与完整体验模式的功能适配](https://www.ithome.com/0/883/023.htm)
* [基础模式和完整体验模式差在哪](https://ost.51cto.com/answer/45012)

应用通过 `inputMethodEngine.getInputMethodAbility().getSecurityMode()` 检测：

```ts
const mode = inputMethodEngine.getInputMethodAbility().getSecurityMode();
// SecurityMode.FULL / SecurityMode.BASIC
```

注意该方法在 **`InputMethodAbility`** 上（不是 `InputMethodEngine`），且只能由输入法应用调用。

应用页在基础模式下会显示醒目横幅，指引用户去系统设置切换；键盘诊断里也会显示 `securityMode=`。

### 6.16 为什么最终不采用「同进程」(由AI生成)

`module.json5` 的 `extensionAbilities` 支持 `extensionProcessMode`，取值含 `runWithMainProcess`，实测**可以让键盘与主进程同进程**，从而共享数据沙箱与 `RimeEngineService` 单例，一次性消除跨进程问题。

**但最终没有采用**，因为这会削弱鸿蒙为输入法提供的进程隔离：输入法会看到其他应用中的每一次按键，让它跑在自家应用进程里并不划算。安全优先。

因此当前架构是：

* 键盘保持独立进程与独立沙箱
* 配置通过 **完整体验模式（授予扩展读文件能力）+ URI 公共事件交接** 送达
* 应用页只负责选文件夹与保管 URI（持久化到自己的沙箱，页面重建后仍能应答），**不做复制**——复制由拥有数据目录的扩展完成，这样在两种拓扑下都只复制一次

`getDiagnostics()` 末尾会附上键盘进程自己的日志尾部，这是确认 URI 是否真的送达的唯一途径。

### 6.17 键盘 UI 参照 fcitx5-android 重写(由AI生成)

布局、键宽与配色照搬 [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android)，而不是自行发挥：

**字母页**（`TextKeyboard.Layout`）

```
Q W E R T Y U I O P     每键带数字角标
A S D F G H J K L
[⇧] Z X C V B N M [⌫]
[?123] , [中/英] [空格] . [↵]
```

**数字/符号页**（`NumberKeyboard.Layout`）

```
+ 1 2 3 /
- 4 5 6 [空格]
* 7 8 9 [⌫]
ABC , !?# 0 = . [↵]
```

**选择器**（`PickerWindowPreset`）：符号 10 列 × 3 行、Emoji 7 列 × 3 行，带分类标签与翻页。

**配色**（`ThemePreset.MaterialLight`）：`KeyboardTheme.ets` 里的字段与 `Theme.kt` 一一对应——键面 `#FBFBFC`、功能键 `#DFE2E4`、强调键 `#5CB5AB`、主文字 `#37474F`、备选文字 `#7A858A`、空格 `#C9CED1`。

**键宽**沿用参考实现的约定：正数是该行的份额，`0` 表示「平分剩余」；`resolveRows()` 在布局前把 0 展开成具体份额，因为 ArkUI 的 `layoutWeight` 只接受正数。

**Emoji 直接提交**而不经过 Rime：`KeyboardHub.commitDirect()`——它们常由多个码位组成（ZWJ 序列、肤色修饰），而 `typeCharacter()` 只转发第一个码位，会把家庭 emoji 变成单人。符号仍走 Rime，让标点处理器应用全角规则，与参考实现一致。

> 一个反复踩到的坑：**本文件所有 `@Builder` 都是零参数**。带参 `@Builder` 使用值语义，状态变化时 ArkUI 不会重新执行它——之前中/英键的标签和翻页箭头的可用状态都被永久冻结。即使传入的是常量也不安全，因为 builder 内部仍会读 `this`。因此按键渲染直接内联在 `ForEach` 中，面板切换读 `this.panel` 而不是传标志位。

### 6.18 语法模型（.gram）支持(由AI生成)

此前发现 `rime_ice.custom.yaml` 会通过 patch 引入 `grammar:`，而 librime 里 **`grammar` 只有抽象接口**（`src/rime/gear/grammar.h`），实现来自独立插件。现已接入。

**插件**：[`lotem/librime-octagram`](https://github.com/lotem/librime-octagram)。接入方式与 lua 插件相同：

1. `fetch_sources.sh` 拉取到 `thirdparty/librime-octagram`
2. `build_engine.sh` 复制到 `librime/plugins/octagram`（`BUILD_MERGED_PLUGINS=ON` 合入 `librime.a`）
3. 它需要 `darts.h` 与 `utf8.h`，这两个 librime 自带并在 `add_subdirectory(plugins)` 之前 `include_directories`，所以直接可用
4. 关闭 `BUILD_TOOLS`（`build_grammar` 是给桌面端用的命令行工具）

插件注册的组件名是 **`grammar`**，运行时行为：

```cpp
r.Register("grammar", new OctagramComponent);
config->GetString("grammar/language", &language);   // 方案里的 grammar/language
const ResourceType kGramDbType = {"gram_db", "", ".gram"};
// 于是加载 <user|shared>/<language>.gram
```

**模块必须被真正加载**，否则代码链接了也不会生效：librime 通过 `RIME_EXTRA_MODULES` 宏决定运行时加载哪些模块，配置日志里应出现

```
-- rime_plugins_modules: lua;octagram
```

**验证方式**（`scripts/build_host_probe.sh --run` 会构建同版本的主机探针）：

```
grammar_module.cc] registering components from module 'grammar'.
component check: grammar=1 lua_translator=1 lua_filter=1 simplifier=1
octagram.cc] use grammar: testgram
```

最后一行即插件成功读取 `.gram`。

**用真实模型验证排序效果**（`test_file/test_config/wanxiang-lts-zh-hans.gram`，420 MB）。同一输入 `womenyiqiqukanyidianying`：

| | 首选候选 |
| --- | --- |
| 有语法模型 | `我们一起去看一点映` |
| 无语法模型 | `我们一起去看以电影` |

候选顺序**确实被语法模型改变**，即句级组合在用语言模型重排。模型缺失时插件会明确报错：

```
E octagram.cc:180] failed to load grammar database: wanxiang-lts-zh-hans
```

**能加载不等于能影响排序**——只看到 `use grammar` 不足以说明问题，必须做这样的 A/B 对照。

应用内则在键盘「方案设置 → 诊断」里显示：

```
component.lua_translator=true
component.grammar=true
grammarLanguage=wanxiang-lts-zh-hans file=/data/.../shared/wanxiang-lts-zh-hans.gram (410684123 bytes)
```

`grammarLanguage` 会同时报告方案声明的语言和 `.gram` 文件是否存在于 user/shared 目录——缺少文件时插件只会静默退回无语法模型，与"语法模型被关掉"无法区分。

> 顺带修掉一个 librime-lua 的上游 bug：它把 `LUA_VERSION` 同时用作 pkg-config 模块名缓存变量和 `pkg_check_modules` 的结果变量，首次配置成功后缓存里变成 `5.4.7`，下次配置就会去找名为 `5.4.7` 的模块而失败。补丁 `scripts/patches/librime-lua/0001-*.patch` 把缓存变量改名为 `RIME_LUA_PKG`。这也是"`--clean` 能过、增量构建过不去"的原因。

### 6.19 导入自定义配置的语义(由AI生成)

「导入配置文件夹」是**整体替换**而非合并：先 `rmdirSync` 递归清空内置方案目录，再复制所选文件夹的内容。这样做是为了让配置包（如雾凇拼音）成为唯一配置源，不会残留内置文件。

因此有两道保护：

* 导入前先扫描，文件夹为空或没有任何 `.yaml` 就**直接拒绝**（此时尚未删除任何东西）；
* 提供「恢复内置配置」，从 rawfile 重新解压。

`fs.rmdirSync` 文档确认会递归删除目录及其所有子目录与文件。

### 6.20 fcitx5 与 OHOS libc++ 15 的兼容问题(由AI生成)

**这是整个移植中最麻烦的部分。** HarmonyOS NDK（含 hms native）内置的是 **libc++ 15004（LLVM 15）**，而 fcitx5 5.1.23 是按 C++20/23 编写的，两者存在多处缺口。此外 **clang 15 的默认 C++ 标准仍是 gnu++14**（升到 gnu++17 是 clang 16 的事），这一点会影响 CMake 的编译器探测。

| 缺口 | 现象 | 处理方式 |
| --- | --- | --- |
| 无 `<source_location>` 头文件 | `fcitx-utils/log.h` 无条件包含它，直接编译失败 | 提供 shim：`overlay/cxx-compat/include/source_location`，用 `__builtin_FILE()/__builtin_LINE()` 实现标准接口 |
| `<format>` 与 `std::ranges` 被 libc++ 门控 | `no member named 'vformat' in namespace 'std'` | 加 `-fexperimental-library` |
| `<format>` 的 `format_error` vtable 在 `libc++experimental` 里 | 模块链接时报 undefined symbol | 链接时显式加 `-lc++experimental` |
| 无 `std::hash<std::filesystem::path>`（libc++ 17 才补上） | `std::hash<filesystem::path> does not provide a call operator` | 强制包含 `fcitx5_ohos_cxx_compat.h`，特化该 hash；**并用 `__cplusplus >= 201703L` 包住**，否则会破坏 CMake 在 gnu++14 下的编译器探测 |
| `<format>` 无 chrono 格式化 | `log.cpp` 格式化时间戳失败 | 补丁 `0001-log-avoid-chrono-format.patch`，改用 `localtime_r` + `strftime` |
| clang 15 未实现 P1816（聚合类 CTAD） | `icontheme.cpp` 的 `VariantOverload{...}` 推导失败 | 补丁 `0002-icontheme-ctad-guide.patch`，补一条显式推导指引 |
| fcitx5 导出的 CMake target 未解析自身依赖 | 插件配置时报 `LibIntl::LibIntl` / `Pthread::Pthread` / `PkgConfig::LibUV` / `DL::DL` 不存在 | 通过 `CMAKE_PROJECT_INCLUDE` 注入 `overlay/fcitx5-addon-prelude.cmake` |
| `RIME_TARGET` 只接受库路径，不带 include | `rime_api.h` 找不到 | prelude 中定义 `Rime::Rime` 接口 target，携带 include 目录与 whole-archive + 依赖链 |
| `library.h` 仅在 `ENABLE_DL=ON` 时安装 | fcitx5-rime 无条件包含它 | 打开 `ENABLE_DL`（musl 的 dlopen 在 libc 中，另有 stub `libdl.a`，无额外代价） |
| libuv 源码在 musl 上编不过（`sched_getaffinity`/`cpu_set_t`） | libuv 编译失败 | 直接使用 OHOS sysroot 自带的 `libuv.so` 1.44.1，并生成 `libuv.pc` |
| Lua 5.4 不再随源码提供 `lua.hpp` | `lua.hpp file not found` | overlay 中生成并安装该 C++ 包装头 |
| fcitx5 master 严格需要 core ≥ 5.1.22，而最新 release tag 仅 5.1.9 | 无法用发布版 | 使用 master 归档（版本 5.1.23），配合上述兼容层 |

补丁统一放在 `scripts/patches/<组件>/`，由 `build_engine.sh` **就地**幂等应用（先反向探测，已打过则跳过）——注意它会修改 `thirdparty/` 下对应的上游源码树，重跑 `fetch_sources.sh` 才能还原为原始状态。

---

## 7. 运行机制(由AI辅助生成)

### 首次启动

1. `RimePaths.prepare()` 把 `resources/rawfile/rime/` 递归解压到 `filesDir/rime/shared`
2. `rime.configure()` 指定 shared/user/log 目录
3. `rime.initialize()` 启动 librime
4. `rime.startMaintenance(true)` 触发**全量部署**（编译 `.dict.yaml` → `.table.bin`/`.prism.bin`）
5. 部署进度通过 `deploy` 通知回传，UI 显示「正在部署 Rime 数据…」
6. 部署成功后 `deploy`/`success` 通知到达，会话重建，键盘可用

> 首次全量部署需要编译 4 MB 的 `essay.txt` 词库，在真机上可能需要数十秒。**必须使用 `startMaintenance()` 异步部署**，同步 `deploy()` 会卡死 JS 线程。

### 输入

- 按键 → X11 keysym → `process_key`
- 预编辑由键盘自己显示在候选词上方的一行里（不写入编辑器）
- 候选栏点击 / 空格选词 → 提交文本用 `insertTextSync()` 写入

### 输入状态与三个层次

同一个「未完成」概念在鸿蒙的输入法接口里对应三块状态，清空时必须分别处理：

| 层 | 存放位置 | 清除方式 |
| --- | --- | --- |
| 原始拼音及其候选 | librime 的 composition | `rime.clearComposition()` |
| 已最终上屏的文字 | 文档本身 | **不处理**——它已经是用户的内容 |

（早先还有第三层：把拼音作为 preview text 内联显示在编辑器里。该功能已**移除**，原因见 §6 踩坑表。）

现在拼音由键盘自己绘制，位于候选词上方同一条色带上，与候选词**同色**、字号更小、同样靠左对齐。输入期间左侧的三点设置按钮会让位，使拼音与候选词都从最左缘开始；提交或删除后按钮自动恢复。

候选栏右上角的按键按当前状态切换语义：

- **无未确认输入** → 显示 `⌄`，按下收起键盘
- **有未确认输入**（preedit 或候选词非空） → 显示 `✕`，按下清空前两层，保留已上屏文字；清空后状态归零，按键**自行变回** `⌄`

这个切换不需要额外的状态位：按键读取的就是引擎刚清空的那份状态。实现见 `KeyboardHub.onEscape()` 与 `KeyboardPanel.hasPendingInput()`。

---

## 8. 后续工作(由AI辅助生成)

1. **把 fcitx5 引擎接入 NAPI**
   库已经全部构建完成，还差“用起来”这一步：
   - 在 `entry/src/main/cpp/rime_napi/` 旁增加 `fcitx_engine.{h,cpp}`，创建一个嵌入式 `FcitxInstance`（`ENABLE_SERVER=OFF` 即为嵌入式库模式）
   - 静态注册所需 addon（`Fcitx5::Module::QuickPhrase`、`Notifications`、lua、rime），代替 dlopen
   - 把 `FcitxInstance` 的输入上下文映射到现有 `RimeContext` 形状，ArkTS 侧即可无缝切换引擎
   - 注意 addon 与 librime 的静态库链接同样需要 `--whole-archive` 与 linker group
2. **真机验证**
   - 首次部署耗时与内存占用
   - 面板尺寸、候选栏滚动、键盘高度自适应
   - `setPreviewTextSync` 与焦点切换的边界情况
3. **物理键盘**
   - 目前软键盘按固定映射发送按键；物理键盘需要接入 `onKeyEvent` 并读取真实修饰键状态
4. **功能完善**
   - 方案切换 UI（`getSchemaList` / `selectSchema` 已就绪）
   - 用户词典同步、简繁切换、标点模式切换
   - 键盘布局扩展（数字行、符号页、手写）
5. **签名**
   - 当前 `build-profile.json5` 的 `signingConfigs` 为空，产出未签名 HAP；安装到真机前需要在 DevEco Studio 中配置签名
6. **升级工具链时的清理**
   - `overlay/cxx-compat/` 中的两个 shim 与两个 fcitx5 补丁都是针对 libc++ 15 / clang 15 的；若将来 DevEco 升级到 clang 16+，应逐一删除（每个文件内都写明了移除条件）

---

## 9. 许可

移植自 Fcitx5-Android（GPL-3.0-or-later）与 librime（BSD-3-Clause）。本项目沿用 **GPL-3.0-or-later**。
