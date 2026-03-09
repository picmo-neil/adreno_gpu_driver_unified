# 🎯 ADRENO GPU 驱动指南
## 完整安装与配置手册

**模块名称：** Adreno GPU Driver Unified
**模块 ID：** `adreno_gpu_driver_unified`
**开发者：** @pica_pica_picachu
**联系方式：** Telegram @zesty_pic
**版本：** 通用版（支持 Magisk • KernelSU • APatch • Recovery）

> **⚡ 一个 ZIP 文件，适用于所有安装方式**

---

# 📋 目录

## 第一部分：快速入门（新手指南）
1. [这是什么？能做什么？](#what-is-this)
2. [快速前置检查清单](#quick-prerequisites)
3. [安装方式对比 — 选择一种](#installation-methods-comparison)
4. [Magisk 安装（推荐）](#magisk-quick-install)
5. [KernelSU 安装](#kernelsu-quick-install)
6. [APatch 安装](#apatch-quick-install)
7. [快速故障排查](#quick-troubleshooting)

## 第二部分：进阶完整指南
8. [深入解析：模块工作原理](#how-module-works)
9. [文件结构与组件](#file-structure-detailed)
10. [详细启动流程](#boot-process-detailed)
11. [属性管理系统](#property-management)
12. [配置系统](#configuration-system)
13. [WebUI 管理器完整指南](#webui-complete-guide)
14. [SELinux 策略注入](#selinux-policy)
15. [缓存管理系统](#cache-management)
16. [卡机检测与恢复](#bootloop-detection-system)
17. [OEM ROM 兼容性](#oem-rom-compatibility)

## 第三部分：技术参考
18. [配置文件参考](#config-file-reference)
19. [系统属性参考](#system-properties)
20. [日志文件完整参考](#log-files-reference)
21. [GPU 兼容性矩阵](#gpu-compatibility-matrix)
22. [驱动版本选择](#driver-version-selection)
23. [ROM 特定注意事项](#rom-specific)
24. [RENDER_MODE 技术细节](#render-mode-technical)

## 第四部分：故障排查与恢复
25. [完整故障排查指南](#complete-troubleshooting)
26. [卡机恢复（所有方式）](#bootloop-recovery-all)
27. [摄像头无法使用](#fix-camera)
28. [录屏功能损坏](#fix-screen-recorder)
29. [夜间模式问题](#fix-night-mode)
30. [性能问题](#fix-performance)
31. [图形异常](#fix-graphics-glitches)
32. [模块未加载](#fix-module-not-loading)

## 第五部分：Recovery 模式安装
33. [Recovery 模式完整指南](#recovery-mode-guide)
34. [了解风险](#recovery-risks)
35. [必须备份的内容](#recovery-backups)
36. [Recovery 安装步骤](#recovery-installation-steps)

## 第六部分：WebUI 管理器指南
37. [主页标签](#webui-home)
38. [配置标签](#webui-config)
39. [工具标签](#webui-utils)
40. [数据标签](#webui-data)
41. [自定义驱动工具](#webui-custom-tools)
42. [语言与主题](#webui-language-theme)
43. [终端日志](#webui-terminal)

## 第七部分：附录
44. [常见问题解答（FAQ）](#faq)
45. [术语表](#glossary)
46. [致谢](#credits)
47. [许可证与免责声明](#license)

---

# 第一部分：快速入门

<a name="what-is-this"></a>
## 1. 这是什么？能做什么？

### 简单说明（适合新手）

你的手机有 GPU（图形处理单元）——负责处理所有图形、游戏和视觉效果的芯片。就像 PC 显卡一样，GPU 需要"驱动程序"才能正常工作。

**本模块将手机的 GPU 驱动替换为不同版本。**

**你可能获得的效果：**
- ✅ 更好的游戏性能（更高帧率、更流畅的游戏体验）
- ✅ 改善图形渲染
- ✅ 更好的应用性能
- 😐 没有明显差异
- ❌ 性能变差
- ❌ 功能损坏（摄像头、录屏等）

**实话实说：** 效果 **100% 取决于设备**。在某台手机上效果极佳的方案，可能在另一台上完全无效。

### 什么是"GPU 驱动"？

类比更新电脑显卡驱动：
- **Windows PC：** 下载 NVIDIA/AMD 驱动
- **Android 手机：** 通过本模块安装 Adreno 驱动

### 本模块的主要功能

**🎯 通用安装**
- 一个 ZIP 支持：Magisk、KernelSU、APatch 以及自定义 Recovery
- 自动检测运行环境
- 在所有平台上正确安装

**🛡️ 安全功能**
- 卡机检测（检测手机是否反复重启）
- 自动崩溃日志收集
- 配置备份（更新后仍保留）
- 轻松移除（适用于 Magisk/KernelSU/APatch）

**🎨 Web 界面（仅 Magisk/KernelSU/APatch）**
- 无需编辑文件即可更改设置
- 一键修复常见问题
- 查看日志和系统信息
- 多语言支持

**⚡ 智能缓存管理**
- 自动清理 GPU 着色器缓存
- 防止兼容性问题
- 针对新驱动进行优化

<a name="quick-prerequisites"></a>
## 2. 快速前置检查清单

### ✅ 必须满足（全部必需）

**设备要求：**
- [ ] 高通 Adreno GPU（通过 DevCheck 应用确认）
  - ❌ Mali GPU（三星/联发科）— 不支持
  - ❌ PowerVR GPU — 不支持
  - ❌ Adreno 5xx 或更旧 — 不推荐

- [ ] Android 11 或更新版本（Android 10 可能有效但不受支持）
- [ ] ARM64 架构（64 位设备）
- [ ] 至少 500MB 可用存储空间
- [ ] 已解锁 Bootloader

**Root/Recovery 要求（选择一种）：**
- [ ] Magisk 20.4+ 已安装，或
- [ ] KernelSU 0.5.0+ 已安装，或
- [ ] APatch 0.10.7+ 已安装，或
- [ ] 自定义 Recovery（TWRP 3.5.0+、OrangeFox R11+）

**知识要求：**
- [ ] 知道如何安装 Magisk/KernelSU/APatch 模块
- [ ] 知道如何进入 Recovery 模式
- [ ] 知道如何从卡机状态恢复
- [ ] 已做好备份（尤其是 Recovery 方式）

### ⚠️ 重要警告

**安装前必读：**

1. **❌ 不保证有改善**
   - 驱动可能改善、变差或毫无变化
   - 性能取决于驱动兼容性
   - 这是 **实验性** 功能

2. **❌ 可能损坏功能**
   - 摄像头可能无法使用
   - 录屏可能损坏
   - 夜间模式/护眼模式可能失效
   - 某些应用可能崩溃

3. **❌ 卡机风险**
   - 不兼容的驱动 = 卡机
   - 必须知道如何恢复
   - **安装前务必备份**

4. **❌ 一次只能装一个**
   - 先卸载现有的 GPU 驱动模块
   - 不要混用多个 GPU 模块

5. **✅ 务必备份**
   - Magisk/KernelSU/APatch：易于移除
   - Recovery 模式：**必须备份 vendor 分区！**

<a name="installation-methods-comparison"></a>
## 3. 安装方式对比 — 选择一种

| 方式 | 可撤销？ | 系统更改 | WebUI？ | 难度 | 风险 |
|------|---------|----------|--------|------|------|
| **Magisk** | ✅ 是（简单） | ❌ 无 | ✅ 是 | 🟢 简单 | 🟢 低 |
| **KernelSU** | ✅ 是（简单） | ❌ 无 | ✅ 是 | 🟢 简单 | 🟢 低 |
| **APatch** | ✅ 是（简单） | ❌ 无 | ✅ 是 | 🟢 简单 | 🟢 低 |
| **Recovery** | ❌ 否（永久） | ✅ 直接修改 | ❌ 否 | 🔴 困难 | 🔴 高 |

### 应该选哪种？

**已安装 Magisk：**
→ 使用 **方式 A：Magisk**（推荐）

**已安装 KernelSU：**
→ 使用 **方式 B：KernelSU**
- **重要：** 需要安装 metamodule！

**已安装 APatch：**
→ 使用 **方式 C：APatch**

**没有 Root 但有自定义 Recovery：**
→ 使用 **方式 D：Recovery**（仅限高级用户）
- ⚠️ 永久更改
- ⚠️ 必须备份 vendor
- ⚠️ 没有 WebUI

**第一次尝试 GPU 驱动？**
→ **先安装 Magisk**，再使用方式 A

<a name="magisk-quick-install"></a>
## 4. Magisk 安装（推荐）

### 前置条件
- ✅ Magisk 20.4 或更新版本
- ✅ Magisk Manager 应用
- ✅ 已下载模块 ZIP

### 安装步骤

1. 打开 Magisk Manager
2. 进入 **模块** 标签
3. 点击"从存储安装"
4. 选择 `adreno_gpu_driver_unified_vX.X.X.zip`
5. 等待安装（30–60 秒）
6. 确认安装摘要中有：
   - ✅ "GPU detected: Adreno XXX"
   - ✅ "Configuration loaded"
   - ✅ "XX files installed"
   - ✅ "Caches cleaned"
7. 重启设备
8. 验证：打开 Magisk Manager → 模块标签 → 确认模块已启用

### 如果手机无法启动（卡机）

**方式 1：音量键恢复**（最简单）
```
1. 完全关机
2. 按电源键开机
3. 出现 Logo 时按住音量下键
4. 保持按住直到系统启动
5. 打开 Magisk Manager → 模块 → 禁用 Adreno GPU Driver
6. 正常重启
```

**方式 2：Recovery 文件管理器**
```
1. 进入 Recovery（电源键 + 音量上键）
2. Mount → 启用 Data
3. 文件管理器 → /data/adb/modules/
4. 删除 adreno_gpu_driver_unified 文件夹
5. 重启系统
```

**方式 3：ADB**
```bash
adb shell su -c "rm -rf /data/adb/modules/adreno_gpu_driver_unified && reboot"
```

<a name="kernelsu-quick-install"></a>
## 5. KernelSU 安装

### 前置条件
- ✅ KernelSU 0.5.0 或更新版本
- ✅ KernelSU Manager 应用
- ✅ 已下载模块 ZIP
- ✅ **必须：已安装 Metamodule**（推荐 MetaMagicMount）

### 重要：Metamodule 要求

**⚠️ KernelSU 需要 Metamodule 才能挂载模块文件**

推荐的 Metamodule：
1. **MetaMagicMount**（最推荐）
2. **Meta-Mountify**（次选）
3. **Meta-OverlayFS**
4. **Meta-Hybrid**

**没有 Metamodule 的后果：**
- ❌ 模块安装后不生效
- ❌ 文件不会被挂载到系统
- ❌ 仍使用原版驱动

### KernelSU 设置（重要）

安装前：KernelSU Manager → 设置 → 找到"默认卸载模块" → **关闭**。

### 安装步骤

1. 确认 Metamodule 已安装并启用
2. KernelSU Manager → 模块 → 安装（+ 按钮）
3. 选择模块 ZIP 文件
4. 等待安装完成
5. 检查警告——如果看到"No metamodule detected" → 停止，先安装 Metamodule
6. 重启设备

### 访问 WebUI（Magisk 上）
安装 KernelSU WebUI APK，授予 Root 权限后即可查看所有模块的 WebUI。

### 访问 WebUI（KernelSU 上）
KernelSU Manager → 模块 → 点击"Adreno GPU Driver" → 打开 WebUI

<a name="apatch-quick-install"></a>
## 6. APatch 安装

### 前置条件
- ✅ APatch 0.10.7 或更新版本
- ✅ APatch Manager 应用
- ✅ 已下载模块 ZIP

### APatch 挂载模式

APatch 支持三种挂载模式，模块会自动检测并适配：
- **Magic Mount**（v0.10.8+ 默认）— 兼容性最好
- **OverlayFS**（可选）— 通过 `.overlay_enable` 标记启用
- **Lite Mode** — 最小挂载，兼容模式

### 安装步骤

1. 打开 APatch Manager → 模块 → 安装
2. 从存储选择 ZIP
3. 等待安装（APatch 模式自动检测）
4. 重启设备
5. 在 APatch Manager → 模块中验证模块已启用

<a name="quick-troubleshooting"></a>
## 7. 快速故障排查

### 问题：模块不工作（文件未挂载）

- **Magisk：** 确保 Magic Mount 已在设置中启用。
- **KernelSU：** 先安装 MetaMagicMount 或其他 Metamodule。如果模块文件夹中存在 `skip_mount` → 没有检测到 Metamodule。
- **APatch：** 检查挂载模式和 APatch 版本（0.10.8+ 才有内置 Magic Mount）。

### 问题：手机启动后崩溃/重启

**原因：** 模块已挂载但驱动与硬件不兼容。最简单的修复方法是通过 Recovery 刷入。

**解决方案：** 移除模块，尝试不同的驱动版本。

### 问题：摄像头无法使用

WebUI → 工具标签 → 点击"修复摄像头" → 重启。这会移除可能与摄像头 HAL 冲突的 OpenCL/计算库。

### 问题：录屏损坏

WebUI → 工具标签 → 点击"修复录屏" → 重启。

### 问题：夜间模式/护眼模式不工作

WebUI → 工具标签 → 点击"修复夜间模式" → 重启。

### 问题：无法访问 WebUI

确认模块已启用，启动后等待 5 分钟，尝试不同的浏览器。检查 `/data/local/tmp/Adreno_Driver/webui_running` 标记是否存在。

---

# 第二部分：进阶完整指南

<a name="how-module-works"></a>
## 8. 深入解析：模块工作原理

模块核心做两件事：

1. **替换 GPU 驱动** — 在任何进程加载系统驱动之前，通过 magic-mount 将自定义 Adreno `.so` 库注入文件系统，使每个应用和 Android 合成器（SurfaceFlinger）从第一帧起就使用自定义驱动。
2. **配置渲染器** — 设置 Android 系统属性，告知 HWUI 渲染引擎和 SurfaceFlinger 使用哪种渲染管线（Vulkan 或 OpenGL），并为自定义驱动应用稳定性、性能和兼容性调整标志。

### 模块模式（Magisk/KernelSU/APatch）

`/data/adb/modules/adreno_gpu_driver_unified/system/vendor/` 目录镜像真实的 `/vendor/` 分区。Root 管理器的挂载系统（Magic Mount 或 OverlayFS）将这些文件叠加在原生 vendor 分区之上——系统看到的是自定义驱动，而原版文件在底层保持不变。禁用或移除模块会立即恢复原状。

### Recovery 模式（直接安装）

文件直接复制到 `/vendor/lib64/`、`/vendor/firmware/` 等目录。这是永久性的——原版驱动被覆盖。没有 WebUI，不易移除。仅适合高级用户。

<a name="file-structure-detailed"></a>
## 9. 文件结构与组件

```
adreno_gpu_driver_unified/
├── META-INF/com/google/android/
│   ├── update-binary              # 通用安装程序
│   └── updater-script
│
├── module.prop                    # 模块元数据
├── customize.sh                   # 安装时运行
├── post-fs-data.sh                # 早期启动脚本
├── service.sh                     # 晚期启动脚本
├── uninstall.sh                   # 移除时运行
├── adreno_config.txt              # 主配置文件
├── qgl_config.txt                 # QGL JSON 配置
├── system.prop                    # 系统属性覆盖
│
├── webroot/                       # Web 界面
│   ├── index.html
│   ├── index.js
│   └── style.css / theme.css
│
└── system/vendor/
    ├── lib/                       # 32 位库（ARM64_OPT=n 时安装）
    ├── lib64/                     # 64 位库（始终安装）
    │   ├── libvulkan_adreno.so    # Vulkan 驱动
    │   ├── libGLESv2_adreno.so   # OpenGL ES 驱动
    │   ├── libOpenCL.so           # ⚠️ 可选 — 可能损坏摄像头
    │   ├── libC2D2.so             # ⚠️ 可选 — 可能损坏录屏
    │   ├── libsnapdragon_color_manager.so  # ⚠️ 可选 — 可能损坏夜间模式
    │   └── ...
    └── firmware/
        └── ...
```

### 库快速参考

| 库组 | 用途 | 不兼容时的风险 |
|-----|------|--------------|
| `libGLESv2_adreno.so`、`libvulkan_adreno.so`、`libgsl.so` | 核心图形驱动 | 卡机 |
| `libOpenCL.so`、`libCB.so`、`libkcl.so` 等 | GPU 计算/OpenCL | 摄像头损坏 |
| `libC2D2.so`、`libc2dcolorconvert.so` | 2D 合成 | 录屏损坏 |
| `libsnapdragon_color_manager.so` | 显示颜色管理 | 夜间模式损坏 |
| `libgputonemap.so`、`libgpukbc.so`、`libdmabufheap.so` | 高级 GPU 功能 | 卡机 |

<a name="boot-process-detailed"></a>
## 10. 详细启动流程

### 阶段 1 — `post-fs-data.sh`（极早期启动，Zygote 之前）

文件系统挂载后、任何应用或服务进程启动前运行。此阶段：
- 通过 `resetprop` 应用渲染器系统属性
- 写入模块的 `system.prop` 文件
- 注入自定义驱动所需的 SELinux 策略规则
- 原子性配置 QGL JSON 配置
- 递增启动尝试计数器

### 阶段 2 — `service.sh`（晚期启动，`boot_completed` 之后）

设备完全启动并可交互后运行。此阶段：
- 重置启动尝试计数器
- 重新强制设置 `debug.hwui.renderer`
- 写入持久性 `system.prop` 条目
- 可选强制停止第三方应用（适用于 `skiavk_all` 模式）

### 首次启动安全机制

安装模块后不会立即激活 Vulkan 渲染：
1. 安装程序创建 `.first_boot_pending` 标记文件
2. `post-fs-data.sh` 检测到此标记后 **推迟所有渲染器配置**
3. 创建 `.service_skip_render` 标记
4. `service.sh` 检测到跳过标记后也跳过渲染器配置
5. **第二次启动**时，`post-fs-data.sh` 正常应用配置的渲染模式

<a name="property-management"></a>
## 11. 属性管理系统

### `resetprop`（实时属性注入）

立即在运行中的系统中设置属性。在 `post-fs-data.sh` 中 SurfaceFlinger 启动之前使用是安全的。

### `system.prop`（启动时持久化）

模块维护一个 `system.prop` 文件。Root 管理器在启动早期（magic-mount 之后，任何应用进程启动之前）加载此文件。

### `renderengine.backend` 卡机问题（已修复）

在 OEM ROM（MIUI/HyperOS、三星 OneUI、ColorOS）上，SurfaceFlinger 为 `debug.renderengine.backend` 属性注册了实时 `SystemProperties::addChangeCallback`。如果在 SF 运行时该值发生变化，SF 会尝试在帧中间重新初始化其 RenderEngine——这会导致 SF 崩溃、所有应用失去窗口界面，设备看门狗重启。

**修复方案：** `debug.renderengine.backend` 仅在 `post-fs-data.sh` 中 SF 启动之前设置，永远不在 `service.sh` 中实时 resetprop，也不写入 `system.prop`。

<a name="configuration-system"></a>
## 12. 配置系统

### 配置文件：`adreno_config.txt`

| 设置 | 值 | 默认值 | 用途 |
|-----|----|--------|------|
| `PLT` | `y` / `n` | `n` | 修补 `public.libraries*.txt` 以注册 `gpu++.so`——Zura's Bench++ 驱动必需 |
| `QGL` | `y` / `n` | `n` | 将调优的 `qgl_config.txt` 部署到 `/data/vendor/gpu/` |
| `ARM64_OPT` | `y` / `n` | `n` | 移除 32 位驱动库以节省约 100–200MB。**仅在零 32 位应用时安全** |
| `VERBOSE` | `y` / `n` | `n` | 启用详细的逐操作日志 |
| `RENDER_MODE` | `normal` / `skiavk` / `skiagl` / `skiavk_all` | `normal` | 设置 HWUI 和 SurfaceFlinger 渲染后端 |

**大多数用户的推荐：** 保持所有设置为默认值（`n` / `normal`），只更改你有特定需求的选项。

### 常见配置方案

**最大兼容性（所有用户）：** `PLT=n  QGL=n  ARM64_OPT=n  VERBOSE=n  RENDER_MODE=normal`

**启用 Vulkan 渲染：** 同上但 `RENDER_MODE=skiavk`

**Zura Bench++ 测试：** `PLT=y  RENDER_MODE=normal`

**调试问题：** `VERBOSE=y`

### 更改配置

- **WebUI（推荐）：** WebUI → 配置标签 → 更改设置 → 立即应用或保存并重启
- **手动（设备上）：** 编辑 `/data/adb/modules/adreno_gpu_driver_unified/adreno_config.txt` 并重启
- **Recovery 模式：** 刷入前编辑 ZIP 中的 `adreno_config.txt`

<a name="webui-complete-guide"></a>
## 13. WebUI 管理器完整指南

详见 **第六部分** 的完整 WebUI 用户指南。

**快速访问：**
- Magisk：安装 KernelSU WebUI APK，授予 Root 权限后打开
- KernelSU：KernelSU Manager → 模块 → Adreno GPU Driver → 打开 WebUI
- APatch：APatch Manager → 模块 → 打开 WebUI

<a name="selinux-policy"></a>
## 14. SELinux 策略注入

### 为何必要

自定义 Adreno 驱动库需要访问 GPU 设备节点（`/dev/kgsl-3d0` 等），并需要作为 `same_process_hal`（进程内 HAL）加载。没有策略注入，GPU 无法初始化，应用会崩溃，或 SurfaceFlinger 拒绝加载自定义驱动。

### 注入内容

`post-fs-data.sh` 在激活渲染器之前同步注入超过 100 条 SELinux 策略规则：

- **GPU 设备访问** — 允许各进程上下文的 `gpu_device` ioctls 和读取
- **同进程 HAL** — 允许自定义驱动被所有相关进程类型作为进程内 HAL 库加载
- **Vendor 文件上下文** — 允许访问 Adreno 特定 vendor 库路径
- **Android 16 QPR2** — 包含新内核 SELinux 强制执行所需的更新 `allowxperm` IOCTL 范围规则（0x0000–0xffff）
- **SDK 版本化应用域** — 覆盖 SDK 25 至 36 的 `untrusted_app` 域
- **OEM 特定规则** — 三星自定义库路径方案、OPPO/Realme vendor 路径布局等修复

<a name="cache-management"></a>
## 15. 缓存管理系统

替换 GPU 驱动时，现有的着色器管线缓存会失效。模块在 `/data/local/tmp/adreno_last_render_mode` 跟踪上次活动的渲染模式。每次启动时，如果当前模式与存储的模式不同，模块会选择性清除：

- `/data/misc/hwui/` — 系统级 HWUI 缓存
- 所有已安装应用的每应用 `app_skia_pipeline_cache` 目录

**缓存清除后的首次启动行为：** 首次启动将需要 1–3 分钟而不是通常的 30 秒。游戏的首次启动会有明显的卡顿或编译暂停，这是暂时的。

<a name="bootloop-detection-system"></a>
## 16. 卡机检测与恢复

### 检测原理

`/data/local/tmp/adreno_boot_attempts` 处的启动计数器跟踪 `post-fs-data.sh` 在没有对应成功 `service.sh` 完成的情况下运行了多少次。

- `post-fs-data.sh` 在每次运行开始时**递增**计数器
- `service.sh` 在 `boot_completed` 后将其**重置**为 0
- 如果计数器达到 **3**（三次连续失败的启动，正常运行时间不足 60 秒），`post-fs-data.sh` 通过触碰 Magisk/KSU `disable` 标志禁用模块

### 检测到卡机后的处置

模块在脱离之前收集诊断日志：`last_kmsg`、`pstore` 内容、`dmesg` 以及人类可读的 `boot_state.txt`。所有日志保存到 `/sdcard/Adreno_Driver/Bootloop/bootloop_TIMESTAMP/`。

<a name="oem-rom-compatibility"></a>
## 17. OEM ROM 兼容性

模块检测并处理：

- **MIUI/HyperOS** — 清除 `debug.vulkan.dev.layers`，禁用 Snapdragon 分析器钩子
- **三星 OneUI** — 修复 Samsung 自定义库路径方案的 SELinux 上下文，处理 Samsung Vulkan 门控属性
- **ColorOS / RealmeUI** — 调整 OPPO vendor 路径布局的 SELinux 上下文
- **FuntouchOS** — 类似的 vendor 路径和 layer 清理

---

# 第三部分：技术参考

<a name="config-file-reference"></a>
## 18. 配置文件参考

### `adreno_config.txt` — 所有选项

**PLT（公共库文本）修补**
- `PLT=n`（默认）— 不修改 public.libraries.txt
- `PLT=y` — 将 `gpu++.so 64` 添加到 `/vendor/etc/public.libraries*.txt`，启用应用加载扩展 GPU 功能库。Zura's Bench++ 驱动必需。风险：DRM 应用和银行应用可能检测到系统修改。

**QGL（高通图形库）配置**
- `QGL=n`（默认）— 无自定义 QGL 配置
- `QGL=y` — 将调优的 `qgl_config.txt` 写入 `/data/vendor/gpu/`。配置控制内存分配策略、命令缓冲区大小和管线编译设置。

**ARM64 优化**
- `ARM64_OPT=n`（默认）— 安装 32 位和 64 位库
- `ARM64_OPT=y` — 移除 `system/vendor/lib/`（32 位库）。节省 100–200MB。会破坏所有 32 位应用或游戏。

**详细日志**
- `VERBOSE=n`（默认）— 正常日志
- `VERBOSE=y` — 记录每个单独操作。仅用于调试。

**RENDER_MODE** — 详见第 24 节。有效值：`normal`、`skiavk`、`skiagl`、`skiavk_all`。

<a name="system-properties"></a>
## 19. 系统属性参考

| 属性 | 设置位置 | 用途 |
|-----|---------|------|
| `debug.hwui.renderer` | `post-fs-data.sh` + `service.sh` | 每进程 HWUI 后端 |
| `debug.renderengine.backend` | 仅 `post-fs-data.sh` | SurfaceFlinger 合成器后端 — **启动后永不实时设置** |
| `ro.hwui.use_vulkan` | `post-fs-data.sh` | 系统级 Vulkan 启用标志 |
| `debug.sf.hw` | `system.prop` | SurfaceFlinger 硬件合成 |
| `graphics.gpu.profiler.support` | `post-fs-data.sh` | 禁用以防止分析器崩溃 |
| `debug.vulkan.dev.layers` | `post-fs-data.sh`（MIUI） | 清除以防止 OEM Vulkan layer 注入 |

<a name="log-files-reference"></a>
## 20. 日志文件完整参考

所有日志写入 `/sdcard/Adreno_Driver/`：

| 路径 | 内容 | 保留数量 |
|-----|------|---------|
| `Booted/postfs_*.log` | 完整 post-fs-data 序列 | 最近 5 个 |
| `Booted/service_*.log` | service.sh 完成情况 | 最近 5 个 |
| `Bootloop/bootloop_TIMESTAMP/` | 崩溃日志和诊断信息 | 最近 3 个 |
| `Config/adreno_config.txt` | 当前配置备份 | 始终保留 |

<a name="gpu-compatibility-matrix"></a>
## 21. GPU 兼容性矩阵

> **开发者注：** 任何具有 kernel 4.14+ 的 Adreno 均可使用驱动 819。任何具有 kernel 5.4+ 的 Adreno 均可使用驱动 837/840+。此列表显示能够启动的驱动——能启动不代表性能更好。请自行测试和基准测试。

### Adreno 4xx 系列

**Adreno 418：** 兼容：223、601、646 — 推荐：601
**Adreno 420：** 兼容：24 — 推荐：24（唯一选项）
**Adreno 430：** 兼容：24、436、601、646 — 推荐：436

### Adreno 5xx 系列

**Adreno 504：** 兼容：415、502 — 推荐：502
**Adreno 505/506/508/509：** 兼容：313、331、415、454、472、490、502 — 推荐：490 或 502
**Adreno 510/512：** 兼容：331 — 推荐：331
**Adreno 530：** 兼容：384、393、415、454、490、502 — 推荐：490
**Adreno 540：** 兼容：331、415、454、490、502、555 — 推荐：502 或 555

### Adreno 6xx 系列

**Adreno 610 v1：** 最高 v819 — 推荐：757 或 819
**Adreno 610 v2：** 最高 v777 — 推荐：757 或 777。⚠️ v819 会在 v2 上卡机
**Adreno 618：** 兼容：366、415、464、502、611、615、655、687、777、786、819 — 推荐：777 或 819
**Adreno 630：** 兼容：331、415、464、502、615、797 — 推荐：615 或 797（SD845 设备）
**Adreno 640：** 兼容：359–819（范围广）— 推荐：786 或 819（SD855/SD860）
**Adreno 650：** 兼容：443–819（范围极广）— 推荐：777、786 或 819（SD865/SD870）
**Adreno 660：** 兼容：522–837 — 推荐：819 或 837（SD888）

### Adreno 7xx 系列

**Adreno 725：** 兼容：615–840 — 推荐：v819 或 v840
**Adreno 730：** 兼容：614–837 — 推荐：819 或 837（SD8 Gen 1）
**Adreno 740：** 兼容：614–837 — 推荐：837 或 821（SD8 Gen 2）
**Adreno 750：** 兼容：744–837 — 推荐：837（SD8 Gen 3）

### Adreno 8xx 系列

**Adreno 802：** 非常新的架构，驱动支持有限，仅实验性支持。

<a name="driver-version-selection"></a>
## 22. 驱动版本选择

**系统性查找最佳驱动的方法：**

1. 找到你的 GPU：`adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model`
2. 查看上方兼容性矩阵中推荐的驱动
3. 建立基准：运行 3DMark Sling Shot Extreme 3 次取平均分
4. 首先测试推荐版本
5. 每次步进一个版本（更新或更旧）进行测试
6. 记录结果并与社区分享

兼容性 ≠ 性能更好。驱动能启动不代表它是改进。务必基准测试和比较。

<a name="rom-specific"></a>
## 23. ROM 特定注意事项

### MIUI / HyperOS
最新版本使用 EROFS（只读文件系统）— **Recovery 模式安装在 EROFS 上不可能，只能使用模块模式**。推荐：`RENDER_MODE=normal`，`PLT=n`。

### 三星 OneUI
可能影响 Game Launcher 和 Bixby Vision。彻底测试摄像头功能。

### ColorOS / RealmeUI
可能需要 `ARM64_OPT=n`，即使在纯 64 位设备上。推荐：`RENDER_MODE=normal`。

### FuntouchOS / OriginOS（vivo）
如果在 KernelSU 上遇到挂载问题，使用 `META_OVERLAYFS` metamodule。推荐 `RENDER_MODE=skiagl`。

### 自定义 ROM（LineageOS、Pixel Experience 等）
兼容性最好。纯净 AOSP 基础意味着最高成功率和最少损坏功能。

<a name="render-mode-technical"></a>
## 24. RENDER_MODE 技术细节

### 渲染模式表

| 模式 | HWUI 渲染器 | SurfaceFlinger 后端 | 行为 |
|-----|------------|-------------------|------|
| `normal` | 系统默认 | 系统默认 | 不覆盖渲染器；模块仅替换驱动二进制。最安全。 |
| `skiavk` | Skia + Vulkan | `skiavkthreaded` | 完整 Vulkan 渲染管线。使用自定义驱动时 GPU 利用率最佳。 |
| `skiagl` | Skia + OpenGL | `skiaglthreaded` | OpenGL 渲染管线。Vulkan 有问题时的备选方案。 |
| `skiavk_all` | Skia + Vulkan | `skiavkthreaded` | 与 `skiavk` 相同，另外在启动时节流强制停止后台应用，使每个进程以 Vulkan 渲染器冷启动。 |

### 何时使用各模式

- **normal** — 如果没有特定理由就使用此模式。最大兼容性。大多数用户推荐。
- **skiavk** — 在 2020+ 的现代设备（Adreno 6xx/7xx/8xx）上尝试，如果想要 Vulkan 加速的 UI 渲染。低风险。
- **skiagl** — 仅在有渲染异常、UI 伪影或 Vulkan 兼容性问题时使用。
- **skiavk_all** — 实验性。仅用于基准测试，或当某些应用在常规 `skiavk` 启动后仍渲染不正确时使用。

---

# 第四部分：故障排查与恢复

<a name="complete-troubleshooting"></a>
## 25. 完整故障排查指南

### 通用诊断步骤

```bash
# 1. 检查模块状态
adb shell su -c "ls /data/adb/modules/adreno_gpu_driver_unified/"
# 查找：module.prop（必需），disable（不好！），skip_mount（不好！）

# 2. 验证驱动实际已挂载
adb shell ls -la /vendor/lib64/libGLESv2_adreno.so

# 3. 检查 SELinux 拒绝
adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno|vendor" | head -20

# 4. 检查启动日志
adb shell ls /sdcard/Adreno_Driver/Booted/

# 5. 检查 GPU 是否被识别
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

### 问题：应用崩溃（尤其是键盘/Gboard）

**KernelSU 上最可能的原因：** 没有安装 Metamodule。
检查：`adb shell ls /data/adb/modules/adreno_gpu_driver_unified/skip_mount`
如果文件存在 → Metamodule 缺失。解决方案：安装 MetaMagicMount 并重新安装此模块。

<a name="bootloop-recovery-all"></a>
## 26. 卡机恢复（所有方式）

### 方式 1：音量键恢复（Magisk — 最简单）
```
1. 完全关机
2. 按电源键开机
3. 出现启动 Logo 时按住音量下键
4. 保持按住直到主屏幕加载（这会禁用所有 Magisk 模块）
5. 打开 Magisk Manager → 模块 → 找到"Adreno GPU Driver" → 禁用 → 重启
```

### 方式 2：Recovery 文件管理器（通用）
```
1. 进入自定义 Recovery（电源键 + 音量上键）
2. Mount → 启用 Data 分区
3. 文件管理器 → /data/adb/modules/
4. 找到 adreno_gpu_driver_unified → 长按 → 删除
5. 重启
```

### 方式 3：ADB Shell
```bash
# 选项 A：删除模块文件夹
adb shell su -c "rm -rf /data/adb/modules/adreno_gpu_driver_unified && reboot"

# 选项 B：禁用模块（保留文件，禁止加载）
adb shell su -c "touch /data/adb/modules/adreno_gpu_driver_unified/disable && reboot"
```

### 方式 4：安全模式
```
1. 尝试正常启动
2. 出现 Logo 时按住音量下键
3. 如果角落出现"安全模式"文字 → 模块已禁用！
4. 通过 Magisk Manager 移除模块 → 正常重启
```

<a name="fix-camera"></a>
## 27. 摄像头无法使用

### 症状

| 症状 | 可能原因 |
|-----|---------|
| 摄像头应用立即崩溃 | OpenCL 库冲突 |
| 摄像头打开但卡住/冻结 | GPU 数据生产者冲突 |
| 摄像头工作但无预览 | LLVM 编译器冲突 |
| 摄像头工作但照片损坏 | 内核计算层冲突 |

### 快速修复（WebUI）

1. WebUI → 工具标签 → **修复摄像头**
2. 确认移除
3. 重启设备

### 移除的内容

`libCB.so`、`libgpudataproducer.so`、`libkcl.so`、`libkernelmanager.so`、`libllvm-qcom.so`、`libOpenCL.so`、`libOpenCL_adreno.so`、`libVkLayer_ADRENO_qprofiler.so`

> **关于 `libVkLayer_ADRENO_qprofiler.so`：** 这是 Adreno Vulkan 分析器层。在部分 OEM ROM 上，该库会被摄像头 HAL 加载，在使用自定义驱动时导致摄像头故障。

如需恢复这些库，重新刷入模块 ZIP。

### 手动修复（ADB）

```bash
adb shell su -c "
MODLIB=/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64
rm -f \$MODLIB/libOpenCL.so \$MODLIB/libOpenCL_adreno.so \$MODLIB/libCB.so
rm -f \$MODLIB/libkcl.so \$MODLIB/libkernelmanager.so
rm -f \$MODLIB/libgpudataproducer.so \$MODLIB/libllvm-qcom.so
"
# 重启
```

**注意：** 如果模块安装前摄像头就已损坏，此修复无效——它只解决由模块自身库导致的损坏。

### Android 16 QPR2 及以上版本 — 存储损坏提示

在 Android 16 QPR2 及以上版本上，部分用户报告移除 OpenCL 库也可以解决存储损坏问题。有两种方式：

**方式 A — 手动移除 OpenCL 库**（仅移除 OpenCL 特定计算库）：

从模块覆盖层 `/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64/` 中删除以下文件：

```
libOpenCL.so
libOpenCL_adreno.so
libCB.so
libkcl.so
libkernelmanager.so
libllvm-qcom.so
libgpudataproducer.so
```

**方式 B — 快速修复摄像头**（WebUI → 工具 → 修复摄像头）：

移除更广泛的 OpenCL 和计算库集合：

```
libCB.so
libgpudataproducer.so
libkcl.so
libkernelmanager.so
libllvm-qcom.so
libOpenCL.so
libOpenCL_adreno.so
libVkLayer_ADRENO_qprofiler.so
```

> **关于 `libVkLayer_ADRENO_qprofiler.so`：** 这是 Adreno Vulkan 分析器层。在部分 OEM ROM（尤其是 MIUI/HyperOS、ColorOS 等）上，该库会被摄像头 HAL 加载，在使用自定义驱动时导致摄像头故障。快速修复摄像头会将其移除以解决这类问题。

两种方式都可以解决受影响设备上的存储损坏问题。方式 A 更保守。方式 B 移除更多库，是推荐的一键解决方案。两种方式之后均需重启。

> ⚠️ **免责声明：** 此方法仅适用于 Android 16 QPR2 及以上版本中**极少数特定设备**，**不是**通用修复方法。除非已确认你的特定设备存在此问题，否则不要期望移除这些库能解决存储损坏。

### Vendor GPU 文件 — 存储损坏预防

某些设备在刷入自定义驱动之前，可能需要将自己设备的原厂 vendor 分区中的 `vendor/gpu/` 文件复制到驱动刷入文件夹中。跳过此步骤可能在受影响的设备上导致存储损坏。

> ⚠️ **设备特定：** 并非所有设备都需要此操作。只有在刷入后遇到存储损坏，或已知你的设备需要此操作时才执行。从设备的原厂 vendor 镜像中提取 `vendor/gpu/` 目录，并在刷入前将其放入驱动刷入文件夹。

<a name="fix-screen-recorder"></a>
## 28. 录屏损坏

### 症状

录屏无法启动、录制显示黑屏、截图损坏、安装模块后出现"编码失败"错误。

### 快速修复（WebUI）

WebUI → 工具标签 → **修复录屏** → 重启。

### 移除的内容

`libC2D2.so`、`libc2d30_bltlib.so`、`libc2dcolorconvert.so`

<a name="fix-night-mode"></a>
## 29. 夜间模式问题

### 症状

安装模块后夜间模式/护眼模式/阅读模式停止工作。

### 快速修复（WebUI）

WebUI → 工具标签 → **修复夜间模式** → 重启。

### 移除的内容

`libsnapdragon_color_manager.so`

<a name="fix-performance"></a>
## 30. 性能问题

### 性能比之前更差

- 检查 `RENDER_MODE`——如果启用了 `skiavk`，Vulkan 驱动可能对你的设备调优不佳。尝试 `normal`。
- 清除 GPU 缓存（WebUI → 工具 → 清除 GPU 缓存）
- 尝试更旧或更新的驱动版本
- 检查 GPU 温度：`adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`

### 系统性测试驱动版本

1. 从兼容性矩阵推荐版本开始
2. 建立基准测试基准（3DMark Sling Shot Extreme，3 次取平均）
3. 测试推荐版本 → 基准测试
4. 步进到下一个更新版本 → 基准测试
5. 如果更差，步进到更旧版本 → 基准测试
6. 记录所有结果

<a name="fix-graphics-glitches"></a>
## 31. 图形异常

### 视觉伪影、UI 闪烁、损坏图形

- 如果使用 `skiavk` 或 `skiavk_all`：切换到 `skiagl` 或 `normal`
- 清除 GPU 缓存
- 尝试不同的驱动版本
- 检查 SELinux 拒绝：`adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno"`

<a name="fix-module-not-loading"></a>
## 32. 模块未加载

**KernelSU：** 先安装 MetaMagicMount 或其他 Metamodule。检查 `skip_mount` 文件：
```bash
adb shell ls /data/adb/modules/adreno_gpu_driver_unified/skip_mount
```
如果存在 → 安装时未检测到 Metamodule。

**Magisk：** 确保 Magic Mount 已在设置中启用。检查模块没有 `disable` 标记。

**APatch：** 验证 APatch 版本（0.10.8+ 才有内置 Magic Mount）。

---

# 第五部分：Recovery 模式安装

<a name="recovery-mode-guide"></a>
## 33. Recovery 模式完整指南

Recovery 模式安装将驱动文件**直接复制到 vendor 分区**。更改是**永久的且不易撤销的**。仅在无法使用 Magisk/KernelSU/APatch 时使用。

<a name="recovery-risks"></a>
## 34. 了解风险

| 风险 | 模块模式 | Recovery 模式 |
|-----|---------|--------------|
| 可撤销 | ✅ 立即 | ❌ 需要恢复 vendor |
| 存活 OTA | ✅ 大部分 | ❌ OTA 会抹去 |
| WebUI 可用 | ✅ 是 | ❌ 否 |
| 可更改设置 | ✅ 是 | ❌ 必须重刷 |
| EROFS vendor | ✅ 可用 | ❌ 不可能 |

**⚠️ 不要在 EROFS vendor 分区设备上使用 Recovery 模式。**

<a name="recovery-backups"></a>
## 35. 必须备份的内容

在 Recovery 模式刷入前，必须备份 vendor 分区：

```bash
# 通过 TWRP
TWRP → 备份 → 选择"Vendor" → 滑动备份

# 通过 ADB
adb shell su -c "dd if=/dev/block/by-name/vendor of=/sdcard/vendor_backup.img"
```

<a name="recovery-installation-steps"></a>
## 36. Recovery 安装步骤

1. **刷入前编辑配置** — 在 PC 上解压 ZIP，打开 `adreno_config.txt`，设置所需的 PLT/QGL/ARM64_OPT/RENDER_MODE 值，保存（UTF-8，无 BOM），重新打包 ZIP
2. **进入自定义 Recovery**（电源键 + 音量上键）
3. **安装 ZIP** — 不需要 Advanced Wipe；直接刷入 ZIP
4. 安装程序自动检测 Recovery 模式，以读写方式挂载 `/vendor`，直接复制驱动文件，设置权限并应用配置
5. **重启** — 没有 WebUI；不重刷就无法更改设置
6. **卸载方式**：恢复 vendor 备份，或脏刷 ROM

---

# 第六部分：WebUI 管理器指南

从你的 Root 管理器（Magisk/KernelSU/APatch）打开 WebUI，点击模块的 web 图标或使用 KernelSU WebUI APK。界面有四个标签：**主页**、**配置**、**工具**和**数据**。

---

<a name="webui-home"></a>
## 37. 主页标签

登陆页面，一览你的设备状态。

**系统信息面板** — 显示设备型号、Android 版本、内核、CPU/GPU 标识符，以及模块已挂载的当前活动 Adreno 驱动版本。

**渲染状态面板** — 显示三个渲染器属性的实时值：
- `debug.hwui.renderer` — 每个应用使用的渲染管线
- `debug.renderengine.backend` — SurfaceFlinger 的合成器后端
- `ro.hwui.use_vulkan` — 系统级是否启用 Vulkan

---

<a name="webui-config"></a>
## 38. 配置标签

在此选择模块如何配置图形栈。

### 渲染模式

| 模式 | 作用 |
|-----|------|
| **Normal** | 无渲染器覆盖。模块仅替换驱动二进制。最安全的备选。 |
| **skiavk** | 设置 HWUI 为 Skia+Vulkan，SurfaceFlinger 为 `skiavkthreaded`。使用自定义驱动时 GPU 性能最佳。 |
| **skiagl** | 设置 HWUI 为 Skia+OpenGL，SurfaceFlinger 为 `skiaglthreaded`。如果 Vulkan 在你的设备上有问题时使用。 |
| **skiavk_all** | 与 skiavk 相同，但还会在启动时强制停止所有第三方后台应用，使它们以 Vulkan 渲染器全新冷启动。 |

### 应用更改

**立即应用** — 通过 `resetprop` 立即注入属性而不重启。已运行的应用缓存了渲染器，关闭并重新打开它们以获取更改。

**保存并重启** — 将属性写入模块持久性 `system.prop` 并重启。

> **提示：** 先用*立即应用*测试模式。如果一切正常，再用*保存并重启*使其永久生效。

### QGL 配置

打开 **QGL 编辑器** — 高通图形库 JSON 配置文件的文本编辑器。

---

<a name="webui-utils"></a>
## 39. 工具标签

故障排查和驱动操作工具。

### GPU 欺骗器

让 GPU 驱动向应用和游戏报告不同的 Adreno 型号编号。

**使用方法：**
1. 点击**扫描** — 读取模块中所有 `libgsl.so` 文件，列出找到的每个 Adreno 型号 ID
2. **选择源** — 选择二进制中当前的型号（你的 GPU 实际型号）
3. **输入目标** — 输入你想要驱动报告的型号 ID
4. 点击**应用欺骗**

### 恢复原版

从欺骗器创建的备份恢复原版 `libgsl.so`。

### 摄像头修复

移除已知会在某些设备/ROM 上损坏摄像头的特定 OpenCL 和计算库：`libCB.so`、`libgpudataproducer.so`、`libkcl.so`、`libkernelmanager.so`、`libllvm-qcom.so`、`libOpenCL.so`、`libOpenCL_adreno.so`、`libVkLayer_ADRENO_qprofiler.so`。

`libVkLayer_ADRENO_qprofiler.so` 是 Adreno Vulkan 分析器层——在部分 OEM ROM 上，该库会被摄像头 HAL 加载，在使用自定义驱动时导致摄像头故障。

### 录屏修复

移除可能损坏系统录屏的 C2D 库：`libC2D2.so`、`libc2d30_bltlib.so`、`libc2dcolorconvert.so`。

### 夜间模式修复

移除可能阻止夜间模式工作的 `libsnapdragon_color_manager.so`。

### 清除 GPU 缓存

删除系统 HWUI 着色器缓存（`/data/misc/hwui/`）和每应用 Skia 管线缓存。

---

<a name="webui-data"></a>
## 40. 数据标签

日志和统计信息。

### 统计

- **配置数** — 保存配置更改的次数
- **修复数** — 应用修复工具的次数
- **欺骗数** — 应用 GPU 欺骗的次数

### 启动日志

列出来自 `/sdcard/Adreno_Driver/Booted/` 和 `/Bootloop/` 的日志文件。点击日志条目查看完整内容。使用**导出**复制或分享日志文件。

---

<a name="webui-custom-tools"></a>
## 41. 自定义驱动工具（高级）

从配置标签的高级部分访问。

### 自定义 GPU 欺骗

在**你提供的任何 `libgsl.so` 文件**中欺骗型号 ID——不仅限于模块中当前的文件。

> ⚠️ **绝不要直接指向 `/vendor/` 或 `/system/`。** 修改 Android 运行时的实时系统库会导致卡机。始终先将驱动文件复制到 `/sdcard/`，然后在那里进行欺骗。

---

<a name="webui-language-theme"></a>
## 42. 语言与主题

UI 支持英语、简体中文和繁体中文作为内置选项。你还可以通过语言选择器将整个界面自动翻译成任何其他语言——该工具使用 Claude API 生成翻译并将其保存在本地供将来使用。文档（README）可以通过**翻译文档**选项单独翻译（仅适用于自定义语言）。

主题选择器（🎨）可让你更改 UI 强调色。选择会自动保存到配置中并在会话间持久保留。

---

<a name="webui-terminal"></a>
## 43. 终端日志

在每个标签上可见的可滚动终端面板，实时输出所有操作——属性应用、缓存清除、欺骗结果、QGL 保存和错误。颜色编码：绿色 = 成功，黄色 = 警告，红色 = 错误，白色 = 信息。

---

# 第七部分：附录

<a name="faq"></a>
## 44. 常见问题解答（FAQ）

**Q：这会在我的设备上工作吗？**

模块在满足以下条件的任何 Android 设备上工作：高通 Adreno GPU（`/sys/class/kgsl/kgsl-3d0/` 路径必须存在）、Android 11+、ARM64 架构，以及通过 Magisk/KernelSU/APatch 的 Root（或用于永久安装的自定义 Recovery）。搭载 Exynos、联发科或其他非 Adreno GPU 的设备**不支持**。

---

**Q：如何知道我的设备有哪个 GPU 型号？**

```bash
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

或使用 Play Store 的 DevCheck 应用（免费）。

---

**Q：哪个驱动版本应该使用？**

从兼容性矩阵（第 21 节）中你的 GPU 推荐版本开始。如果有问题，每次步进一个版本向下尝试。

---

**Q：RENDER_MODE 有什么用？应该选哪个？**

- **normal** — 如果没有特定原因就使用此模式。最大兼容性。
- **skiavk** — 如果想要 Vulkan 加速 UI 渲染可以尝试。低风险。
- **skiagl** — 仅在默认模式有渲染问题时使用。
- **skiavk_all** — 实验性。仅用于基准测试或应用渲染不正确时。

---

**Q：我的摄像头在安装后仍然正常工作。这正常吗？**

完全正常。摄像头问题**不是普遍的**——取决于你特定的驱动版本和设备。

---

**Q：社区智慧 — 有经验的用户推荐什么？**

1. 保守开始：模块模式，默认设置，推荐驱动版本
2. 每次只更改一项
3. 保持详细记录：尝试的驱动、效果、基准测试分数
4. 知道什么时候放弃：3+ 个驱动不工作 → ROM 不兼容，接受原版驱动可能是最好的
5. 在 XDA 或 Telegram 上分享你的发现

<a name="glossary"></a>
## 45. 术语表

| 术语 | 定义 |
|-----|------|
| **Adreno** | 高通 GPU 产品线品牌名称 |
| **GPU 驱动** | 控制 GPU 处理图形命令的软件 |
| **HWUI** | 硬件 UI — Android 的硬件加速用户界面渲染系统 |
| **SurfaceFlinger** | Android 的显示合成器 — 将所有窗口界面组合成最终屏幕图像 |
| **SELinux** | 安全增强 Linux — Android 的强制访问控制系统 |
| **Magic Mount** | Magisk 将文件叠加到文件系统而不修改分区的系统 |
| **OverlayFS** | Linux 文件系统叠加机制，Magic Mount 的替代方案 |
| **Metamodule** | 提供 KernelSU 原生缺乏的文件挂载能力的 KernelSU 辅助模块 |
| **PLT** | 公共库文本 — 列出应用允许加载的库的 `public.libraries.txt` 文件 |
| **QGL** | 高通图形库 — 用于 GPU 配置调优的高通内部系统 |
| **Vulkan** | 低开销、显式 3D 图形 API — 在现代 GPU 上比 OpenGL 更高效 |
| **Skia** | Android 的 2D 图形库 — 由 HWUI 用于渲染 UI 元素 |
| **skiavk** | 使用 Vulkan 后端的 Skia 渲染 |
| **skiagl** | 使用 OpenGL ES 后端的 Skia 渲染 |
| **着色器缓存** | 应用存储的预编译 GPU 程序，用于后续启动时更快渲染 |
| **KGSL** | 内核图形支持层 — Adreno GPU 的 Linux 内核驱动 |
| **EROFS** | 扩展只读文件系统 — 新版 ROM 中使用的压缩只读文件系统 |
| **卡机** | 设备在完全启动前持续重启的状态 |
| **resetprop** | Magisk 用于在运行时修改只读系统属性的工具 |

<a name="credits"></a>
## 46. 致谢

- **模块开发者：** @pica_pica_picachu
- **联系方式：** Telegram @zesty_pic
- **文档：** 在 Claude AI 辅助下生成和维护

特别感谢 Adreno 驱动修改社区提供的驱动兼容性测试数据，Magisk/KernelSU/APatch 团队提供的优秀 Root 框架，以及所有贡献卡机报告和兼容性发现的用户。

<a name="license"></a>
## 47. 许可证与免责声明

**风险自担。**

- 本模块修改关键系统 GPU 驱动文件
- 不提供任何明示或暗示的保证
- 开发者对设备变砖、数据丢失、功能损坏或任何其他损害不负责任
- 安装前务必备份
- 如有可能，先在备用设备上测试
- 包含的驱动文件是高通技术公司的财产

*文档可能包含不准确之处。请独立验证关键信息。*

---

*文档结束*
