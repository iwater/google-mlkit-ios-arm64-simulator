#!/bin/bash
# =============================================================================
# Google ML Kit arm64 iOS 模拟器适配构建脚本
# =============================================================================
# 功能：将 MLKit framework 改造为 xcframework，同时支持 arm64 真机 + arm64/x86_64 模拟器
# 原理：修改 Mach-O 的 LC_BUILD_VERSION platform 字段（IOS -> IOSSIMULATOR）
# 兼容：Intel Mac（vtool）和 arm64 Mac（python3 fallback）
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/LocalPods"
SIM_PLATFORM=7   # PLATFORM_IOSSIMULATOR
MIN_IOS="15.5"
DEBUG="${DEBUG:-0}"

GENERATE_SPECS="${GENERATE_SPECS:-1}"
SPECS_DIR="${SPECS_DIR:-${SCRIPT_DIR}/Specs}"
GITHUB_USER="${GITHUB_USER:-iwater}"
GITHUB_REPO="${GITHUB_REPO:-google-mlkit-ios-arm64-simulator}"
GITHUB_TAG="${GITHUB_TAG:-v1.0.0}"

PACK_RELEASES="${PACK_RELEASES:-1}"
RELEASES_DIR="${RELEASES_DIR:-${SCRIPT_DIR}/Releases}"

log()  { echo "[BUILD] $*"; }
err()  { echo "[ERROR] $*" >&2; }
debug_log() { [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

# =============================================================================
# 核心 patch 函数：修改 Mach-O 的 platform 字段
# 策略优先级：vtool -replace → vtool（无-replace）→ python3 直接修改字节码
# =============================================================================
patch_platform() {
  local input="$1" output="$2" platform="$3" arch="$4"
  local tmpout="${output}.tmp"

  # 策略1: vtool -replace
  if timeout 10 vtool -arch "$arch" -set-build-version "$platform" "$MIN_IOS" "$MIN_IOS" \
    -replace -output "$tmpout" "$input" 2>/dev/null; then
    mv "$tmpout" "$output"
    debug_log "    patch_platform: vtool -replace OK"
    return 0
  fi
  rm -f "$tmpout"

  # 策略2: vtool 无 -replace
  if timeout 10 vtool -arch "$arch" -set-build-version "$platform" "$MIN_IOS" "$MIN_IOS" \
    -output "$tmpout" "$input" 2>/dev/null; then
    mv "$tmpout" "$output"
    debug_log "    patch_platform: vtool (no replace) OK"
    return 0
  fi
  rm -f "$tmpout"

  # 策略3: python3 直接修改二进制中的 platform 字段
  # 仅对已有 LC_BUILD_VERSION (cmd=0x32) 的文件有效
  if command -v python3 &>/dev/null; then
    if timeout 30 python3 -c "
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
platform_val = int(sys.argv[2])
magic = struct.unpack_from('<I', data, 0)[0]
if magic == 0xfeedfacf:
    offset = 32
elif magic == 0xfeedface:
    offset = 28
else:
    sys.exit(1)
sizeofcmds = struct.unpack_from('<I', data, 20)[0]
end = offset + sizeofcmds
i = offset
while i < end - 8:
    cmd = struct.unpack_from('<I', data, i)[0]
    cmdsize = struct.unpack_from('<I', data, i + 4)[0]
    if cmdsize < 8 or i + cmdsize > end:
        break
    if cmd == 0x32:
        struct.pack_into('<I', data, i + 8, platform_val)
        open(sys.argv[3], 'wb').write(data)
        sys.exit(0)
    i += cmdsize
sys.exit(1)
" "$input" "$platform" "$output" 2>/dev/null; then
      debug_log "    patch_platform: python3 modify OK"
      return 0
    fi

    # 策略4: python3 插入新的 LC_BUILD_VERSION（处理完全没有此命令的二进制）
    if timeout 30 python3 -c "
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
platform_val = int(sys.argv[2])
magic = struct.unpack_from('<I', data, 0)[0]
if magic == 0xfeedfacf:
    hdr_size = 32
elif magic == 0xfeedface:
    hdr_size = 28
else:
    sys.exit(1)
ncmds = struct.unpack_from('<I', data, 16)[0]
sizeofcmds = struct.unpack_from('<I', data, 20)[0]
cmds_end = hdr_size + sizeofcmds
# LC_BUILD_VERSION: cmd(4) + cmdsize(4) + platform(4) + minos(4) + sdk(4) + ntools(4) = 24 bytes
new_cmd_size = 24
# 检查 load commands 结束处和第一个 segment 之间是否有足够空间
# 找到第一个 segment 的 fileoff 来确定 gap
i = hdr_size
first_seg_offset = len(data)
while i < cmds_end - 8:
    cmd = struct.unpack_from('<I', data, i)[0]
    cmdsize = struct.unpack_from('<I', data, i + 4)[0]
    if cmdsize < 8 or i + cmdsize > cmds_end:
        break
    if cmd in (0x19, 0x1a):  # LC_SEGMENT / LC_SEGMENT_64
        seg_fileoff_off = i + 32 if cmd == 0x1a else i + 28
        seg_fileoff = struct.unpack_from('<Q' if cmd == 0x1a else '<I', data, seg_fileoff_off)[0]
        if seg_fileoff > 0 and seg_fileoff < first_seg_offset:
            first_seg_offset = seg_fileoff
        break
    i += cmdsize
gap = first_seg_offset - cmds_end
if gap < new_cmd_size:
    sys.exit(1)
# 写入新的 LC_BUILD_VERSION
new_cmd = struct.pack('<IIIIII', 0x32, new_cmd_size, platform_val, 0x000f0000, 0x000f0000, 0)
data[cmds_end:cmds_end + new_cmd_size] = new_cmd
# 更新 header: ncmds + 1, sizeofcmds + new_cmd_size
struct.pack_into('<I', data, 16, ncmds + 1)
struct.pack_into('<I', data, 20, sizeofcmds + new_cmd_size)
open(sys.argv[3], 'wb').write(data)
sys.exit(0)
" "$input" "$platform" "$output" 2>/dev/null; then
      debug_log "    patch_platform: python3 INSERT OK"
      return 0
    fi
  fi

  debug_log "    patch_platform: ALL strategies FAILED"
  return 1
}

# =============================================================================
# Patch ar archive：逐个提取 .o -> patch -> 重新打包
# =============================================================================
patch_arm64_archive() {
  local archive="$1" output="$2"
  local work_dir="${archive}.workdir"
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  cd "$work_dir"
  local idx=0
  local members
  members=$(ar t "$archive" | grep -v '^__\.SYMDEF')
  for member in $members; do
    local out_name
    out_name=$(printf "obj_%05d.o" "$idx")
    ar p "$archive" "$member" > "$out_name" 2>/dev/null || true
    idx=$((idx + 1))
  done
  chmod 644 *.o 2>/dev/null || true
  rm -f __.SYMDEF
  cd "$SCRIPT_DIR"

  local patched=0
  local failed=0
  for obj in "${work_dir}"/*.o; do
    [[ -f "$obj" ]] || continue
    local obj_type
    obj_type=$(file -b "$obj" 2>/dev/null || true)
    local is_macho=false
    if echo "$obj_type" | grep -qiE "Mach-O|object"; then
      is_macho=true
    elif xxd -l 4 "$obj" 2>/dev/null | grep -qE "feedface|feedfacf|cafebabe|cffaedfe"; then
      is_macho=true
    fi

    if $is_macho; then
      if patch_platform "$obj" "$obj" "$SIM_PLATFORM" "arm64"; then
        patched=$((patched + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done

  cd "$work_dir"
  libtool -static -no_warning_for_no_symbols -o "$output" *.o
  cd "$SCRIPT_DIR"
  rm -rf "$work_dir"
  log "  patched $patched objects ($failed failed)"
}

# =============================================================================
# 构建 xcframework
# =============================================================================
build_xcframework() {
  local name="$1"
  local fw_dir
  fw_dir=$(find "${BUILD_DIR}/${name}" -type d -name "${name}.framework" 2>/dev/null | head -1)
  [[ -z "$fw_dir" ]] && { err "$name: framework not found"; return; }

  local original="${fw_dir}/${name}"
  [[ ! -f "$original" ]] && { err "$name: binary not found"; return; }

  log "  $name: building xcframework"

  local file_type
  file_type=$(file -b "$original")

  local work="${BUILD_DIR}/.xcwork_${name}"
  rm -rf "$work"
  mkdir -p "$work/device" "$work/sim_arm64" "$work/sim_x86"

  cp -R "$fw_dir" "$work/device/${name}.framework"
  cp -R "$fw_dir" "$work/sim_arm64/${name}.framework"
  cp -R "$fw_dir" "$work/sim_x86/${name}.framework"

  local device_binary="$work/device/${name}.framework/${name}"
  local sim_arm64_binary="$work/sim_arm64/${name}.framework/${name}"
  local sim_x86_binary="$work/sim_x86/${name}.framework/${name}"

  local build_device=false build_sim_arm64=false build_sim_x86=false

  if echo "$file_type" | grep -q "universal"; then
    log "  $name: fat binary"

    local tmp_arm64="${work}/tmp_arm64"
    local tmp_x86="${work}/tmp_x86"
    lipo -thin arm64 "$original" -output "$tmp_arm64"
    lipo -thin x86_64 "$original" -output "$tmp_x86"

    local has_platform
    has_platform=$(otool -l "$tmp_arm64" | grep -c "LC_BUILD_VERSION\|LC_VERSION_MIN" || true)

    if [[ "$has_platform" -gt 0 ]]; then
      # 有 platform info
      cp "$tmp_arm64" "$device_binary"
      build_device=true

      local tmp_type
      tmp_type=$(file -b "$tmp_arm64")
      if echo "$tmp_type" | grep -q "ar archive"; then
        patch_arm64_archive "$tmp_arm64" "$sim_arm64_binary"
      else
        patch_platform "$tmp_arm64" "$sim_arm64_binary" "$SIM_PLATFORM" "arm64"
      fi
      # 验证 sim arm64 是否 patch 成功
      if [[ -f "$sim_arm64_binary" ]]; then
        build_sim_arm64=true
      else
        log "  $name: sim arm64 patch failed, falling back to copy"
        cp "$tmp_arm64" "$sim_arm64_binary"
        build_sim_arm64=true
      fi

      cp "$tmp_x86" "$sim_x86_binary"
      build_sim_x86=true
    else
      # 无 platform info：device 和 sim 都需要 patch
      local tmp_type
      tmp_type=$(file -b "$tmp_arm64")
      if echo "$tmp_type" | grep -q "ar archive"; then
        # ar archive: device 也需要 patch 每个 .o
        patch_arm64_archive "$tmp_arm64" "$device_binary"
        cp "$device_binary" "$sim_arm64_binary"
        patch_arm64_archive "$tmp_arm64" "$sim_arm64_binary"
      else
        # 纯 Mach-O: device 加 platform=2, sim 加 platform=7
        patch_platform "$tmp_arm64" "$device_binary" 2 "arm64" || cp "$tmp_arm64" "$device_binary"
        patch_platform "$tmp_arm64" "$sim_arm64_binary" "$SIM_PLATFORM" "arm64" || cp "$tmp_arm64" "$sim_arm64_binary"
      fi
      build_device=true
      build_sim_arm64=true

      cp "$tmp_x86" "$sim_x86_binary"
      build_sim_x86=true
    fi

    rm -f "$tmp_arm64" "$tmp_x86"

  elif echo "$file_type" | grep -q "Mach-O"; then
    local arch
    arch=$(lipo -info "$original" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1)

    if [[ "$arch" == "arm64" ]]; then
      log "  $name: single arm64 Mach-O"
      cp "$original" "$device_binary"
      build_device=true
      patch_platform "$original" "$sim_arm64_binary" "$SIM_PLATFORM" "arm64" || \
        cp "$original" "$sim_arm64_binary"
      build_sim_arm64=true
    else
      log "  $name: single $arch Mach-O"
      cp "$original" "$device_binary"
      build_device=true
      cp "$original" "$sim_x86_binary"
      build_sim_x86=true
    fi
  fi

  # 合并模拟器架构
  if $build_sim_arm64 && $build_sim_x86; then
    log "  $name: merging sim arm64 + x86_64"
    lipo -create "$sim_arm64_binary" "$sim_x86_binary" -output "${sim_arm64_binary}.fat"
    mv "${sim_arm64_binary}.fat" "$sim_arm64_binary"
    rm -f "$sim_x86_binary"
    rm -rf "$work/sim_x86"
    build_sim_x86=false
  fi

  # 创建 xcframework
  local xcfw="${BUILD_DIR}/${name}.xcframework"
  rm -rf "$xcfw"

  local cmd="xcodebuild -create-xcframework"
  $build_device   && cmd+=" -framework $work/device/${name}.framework"
  $build_sim_arm64 && cmd+=" -framework $work/sim_arm64/${name}.framework"
  $build_sim_x86  && cmd+=" -framework $work/sim_x86/${name}.framework"
  cmd+=" -output $xcfw"

  eval "$cmd" 2>&1
  log "  $name: -> ${name}.xcframework"
  rm -rf "$work"
}

# =============================================================================
# 生成 podspec
# =============================================================================
generate_podspec() {
  local name="$1" version="$2"
  local pod_dir="${BUILD_DIR}/${name}"
  local fw_list="" lib_list=""
  case "$name" in
    MLKitCommon)                fw_list="Foundation LocalAuthentication"; lib_list="c++ sqlite3 z" ;;
    MLImage)                    fw_list="CoreGraphics CoreMedia CoreVideo Foundation UIKit" ;;
    MLKitVision)                fw_list="Accelerate AVFoundation CoreGraphics CoreMedia CoreVideo Foundation UIKit" ;;
    MLKitTextRecognitionCommon) fw_list="Accelerate AVFoundation CoreGraphics CoreImage CoreLocation CoreMedia CoreVideo Foundation UIKit"; lib_list="c++" ;;
    MLKitTextRecognition | MLKitTextRecognitionChinese | MLKitTextRecognitionDevanagari | MLKitTextRecognitionJapanese | MLKitTextRecognitionKorean)       fw_list="Accelerate AVFoundation CoreGraphics CoreImage CoreMedia CoreVideo Foundation UIKit"; lib_list="c++" ;;
  esac

  local res_bundle_name=""
  case "$name" in
    MLKitTextRecognition)           res_bundle_name="LatinOCRResources" ;;
    MLKitTextRecognitionChinese)     res_bundle_name="ChineseOCRResources" ;;
    MLKitTextRecognitionDevanagari)  res_bundle_name="DevanagariOCRResources" ;;
    MLKitTextRecognitionJapanese)    res_bundle_name="JapaneseOCRResources" ;;
    MLKitTextRecognitionKorean)      res_bundle_name="KoreanOCRResources" ;;
  esac

  {
    echo "Pod::Spec.new do |s|"
    echo "  s.name         = \"${name}\""
    echo "  s.version      = \"${version}\""
    echo "  s.summary      = \"${name} - patched for arm64 simulator\""
    echo "  s.homepage     = \"https://developers.google.com/ml-kit/guides\""
    echo "  s.license      = { :type => \"Copyright\", :text => \"Copyright 2025 Google LLC\" }"
    echo "  s.author       = { \"Google\" => \"cocoapods@google.com\" }"
    echo "  s.platform     = :ios, \"15.5\""
    echo "  s.swift_version = \"5.7\""
    echo "  s.source       = { :path => \".\" }"
    echo "  s.vendored_frameworks = \"${name}.xcframework\""
    [[ -n "$res_bundle_name" && -d "${pod_dir}/Resources" ]] && echo "  s.resource_bundles = { \"${res_bundle_name}\" => [\"Resources/${res_bundle_name}/**\"] }"
    [[ -n "$fw_list" ]] && echo "  s.frameworks = [$(echo "$fw_list" | sed 's/[^ ]*/"&"/g' | sed 's/ /, /g')]"
    [[ -n "$lib_list" ]] && echo "  s.libraries  = [$(echo "$lib_list" | sed 's/[^ ]*/"&"/g' | sed 's/ /, /g')]"
    echo "end"
  } > "${pod_dir}/${name}.podspec"
  log "  $name: -> ${name}.podspec"
}

generate_spec_repo_podspec() {
  local name="$1" version="$2"
  local spec_dir="${SPECS_DIR}/Specs/${name}/${version}"
  mkdir -p "$spec_dir"
  local fw_list="" lib_list=""
  case "$name" in
    MLKitCommon)                fw_list="Foundation LocalAuthentication"; lib_list="c++ sqlite3 z" ;;
    MLImage)                    fw_list="CoreGraphics CoreMedia CoreVideo Foundation UIKit" ;;
    MLKitVision)                fw_list="Accelerate AVFoundation CoreGraphics CoreMedia CoreVideo Foundation UIKit" ;;
    MLKitTextRecognitionCommon) fw_list="Accelerate AVFoundation CoreGraphics CoreImage CoreLocation CoreMedia CoreVideo Foundation UIKit"; lib_list="c++" ;;
    MLKitTextRecognition | MLKitTextRecognitionChinese | MLKitTextRecognitionDevanagari | MLKitTextRecognitionJapanese | MLKitTextRecognitionKorean)       fw_list="Accelerate AVFoundation CoreGraphics CoreImage CoreMedia CoreVideo Foundation UIKit"; lib_list="c++" ;;
  esac

  local res_bundle_name=""
  case "$name" in
    MLKitTextRecognition)           res_bundle_name="LatinOCRResources" ;;
    MLKitTextRecognitionChinese)     res_bundle_name="ChineseOCRResources" ;;
    MLKitTextRecognitionDevanagari)  res_bundle_name="DevanagariOCRResources" ;;
    MLKitTextRecognitionJapanese)    res_bundle_name="JapaneseOCRResources" ;;
    MLKitTextRecognitionKorean)      res_bundle_name="KoreanOCRResources" ;;
  esac

  {
    echo "Pod::Spec.new do |s|"
    echo "  s.name         = \"${name}\""
    echo "  s.version      = \"${version}\""
    echo "  s.summary      = \"${name} - patched for arm64 simulator\""
    echo "  s.homepage     = \"https://developers.google.com/ml-kit/guides\""
    echo "  s.license      = { :type => \"Copyright\", :text => \"Copyright 2025 Google LLC\" }"
    echo "  s.author       = { \"Google\" => \"cocoapods@google.com\" }"
    echo "  s.platform     = :ios, \"15.5\""
    echo "  s.swift_version = \"5.7\""
    echo "  s.source       = { :http => \"https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${GITHUB_TAG}/${name}.xcframework.zip\" }"
    echo "  s.vendored_frameworks = \"${name}.xcframework\""
    [[ -n "$res_bundle_name" ]] && echo "  s.resource_bundles = { \"${res_bundle_name}\" => [\"Resources/${res_bundle_name}/**\"] }"
    [[ -n "$fw_list" ]] && echo "  s.frameworks = [$(echo "$fw_list" | sed 's/[^ ]*/"&"/g' | sed 's/ /, /g')]"
    [[ -n "$lib_list" ]] && echo "  s.libraries  = [$(echo "$lib_list" | sed 's/[^ ]*/"&"/g' | sed 's/ /, /g')]"
    echo "end"
  } > "${spec_dir}/${name}.podspec"
  log "  $name spec: -> ${spec_dir}/${name}.podspec"
}

pack_release_zip() {
  local name="$1"
  local pod_dir="${BUILD_DIR}/${name}"
  [[ -d "$pod_dir" ]] || return
  log "  $name: packing release zip..."
  mkdir -p "$RELEASES_DIR"
  local zip_path="${RELEASES_DIR}/${name}.xcframework.zip"
  rm -f "$zip_path"
  (
    cd "$pod_dir"
    zip -rq "$zip_path" .
  )
  log "  $name zip: -> $zip_path"
}

# =============================================================================
# 主流程
# =============================================================================
download_and_extract() {
  local name="$1" url="$2"
  local pod_dir="${BUILD_DIR}/${name}"
  [[ -d "$pod_dir" ]] && { log "  $name: exists"; return; }
  log "  $name: downloading..."
  curl -sL -o "${BUILD_DIR}/.tmp_${name}.tar.gz" "$url"
  mkdir -p "$pod_dir"
  tar -xzf "${BUILD_DIR}/.tmp_${name}.tar.gz" -C "$pod_dir" --strip-components=0
  rm -f "${BUILD_DIR}/.tmp_${name}.tar.gz"
}

main() {
  log "=== MLKit XCFramework Builder ==="
  mkdir -p "$BUILD_DIR"

  log "--- Download ---"
  download_and_extract "MLKitCommon"                "https://dl.google.com/dl/cpdc/00f258dabdb58dfa/MLKitCommon-14.0.0.tar.gz"
  download_and_extract "MLImage"                    "https://dl.google.com/dl/cpdc/438c904a2516b489/MLImage-1.0.0-beta8.tar.gz"
  download_and_extract "MLKitVision"                "https://dl.google.com/dl/cpdc/4e1652530984149e/MLKitVision-10.0.0.tar.gz"
  download_and_extract "MLKitTextRecognitionCommon" "https://dl.google.com/dl/cpdc/ffd1e8a2dd89e128/MLKitTextRecognitionCommon-6.0.0.tar.gz"
  download_and_extract "MLKitTextRecognition"       "https://dl.google.com/dl/cpdc/d19e9c059f422b0c/MLKitTextRecognition-7.0.0.tar.gz"
  download_and_extract "MLKitTextRecognitionChinese"    "https://dl.google.com/dl/cpdc/88856ee0a4da8910/MLKitTextRecognitionChinese-6.0.0.tar.gz"
  download_and_extract "MLKitTextRecognitionDevanagari" "https://dl.google.com/dl/cpdc/179643a21ac697ae/MLKitTextRecognitionDevanagari-6.0.0.tar.gz"
  download_and_extract "MLKitTextRecognitionJapanese"   "https://dl.google.com/dl/cpdc/1855262723e8ed6b/MLKitTextRecognitionJapanese-6.0.0.tar.gz"
  download_and_extract "MLKitTextRecognitionKorean"     "https://dl.google.com/dl/cpdc/7bfa31d60eef9311/MLKitTextRecognitionKorean-6.0.0.tar.gz"

  log ""
  log "--- Build XCFrameworks ---"
  build_xcframework "MLKitCommon"
  build_xcframework "MLImage"
  build_xcframework "MLKitVision"
  build_xcframework "MLKitTextRecognitionCommon"
  build_xcframework "MLKitTextRecognition"
  build_xcframework "MLKitTextRecognitionChinese"
  build_xcframework "MLKitTextRecognitionDevanagari"
  build_xcframework "MLKitTextRecognitionJapanese"
  build_xcframework "MLKitTextRecognitionKorean"

  log ""
  log "--- Generate Podspecs ---"
  generate_podspec "MLKitCommon"                "14.0.0"
  generate_podspec "MLImage"                    "1.0.0-beta8"
  generate_podspec "MLKitVision"                "10.0.0"
  generate_podspec "MLKitTextRecognitionCommon" "6.0.0"
  generate_podspec "MLKitTextRecognition"       "7.0.0"
  generate_podspec "MLKitTextRecognitionChinese"    "6.0.0"
  generate_podspec "MLKitTextRecognitionDevanagari" "6.0.0"
  generate_podspec "MLKitTextRecognitionJapanese"   "6.0.0"
  generate_podspec "MLKitTextRecognitionKorean"     "6.0.0"

  if [[ "$GENERATE_SPECS" == "1" ]]; then
    log ""
    log "--- Generate Spec Repo Podspecs ---"
    generate_spec_repo_podspec "MLKitCommon"                "14.0.0"
    generate_spec_repo_podspec "MLImage"                    "1.0.0-beta8"
    generate_spec_repo_podspec "MLKitVision"                "10.0.0"
    generate_spec_repo_podspec "MLKitTextRecognitionCommon" "6.0.0"
    generate_spec_repo_podspec "MLKitTextRecognition"       "7.0.0"
    generate_spec_repo_podspec "MLKitTextRecognitionChinese"    "6.0.0"
    generate_spec_repo_podspec "MLKitTextRecognitionDevanagari" "6.0.0"
    generate_spec_repo_podspec "MLKitTextRecognitionJapanese"   "6.0.0"
    generate_spec_repo_podspec "MLKitTextRecognitionKorean"     "6.0.0"
  fi

  log ""
  log "--- Podfile ---"
  cat > "${BUILD_DIR}/Podfile" <<'PODFILE'
platform :ios, '15.5'

target 'YourApp' do
  use_frameworks! :linkage => :static

  pod 'MLKitCommon',                :path => './LocalPods/MLKitCommon'
  pod 'MLImage',                    :path => './LocalPods/MLImage'
  pod 'MLKitVision',                :path => './LocalPods/MLKitVision'
  pod 'MLKitTextRecognitionCommon', :path => './LocalPods/MLKitTextRecognitionCommon'
  pod 'MLKitTextRecognition',       :path => './LocalPods/MLKitTextRecognition'
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
PODFILE
  log "  -> ${BUILD_DIR}/Podfile"

  log ""
  log "--- Verify ---"
  for name in MLKitCommon MLImage MLKitVision MLKitTextRecognitionCommon MLKitTextRecognition MLKitTextRecognitionChinese MLKitTextRecognitionDevanagari MLKitTextRecognitionJapanese MLKitTextRecognitionKorean; do
    xcfw="${BUILD_DIR}/${name}.xcframework"
    if [[ -d "$xcfw" ]]; then
      log "  $name.xcframework:"
      for platform_dir in "$xcfw"/*/; do
        log "    $(basename "$platform_dir")"
      done
    else
      log "  $name.xcframework: NOT FOUND"
    fi
  done

  if [[ "$PACK_RELEASES" == "1" ]]; then
    log ""
    log "--- Pack Release ZIPs ---"
    pack_release_zip "MLKitCommon"
    pack_release_zip "MLImage"
    pack_release_zip "MLKitVision"
    pack_release_zip "MLKitTextRecognitionCommon"
    pack_release_zip "MLKitTextRecognition"
    pack_release_zip "MLKitTextRecognitionChinese"
    pack_release_zip "MLKitTextRecognitionDevanagari"
    pack_release_zip "MLKitTextRecognitionJapanese"
    pack_release_zip "MLKitTextRecognitionKorean"
  fi

  log ""
  log "=== Done ==="
}

main "$@"
