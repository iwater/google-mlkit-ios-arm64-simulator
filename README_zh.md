# Google ML Kit Text Recognition - arm64 iOS 模拟器适配方案

## 背景

Google ML Kit 的 iOS SDK（MLKitTextRecognition 等）通过 CocoaPods 分发时，明确排除了 arm64 模拟器架构：

```ruby
pod_target_xcconfig: {
  "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "arm64"
}
```

在 Apple Silicon Mac（M1/M2/M3/M4）上使用 Xcode 运行 iOS 模拟器时，无法链接这些库。原始二进制仅支持 arm64 真机和 x86_64 模拟器（Intel Mac），缺少 arm64 模拟器支持。

## 方案概述

通过修改 Mach-O 二进制文件的 LC_BUILD_VERSION 加载命令，将平台标识从 iOS 改为 iOS Simulator，使 Xcode 链接器和运行时将这些库识别为模拟器兼容版本。

最终产物为 xcframework，同时包含三个目标平台：
- ios-arm64（真机）
- ios-arm64-simulator（Apple Silicon 模拟器，已 patch）
- ios-x86_64-simulator（Intel 模拟器，原始版本）

## 技术细节

### 1. Mach-O 平台标识

每个 Mach-O 二进制文件都包含一个 LC_BUILD_VERSION 加载命令，其中 platform 字段决定了该二进制可以在哪种环境运行：

| 平台值 | 常量名 | 含义 |
|--------|--------|------|
| 1 | PLATFORM_MACOS | macOS |
| 2 | PLATFORM_IOS | iOS 真机 |
| 7 | PLATFORM_IOSSIMULATOR | iOS 模拟器 |

Xcode 链接器在构建时会检查所有输入二进制的 platform 字段。如果真机库（platform=2）被用于模拟器构建（需要 platform=7），链接器会拒绝该库。

### 2. 二进制格式差异

MLKit 的 framework 二进制存在两种格式：

| 格式 | 说明 | 处理方式 |
|------|------|----------|
| Fat binary (universal) | 包含多个架构切片（如 x86_64 + arm64） | 用 lipo -thin 提取各架构，分别处理 |
| ar archive | 静态库归档，包含多个 .o object files | 需要解包、逐个 patch .o 文件、重新打包 |
| 纯 Mach-O | 单架构的动态库或 object file | 直接用 vtool 修改 |

### 3. ar archive 的特殊处理

MLKit 的大部分 framework（MLKitCommon、MLKitVision、MLKitTextRecognition）使用 ar archive 格式（静态库）。这些归档文件内部包含数百个 .o object files。

处理流程：
1. 用 lipo -thin arm64 从 fat binary 中提取 arm64 切片
2. 用 ar p 逐个提取归档中的 object files，每个文件用唯一序号命名（如 obj_00000.o）以避免同名覆盖
3. 用 vtool 修改每个 .o 文件的 platform tag
4. 用 libtool -static 重新打包为静态库

**注意事项：**
- ar archive 中存在同名 object files（如 globals.o），ar x 会覆盖导致符号丢失，需用唯一序号命名提取
- 部分归档包含 __.SYMDEF 符号表文件，重新打包时应移除，否则会导致归档格式损坏
- 使用 libtool -static 而非 ar rcs 重新打包，兼容性更好

### 4. 缺少 LC_BUILD_VERSION 的情况

MLKitTextRecognitionCommon 的二进制文件不包含 LC_BUILD_VERSION 或 LC_VERSION_MIN_IPHONEOS 加载命令。此时需要先用 vtool 添加平台信息，否则 xcodebuild -create-xcframework 无法识别目标平台。

### 5. 缺少符号处理

预构建的 MLKitCommon xcframework 内部引用了一些在其他库中定义的符号：
- `GULOSLogBasic` / `GULOSLogError`：来自 GoogleUtilities 的日志函数
- `MLKITx_absl::*`：abseil-cpp 的 C++ 符号（带 MLKITx 前缀的命名空间）

为了优雅解决此问题（无需开发者在宿主工程中手动添加符号桩），构建工具自动生成了一个独立的纯源码 Pod 库 `MLKitAbseilStubs`。该 Pod 包含了 `AbseilStubs.mm` 源码并在 Apple Silicon 模拟器架构（`TARGET_OS_SIMULATOR && defined(__arm64__)`）下编译。`MLKitCommon` 对其声明了强依赖，使得 CocoaPods 会在 Xcode 构建时全自动将其引入并链接。

## 处理流程

```
原始 fat binary (x86_64 + arm64)
        |
        |-- lipo -thin arm64 --> arm64 slice --> vtool patch (platform -> IOSSIMULATOR)
        |                         |
        |                         |-- ar archive? -> ar p 逐个提取(唯一命名) -> vtool patch 每个 .o -> libtool 重新打包
        |                         |-- Mach-O? -> 直接 vtool patch
        |
        |-- lipo -thin x86_64 --> x86_64 slice（无需修改，保持原样）
        |
        +-- 原始 arm64 slice --> 用于真机（保持 platform = IOS）
        
        v
xcodebuild -create-xcframework（合并真机 + 模拟器切片）
        v
最终 .xcframework（支持 arm64 真机 + arm64/x86_64 模拟器）
```

## 依赖关系

```
MLKitTextRecognition (7.0.0)
+-- MLKitTextRecognitionCommon (6.0.0)
|   +-- MLKitCommon (14.0.0)
|   +-- MLKitVision (10.0.0)
+-- MLKitCommon (14.0.0)
+-- MLKitVision (10.0.0)
    +-- MLKitCommon (14.0.0)
    +-- MLImage (1.0.0-beta8)
```

## 使用方式

### 方式一：私有 Spec Repo 集成（GitHub 托管，最推荐）

这种方式最优雅。您可以把编译好的二进制 `.zip` 压缩包上传到 GitHub Releases，然后使用一个极轻量的私有 Specs 仓库托管 podspecs。它能让宿主项目的 `Podfile` 保持绝对干净，并且**完全不需要**为了模拟器调试而改动您任何自定义 React Native 模块的 `podspec`。

#### 集成步骤：
1. **生成发布文件**：运行 `./build_local_pods.sh`。这会在本地自动生成两个目录：
   - `Releases/`：包含了所有打包好的 `.xcframework.zip` 二进制压缩包。
   - `Specs/`：包含了符合 CocoaPods 规格的自定义 Specs 目录结构，其内部自动指向了您配置的 GitHub Releases 链接。
2. **发布二进制**：在您的 GitHub 二进制托管仓库中创建一个 Release（如 `v1.0.0`），把 `Releases/` 下所有的 `.xcframework.zip` 文件直接拖进去上传。
3. **推送 Spec 仓库**：在 GitHub 上建一个轻量的 Specs 仓库（如 `google-mlkit-ios-arm64-simulator-specs`），将本地 `Specs/` 目录下的内容初始化为 Git 仓库并推送到远程。
4. **宿主 App `Podfile` 引入**：
   在宿主项目的 `Podfile` 顶部引入您的私有源，然后像普通 Pod 依赖一样声明即可：
   ```ruby
   source 'https://github.com/iwater/google-mlkit-ios-arm64-simulator-specs.git' # 您的私有 specs 仓库
   source 'https://cdn.cocoapods.org/' # 官方源作为兜底

   target 'YourApp' do
     # 引入您的 React Native 模块，或者直接引入 MLKit。
     # CocoaPods 将由于优先级，自动从您的私有 Specs 源拉取 Patch 后的无排挤限制的包。
     pod 'react-native-nitro-text-recognition', :path => '../modules/react-native-nitro-text-recognition'
   end
   ```

### 方式二：本地 LocalPods 集成

1. 将 `LocalPods/` 目录复制到项目根目录
2. 将 Podfile 复制到项目根目录，修改 target 'YourApp' 为你的实际 target 名称
3. 运行 `pod install`

```ruby
platform :ios, '15.5'

target 'YourApp' do
  use_frameworks! :linkage => :static

  pod 'MLKitAbseilStubs',           :path => './LocalPods/MLKitAbseilStubs'
  pod 'MLKitCommon',                :path => './LocalPods/MLKitCommon'
  pod 'MLImage',                    :path => './LocalPods/MLImage'
  pod 'MLKitVision',                :path => './LocalPods/MLKitVision'
  pod 'MLKitTextRecognitionCommon', :path => './LocalPods/MLKitTextRecognitionCommon'
  pod 'MLKitTextRecognition',       :path => './LocalPods/MLKitTextRecognition'
  # 如果需要多语言 OCR，一并引入本地包
  pod 'MLKitTextRecognitionChinese',    :path => './LocalPods/MLKitTextRecognitionChinese'
  pod 'MLKitTextRecognitionDevanagari', :path => './LocalPods/MLKitTextRecognitionDevanagari'
  pod 'MLKitTextRecognitionJapanese',   :path => './LocalPods/MLKitTextRecognitionJapanese'
  pod 'MLKitTextRecognitionKorean',     :path => './LocalPods/MLKitTextRecognitionKorean'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.5'
      config.build_settings.delete 'EXCLUDED_ARCHS[sdk=iphonesimulator*]'
    end
  end
end
```

### 方式三：手动集成

将以下 9 个 `.xcframework` 直接拖入 Xcode 项目：

```
LocalPods/MLKitCommon.xcframework
LocalPods/MLImage.xcframework
LocalPods/MLKitVision.xcframework
LocalPods/MLKitTextRecognitionCommon.xcframework
LocalPods/MLKitTextRecognition.xcframework
LocalPods/MLKitTextRecognitionChinese.xcframework
LocalPods/MLKitTextRecognitionDevanagari.xcframework
LocalPods/MLKitTextRecognitionJapanese.xcframework
LocalPods/MLKitTextRecognitionKorean.xcframework
```

确保 Build Settings 中未设置 `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64`。

**手动集成需要额外处理：**
- 需要通过 SPM 或手动添加所有源码依赖（GoogleUtilities、GTMSessionFetcher 等）
- 需要提供 `GULOSLogBasic`、`GULOSLogError` 和 `MLKITx_absl::*` 的 stub 实现
- 需要将多语言下的 `Resources/*OCRResources/` 目录打包为对应的 `.bundle` 并添加到 app bundle

## 重新构建

如需重新构建（例如更新版本），运行：

```bash
./build_local_pods.sh
```

脚本会自动下载指定版本的 framework、patch 平台标识、生成 xcframework 和 podspec。

修改版本号：编辑 build_local_pods.sh 中的下载 URL 和版本号。

## 已知限制

1. **arm64 模拟器性能**：patch 后的二进制在模拟器上运行时，部分功能可能因缺少真机硬件加速（如 Neural Engine）而降级，但核心 OCR 功能正常工作
2. **__.SYMDEF 符号表**：原始 Google MLKit 的 ar archive 中 __.SYMDEF 可能包含不属于该 archive 的符号（来自合并构建），重新打包后这些符号会丢失，需要通过 stub 补充

## 权利声明与许可证

本项目包含来自 **Google ML Kit** 的预构建二进制文件和模型文件，受以下版权和许可条款约束：

- **Google ML Kit Text Recognition** — Copyright 2025 Google LLC
- **Google ML Kit Common** — Copyright 2025 Google LLC
- **Google ML Kit Vision** — Copyright 2025 Google LLC
- **Google ML Kit Text Recognition Common** — Copyright 2025 Google LLC
- **MLImage** — Copyright 2025 Google LLC

预构建的 xcframework 二进制文件、OCR 模型文件（`LatinOCRResources/`）及相关资源均在 [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0) 下分发。

本项目对二进制文件应用了平台补丁（修改 LC_BUILD_VERSION）以支持 arm64 模拟器。这些补丁不改变原始库的功能，根据 Apache 许可证不构成演绎作品。

### 第三方依赖

以下开源库作为传递依赖（通过 CocoaPods 源码 pod）使用：

| 库 | 许可证 |
|----|--------|
| Abseil (C++) | Apache License 2.0 |
| GoogleUtilities | Apache License 2.0 |
| GTMSessionFetcher | Apache License 2.0 |
| GoogleDataTransport | Apache License 2.0 |
| GoogleToolboxForMac | Apache License 2.0 |
| Protobuf (Protocol Buffers) | BSD 3-Clause |
| PromisesObjC | Apache License 2.0 |
| nanopb | BSD 3-Clause |

完整许可证文本可在 `LocalPods/` 下各 pod 的 `NOTICES` 文件中查阅。

## 文件说明

```
+-- build_local_pods.sh          # 构建脚本
+-- LocalPods/                   # 构建产物
|   +-- Podfile                  # CocoaPods 配置模板
|   +-- MLKitCommon/
|   |   +-- MLKitCommon.podspec  # 二进制 podspec，链入 MLKitCommon framework 并依赖 MLKitAbseilStubs
|   |   +-- MLKitCommon.xcframework/ # 含 arm64 模拟器架构的二进制
|   +-- MLKitAbseilStubs/
|   |   +-- MLKitAbseilStubs.podspec # 桩文件源码 podspec
|   |   +-- AbseilStubs.mm           # 桩文件实现源码
|   +-- MLImage/
|   |   +-- MLImage.podspec
|   |   +-- MLImage.xcframework/
|   +-- MLKitVision/
|   |   +-- MLKitVision.podspec
|   |   +-- MLKitVision.xcframework/
|   +-- MLKitTextRecognitionCommon/
|   |   +-- MLKitTextRecognitionCommon.podspec
|   |   +-- MLKitTextRecognitionCommon.xcframework/
|   +-- MLKitTextRecognition/
|   |   +-- MLKitTextRecognition.podspec  # 含 resource_bundles 配置
|   |   +-- Resources/LatinOCRResources/  # OCR 模型文件
|   |   +-- MLKitTextRecognition.xcframework/
+-- example/                     # 测试项目
|   +-- ocrexample/              # iOS 示例 app
|   |   +-- ocrexample/
|   |   |   +-- ContentView.swift       # OCR 测试界面
|   |   |   +-- AbseilStubs.mm          # MLKITx_absl 符号 stub 实现
|   |   |   +-- ocrexampleApp.swift
|   |   +-- ocrexample.xcodeproj/
+-- NOTICES
```
