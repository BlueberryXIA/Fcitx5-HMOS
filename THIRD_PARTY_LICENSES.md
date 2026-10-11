# 第三方组件许可证审计

本文件记录项目实际分发的内容里包含哪些第三方代码、各自的许可证，以及它们对项目自身许可证选择的约束。

审计时间是「当前 `libentry.so` 的真实链接内容」，而不是「构建脚本里出现了哪些目录」——两者差别很大，见下文。

---

## 1. 实际链接进应用的库

`entry/src/main/cpp/CMakeLists.txt` 的链接列表即分发内容：

| 组件 | 许可证 | 说明 |
| --- | --- | --- |
| librime | BSD-3-Clause | 核心引擎 |
| librime-lua | BSD-3-Clause | 合入 librime.a |
| librime-octagram | BSD-3-Clause | 合入 librime.a |
| glog | BSD-3-Clause | 日志 |
| leveldb | BSD-3-Clause | 用户词典存储 |
| yaml-cpp | MIT | 配置解析 |
| marisa-trie | BSD-2-Clause | 双许可 BSD-2 / LGPL-2.1，本项目取 BSD-2 |
| opencc | Apache-2.0 | 简繁转换 |
| lua | MIT | lua 插件的解释器 |
| boost.regex | BSL-1.0 | 正则 |

**结论：全部为宽松许可证（BSD / MIT / Apache-2.0 / BSL-1.0），没有任何 copyleft 约束。** 分发的二进制里不含 LGPL 或 GPL 代码。

Apache-2.0 与 BSD 都允许把代码与其他条款的作品组合分发，只需保留版权声明与许可证全文。

---

## 2. 构建了但**没有**链接进应用的组件

| 组件 | 许可证 | 状态 |
| --- | --- | --- |
| fcitx5 | LGPL-2.1-or-later | 编译产出 `libFcitx5Core.a` 等，**未链接** |
| fcitx5-lua | LGPL-2.1-or-later | **未链接** |
| fcitx5-rime | LGPL-2.1-or-later，其中 4 个文件是 **GPL-2.0-or-later** | **未链接** |

已核实最终产物：

```
$ llvm-nm -C libentry.so | grep -ci fcitx
0
```

`fcitx5-rime` 里为 GPL 的文件是 `rimeservice.{cpp,h}` 与 `rimesession.{cpp,h}`。**强 copyleft 的 GPL 若被链接，会要求整个作品以 GPL 分发**——本项目没有链接它们，因此不受约束。

> 这几个组件目前是本项目的**死重**：构建耗时但没有被使用。要么明确其用途，要么从构建流程中移除。

---

## 3. 参考项目（已克隆到工作区，未参与构建）

| 项目 | 许可证 | 用途 |
| --- | --- | --- |
| [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) | **LGPL-2.1** | 键盘 UI 的参照来源，见第 4 节 |
| [fcitx5-harmony](https://github.com/fcitx-contrib/fcitx5-harmony) | **GPL-3.0** | 仅阅读其架构，**未复制任何代码** |

两者都在 `.gitignore` 之外时不应提交进仓库；GPL-3.0 的项目尤其不应把代码混入。

---

## 4. 本项目的许可证：AGPL-3.0-or-later

本项目以 **GNU Affero General Public License v3.0 or later** 发布，全文见 [`LICENSE`](LICENSE)，每个自研源文件带 SPDX 标识：

```
SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (C) 2026 Haochen Xia
```

### 为什么是 AGPL 而不是「禁止商业使用」的许可证

需求是「可以被学习和借鉴，但不允许商业性质的二次分发」。**OSI 认可的许可证不可能禁止商业使用**——[开源定义](https://opensource.org/osd)第 6 条明确禁止限制特定领域的用途。

但 AGPL-3.0 恰好实现了「禁止商业性质的**二次分发**」：

- 商业使用**允许**，学习、修改、自用都不受限
- 只要**分发**衍生作品（或通过网络提供服务），就必须以 AGPL 提供完整源码
- 因此没人能把本项目改一改闭源卖钱，也堵住了「架服务器提供改版」的规避方式

若只需要前者、不在意 SaaS 漏洞，GPL-3.0 语义相同且更宽松。

### 对分发渠道的影响

- **可以**：华为应用市场、F-Droid、各大 Linux 发行版、自行分发
- **不可以**：Apple App Store（其 DRM 条款与 GPL 系冲突）

### 第三方许可证的兼容性

第 1 节的宽松许可证全部与 AGPL-3.0 兼容：BSD、MIT、**Apache-2.0**（兼容 GPL-3.0 及 AGPL-3.0）、BSL-1.0。

第 2 节的 fcitx5 系列未链接，不参与分发。其中 `fcitx5-rime` 有 4 个 **GPL-2.0-or-later** 文件——注意 **GPL-2.0-only 与 AGPL-3.0 不兼容**，而 `-or-later` 可以升级到 GPL-3.0，因此是可兼容的；但既然没有链接，这一点不影响本项目。

---

## 5. 键盘 UI 派生自 LGPL-2.1 代码（在 AGPL-3.0 下已无问题）

按需求「直接照搬重写」，键盘界面是从 fcitx5-android 转写而来，涉及：

| 本项目文件 | 派生内容 |
| --- | --- |
| `inputmethod/keyboard/KeyboardLayouts.ets` | `TextKeyboard.Layout`、`NumberKeyboard.Layout` 的行序、按键顺序与百分比键宽 |
| `inputmethod/keyboard/KeyboardTheme.ets` | `ThemePreset.MaterialLight` 的配色字段与取值 |
| `inputmethod/keyboard/PickerData.ets` | `PickerData.kt` 的分类结构与标签 |
| `pages/KeyboardPanel.ets` | `PickerPageUi.Density` 的网格尺寸（符号 10×3、Emoji 7×3） |
| `inputmethod/keyboard/LongPressOptions.ets` | 长按字母键时给出的符号。这张配对表本身转录自 fcitx5 的 `src/im/keyboard/longpress.cpp`（LGPL-2.1-or-later），经由 fcitx5-android 的 `input/popup/PopupPreset.kt` 转写；本项目只取每条配对中的符号，去掉了上游附带的带变音符号的形式 |

**兼容性链条成立**：fcitx5-android 是 `LGPL-2.1-or-later` → 可选择 LGPL-3.0 → LGPL-3.0 与 AGPL-3.0 兼容。因此这些派生文件整体置于 AGPL-3.0 之下是合法的，**不需要重写**。

（早先曾考虑「禁止商业使用」的非商业许可证，那时的结论是必须重写这些文件以与 LGPL 脱钩。改用 AGPL-3.0 后该约束消失。）

---

## 6. 其他需要留意的内容

- `test_file/test_config/` 是用户自备的配置（位于被 Git 忽略的 `test_file/` 下），不属于项目源码，但其中若含第三方方案（如雾凇拼音）与语言模型（`wanxiang-lts-zh-hans.gram`），分发时应遵守各自的许可证。
- `entry/src/main/resources/rawfile/rime/` 内置的 Rime 预设数据来自 librime，BSD-3-Clause。
- `entry/src/main/resources/rawfile/rime/opencc/` 的 OpenCC 数据来自 OpenCC，Apache-2.0。

---

## 7. 合规做法（已实施）

Apache-2.0 与 BSD 都**强制要求**随分发内容提供许可证全文与版权声明，因此许可证文本已打包进 HAP：

```
entry/src/main/resources/rawfile/licenses/
```

应用内首页的「开源许可」卡片可以逐条阅读，不需要外部文件。

改动代码时请一并更新本文件，尤其是新增第三方依赖时。

---

## 8. 联系

**邮箱：blueberry_xia@qq.com**

如果发现本项目**无意间引入了许可证不兼容的代码或资源**，或存在任何**侵权**问题，请邮件告知，会尽快处理。这类问题作者尤其重视——本项目为个人学习项目，无意侵犯任何人的权益。

一般的错误报告与建议，邮件或在本仓库提交 issue 均可。作者目前高三在读，回复可能不及时，敬请谅解。
