# 🎯 ADRENO GPU 驅動指南
## 完整安裝與配置手冊

**模組名稱：** Adreno GPU Driver Unified
**模組 ID：** `adreno_gpu_driver_unified`
**開發者：** @pica_pica_picachu
**聯絡方式：** Telegram @zesty_pic
**版本：** 通用版（支援 Magisk • KernelSU • APatch • Recovery）

> **⚡ 一個 ZIP 檔案，適用於所有安裝方式**

> **⚠️ 卡機聲明：** 本模組包含可選的庫檔案替換（`libdmabufheap.so`、`libgpu_tonemapper.so`），這些庫與您設備特定的 Adreno GPU 世代、ROM 版本和供應商分割區相容。這些庫可能導致不受支援的設備卡機。如果遇到 3 次以上連續卡機，請透過快速修復移除這些庫，或重新刷入不帶庫覆蓋的版本。

---

# 📋 目錄

## 第一部分：快速入門（新手指南）
1. [這是什麼？能做什麼？](#what-is-this)
2. [快速前置檢查清單](#quick-prerequisites)
3. [安裝方式對比 — 選擇一種](#installation-methods-comparison)
4. [Magisk 安裝（推薦）](#magisk-quick-install)
5. [KernelSU 安裝](#kernelsu-quick-install)
6. [APatch 安裝](#apatch-quick-install)
7. [快速故障排查](#quick-troubleshooting)

## 第二部分：進階完整指南
8. [深入解析：模組工作原理](#how-module-works)
9. [檔案結構與元件](#file-structure-detailed)
10. [詳細啟動流程](#boot-process-detailed)
11. [屬性管理系統](#property-management)
12. [設定系統](#configuration-system)
13. [WebUI 管理器完整指南](#webui-complete-guide)
14. [SELinux 策略注入](#selinux-policy)
15. [快取管理系統](#cache-management)
16. [卡機偵測與恢復](#bootloop-detection-system)
17. [OEM ROM 相容性](#oem-rom-compatibility)

## 第三部分：技術參考
18. [設定檔參考](#config-file-reference)
19. [系統屬性參考](#system-properties)
20. [日誌檔案完整參考](#log-files-reference)
21. [GPU 相容性矩陣](#gpu-compatibility-matrix)
22. [驅動版本選擇](#driver-version-selection)
23. [ROM 特定注意事項](#rom-specific)
24. [RENDER_MODE 技術細節](#render-mode-technical)

## 第四部分：故障排查與恢復
25. [完整故障排查指南](#complete-troubleshooting)
26. [卡機恢復（所有方式）](#bootloop-recovery-all)
27. [相機無法使用](#fix-camera)
28. [螢幕錄製功能損壞](#fix-screen-recorder)
29. [夜間模式問題](#fix-night-mode)
30. [效能問題](#fix-performance)
31. [圖形異常](#fix-graphics-glitches)
32. [模組未載入](#fix-module-not-loading)

## 第五部分：Recovery 模式安裝
33. [Recovery 模式完整指南](#recovery-mode-guide)
34. [瞭解風險](#recovery-risks)
35. [必須備份的內容](#recovery-backups)
36. [Recovery 安裝步驟](#recovery-installation-steps)

## 第六部分：WebUI 管理器指南
37. [主頁標籤](#webui-home)
38. [設定標籤](#webui-config)
39. [工具標籤](#webui-utils)
40. [資料標籤](#webui-data)
41. [自訂驅動工具](#webui-custom-tools)
42. [語言與主題](#webui-language-theme)
43. [終端日誌](#webui-terminal)

## 第七部分：附錄
44. [常見問題解答（FAQ）](#faq)
45. [術語表](#glossary)
46. [致謝](#credits)
47. [授權與免責聲明](#license)

---

# 第一部分：快速入門

<a name="what-is-this"></a>
## 1. 這是什麼？能做什麼？

### 簡單說明（適合新手）

你的手機有 GPU（圖形處理單元）——負責處理所有圖形、遊戲和視覺效果的晶片。就像 PC 顯示卡一樣，GPU 需要「驅動程式」才能正常運作。

**本模組將手機的 GPU 驅動替換為不同版本。**

**你可能獲得的效果：**
- ✅ 更好的遊戲效能（更高幀率、更流暢的遊戲體驗）
- ✅ 改善圖形算繪
- ✅ 更好的應用效能
- 😐 沒有明顯差異
- ❌ 效能變差
- ❌ 功能損壞（相機、螢幕錄製等）

**實話實說：** 效果 **100% 取決於裝置**。在某台手機上效果極佳的方案，可能在另一台上完全無效。

### 什麼是「GPU 驅動」？

類比更新電腦顯示卡驅動：
- **Windows PC：** 下載 NVIDIA/AMD 驅動
- **Android 手機：** 透過本模組安裝 Adreno 驅動

### 本模組的主要功能

**🎯 通用安裝**
- 一個 ZIP 支援：Magisk、KernelSU、APatch 以及自訂 Recovery
- 自動偵測執行環境
- 在所有平台上正確安裝

**🛡️ 安全功能**
- 卡機偵測（偵測手機是否反覆重啟）
- 自動崩潰日誌收集
- 設定備份（更新後仍保留）
- 輕鬆移除（適用於 Magisk/KernelSU/APatch）

**🎨 Web 介面（僅 Magisk/KernelSU/APatch）**
- 無需編輯檔案即可變更設定
- 一鍵修復常見問題
- 查看日誌和系統資訊
- 多語言支援

**⚡ 智慧快取管理**
- 自動清理 GPU 著色器快取
- 防止相容性問題
- 針對新驅動進行最佳化

<a name="quick-prerequisites"></a>
## 2. 快速前置檢查清單

### ✅ 必須滿足（全部必需）

**裝置要求：**
- [ ] 高通 Adreno GPU（透過 DevCheck 應用程式確認）
  - ❌ Mali GPU（三星/聯發科）— 不支援
  - ❌ PowerVR GPU — 不支援
  - ❌ Adreno 5xx 或更舊 — 不推薦

- [ ] Android 11 或更新版本（Android 10 可能有效但不受支援）
- [ ] ARM64 架構（64 位元裝置）
- [ ] 至少 500MB 可用儲存空間
- [ ] 已解鎖 Bootloader

**Root/Recovery 要求（選擇一種）：**
- [ ] Magisk 20.4+ 已安裝，或
- [ ] KernelSU 0.5.0+ 已安裝，或
- [ ] APatch 0.10.7+ 已安裝，或
- [ ] 自訂 Recovery（TWRP 3.5.0+、OrangeFox R11+）

**知識要求：**
- [ ] 知道如何安裝 Magisk/KernelSU/APatch 模組
- [ ] 知道如何進入 Recovery 模式
- [ ] 知道如何從卡機狀態恢復
- [ ] 已做好備份（尤其是 Recovery 方式）

### ⚠️ 重要警告

**安裝前必讀：**

1. **❌ 不保證有改善**
   - 驅動可能改善、變差或毫無變化
   - 效能取決於驅動相容性
   - 這是 **實驗性** 功能

2. **❌ 可能損壞功能**
   - 相機可能無法使用
   - 螢幕錄製可能損壞
   - 夜間模式/護眼模式可能失效
   - 某些應用程式可能崩潰

3. **❌ 卡機風險**
   - 不相容的驅動 = 卡機
   - 必須知道如何恢復
   - **安裝前務必備份**

4. **❌ 一次只能裝一個**
   - 先卸載現有的 GPU 驅動模組
   - 不要混用多個 GPU 模組

5. **✅ 務必備份**
   - Magisk/KernelSU/APatch：易於移除
   - Recovery 模式：**必須備份 vendor 分區！**

<a name="installation-methods-comparison"></a>
## 3. 安裝方式對比 — 選擇一種

| 方式 | 可撤銷？ | 系統更改 | WebUI？ | 難度 | 風險 |
|------|---------|----------|--------|------|------|
| **Magisk** | ✅ 是（簡單） | ❌ 無 | ✅ 是 | 🟢 簡單 | 🟢 低 |
| **KernelSU** | ✅ 是（簡單） | ❌ 無 | ✅ 是 | 🟢 簡單 | 🟢 低 |
| **APatch** | ✅ 是（簡單） | ❌ 無 | ✅ 是 | 🟢 簡單 | 🟢 低 |
| **Recovery** | ❌ 否（永久） | ✅ 直接修改 | ❌ 否 | 🔴 困難 | 🔴 高 |

### 應該選哪種？

**已安裝 Magisk：**
→ 使用 **方式 A：Magisk**（推薦）

**已安裝 KernelSU：**
→ 使用 **方式 B：KernelSU**
- **重要：** 需要安裝 Metamodule！

**已安裝 APatch：**
→ 使用 **方式 C：APatch**

**沒有 Root 但有自訂 Recovery：**
→ 使用 **方式 D：Recovery**（僅限進階使用者）
- ⚠️ 永久更改
- ⚠️ 必須備份 vendor
- ⚠️ 沒有 WebUI

**第一次嘗試 GPU 驅動？**
→ **先安裝 Magisk**，再使用方式 A

<a name="magisk-quick-install"></a>
## 4. Magisk 安裝（推薦）

### 前置條件
- ✅ Magisk 20.4 或更新版本
- ✅ Magisk Manager 應用程式
- ✅ 已下載模組 ZIP

### 安裝步驟

1. 開啟 Magisk Manager
2. 進入**模組**標籤
3. 點擊「從儲存空間安裝」
4. 選擇 `adreno_gpu_driver_unified_vX.X.X.zip`
5. 等待安裝（30–60 秒）
6. 確認安裝摘要中有：
   - ✅ "GPU detected: Adreno XXX"
   - ✅ "Configuration loaded"
   - ✅ "XX files installed"
   - ✅ "Caches cleaned"
7. 重新啟動裝置
8. 驗證：開啟 Magisk Manager → 模組標籤 → 確認模組已啟用

### 如果手機無法啟動（卡機）

**方式 1：音量鍵恢復**（最簡單）
```
1. 完全關機
2. 按電源鍵開機
3. 出現 Logo 時按住音量下鍵
4. 保持按住直到系統啟動
5. 開啟 Magisk Manager → 模組 → 停用 Adreno GPU Driver
6. 正常重新啟動
```

**方式 2：Recovery 檔案管理員**
```
1. 進入 Recovery（電源鍵 + 音量上鍵）
2. Mount → 啟用 Data
3. 檔案管理員 → /data/adb/modules/
4. 刪除 adreno_gpu_driver_unified 資料夾
5. 重新啟動系統
```

**方式 3：ADB**
```bash
adb shell su -c "rm -rf /data/adb/modules/adreno_gpu_driver_unified && reboot"
```

<a name="kernelsu-quick-install"></a>
## 5. KernelSU 安裝

### 前置條件
- ✅ KernelSU 0.5.0 或更新版本
- ✅ KernelSU Manager 應用程式
- ✅ 已下載模組 ZIP
- ✅ **必須：已安裝 Metamodule**（推薦 MetaMagicMount）

### 重要：Metamodule 要求

**⚠️ KernelSU 需要 Metamodule 才能掛載模組檔案**

推薦的 Metamodule：
1. **MetaMagicMount**（最推薦）
2. **Meta-Mountify**（次選）
3. **Meta-OverlayFS**
4. **Meta-Hybrid**

**沒有 Metamodule 的後果：**
- ❌ 模組安裝後不生效
- ❌ 檔案不會被掛載到系統
- ❌ 仍使用原版驅動

### KernelSU 設定（重要）

安裝前：KernelSU Manager → 設定 → 找到「預設卸載模組」→ **關閉**。

### 安裝步驟

1. 確認 Metamodule 已安裝並啟用
2. KernelSU Manager → 模組 → 安裝（+ 按鈕）
3. 選擇模組 ZIP 檔案
4. 等待安裝完成
5. 檢查警告——如果看到「No metamodule detected」→ 停止，先安裝 Metamodule
6. 重新啟動裝置

### 存取 WebUI（Magisk 上）
安裝 KernelSU WebUI APK，授予 Root 權限後即可查看所有模組的 WebUI。

### 存取 WebUI（KernelSU 上）
KernelSU Manager → 模組 → 點擊「Adreno GPU Driver」→ 開啟 WebUI

<a name="apatch-quick-install"></a>
## 6. APatch 安裝

### 前置條件
- ✅ APatch 0.10.7 或更新版本
- ✅ APatch Manager 應用程式
- ✅ 已下載模組 ZIP

### APatch 掛載模式

APatch 支援三種掛載模式，模組會自動偵測並適配：
- **Magic Mount**（v0.10.8+ 預設）— 相容性最好
- **OverlayFS**（可選）— 透過 `.overlay_enable` 標記啟用
- **Lite Mode** — 最小掛載，相容模式

### 安裝步驟

1. 開啟 APatch Manager → 模組 → 安裝
2. 從儲存空間選擇 ZIP
3. 等待安裝（APatch 模式自動偵測）
4. 重新啟動裝置
5. 在 APatch Manager → 模組中驗證模組已啟用

<a name="quick-troubleshooting"></a>
## 7. 快速故障排查

### 問題：模組不工作（檔案未掛載）

- **Magisk：** 確保 Magic Mount 已在設定中啟用。
- **KernelSU：** 先安裝 MetaMagicMount 或其他 Metamodule。如果模組資料夾中存在 `skip_mount` → 沒有偵測到 Metamodule。
- **APatch：** 檢查掛載模式和 APatch 版本（0.10.8+ 才有內建 Magic Mount）。

### 問題：手機啟動後崩潰/重啟

**原因：** 模組已掛載但驅動與硬體不相容。最簡單的修復方法是透過 Recovery 刷入。

**解決方案：** 移除模組，嘗試不同的驅動版本。

### 問題：相機無法使用

WebUI → 工具標籤 → 點擊「修復相機」→ 重新啟動。這會移除可能與相機 HAL 衝突的 OpenCL/計算函式庫。

### 問題：螢幕錄製損壞

WebUI → 工具標籤 → 點擊「修復螢幕錄製」→ 重新啟動。

### 問題：夜間模式/護眼模式不工作

WebUI → 工具標籤 → 點擊「修復夜間模式」→ 重新啟動。

### 問題：無法存取 WebUI

確認模組已啟用，啟動後等待 5 分鐘，嘗試不同的瀏覽器。檢查 `/data/local/tmp/Adreno_Driver/webui_running` 標記是否存在。

---

# 第二部分：進階完整指南

<a name="how-module-works"></a>
## 8. 深入解析：模組工作原理

模組核心做兩件事：

1. **替換 GPU 驅動** — 在任何程序載入系統驅動之前，透過 magic-mount 將自訂 Adreno `.so` 函式庫注入檔案系統，使每個應用程式和 Android 合成器（SurfaceFlinger）從第一幀起就使用自訂驅動。
2. **設定算繪器** — 設定 Android 系統屬性，告知 HWUI 算繪引擎和 SurfaceFlinger 使用哪種算繪管線（Vulkan 或 OpenGL），並為自訂驅動套用穩定性、效能和相容性調整旗標。

### 模組模式（Magisk/KernelSU/APatch）

`/data/adb/modules/adreno_gpu_driver_unified/system/vendor/` 目錄映射真實的 `/vendor/` 分區。Root 管理器的掛載系統（Magic Mount 或 OverlayFS）將這些檔案疊加在原生 vendor 分區之上——系統看到的是自訂驅動，而原版檔案在底層保持不變。停用或移除模組會立即恢復原狀。

### Recovery 模式（直接安裝）

檔案直接複製到 `/vendor/lib64/`、`/vendor/firmware/` 等目錄。這是永久性的——原版驅動被覆蓋。沒有 WebUI，不易移除。僅適合進階使用者。

<a name="file-structure-detailed"></a>
## 9. 檔案結構與元件

```
adreno_gpu_driver_unified/
├── META-INF/com/google/android/
│   ├── update-binary              # 通用安裝程式
│   └── updater-script
│
├── module.prop                    # 模組中繼資料
├── customize.sh                   # 安裝時執行
├── post-fs-data.sh                # 早期啟動指令碼
├── service.sh                     # 晚期啟動指令碼
├── uninstall.sh                   # 移除時執行
├── adreno_config.txt              # 主設定檔
├── qgl_config.txt                 # QGL JSON 設定
├── system.prop                    # 系統屬性覆蓋
│
├── webroot/                       # Web 介面
│   ├── index.html
│   ├── index.js
│   └── style.css / theme.css
│
└── system/vendor/
    ├── lib/                       # 32 位元函式庫（ARM64_OPT=n 時安裝）
    ├── lib64/                     # 64 位元函式庫（始終安裝）
    │   ├── libvulkan_adreno.so    # Vulkan 驅動
    │   ├── libGLESv2_adreno.so   # OpenGL ES 驅動
    │   ├── libOpenCL.so           # ⚠️ 可選 — 可能損壞相機
    │   ├── libC2D2.so             # ⚠️ 可選 — 可能損壞螢幕錄製
    │   ├── libsnapdragon_color_manager.so  # ⚠️ 可選 — 可能損壞夜間模式
    │   └── ...
    └── firmware/
        └── ...
```

### 函式庫快速參考

| 函式庫組 | 用途 | 不相容時的風險 |
|---------|------|--------------|
| `libGLESv2_adreno.so`、`libvulkan_adreno.so`、`libgsl.so` | 核心圖形驅動 | 卡機 |
| `libOpenCL.so`、`libCB.so`、`libkcl.so` 等 | GPU 運算/OpenCL | 相機損壞 |
| `libC2D2.so`、`libc2dcolorconvert.so` | 2D 合成 | 螢幕錄製損壞 |
| `libsnapdragon_color_manager.so` | 顯示色彩管理 | 夜間模式損壞 |
| `libgputonemap.so`、`libgpukbc.so`、`libdmabufheap.so` | 進階 GPU 功能 | 卡機 |

<a name="boot-process-detailed"></a>
## 10. 詳細啟動流程

### 階段 1 — `post-fs-data.sh`（極早期啟動，Zygote 之前）

檔案系統掛載後、任何應用程式或服務程序啟動前執行。此階段：
- 透過 `resetprop` 套用算繪器系統屬性
- 寫入模組的 `system.prop` 檔案
- 注入自訂驅動所需的 SELinux 策略規則
- 原子性設定 QGL JSON 設定
- 遞增啟動嘗試計數器

### 階段 2 — `service.sh`（晚期啟動，`boot_completed` 之後）

裝置完全啟動並可互動後執行。此階段：
- 重置啟動嘗試計數器
- 重新強制設定 `debug.hwui.renderer`
- 寫入持久性 `system.prop` 條目
- 可選強制停止第三方應用程式（適用於 `skiavk_all` 模式）

### Vulkan 相容性安全閘道

算繪器在所有啟動時（包括安裝後的首次啟動）立即套用。安全性由 `post-fs-data.sh` 中的結構性 Vulkan 相容性檢查提供：

1. `post-fs-data.sh` 檢查裝置上是否存在有效的 Vulkan ICD（可安裝用戶端驅動程式）。
2. 如果未找到 Vulkan ICD，算繪模式會從 `skiavk` **自動降級**為 `skiagl`——這是真正的結構性回退，而非時間延遲。
3. 當算繪模式變更時，管線快取在 Zygote 啟動前被清除，防止過期快取導致的當機。
4. `service.sh` 確認啟動成功並寫入 `.boot_success` 標記，該標記在後續啟動時控制 `skiavkthreaded` 後端的提升。

此方法提供真正的 Vulkan 能力偵測，而非將算繪器推遲到第二次啟動。

<a name="property-management"></a>
## 11. 屬性管理系統

### `resetprop`（即時屬性注入）

立即在執行中的系統中設定屬性。在 `post-fs-data.sh` 中 SurfaceFlinger 啟動之前使用是安全的。

### `system.prop`（啟動時持久化）

模組維護一個 `system.prop` 檔案。Root 管理器在啟動早期（magic-mount 之後，任何應用程式程序啟動之前）載入此檔案。

### `renderengine.backend` 卡機問題（已修復）

在 OEM ROM（MIUI/HyperOS、三星 OneUI、ColorOS）上，SurfaceFlinger 為 `debug.renderengine.backend` 屬性註冊了即時 `SystemProperties::addChangeCallback`。如果在 SF 執行時該值發生變化，SF 會嘗試在幀中間重新初始化其 RenderEngine——這會導致 SF 崩潰、所有應用程式失去視窗介面，裝置看門狗重新啟動。

**修復方案：** `debug.renderengine.backend` 僅在 `post-fs-data.sh` 中 SF 啟動之前設定，永遠不在 `service.sh` 中即時 resetprop，也不寫入 `system.prop`。

<a name="configuration-system"></a>
## 12. 設定系統

### 設定檔：`adreno_config.txt`

| 設定 | 值 | 預設值 | 用途 |
|-----|----|--------|------|
| `PLT` | `y` / `n` | `n` | 修補 `public.libraries*.txt` 以註冊 `gpu++.so`——Zura's Bench++ 驅動必需 |
| `QGL` | `y` / `n` | `n` | 將調優的 `qgl_config.txt` 部署到 `/data/vendor/gpu/` |
| `ARM64_OPT` | `y` / `n` | `n` | 移除 32 位元驅動函式庫以節省約 100–200MB。**僅在零 32 位元應用程式時安全** |
| `VERBOSE` | `y` / `n` | `n` | 啟用詳細的逐操作日誌 |
| `RENDER_MODE` | `normal` / `skiavk` / `skiagl` / `skiavk_all` | `normal` | 設定 HWUI 和 SurfaceFlinger 算繪後端 |

**大多數使用者的推薦：** 保持所有設定為預設值（`n` / `normal`），只更改你有特定需求的選項。

### 常見設定方案

**最大相容性（所有使用者）：** `PLT=n  QGL=n  ARM64_OPT=n  VERBOSE=n  RENDER_MODE=normal`

**啟用 Vulkan 算繪：** 同上但 `RENDER_MODE=skiavk`

**Zura Bench++ 測試：** `PLT=y  RENDER_MODE=normal`

**偵錯問題：** `VERBOSE=y`

### 變更設定

- **WebUI（推薦）：** WebUI → 設定標籤 → 變更設定 → 立即套用或儲存並重新啟動
- **手動（裝置上）：** 編輯 `/data/adb/modules/adreno_gpu_driver_unified/adreno_config.txt` 並重新啟動
- **Recovery 模式：** 刷入前編輯 ZIP 中的 `adreno_config.txt`

<a name="webui-complete-guide"></a>
## 13. WebUI 管理器完整指南

詳見**第六部分**的完整 WebUI 使用者指南。

**快速存取：**
- Magisk：安裝 KernelSU WebUI APK，授予 Root 權限後開啟
- KernelSU：KernelSU Manager → 模組 → Adreno GPU Driver → 開啟 WebUI
- APatch：APatch Manager → 模組 → 開啟 WebUI

<a name="selinux-policy"></a>
## 14. SELinux 策略注入

### 為何必要

自訂 Adreno 驅動函式庫需要存取 GPU 裝置節點（`/dev/kgsl-3d0` 等），並需要作為 `same_process_hal`（程序內 HAL）載入。沒有策略注入，GPU 無法初始化，應用程式會崩潰，或 SurfaceFlinger 拒絕載入自訂驅動。

### 注入內容

`post-fs-data.sh` 在啟用算繪器之前同步注入超過 100 條 SELinux 策略規則：

- **GPU 裝置存取** — 允許各程序上下文的 `gpu_device` ioctls 和讀取
- **同程序 HAL** — 允許自訂驅動被所有相關程序類型作為程序內 HAL 函式庫載入
- **Vendor 檔案上下文** — 允許存取 Adreno 特定 vendor 函式庫路徑
- **Android 16 QPR2** — 包含新核心 SELinux 強制執行所需的更新 `allowxperm` IOCTL 範圍規則（0x0000–0xffff）
- **SDK 版本化應用程式域** — 涵蓋 SDK 25 至 36 的 `untrusted_app` 域
- **OEM 特定規則** — 三星自訂函式庫路徑方案、OPPO/Realme vendor 路徑版面配置等修復

<a name="cache-management"></a>
## 15. 快取管理系統

替換 GPU 驅動時，現有的著色器管線快取會失效。模組在 `/data/local/tmp/adreno_last_render_mode` 追蹤上次活動的算繪模式。每次啟動時，如果目前模式與儲存的模式不同，模組會選擇性清除：

- `/data/misc/hwui/` — 系統級 HWUI 快取
- 所有已安裝應用程式的每應用程式 `app_skia_pipeline_cache` 目錄

**快取清除後的首次啟動行為：** 首次啟動將需要 1–3 分鐘而不是通常的 30 秒。這是暫時的。

<a name="bootloop-detection-system"></a>
## 16. 卡機偵測與恢復

### 偵測原理

`/data/local/tmp/adreno_boot_attempts` 處的啟動計數器追蹤 `post-fs-data.sh` 在沒有對應成功 `service.sh` 完成的情況下執行了多少次。

- `post-fs-data.sh` 在每次執行開始時**遞增**計數器
- `service.sh` 在 `boot_completed` 後將其**重置**為 0
- 如果計數器達到 **3**，`post-fs-data.sh` 透過觸碰 Magisk/KSU `disable` 旗標停用模組

### 偵測到卡機後的處置

模組在脫離之前收集診斷日誌。所有日誌儲存到 `/sdcard/Adreno_Driver/Bootloop/bootloop_TIMESTAMP/`。

<a name="oem-rom-compatibility"></a>
## 17. OEM ROM 相容性

模組偵測並處理：

- **MIUI/HyperOS** — 清除 `debug.vulkan.dev.layers`，停用 Snapdragon 分析器鉤點
- **三星 OneUI** — 修復 Samsung 自訂函式庫路徑方案的 SELinux 上下文
- **ColorOS / RealmeUI** — 調整 OPPO vendor 路徑版面配置的 SELinux 上下文
- **FuntouchOS** — 類似的 vendor 路徑和 layer 清理

---

# 第三部分：技術參考

<a name="config-file-reference"></a>
## 18. 設定檔參考

### `adreno_config.txt` — 所有選項

**PLT（公共函式庫文字）修補**
- `PLT=n`（預設）— 不修改 public.libraries.txt
- `PLT=y` — 將 `gpu++.so 64` 新增到 `/vendor/etc/public.libraries*.txt`。風險：DRM 應用程式和銀行應用程式可能偵測到系統修改。

**QGL（高通圖形函式庫）設定**
- `QGL=n`（預設）— 無自訂 QGL 設定
- `QGL=y` — 將調優的 `qgl_config.txt` 寫入 `/data/vendor/gpu/`。設定控制記憶體配置策略、命令緩衝區大小和管線編譯設定。

**ARM64 最佳化**
- `ARM64_OPT=n`（預設）— 安裝 32 位元和 64 位元函式庫
- `ARM64_OPT=y` — 移除 32 位元函式庫。節省 100–200MB。會破壞所有 32 位元應用程式或遊戲。

**RENDER_MODE** — 詳見第 24 節。有效值：`normal`、`skiavk`、`skiagl`、`skiavk_all`。

<a name="system-properties"></a>
## 19. 系統屬性參考

| 屬性 | 設定位置 | 用途 |
|-----|---------|------|
| `debug.hwui.renderer` | `post-fs-data.sh` + `service.sh` | 每程序 HWUI 後端 |
| `debug.renderengine.backend` | 僅 `post-fs-data.sh` | SurfaceFlinger 合成器後端 — **啟動後永不即時設定** |
| `ro.hwui.use_vulkan` | `post-fs-data.sh` | 系統級 Vulkan 啟用旗標 |
| `graphics.gpu.profiler.support` | `post-fs-data.sh` | 停用以防止分析器崩潰 |

<a name="log-files-reference"></a>
## 20. 日誌檔案完整參考

| 路徑 | 內容 | 保留數量 |
|-----|------|---------|
| `Booted/postfs_*.log` | 完整 post-fs-data 序列 | 最近 5 個 |
| `Booted/service_*.log` | service.sh 完成情況 | 最近 5 個 |
| `Bootloop/bootloop_TIMESTAMP/` | 崩潰日誌和診斷資訊 | 最近 3 個 |
| `Config/adreno_config.txt` | 目前設定備份 | 始終保留 |

<a name="gpu-compatibility-matrix"></a>
## 21. GPU 相容性矩陣

> **開發者注：** 任何具有 kernel 4.14+ 的 Adreno 均可使用驅動 819。任何具有 kernel 5.4+ 的 Adreno 均可使用驅動 837/840+。此清單顯示能夠啟動的驅動——能啟動不代表效能更好。請自行測試和基準測試。

### Adreno 4xx 系列

**Adreno 418：** 相容：223、601、646 — 推薦：601
**Adreno 420：** 相容：24 — 推薦：24（唯一選項）
**Adreno 430：** 相容：24、436、601、646 — 推薦：436

### Adreno 5xx 系列

**Adreno 504：** 相容：415、502 — 推薦：502
**Adreno 505/506/508/509：** 相容：313–502 — 推薦：490 或 502
**Adreno 530：** 相容：384–502 — 推薦：490
**Adreno 540：** 相容：331–555 — 推薦：502 或 555

### Adreno 6xx 系列

**Adreno 610 v1：** 最高 v819 — 推薦：757 或 819
**Adreno 610 v2：** 最高 v777 — 推薦：757 或 777。⚠️ v819 會在 v2 上卡機
**Adreno 618：** 相容：366–819 — 推薦：777 或 819
**Adreno 630：** 相容：331–797 — 推薦：615 或 797（SD845 裝置）
**Adreno 640：** 相容：359–819 — 推薦：786 或 819（SD855/SD860）
**Adreno 650：** 相容：443–819（極廣範圍）— 推薦：777、786 或 819（SD865/SD870）
**Adreno 660：** 相容：522–837 — 推薦：819 或 837（SD888）

### Adreno 7xx 系列

**Adreno 725：** 相容：615–840 — 推薦：v819 或 v840
**Adreno 730：** 相容：614–837 — 推薦：819 或 837（SD8 Gen 1）
**Adreno 740：** 相容：614–837 — 推薦：837 或 821（SD8 Gen 2）
**Adreno 750：** 相容：744–837 — 推薦：837（SD8 Gen 3）

### Adreno 8xx 系列

**Adreno 802：** 非常新的架構，驅動支援有限，僅實驗性支援。

<a name="driver-version-selection"></a>
## 22. 驅動版本選擇

1. 找到你的 GPU：`adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model`
2. 查看兼容性矩陣中推薦的驅動
3. 建立基準：執行 3DMark Sling Shot Extreme 3 次取平均分
4. 首先測試推薦版本
5. 每次步進一個版本進行測試
6. 記錄結果並與社群分享

<a name="rom-specific"></a>
## 23. ROM 特定注意事項

### MIUI / HyperOS
最新版本使用 EROFS — **Recovery 模式安裝在 EROFS 上不可能，只能使用模組模式**。推薦：`RENDER_MODE=normal`，`PLT=n`。

### 三星 OneUI
可能影響 Game Launcher 和 Bixby Vision。徹底測試相機功能。

### ColorOS / RealmeUI
可能需要 `ARM64_OPT=n`，即使在純 64 位元裝置上。

### FuntouchOS / OriginOS（vivo）
如果在 KernelSU 上遇到掛載問題，使用 `META_OVERLAYFS` metamodule。推薦 `RENDER_MODE=skiagl`。

### 自訂 ROM（LineageOS、Pixel Experience 等）
相容性最好。純淨 AOSP 基礎意味著最高成功率。

<a name="render-mode-technical"></a>
## 24. RENDER_MODE 技術細節

### 算繪模式表

| 模式 | HWUI 算繪器 | SurfaceFlinger 後端 | 行為 |
|-----|------------|-------------------|------|
| `normal` | 系統預設 | 系統預設 | 不覆蓋算繪器；模組僅替換驅動二進位。最安全。 |
| `skiavk` | Skia + Vulkan | `skiavkthreaded` | 完整 Vulkan 算繪管線。使用自訂驅動時 GPU 使用率最佳。 |
| `skiagl` | Skia + OpenGL | `skiaglthreaded` | OpenGL 算繪管線。Vulkan 有問題時的備選方案。 |
| `skiavk_all` | Skia + Vulkan | `skiavkthreaded` | 與 `skiavk` 相同，另外在啟動時節流強制停止後台應用程式。 |

### 何時使用各模式

- **normal** — 如果沒有特定理由就使用此模式。最大相容性。大多數使用者推薦。
- **skiavk** — 在 2020+ 的現代裝置（Adreno 6xx/7xx/8xx）上嘗試。低風險。
- **skiagl** — 僅在有算繪異常、UI 偽影或 Vulkan 相容性問題時使用。
- **skiavk_all** — 實驗性。僅用於基準測試。

---

# 第四部分：故障排查與恢復

<a name="complete-troubleshooting"></a>
## 25. 完整故障排查指南

```bash
# 1. 檢查模組狀態
adb shell su -c "ls /data/adb/modules/adreno_gpu_driver_unified/"

# 2. 驗證驅動實際已掛載
adb shell ls -la /vendor/lib64/libGLESv2_adreno.so

# 3. 檢查 SELinux 拒絕
adb shell dmesg | grep "avc:" | grep -iE "gpu|adreno|vendor" | head -20

# 4. 檢查啟動日誌
adb shell ls /sdcard/Adreno_Driver/Booted/

# 5. 檢查 GPU 是否被識別
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

<a name="bootloop-recovery-all"></a>
## 26. 卡機恢復（所有方式）

### 方式 1：音量鍵恢復（Magisk — 最簡單）
```
1. 完全關機
2. 按電源鍵開機
3. 出現啟動 Logo 時按住音量下鍵
4. 保持按住直到主螢幕載入
5. 開啟 Magisk Manager → 模組 → 停用 → 重新啟動
```

### 方式 2：Recovery 檔案管理員（通用）
```
1. 進入自訂 Recovery（電源鍵 + 音量上鍵）
2. Mount → 啟用 Data 分區
3. 檔案管理員 → /data/adb/modules/
4. 找到 adreno_gpu_driver_unified → 長按 → 刪除
5. 重新啟動
```

### 方式 3：ADB Shell
```bash
adb shell su -c "rm -rf /data/adb/modules/adreno_gpu_driver_unified && reboot"
```

<a name="fix-camera"></a>
## 27. 相機無法使用

### 症狀

| 症狀 | 可能原因 |
|-----|---------|
| 相機應用程式立即崩潰 | OpenCL 函式庫衝突 |
| 相機開啟但卡住/凍結 | GPU 資料生產者衝突 |
| 相機工作但無預覽 | LLVM 編譯器衝突 |
| 相機工作但照片損壞 | 核心運算層衝突 |

### 快速修復（WebUI）

1. WebUI → 工具標籤 → **修復相機**
2. 確認移除
3. 重新啟動裝置

### 移除的內容

`libCB.so`、`libgpudataproducer.so`、`libkcl.so`、`libkernelmanager.so`、`libllvm-qcom.so`、`libOpenCL.so`、`libOpenCL_adreno.so`、`libVkLayer_ADRENO_qprofiler.so`

> **關於 `libVkLayer_ADRENO_qprofiler.so`：** 這是 Adreno Vulkan 分析器層。在部分 OEM ROM 上，該函式庫會被相機 HAL 載入，在使用自訂驅動時導致相機故障。

如需恢復這些函式庫，重新刷入模組 ZIP。

### 手動修復（ADB）

```bash
adb shell su -c "
MODLIB=/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64
rm -f \$MODLIB/libOpenCL.so \$MODLIB/libOpenCL_adreno.so \$MODLIB/libCB.so
rm -f \$MODLIB/libkcl.so \$MODLIB/libkernelmanager.so
rm -f \$MODLIB/libgpudataproducer.so \$MODLIB/libllvm-qcom.so
"
# 重新啟動
```

**注意：** 如果模組安裝前相機就已損壞，此修復無效——它只解決由模組自身函式庫導致的損壞。

### Android 16 QPR2 及以上版本 — 儲存空間損毀提示

在 Android 16 QPR2 及以上版本上，部分使用者回報移除 OpenCL 函式庫也可以解決儲存空間損毀問題。有兩種方式：

**方式 A — 手動移除 OpenCL 函式庫**（僅移除 OpenCL 特定計算函式庫）：

從模組覆蓋層 `/data/adb/modules/adreno_gpu_driver_unified/system/vendor/lib64/` 中刪除以下檔案：

```
libOpenCL.so
libOpenCL_adreno.so
libCB.so
libkcl.so
libkernelmanager.so
libllvm-qcom.so
libgpudataproducer.so
```

**方式 B — 快速修復相機**（WebUI → 工具 → 修復相機）：

移除更廣泛的 OpenCL 和計算函式庫集合：

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

> **關於 `libVkLayer_ADRENO_qprofiler.so`：** 這是 Adreno Vulkan 分析器層。在部分 OEM ROM（尤其是 MIUI/HyperOS、ColorOS 等）上，該函式庫會被相機 HAL 載入，在使用自訂驅動時導致相機故障。快速修復相機會將其移除以解決這類問題。

兩種方式都可以解決受影響裝置上的儲存空間損毀問題。方式 A 更保守。方式 B 移除更多函式庫，是推薦的一鍵解決方案。兩種方式之後均需重新啟動。

> ⚠️ **免責聲明：** 此方法僅適用於 Android 16 QPR2 及以上版本中**極少數特定裝置**，**不是**通用修復方法。除非已確認你的特定裝置存在此問題，否則不要期望移除這些函式庫能解決儲存空間損毀。

### Vendor GPU 檔案 — 儲存空間損毀預防

某些裝置在刷入自訂驅動之前，可能需要將自己裝置的原廠 vendor 分區中的 `vendor/gpu/` 檔案複製到驅動刷入資料夾中。跳過此步驟可能在受影響的裝置上導致儲存空間損毀。

> ⚠️ **裝置特定：** 並非所有裝置都需要此操作。只有在刷入後遇到儲存空間損毀，或已知你的裝置需要此操作時才執行。從裝置的原廠 vendor 映像中提取 `vendor/gpu/` 目錄，並在刷入前將其放入驅動刷入資料夾。

<a name="fix-screen-recorder"></a>
## 28. 螢幕錄製損壞

螢幕錄製無法啟動、錄製顯示黑屏、截圖損壞、安裝模組後出現「編碼失敗」錯誤。

WebUI → 工具標籤 → **修復螢幕錄製** → 重新啟動。

移除的內容：`libC2D2.so`、`libc2d30_bltlib.so`、`libc2dcolorconvert.so`

<a name="fix-night-mode"></a>
## 29. 夜間模式問題

安裝模組後夜間模式/護眼模式/閱讀模式停止工作。

WebUI → 工具標籤 → **修復夜間模式** → 重新啟動。

移除的內容：`libsnapdragon_color_manager.so`

<a name="fix-performance"></a>
## 30. 效能問題

- 檢查 `RENDER_MODE`——嘗試 `normal`
- 清除 GPU 快取（WebUI → 工具 → 清除 GPU 快取）
- 嘗試更舊或更新的驅動版本
- 檢查 GPU 溫度：`adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`

<a name="fix-graphics-glitches"></a>
## 31. 圖形異常

- 如果使用 `skiavk` 或 `skiavk_all`：切換到 `skiagl` 或 `normal`
- 清除 GPU 快取
- 嘗試不同的驅動版本

<a name="fix-module-not-loading"></a>
## 32. 模組未載入

**KernelSU：** 先安裝 MetaMagicMount。檢查 `skip_mount` 檔案是否存在。
**Magisk：** 確保 Magic Mount 已啟用，無 `disable` 標記。
**APatch：** 驗證版本（0.10.8+ 才有內建 Magic Mount）。

---

# 第五部分：Recovery 模式安裝

<a name="recovery-mode-guide"></a>
## 33. Recovery 模式完整指南

Recovery 模式安裝將驅動檔案**直接複製到 vendor 分區**。更改是**永久的且不易撤銷的**。

<a name="recovery-risks"></a>
## 34. 瞭解風險

| 風險 | 模組模式 | Recovery 模式 |
|-----|---------|--------------|
| 可撤銷 | ✅ 立即 | ❌ 需要恢復 vendor |
| 存活 OTA | ✅ 大部分 | ❌ OTA 會抹去 |
| WebUI 可用 | ✅ 是 | ❌ 否 |
| EROFS vendor | ✅ 可用 | ❌ 不可能 |

<a name="recovery-backups"></a>
## 35. 必須備份的內容

```bash
# 透過 TWRP
TWRP → 備份 → 選擇「Vendor」→ 滑動備份

# 透過 ADB
adb shell su -c "dd if=/dev/block/by-name/vendor of=/sdcard/vendor_backup.img"
```

<a name="recovery-installation-steps"></a>
## 36. Recovery 安裝步驟

1. **刷入前編輯設定** — 在 PC 上解壓 ZIP，開啟 `adreno_config.txt`，設定所需值，儲存（UTF-8，無 BOM），重新打包 ZIP
2. **進入自訂 Recovery**（電源鍵 + 音量上鍵）
3. **安裝 ZIP** — 不需要 Advanced Wipe；直接刷入 ZIP
4. 重新啟動
5. **卸載方式**：恢復 vendor 備份，或髒刷 ROM

---

# 第六部分：WebUI 管理器指南

<a name="webui-home"></a>
## 37. 主頁標籤

**系統資訊面板** — 顯示裝置型號、Android 版本、核心、CPU/GPU 識別碼，以及模組已掛載的目前活動 Adreno 驅動版本。

**算繪狀態面板** — 顯示三個算繪器屬性的即時值。

---

<a name="webui-config"></a>
## 38. 設定標籤

### 算繪模式

| 模式 | 作用 |
|-----|------|
| **Normal** | 無算繪器覆蓋。模組僅替換驅動二進位。最安全的備選。 |
| **skiavk** | 設定 HWUI 為 Skia+Vulkan。使用自訂驅動時 GPU 效能最佳。 |
| **skiagl** | 設定 HWUI 為 Skia+OpenGL。如果 Vulkan 在你的裝置上有問題時使用。 |
| **skiavk_all** | 與 skiavk 相同，但還會強制停止所有第三方後台應用程式。 |

### 套用變更

**立即套用** — 透過 `resetprop` 立即注入屬性而不重新啟動。

**儲存並重新啟動** — 將屬性寫入模組持久性 `system.prop` 並重新啟動。

> **提示：** 先用*立即套用*測試模式，確認無誤後再用*儲存並重新啟動*使其永久生效。

---

<a name="webui-utils"></a>
## 39. 工具標籤

### GPU 欺騙器

讓 GPU 驅動向應用程式和遊戲回報不同的 Adreno 型號編號。

### 修復相機

移除已知會損壞相機的特定 OpenCL 和計算函式庫：`libCB.so`、`libgpudataproducer.so`、`libkcl.so`、`libkernelmanager.so`、`libllvm-qcom.so`、`libOpenCL.so`、`libOpenCL_adreno.so`、`libVkLayer_ADRENO_qprofiler.so`。

`libVkLayer_ADRENO_qprofiler.so` 是 Adreno Vulkan 分析器層——在部分 OEM ROM 上，該函式庫會被相機 HAL 載入，在使用自訂驅動時導致相機故障。

### 修復螢幕錄製

移除可能損壞系統螢幕錄製的 C2D 函式庫。

### 修復夜間模式

移除可能阻止夜間模式工作的 `libsnapdragon_color_manager.so`。

### 清除 GPU 快取

刪除系統 HWUI 著色器快取和每應用程式 Skia 管線快取。

---

<a name="webui-data"></a>
## 40. 資料標籤

### 統計

- **設定數** — 儲存設定變更的次數
- **修復數** — 套用修復工具的次數
- **欺騙數** — 套用 GPU 欺騙的次數

### 啟動日誌

列出來自 `/sdcard/Adreno_Driver/Booted/` 和 `/Bootloop/` 的日誌檔案。

---

<a name="webui-custom-tools"></a>
## 41. 自訂驅動工具（進階）

### 自訂 GPU 欺騙

在**你提供的任何 `libgsl.so` 檔案**中欺騙型號 ID。

> ⚠️ **絕不要直接指向 `/vendor/` 或 `/system/`。** 始終先將驅動檔案複製到 `/sdcard/`，然後在那裡進行欺騙。

---

<a name="webui-language-theme"></a>
## 42. 語言與主題

UI 支援英語、簡體中文和繁體中文作為內建選項。你還可以透過語言選擇器將整個介面自動翻譯成任何其他語言（僅適用於自訂語言，中文版本已內建，無需翻譯）。

主題選擇器（🎨）可讓你變更 UI 強調色。

---

<a name="webui-terminal"></a>
## 43. 終端日誌

在每個標籤上可見的可捲動終端面板，即時輸出所有操作。顏色編碼：綠色 = 成功，黃色 = 警告，紅色 = 錯誤，白色 = 資訊。

---

# 第七部分：附錄

<a name="faq"></a>
## 44. 常見問題解答（FAQ）

**Q：這會在我的裝置上工作嗎？**

模組在滿足以下條件的任何 Android 裝置上工作：高通 Adreno GPU、Android 11+、ARM64 架構，以及透過 Magisk/KernelSU/APatch 的 Root。搭載 Exynos、聯發科或其他非 Adreno GPU 的裝置**不支援**。

---

**Q：如何知道我的裝置有哪個 GPU 型號？**

```bash
adb shell cat /sys/class/kgsl/kgsl-3d0/gpu_model
```

---

**Q：RENDER_MODE 有什麼用？應該選哪個？**

- **normal** — 最大相容性，大多數使用者推薦。
- **skiavk** — 想要 Vulkan 加速 UI 算繪可以嘗試。低風險。
- **skiagl** — 僅在預設模式有算繪問題時使用。
- **skiavk_all** — 實驗性。

---

**Q：社群智慧 — 有經驗的使用者推薦什麼？**

1. 保守開始：模組模式，預設設定，推薦驅動版本
2. 每次只更改一項
3. 保持詳細記錄
4. 知道什麼時候放棄
5. 在 XDA 或 Telegram 上分享你的發現

<a name="glossary"></a>
## 45. 術語表

| 術語 | 定義 |
|-----|------|
| **Adreno** | 高通 GPU 產品線品牌名稱 |
| **GPU 驅動** | 控制 GPU 處理圖形命令的軟體 |
| **HWUI** | 硬體 UI — Android 的硬體加速使用者介面算繪系統 |
| **SurfaceFlinger** | Android 的顯示合成器 |
| **SELinux** | 安全增強 Linux — Android 的強制存取控制系統 |
| **Magic Mount** | Magisk 將檔案疊加到檔案系統而不修改分區的系統 |
| **Metamodule** | 提供 KernelSU 原生缺乏的檔案掛載能力的輔助模組 |
| **PLT** | 公共函式庫文字 — 列出應用程式允許載入的函式庫的檔案 |
| **QGL** | 高通圖形函式庫 — 用於 GPU 設定調優的高通內部系統 |
| **Vulkan** | 低開銷、顯式 3D 圖形 API |
| **Skia** | Android 的 2D 圖形函式庫 |
| **skiavk** | 使用 Vulkan 後端的 Skia 算繪 |
| **skiagl** | 使用 OpenGL ES 後端的 Skia 算繪 |
| **著色器快取** | 應用程式儲存的預編譯 GPU 程式 |
| **KGSL** | 核心圖形支援層 — Adreno GPU 的 Linux 核心驅動 |
| **EROFS** | 延伸唯讀檔案系統 |
| **卡機** | 裝置在完全啟動前持續重啟的狀態 |
| **resetprop** | Magisk 用於在執行時修改唯讀系統屬性的工具 |

<a name="credits"></a>
## 46. 致謝

- **模組開發者：** @pica_pica_picachu
- **聯絡方式：** Telegram @zesty_pic
- **文件：** 在 Claude AI 輔助下生成和維護

<a name="license"></a>
## 47. 授權與免責聲明

**風險自擔。**

- 本模組修改關鍵系統 GPU 驅動檔案
- 不提供任何明示或暗示的保證
- 開發者對裝置變磚、資料遺失、功能損壞或任何其他損害不負責任
- 安裝前務必備份
- 包含的驅動檔案是高通技術公司的財產

*文件可能包含不準確之處。請獨立驗證關鍵資訊。*

---

*文件結束*
