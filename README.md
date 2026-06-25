# Google ML Kit Text Recognition - arm64 iOS Simulator Patch

## Background

Google ML Kit's iOS SDK (MLKitTextRecognition, etc.) distributed via CocoaPods explicitly excludes the arm64 simulator architecture:

```ruby
pod_target_xcconfig: {
  "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "arm64"
}
```

When running iOS Simulator from Xcode on Apple Silicon Macs (M1/M2/M3/M4), these libraries cannot be linked. The original binaries only support arm64 device and x86_64 simulator (Intel Mac), lacking arm64 simulator support.

## Overview

This solution patches Mach-O binary files by modifying the `LC_BUILD_VERSION` load command, changing the platform identifier from iOS to iOS Simulator. This makes the Xcode linker and runtime recognize these libraries as simulator-compatible.

The final output is an xcframework containing three target platforms:
- **ios-arm64** (device)
- **ios-arm64-simulator** (Apple Silicon simulator, patched)
- **ios-x86_64-simulator** (Intel simulator, original)

## Technical Details

### 1. Mach-O Platform Identifier

Every Mach-O binary contains an `LC_BUILD_VERSION` load command with a `platform` field that determines the execution environment:

| Value | Constant | Meaning |
|-------|----------|---------|
| 1 | PLATFORM_MACOS | macOS |
| 2 | PLATFORM_IOS | iOS device |
| 7 | PLATFORM_IOSSIMULATOR | iOS Simulator |

The Xcode linker checks the `platform` field of all input binaries during build. If a device library (platform=2) is used in a simulator build (requiring platform=7), the linker rejects it.

### 2. Binary Format Variants

MLKit framework binaries come in several formats:

| Format | Description | Handling |
|--------|-------------|----------|
| Fat binary (universal) | Contains multiple architecture slices (e.g. x86_64 + arm64) | Extract each arch with `lipo -thin`, process separately |
| ar archive | Static library archive containing multiple .o object files | Unpack, patch each .o individually, repack |
| Pure Mach-O | Single-architecture dynamic library or object file | Patch directly with vtool |

### 3. ar archive Special Handling

Most MLKit frameworks (MLKitCommon, MLKitVision, MLKitTextRecognition) use the ar archive format (static libraries). These archives contain hundreds of .o object files internally.

Processing workflow:
1. Extract arm64 slice from fat binary using `lipo -thin arm64`
2. Extract object files one by one using `ar p`, assigning unique sequential names (e.g. `obj_00000.o`) to avoid overwrites
3. Patch each .o file's platform tag using vtool
4. Repack into a static library using `libtool -static`

**Important notes:**
- ar archives contain duplicate-named object files (e.g. `globals.o`). Using `ar x` would overwrite them, causing symbol loss. Extract with unique sequential names instead.
- Some archives include a `__.SYMDEF` symbol table file. Remove it during repacking to avoid archive format corruption.
- Use `libtool -static` instead of `ar rcs` for repacking for better compatibility.

### 4. Missing LC_BUILD_VERSION

MLKitTextRecognitionCommon binaries lack `LC_BUILD_VERSION` or `LC_VERSION_MIN_IPHONEOS` load commands. Platform information must be added with vtool first, otherwise `xcodebuild -create-xcframework` cannot identify the target platform.

### 5. Missing Symbol Handling

The prebuilt MLKitCommon xcframework references symbols defined in other libraries:
- `GULOSLogBasic` / `GULOSLogError` — logging functions from GoogleUtilities
- `MLKITx_absl::*` — abseil-cpp C++ symbols in a custom `MLKITx` namespace

These symbols are resolved by the linker from the GoogleMLKit umbrella pod, but when using xcframeworks standalone, stub implementations are required. See `ocrexample/AbseilStubs.mm` for the stub implementations.

## Build Flow

```
Original fat binary (x86_64 + arm64)
        |
        |-- lipo -thin arm64 --> arm64 slice --> vtool patch (platform -> IOSSIMULATOR)
        |                         |
        |                         |-- ar archive? -> ar p extract (unique naming) -> vtool patch each .o -> libtool repack
        |                         |-- Mach-O? -> direct vtool patch
        |
        |-- lipo -thin x86_64 --> x86_64 slice (unchanged)
        |
        +-- Original arm64 slice --> used for device (keep platform = IOS)
        
        v
xcodebuild -create-xcframework (merge device + simulator slices)
        v
Final .xcframework (supports arm64 device + arm64/x86_64 simulator)
```

## Dependencies

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

### Source Dependencies (via CocoaPods)

The prebuilt xcframeworks (MLKitCommon, MLKitVision, etc.) depend on the following source pods, which compile natively for simulator architectures:

| Pod | Version | Purpose |
|-----|---------|---------|
| GTMSessionFetcher/Core | ~> 1.1 | HTTP requests |
| GoogleDataTransport | ~> 7.0 | Data transport |
| GoogleToolboxForMac/Logger | ~> 2.1 | Logging |
| GoogleToolboxForMac/NSData+zlib | ~> 2.1 | Compression |
| GoogleToolboxForMac/NSDictionary+URLArguments | ~> 2.1 | URL arguments |
| GoogleUtilities/UserDefaults | ~> 6.0 | UserDefaults |
| GoogleUtilitiesComponents | ~> 1.0 | Dependency injection |
| Protobuf | ~> 3.12 | Protocol Buffers |

## Usage

### Option 1: Private Spec Repo Integration (GitHub Hosted - Recommended)

This is the most elegant way to integrate. You upload the built binary `.zip` files to GitHub Releases, and use a lightweight private Specs repository to host the podspecs. It keeps your host project's `Podfile` completely clean and **eliminates the need** to modify the `podspec` of any custom React Native modules for simulator debugging.

#### Setup Steps:
1. **Generate Release Files**: Run `./build_local_pods.sh`. This automatically generates two directories:
   - `Releases/`: Contains all packaged `.xcframework.zip` binary archives.
   - `Specs/`: Contains the CocoaPods-compliant custom Specs directory structure, which automatically points to your configured GitHub Releases link.
2. **Publish Binaries**: Create a Release (e.g. `v1.0.0`) in your GitHub binary hosting repository and upload all the `.xcframework.zip` files from the `Releases/` directory.
3. **Push Specs Repo**: Create a lightweight Specs repository on GitHub (e.g. `raz-cocoapods-specs`), initialize the local `Specs/` directory as a Git repo, and push it.
4. **Host App `Podfile` Integration**:
   Add your private source at the top of your host project's `Podfile`, then declare dependencies as usual:
   ```ruby
   source 'https://github.com/iwater/raz-cocoapods-specs.git' # Your private specs repo URL
   source 'https://cdn.cocoapods.org/' # Official source as fallback

   target 'YourApp' do
     # Include your React Native module or MLKit directly.
     # CocoaPods will automatically pull the patched, simulator-compatible package from your private specs source.
     pod 'react-native-nitro-text-recognition', :path => '../modules/react-native-nitro-text-recognition'
   end
   ```

*(Note: Even when using the private Spec Repo approach, CocoaPods still has a limitation regarding header search paths for static binaries. You MUST still include the `post_install` hook shown in "Option 2" below to patch the Framework search paths.)*

### Option 2: Local LocalPods Integration

1. Copy the `LocalPods/` directory to your project root
2. Copy the Podfile to your project root, change `target 'YourApp'` to your actual target name
3. Run `pod install`

```ruby
require 'fileutils'

platform :ios, '15.5'

target 'YourApp' do
  pod 'GTMSessionFetcher/Core', '~> 1.1'
  pod 'GoogleDataTransport', '~> 7.0'
  pod 'GoogleToolboxForMac/Logger', '~> 2.1'
  pod 'GoogleToolboxForMac/NSData+zlib', '~> 2.1'
  pod 'GoogleToolboxForMac/NSDictionary+URLArguments', '~> 2.1'
  pod 'GoogleUtilities/UserDefaults', '~> 6.0'
  pod 'GoogleUtilitiesComponents', '~> 1.0'
  pod 'Protobuf', '~> 3.12'

  pod 'MLKitCommon',                :path => './LocalPods/MLKitCommon'
  pod 'MLImage',                    :path => './LocalPods/MLImage'
  pod 'MLKitVision',                :path => './LocalPods/MLKitVision'
  pod 'MLKitTextRecognitionCommon', :path => './LocalPods/MLKitTextRecognitionCommon'
  pod 'MLKitTextRecognition',       :path => './LocalPods/MLKitTextRecognition'
  # Include local pods for multi-language OCR if needed
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

      if target.name == 'GoogleDataTransport'
        other_cflags = config.build_settings['OTHER_CFLAGS'] || '$(inherited)'
        unless other_cflags.include?('-Wno-strict-prototypes')
          config.build_settings['OTHER_CFLAGS'] = "#{other_cflags} -Wno-strict-prototypes"
        end
      end
    end
  end

  podfile_dir = File.dirname(installer.podfile.defined_in_file)
  prebuilt_base = "#{podfile_dir}/Pods-Prebuilt"
  FileUtils.rm_rf(prebuilt_base)

  # Support local cache extraction for all language packs
  xcframeworks = %w[MLKitCommon MLImage MLKitVision MLKitTextRecognitionCommon MLKitTextRecognition MLKitTextRecognitionChinese MLKitTextRecognitionDevanagari MLKitTextRecognitionJapanese MLKitTextRecognitionKorean]

  xcframeworks.each do |fw_name|
    xcframework_path = "#{podfile_dir}/LocalPods/#{fw_name}.xcframework"
    next unless File.exist?(xcframework_path)
    sim_slice = Dir.glob("#{xcframework_path}/ios-*simulator*").first
    next unless sim_slice
    framework_in_slice = Dir.glob("#{sim_slice}/#{fw_name}.framework").first
    next unless framework_in_slice
    target_dir = "#{prebuilt_base}/#{fw_name}"
    FileUtils.mkdir_p(target_dir)
    FileUtils.cp_r(framework_in_slice, "#{target_dir}/#{fw_name}.framework")
  end

  xcconfigs_to_patch = Dir.glob("#{installer.sandbox.root}/Target Support Files/Pods-#{File.basename(installer.podfile.defined_in_file, '.*')}/#{File.basename(installer.podfile.defined_in_file, '.*')}.*.xcconfig")

  xcconfigs_to_patch.each do |xcconfig_path|
    lines = File.readlines(xcconfig_path)
    ldflags_parts = []
    fw_search_parts = []
    swift_search_parts = []
    lines.each do |line|
      if line.start_with?("OTHER_LDFLAGS")
        ldflags_parts << line.split("=", 2).last.strip
      elsif line.start_with?("FRAMEWORK_SEARCH_PATHS")
        fw_search_parts << line.split("=", 2).last.strip
      elsif line.start_with?("SWIFT_INCLUDE_PATHS")
        swift_search_parts << line.split("=", 2).last.strip
      end
    end
    xcframeworks.each do |fw_name|
      prebuilt_dir = "#{prebuilt_base}/#{fw_name}"
      next unless File.exist?("#{prebuilt_dir}/#{fw_name}.framework")
      ldflags_parts << "-framework #{fw_name} -F\"#{prebuilt_dir}\""
      fw_search_parts << "\"#{prebuilt_dir}\""
      swift_search_parts << "\"#{prebuilt_dir}\""
    end
    new_lines = lines.reject { |l| l.start_with?("OTHER_LDFLAGS", "FRAMEWORK_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS") }
    new_lines << "OTHER_LDFLAGS = #{ldflags_parts.join(" ")}\n" if ldflags_parts.any?
    new_lines << "FRAMEWORK_SEARCH_PATHS = #{fw_search_parts.join(" ")}\n" if fw_search_parts.any?
    new_lines << "SWIFT_INCLUDE_PATHS = #{swift_search_parts.join(" ")}\n" if swift_search_parts.any?
    File.write(xcconfig_path, new_lines.join)
  end
end
```

**Notes:**
- GoogleDataTransport fails to compile on Xcode 15+ due to `-Werror,-Wstrict-prototypes`. Add `-Wno-strict-prototypes` in `post_install` to fix this.
- Add `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` to your project's Info.plist if using camera/photo library.

### Option 3: Manual Integration

Drag the following 9 `.xcframework` files directly into your Xcode project:

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

Ensure `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` is NOT set in Build Settings.

**Manual integration requires additional steps:**
- Add all source dependencies via SPM or manually (GoogleUtilities, GTMSessionFetcher, etc.)
- Provide stub implementations for `GULOSLogBasic`, `GULOSLogError`, and `MLKITx_absl::*` symbols
- Package `Resources/*OCRResources/` directories from each language pack as corresponding `.bundle` files and add them to the app bundle.

## Rebuilding

To rebuild (e.g. when updating versions), run:

```bash
./build_local_pods.sh
```

The script automatically downloads the specified framework versions, patches platform identifiers, generates xcframeworks and podspecs.

To change versions: edit the download URLs and version numbers in `build_local_pods.sh`.

## Known Limitations

1. **arm64 Simulator Performance**: Patched binaries may have degraded features on simulator due to missing hardware acceleration (e.g. Neural Engine), but core OCR functionality works correctly.
2. **__.SYMDEF Symbol Table**: The original Google MLKit ar archives may contain `__.SYMDEF` entries referencing symbols from other archives (from merged builds). These symbols are lost after repacking and must be supplemented via stubs.
3. **EXCLUDED_ARCHS**: The `EXCLUDED_ARCHS` setting must still be removed in `post_install`, otherwise CocoaPods will block compilation.
4. **CocoaPods xcframework Integration**: CocoaPods generates aggregate targets for vendored xcframeworks without copying framework content to build products, causing Swift module resolution failures. The `post_install` hook in the Podfile resolves this by extracting simulator slices to `Pods-Prebuilt/` and adding `FRAMEWORK_SEARCH_PATHS`/`SWIFT_INCLUDE_PATHS`.

## Attribution & License

This project contains prebuilt binaries and model files from **Google ML Kit**, which are subject to the following copyright and license terms:

- **Google ML Kit Text Recognition** — Copyright 2025 Google LLC
- **Google ML Kit Common** — Copyright 2025 Google LLC
- **Google ML Kit Vision** — Copyright 2025 Google LLC
- **Google ML Kit Text Recognition Common** — Copyright 2025 Google LLC
- **MLImage** — Copyright 2025 Google LLC

The prebuilt xcframework binaries, OCR model files (`LatinOCRResources/`), and associated resources are distributed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).

This project applies platform patches (LC_BUILD_VERSION modification) to enable arm64 simulator support. These patches do not alter the functionality of the original libraries and are not considered derivative works under the Apache License.

### Third-Party Dependencies

The following open-source libraries are used as transitive dependencies (via CocoaPods source pods):

| Library | License |
|---------|---------|
| Abseil (C++) | Apache License 2.0 |
| GoogleUtilities | Apache License 2.0 |
| GTMSessionFetcher | Apache License 2.0 |
| GoogleDataTransport | Apache License 2.0 |
| GoogleToolboxForMac | Apache License 2.0 |
| Protobuf (Protocol Buffers) | BSD 3-Clause |
| PromisesObjC | Apache License 2.0 |
| nanopb | BSD 3-Clause |

Full license texts are available in the `NOTICES` files included with each pod under `LocalPods/`.

## File Structure

```
+-- build_local_pods.sh              # Build script
+-- LocalPods/                       # Build artifacts
|   +-- Podfile                      # CocoaPods config template
|   +-- MLKitCommon/
|   |   +-- MLKitCommon.podspec      # With dependency declarations
|   |   +-- Frameworks/MLKitCommon.framework/
|   +-- MLKitCommon.xcframework/
|   +-- MLImage/
|   +-- MLImage.xcframework/
|   +-- MLKitVision/
|   +-- MLKitVision.xcframework/
|   +-- MLKitTextRecognitionCommon/
|   +-- MLKitTextRecognitionCommon.xcframework/
|   +-- MLKitTextRecognition/
|   |   +-- MLKitTextRecognition.podspec  # With resource_bundles config
|   |   +-- Resources/LatinOCRResources/  # OCR model files
|   +-- MLKitTextRecognition.xcframework/
+-- example/                         # Test project
|   +-- ocrexample/                  # iOS sample app
|   |   +-- ocrexample/
|   |   |   +-- ContentView.swift   # OCR test interface
|   |   |   +-- AbseilStubs.mm      # MLKITx_absl symbol stubs
|   |   |   +-- ocrexampleApp.swift
|   |   +-- ocrexample.xcodeproj/
+-- NOTICES
```
