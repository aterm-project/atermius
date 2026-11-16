#!/usr/bin/env bash
# ==============================================================================
# Apple App Store Connect 新 App 正式归档导出与 6 道合规铁闸预检流水线
#
# 专为作为全新独立 App 首次上架 iOS / iPadOS App Store (含 Apple Silicon Mac 兼容运行) 设计：
#   - 内置 6 道自动化上传前铁闸预检 (Pre-flight Checks)
#   - 支持通过构建参数一键覆盖新 App 的 Bundle ID、Team ID、显示名称与首发版本号
#   - 采用独立洁净 DerivedData + 归档后 (.xcarchive) / 导出后 (.ipa) 双重防泄漏断言
#   - 产物输出目录: ios/dist/appstore/
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/apps/client"
IOS_DIR="$CLIENT_DIR/ios"
RUNNER_DIR="$IOS_DIR/Runner"
PUBSPEC_FILE="$CLIENT_DIR/pubspec.yaml"
PBXPROJ_FILE="$IOS_DIR/Runner.xcodeproj/project.pbxproj"
INFO_PLIST="$RUNNER_DIR/Info.plist"
PRIVACY_MANIFEST="$RUNNER_DIR/PrivacyInfo.xcprivacy"
EXPORT_OPTIONS_PLIST="$IOS_DIR/ExportOptions-AppStore.plist"
APPICON_DIR="$RUNNER_DIR/Assets.xcassets/AppIcon.appiconset"
ENGINE_SCRIPT="$CLIENT_DIR/native/desktop/apple/build_engine.sh"
VERIFY_SCRIPT="$CLIENT_DIR/native/desktop/apple/verify_engine.py"
XCFRAMEWORK_DIR="$CLIENT_DIR/native/desktop/build/ios/bundle/atermius_rdp.xcframework"
APPSTORE_DIST_DIR="$REPO_ROOT/dist/appstore"
ARCHIVE_DERIVED_DATA="$CLIENT_DIR/build/ios_appstore_derived"

if [ -d "$WORKSPACE_ROOT/.tooling/flutter-sdk/flutter/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/flutter-sdk/flutter/bin:$PATH"
fi
if [ -d "$WORKSPACE_ROOT/.tooling/venv/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/venv/bin:$PATH"
fi
if [ -d "$WORKSPACE_ROOT/.tooling/ruby-env/bin" ]; then
  export PATH="$WORKSPACE_ROOT/.tooling/ruby-env/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# ------------------------------------------------------------------------------
# 默认参数解析（优先读取 pubspec.yaml，兜底 1.0.0 / Build 1）
# ------------------------------------------------------------------------------
DEFAULT_VERSION="1.0.0"
DEFAULT_BUILD_NUMBER="1"
if [ -f "$PUBSPEC_FILE" ]; then
  RAW_PUBSPEC_VER="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$PUBSPEC_FILE" | head -n 1)"
  if [ -n "$RAW_PUBSPEC_VER" ]; then
    PARSED_NAME="${RAW_PUBSPEC_VER%%+*}"
    if [[ "$PARSED_NAME" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      DEFAULT_VERSION="$PARSED_NAME"
    fi
    if [[ "$RAW_PUBSPEC_VER" == *"+"* ]]; then
      PARSED_BUILD="${RAW_PUBSPEC_VER#*+}"
      if [[ "$PARSED_BUILD" =~ ^[1-9][0-9]*$ ]]; then
        DEFAULT_BUILD_NUMBER="$PARSED_BUILD"
      fi
    fi
  fi
fi

BUNDLE_ID="${ATERMIUS_APPSTORE_BUNDLE_ID:-}"
TEAM_ID="${ATERMIUS_IOS_TEAM_ID:-2QJ8K75QL2}"
VERSION="$DEFAULT_VERSION"
VERSION_EXPLICIT=0
BUILD_NUMBER="$DEFAULT_BUILD_NUMBER"
DISPLAY_NAME=""
PREFLIGHT_ONLY=0
REBUILD_ENGINE=0
UPLOAD_TO_ASC=0

usage() {
  cat <<'EOF'
Usage: ./scripts/archive_appstore.sh --bundle-id <com.yourcompany.newapp> [options]

专为将项目作为全新 App 打包提交 Apple App Store Connect / TestFlight 设计。

Options:
  --bundle-id <ID>         [必填] 新 App 在 Apple Developer 后台注册的显式 Bundle ID
                           (禁止通配符 * 或复用旧开发默认 ID com.atermius.atermClient)
  --team-id <TEAM_ID>      Apple Developer Team ID (默认: 2QJ8K75QL2)
  --version <X.Y.Z>        App Store 营销版本号 CFBundleShortVersionString (默认读取 pubspec.yaml 或 1.0.0)
  --build-number <N>       构建递增号 CFBundleVersion (默认: 1)
  --display-name <Name>    可选：覆盖新 App 桌面显示名称 (CFBundleDisplayName & 四语本地化)
  --upload                 导出并终检本地洁净 IPA 后，自动直传构建至 App Store Connect (destination=upload)
  --preflight-only         仅执行全套 6 道 App Store 静态合规预检，不运行 xcodebuild archive
  --rebuild-engine         归档前强制重编 OpenSSL + FreeRDP iOS XCFramework
  -h, --help               显示本帮助说明

Examples:
  # 仅运行上传前 6 道静态合规铁闸预检
  ./scripts/archive_appstore.sh --preflight-only --bundle-id com.atermius.ssh

  # 构建新 App 首发正式包 (1.0.0 Build 1)、导出本地 IPA 并自动直传 App Store Connect
  ./scripts/archive_appstore.sh \
    --bundle-id com.yourcompany.newapp \
    --team-id 2QJ8K75QL2 \
    --version 1.0.0 \
    --build-number 1 \
    --display-name "Atermius SSH" \
    --upload
EOF
}

require_arg() {
  local flag="$1"
  local val="${2:-}"
  if [ -z "$val" ] || [[ "$val" == --* ]]; then
    echo "[ERROR] 参数 $flag 需要提供非空值。请运行 --help 查看用法。" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id)
      require_arg "$1" "${2:-}"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --bundle-id=*)
      BUNDLE_ID="${1#*=}"
      shift
      ;;
    --team-id)
      require_arg "$1" "${2:-}"
      TEAM_ID="$2"
      shift 2
      ;;
    --team-id=*)
      TEAM_ID="${1#*=}"
      shift
      ;;
    --version)
      require_arg "$1" "${2:-}"
      VERSION="$2"
      VERSION_EXPLICIT=1
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      VERSION_EXPLICIT=1
      shift
      ;;
    --build-number)
      require_arg "$1" "${2:-}"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --build-number=*)
      BUILD_NUMBER="${1#*=}"
      shift
      ;;
    --display-name|--app-name)
      require_arg "$1" "${2:-}"
      DISPLAY_NAME="$2"
      shift 2
      ;;
    --display-name=*|--app-name=*)
      DISPLAY_NAME="${1#*=}"
      shift
      ;;
    --upload)
      UPLOAD_TO_ASC=1
      shift
      ;;
    --preflight-only)
      PREFLIGHT_ONLY=1
      shift
      ;;
    --rebuild-engine)
      REBUILD_ENGINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] 未知参数: $1（运行 --help 查看支持的选项）" >&2
      exit 2
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 辅助日志与铁闸状态统计
# ------------------------------------------------------------------------------
PREFLIGHT_FAILURES=0

gate_header() {
  echo ""
  echo "----------------------------------------------------------------------"
  echo "==> $1"
  echo "----------------------------------------------------------------------"
}

gate_pass() {
  echo "  [PASS] $1"
}

gate_warn() {
  echo "  [WARN] $1"
}

gate_fail() {
  echo "  [FAIL] $1" >&2
  PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
}

echo "======================================================================"
echo "  Apple App Store Connect Release Pipeline & Pre-flight Gate"
echo "======================================================================"
echo "  Bundle ID     : ${BUNDLE_ID:-<MISSING>}"
echo "  Team ID       : $TEAM_ID"
echo "  Version       : $VERSION (Build $BUILD_NUMBER)"
echo "  Display Name  : ${DISPLAY_NAME:-<keep project default>}"
if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  echo "  Mode          : PREFLIGHT-ONLY (Static Compliance Checks)"
elif [ "$UPLOAD_TO_ASC" -eq 1 ]; then
  echo "  Mode          : FULL ARCHIVE + EXPORT IPA + UPLOAD TO ASC"
else
  echo "  Mode          : FULL ARCHIVE + EXPORT IPA"
fi
echo "  Output Dir    : $APPSTORE_DIST_DIR"
echo "======================================================================"

if [ "$VERSION_EXPLICIT" -eq 0 ] && [[ "$VERSION" =~ ^0\. ]]; then
  gate_warn "当前从 pubspec.yaml 读取到预发布版本号 '$VERSION'；新 App 首次正式提审建议显式指定 --version 1.0.0。"
fi

# 若显式要求重编引擎且非仅预检模式，先构建 XCFramework
if [ "$REBUILD_ENGINE" -eq 1 ] && [ "$PREFLIGHT_ONLY" -eq 0 ]; then
  echo "==> Rebuilding native FreeRDP iOS XCFramework..."
  bash "$ENGINE_SCRIPT" --platform ios
fi

# ==============================================================================
# Gate 1/6: 零私有测试种子与敏感导出文件泄漏检查 (Zero Private Data Leak)
# ==============================================================================
gate_header "[Gate 1/6] 源码树与构建目录私有测试文件零泄漏预检 (Zero Private Data Leak)"

GATE1_OK=1
SCAN_DIRS=("$CLIENT_DIR")
if [ -d "$APPSTORE_DIST_DIR" ]; then
  SCAN_DIRS+=("$APPSTORE_DIST_DIR")
fi

LEAKED_FILES="$(
  find "${SCAN_DIRS[@]}" \
    \( -path "$CLIENT_DIR/.dart_tool" -o -path "$CLIENT_DIR/ios/Pods" \) -prune -o \
    -type f \( \
      -name "atermius-local-seed.json" -o \
      -name "atermius-auto-import.json" -o \
      -name "termius-hosts.csv" -o \
      -name "termius-hosts.json" -o \
      -name "termius-labeled-hosts.json" -o \
      -name "termius-openssh-bundle.zip" -o \
      -name "ssh_config" \
    \) -print 2>/dev/null || true
)"

if [ -n "$LEAKED_FILES" ]; then
  GATE1_OK=0
  while IFS= read -r leaked; do
    [ -n "$leaked" ] && gate_fail "发现严禁混入客户端源码树/构建目录的私有敏感文件: $leaked"
  done <<< "$LEAKED_FILES"
fi

for cfg_file in "$PBXPROJ_FILE" "$PUBSPEC_FILE"; do
  if [ -f "$cfg_file" ]; then
    if grep -Eq 'atermius-local-seed\.json|atermius-auto-import\.json|termius-export|termius-labeled-hosts\.json|termius-openssh-bundle' "$cfg_file"; then
      GATE1_OK=0
      gate_fail "工程资源配置中存在私有种子文件静态挂载引用: $cfg_file"
    fi
  fi
done

if [ -d "$WORKSPACE_ROOT/termius-export" ]; then
  gate_warn "检测到工作区外围目录存在 $WORKSPACE_ROOT/termius-export（未被客户端引用）；归档流水线已强制隔离 DerivedData 并将在导出后对 .xcarchive/.ipa 执行条目级黑名单断言。"
fi
if [ -f "$REPO_ROOT/dist/Atermius-ios-signed.ipa" ]; then
  if /usr/bin/unzip -Z1 "$REPO_ROOT/dist/Atermius-ios-signed.ipa" 2>/dev/null | grep -Fq "atermius-local-seed.json"; then
    gate_warn "旧开发签名包 ios/dist/Atermius-ios-signed.ipa 含有历史测试种子，严禁上传该文件！正式上架请仅使用 ios/dist/appstore/ 下导出的洁净 IPA。"
  fi
fi

if [ "$GATE1_OK" -eq 1 ]; then
  gate_pass "客户端源码树、构建目录、pubspec.yaml 与 project.pbxproj 均零私有测试种子残留"
fi

# ==============================================================================
# Gate 2/6: PrivacyInfo.xcprivacy 存在性、语法与 Required Reason APIs 校验 (ITMS-91053)
# ==============================================================================
gate_header "[Gate 2/6] iOS 隐私清单校验 (ITMS-91053 / PrivacyInfo.xcprivacy)"

if [ ! -f "$PRIVACY_MANIFEST" ]; then
  gate_fail "缺失 iOS 主工程隐私清单: $PRIVACY_MANIFEST"
else
  if ! /usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null 2>&1; then
    gate_fail "plutil -lint 校验失败: $PRIVACY_MANIFEST"
  else
    gate_pass "PrivacyInfo.xcprivacy 存在且通过 plutil -lint 语法验证"
    if PRIVACY_ERR="$(/usr/bin/python3 - "$PRIVACY_MANIFEST" "$PBXPROJ_FILE" <<'PY'
import plistlib
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
pbxproj_path = Path(sys.argv[2])
errors = []

with manifest_path.open("rb") as f:
    data = plistlib.load(f)

if not isinstance(data.get("NSPrivacyTracking"), bool) or data.get("NSPrivacyTracking") is not False:
    errors.append("NSPrivacyTracking 必须显式声明为 <false/>")

if not isinstance(data.get("NSPrivacyTrackingDomains"), list):
    errors.append("NSPrivacyTrackingDomains 必须声明为 <array/>")

required_reasons = {
    "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
    "NSPrivacyAccessedAPICategoryDiskSpace": "E174.1",
    "NSPrivacyAccessedAPICategorySystemBootTime": "35F9.1",
}

api_types = data.get("NSPrivacyAccessedAPITypes")
if not isinstance(api_types, list):
    errors.append("NSPrivacyAccessedAPITypes 缺失或类型不为数组")
else:
    declared = {}
    for item in api_types:
        if isinstance(item, dict):
            cat = item.get("NSPrivacyAccessedAPIType")
            reasons = item.get("NSPrivacyAccessedAPITypeReasons") or []
            if isinstance(cat, str) and isinstance(reasons, list):
                declared.setdefault(cat, set()).update(str(r) for r in reasons)
    for cat, code in required_reasons.items():
        if cat not in declared:
            errors.append(f"缺失 Required Reason API 类别声明: {cat} (需包含 {code})")
        elif code not in declared[cat]:
            errors.append(f"类别 {cat} 缺少批准原因码 {code} (当前: {sorted(declared[cat])})")

if pbxproj_path.is_file():
    pbx_text = pbxproj_path.read_text(encoding="utf-8", errors="replace")
    if "PrivacyInfo.xcprivacy" not in pbx_text:
        errors.append("Runner.xcodeproj/project.pbxproj 尚未引用 PrivacyInfo.xcprivacy")
    else:
        in_resources = False
        mounted = False
        for line in pbx_text.splitlines():
            if "Begin PBXResourcesBuildPhase section" in line:
                in_resources = True
            elif "End PBXResourcesBuildPhase section" in line:
                in_resources = False
            elif in_resources and "PrivacyInfo.xcprivacy" in line:
                mounted = True
                break
        if not mounted:
            errors.append("PrivacyInfo.xcprivacy 未挂载到 project.pbxproj 的 PBXResourcesBuildPhase")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
    )"; then
      gate_pass "PrivacyInfo.xcprivacy 完整声明 CA92.1 / C617.1 / E174.1 / 35F9.1 且已挂载至 PBXResourcesBuildPhase"
    else
      while IFS= read -r err_line; do
        [ -n "$err_line" ] && gate_fail "$err_line"
      done <<< "$PRIVACY_ERR"
    fi
  fi
fi

# ==============================================================================
# Gate 3/6: Info.plist 出口加密合规与全量敏感权限用途串校验 (ITMS-90683)
# ==============================================================================
gate_header "[Gate 3/6] Info.plist 出口合规与四语 NS*UsageDescription 完整性校验 (ITMS-90683)"

if [ ! -f "$INFO_PLIST" ]; then
  gate_fail "缺失 iOS Info.plist: $INFO_PLIST"
elif ! /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null 2>&1; then
  gate_fail "plutil -lint 校验失败: $INFO_PLIST"
else
  gate_pass "ios/Runner/Info.plist 通过 plutil -lint 语法验证"

  LOCALES=("en" "zh-Hans" "ja" "ru")
  STRINGS_LINT_OK=1
  for loc in "${LOCALES[@]}"; do
    STR_FILE="$RUNNER_DIR/${loc}.lproj/InfoPlist.strings"
    if [ ! -f "$STR_FILE" ]; then
      STRINGS_LINT_OK=0
      gate_fail "缺失多语言权限本地化文件: $STR_FILE"
    elif ! /usr/bin/plutil -lint "$STR_FILE" >/dev/null 2>&1; then
      STRINGS_LINT_OK=0
      gate_fail "plutil -lint 校验失败: $STR_FILE"
    fi
  done

  if [ "$STRINGS_LINT_OK" -eq 1 ]; then
    if INFO_ERR="$(/usr/bin/python3 - "$INFO_PLIST" "$RUNNER_DIR" <<'PY'
import json
import plistlib
import subprocess
import sys
from pathlib import Path

info_plist_path = Path(sys.argv[1])
runner_dir = Path(sys.argv[2])
errors = []
warnings = []

with info_plist_path.open("rb") as f:
    info = plistlib.load(f)

if "ITSAppUsesNonExemptEncryption" not in info or not isinstance(info["ITSAppUsesNonExemptEncryption"], bool):
    errors.append("Info.plist 缺失布尔类型键 ITSAppUsesNonExemptEncryption (出口加密合规必填)")

# Phase 1 二进制 nm -u / otool -L 实测链接符号对应的必需权限键 (防 ITMS-90683 秒拒)
mandatory_keys = [
    "NSLocalNetworkUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSCameraUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSAppleMusicUsageDescription",
    "NSFaceIDUsageDescription",
]

# Phase 1 明确甄别零符号、严禁误加的权限键
forbidden_keys = [
    "NSHealthShareUsageDescription",
    "NSHealthUpdateUsageDescription",
    "NSMotionUsageDescription",
]

placeholder_tokens = {"todo", "tbd", "need permission", "permission required", "access needed"}

def check_purpose_value(source_label: str, key: str, val: object, min_len: int) -> None:
    if not isinstance(val, str) or not val.strip():
        errors.append(f"{source_label} 缺失或为空: {key}")
        return
    cleaned = val.strip()
    if len(cleaned) < min_len:
        errors.append(f"{source_label} 中 {key} 描述过短 ({len(cleaned)} 字符 < {min_len}): {cleaned!r}")
    if cleaned.lower() in placeholder_tokens:
        errors.append(f"{source_label} 中 {key} 包含敷衍占位文案: {cleaned!r}")

for key in mandatory_keys:
    check_purpose_value("ios/Runner/Info.plist", key, info.get(key), min_len=12)

for bad_key in forbidden_keys:
    if bad_key in info:
        errors.append(f"ios/Runner/Info.plist 误加了无对应二进制符号的敏感权限键 {bad_key} (易触发人工审核拒信)")

locale_min_len = {
    "en": 12,
    "zh-Hans": 10,
    "ja": 10,
    "ru": 12,
}

for loc, min_len in locale_min_len.items():
    strings_file = runner_dir / f"{loc}.lproj" / "InfoPlist.strings"
    raw_json = subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(strings_file)],
        text=True,
    )
    loc_map = json.loads(raw_json)
    for key in mandatory_keys:
        check_purpose_value(f"{loc}.lproj/InfoPlist.strings", key, loc_map.get(key), min_len=min_len)

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
    )"; then
      gate_pass "ITSAppUsesNonExemptEncryption 已声明，且 7 项二进制关联 NS*UsageDescription 在 Info.plist 与 en/zh-Hans/ja/ru 四语中完整对齐"
    else
      while IFS= read -r err_line; do
        [ -n "$err_line" ] && gate_fail "$err_line"
      done <<< "$INFO_ERR"
    fi
  fi
fi

# ==============================================================================
# Gate 4/6: AppIcon 1024x1024 分辨率与无 Alpha 透明通道校验 (ITMS-90717 / ITMS-90022)
# ==============================================================================
gate_header "[Gate 4/6] AppIcon 1024x1024 图标存在性与无 Alpha 透明通道校验 (ITMS-90717)"

MARKETING_ICON="$APPICON_DIR/Icon-App-1024x1024@1x.png"
if [ ! -d "$APPICON_DIR" ] || [ ! -f "$APPICON_DIR/Contents.json" ]; then
  gate_fail "缺失 AppIcon.appiconset 或 Contents.json: $APPICON_DIR"
elif [ ! -f "$MARKETING_ICON" ]; then
  gate_fail "缺失 1024x1024 App Store 营销图标: $MARKETING_ICON"
else
  SIPS_OUT="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$MARKETING_ICON" 2>/dev/null || true)"
  ICON_W="$(printf '%s\n' "$SIPS_OUT" | awk '/pixelWidth:/ {print $2}')"
  ICON_H="$(printf '%s\n' "$SIPS_OUT" | awk '/pixelHeight:/ {print $2}')"
  ICON_ALPHA="$(printf '%s\n' "$SIPS_OUT" | awk '/hasAlpha:/ {print $2}')"

  if [ "$ICON_W" != "1024" ] || [ "$ICON_H" != "1024" ]; then
    gate_fail "1024x1024 图标实际像素尺寸不匹配: ${ICON_W:-?}x${ICON_H:-?} ($MARKETING_ICON)"
  elif [ "$ICON_ALPHA" != "no" ]; then
    gate_fail "1024x1024 图标存在 Alpha 透明通道 (hasAlpha=$ICON_ALPHA)，违反 ITMS-90717"
  else
    if ICON_ERR="$(/usr/bin/python3 - "$APPICON_DIR" <<'PY'
import json
import struct
import subprocess
import sys
from pathlib import Path

appicon_dir = Path(sys.argv[1])
errors = []

contents = json.loads((appicon_dir / "Contents.json").read_text(encoding="utf-8"))
marketing_entries = [
    img for img in contents.get("images", [])
    if img.get("idiom") == "ios-marketing" and img.get("size") == "1024x1024"
]
if not marketing_entries or not marketing_entries[0].get("filename"):
    errors.append("Contents.json 未配置 ios-marketing 1024x1024 图标映射")

png_files = sorted(appicon_dir.glob("*.png"))
if not png_files:
    errors.append("AppIcon.appiconset 下未找到任何 PNG 文件")

for png in png_files:
    raw = png.read_bytes()
    if len(raw) < 33 or raw[:8] != b"\x89PNG\r\n\x1a\n":
        errors.append(f"非法 PNG 文件头: {png.name}")
        continue
    color_type = raw[25]
    # PNG color_type: 2 = Truecolor RGB (no alpha); 4 = Gray+Alpha; 6 = RGBA
    if color_type in (4, 6):
        errors.append(f"{png.name} PNG IHDR colorType={color_type} 含 Alpha 透明通道 (必须为 RGB colorType=2)")
    # Check chunks for tRNS transparency chunk
    offset = 8
    while offset + 8 <= len(raw):
        length = struct.unpack(">I", raw[offset:offset + 4])[0]
        chunk_type = raw[offset + 4:offset + 8]
        if chunk_type == b"tRNS":
            errors.append(f"{png.name} 包含 PNG tRNS 透明通道数据块")
            break
        if chunk_type == b"IEND":
            break
        offset += 12 + length

    sips = subprocess.check_output(
        ["/usr/bin/sips", "-g", "hasAlpha", str(png)],
        text=True,
    )
    if "hasAlpha: no" not in sips:
        errors.append(f"sips 检测到图标含 Alpha 通道: {png.name}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
    )"; then
      gate_pass "1024x1024 营销图标及全部 AppIcon PNG 尺寸精确、24-bit RGB 无 Alpha 通道 (hasAlpha: no, colorType=2)"
    else
      while IFS= read -r err_line; do
        [ -n "$err_line" ] && gate_fail "$err_line"
      done <<< "$ICON_ERR"
    fi
  fi
fi

# ==============================================================================
# Gate 5/6: atermius_rdp.xcframework 纯 arm64 真机切片与 Info.plist 校验 (ITMS-90087 / ITMS-90562)
# ==============================================================================
gate_header "[Gate 5/6] FreeRDP 内嵌动态库真机 arm64 切片与 Info.plist 校验 (ITMS-90087 / ITMS-90562)"

IOS_ARM64_FW="$XCFRAMEWORK_DIR/ios-arm64/atermius_rdp.framework"
IOS_ARM64_BIN="$IOS_ARM64_FW/atermius_rdp"
IOS_ARM64_PLIST="$IOS_ARM64_FW/Info.plist"

if [ ! -d "$IOS_ARM64_FW" ] || [ ! -f "$IOS_ARM64_BIN" ]; then
  gate_fail "缺失真机切片二进制: $IOS_ARM64_BIN（请先运行 build_engine.sh --platform ios 或附加 --rebuild-engine）"
elif [ ! -f "$IOS_ARM64_PLIST" ]; then
  gate_fail "缺失框架 Info.plist: $IOS_ARM64_PLIST (将触发 ITMS-90562)"
else
  FW_ARCHS="$(/usr/bin/lipo -archs "$IOS_ARM64_BIN" 2>/dev/null | xargs || true)"
  if [ "$FW_ARCHS" != "arm64" ]; then
    gate_fail "atermius_rdp.framework 架构非纯真机 arm64 (当前: '${FW_ARCHS:-unknown}')，将触发 ITMS-90087"
  else
    gate_pass "ios-arm64/atermius_rdp.framework 二进制为纯 arm64 架构"
  fi

  VTOOL_OUT="$(/usr/bin/vtool -show-build "$IOS_ARM64_BIN" 2>/dev/null || true)"
  if ! printf '%s\n' "$VTOOL_OUT" | grep -q "platform IOS"; then
    gate_fail "atermius_rdp 二进制 LC_BUILD_VERSION 未标记为 platform IOS"
  elif printf '%s\n' "$VTOOL_OUT" | grep -q "IOSSIMULATOR"; then
    gate_fail "ios-arm64 真机切片混入了模拟器平台标记 IOSSIMULATOR (ITMS-90087)"
  else
    gate_pass "LC_BUILD_VERSION 确认为纯真机 platform IOS (无模拟器切片污染)"
  fi

  if ! /usr/bin/plutil -lint "$IOS_ARM64_PLIST" >/dev/null 2>&1; then
    gate_fail "plutil -lint 校验失败: $IOS_ARM64_PLIST"
  else
    if FW_ERR="$(/usr/bin/python3 - "$IOS_ARM64_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
with plist_path.open("rb") as f:
    info = plistlib.load(f)

errors = []
required_str = [
    "CFBundleIdentifier",
    "CFBundleExecutable",
    "CFBundlePackageType",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "MinimumOSVersion",
]
for k in required_str:
    val = info.get(k)
    if not isinstance(val, str) or not val.strip():
        errors.append(f"atermius_rdp.framework/Info.plist 缺失必填字符串键: {k}")

if info.get("CFBundleExecutable") != "atermius_rdp":
    errors.append(f"CFBundleExecutable 必须为 'atermius_rdp' (当前: {info.get('CFBundleExecutable')!r})")
if info.get("CFBundlePackageType") != "FMWK":
    errors.append(f"CFBundlePackageType 必须为 'FMWK' (当前: {info.get('CFBundlePackageType')!r})")

platforms = info.get("CFBundleSupportedPlatforms")
if not isinstance(platforms, list) or "iPhoneOS" not in platforms:
    errors.append("CFBundleSupportedPlatforms 必须包含 'iPhoneOS'")
if isinstance(platforms, list) and "iPhoneSimulator" in platforms:
    errors.append("真机切片 CFBundleSupportedPlatforms 严禁包含 'iPhoneSimulator'")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
    )"; then
      gate_pass "atermius_rdp.framework/Info.plist 全部 ITMS-90562 必填元数据完整合法"
    else
      while IFS= read -r err_line; do
        [ -n "$err_line" ] && gate_fail "$err_line"
      done <<< "$FW_ERR"
    fi
  fi

  if [ -d "$IOS_ARM64_FW/_CodeSignature" ]; then
    gate_warn "源 XCFramework 内含历史 _CodeSignature，归档阶段将自动剥离并使用 App Store Distribution 证书重签。"
  fi

  if [ -f "$VERIFY_SCRIPT" ]; then
    if /usr/bin/python3 "$VERIFY_SCRIPT" --platform ios >/dev/null 2>&1; then
      gate_pass "verify_engine.py 验证 C 导出符号表与系统动态库白名单通过"
    else
      gate_fail "verify_engine.py 校验失败，请检查 atermius_rdp.xcframework 动态库依赖"
    fi
  fi
fi

# ==============================================================================
# Gate 6/6: 新 App Bundle ID 唯一性/合法性与 ExportOptions-AppStore.plist 校验
# ==============================================================================
gate_header "[Gate 6/6] 新 App 正式 Bundle ID 防冲突校验与 ExportOptions 配置核验"

if [ -z "$BUNDLE_ID" ]; then
  gate_fail "未提供 --bundle-id！作为新 App 上架必须显式指定在 Apple Developer 后台注册的唯一 Bundle ID（例如: --bundle-id com.yourcompany.newapp）"
elif [[ "$BUNDLE_ID" == *"*"* ]]; then
  gate_fail "拒绝通配符 Bundle ID '$BUNDLE_ID'：App Store Connect 上架必须使用 Explicit App ID"
elif ! [[ "$BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]]; then
  gate_fail "Bundle ID '$BUNDLE_ID' 格式非法：必须为至少两段的合法反向域名标识符（仅含字母、数字、连字符与点）"
else
  case "$BUNDLE_ID" in
    com.atermius.atermClient|com.atermius.atermClient.*|*.RunnerTests|com.example.*|com.yourcompany.*|com.test.*|io.flutter.*)
      gate_fail "拒绝使用旧开发默认冲突或测试占位 Bundle ID '$BUNDLE_ID'！请传入在 Apple Developer 后台为新 App 注册的正式独立 Bundle ID。"
      ;;
    *)
      gate_pass "新 App Bundle ID 校验通过: $BUNDLE_ID"
      ;;
  esac
fi

if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  gate_fail "Apple Developer Team ID '$TEAM_ID' 格式非法（必须为 10 位大写字母或数字，例如 2QJ8K75QL2）"
else
  gate_pass "Apple Developer Team ID 格式合法: $TEAM_ID"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  gate_fail "版本号 --version '$VERSION' 格式非法（必须符合 X.Y 或 X.Y.Z 纯数字格式，如 1.0.0）"
elif ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  gate_fail "构建号 --build-number '$BUILD_NUMBER' 格式非法（必须为正整数，如 1）"
else
  gate_pass "上架版本标识合法: CFBundleShortVersionString=$VERSION, CFBundleVersion=$BUILD_NUMBER"
fi

if [ ! -f "$EXPORT_OPTIONS_PLIST" ]; then
  gate_fail "缺失 App Store 导出配置文件: $EXPORT_OPTIONS_PLIST"
elif ! /usr/bin/plutil -lint "$EXPORT_OPTIONS_PLIST" >/dev/null 2>&1; then
  gate_fail "plutil -lint 校验失败: $EXPORT_OPTIONS_PLIST"
else
  if EXPORT_ERR="$(/usr/bin/python3 - "$EXPORT_OPTIONS_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as f:
    opts = plistlib.load(f)

errors = []
if opts.get("method") != "app-store-connect":
    errors.append(f"ExportOptions method 必须为 'app-store-connect' (当前: {opts.get('method')!r})")
if opts.get("destination") != "export":
    errors.append(f"ExportOptions destination 必须为 'export' (当前: {opts.get('destination')!r})")
if opts.get("signingStyle") != "automatic":
    errors.append(f"ExportOptions signingStyle 必须为 'automatic' (当前: {opts.get('signingStyle')!r})")
if opts.get("uploadSymbols") is not True:
    errors.append("ExportOptions uploadSymbols 必须为 <true/>")
if opts.get("manageAppVersionAndBuildNumber") is not True:
    errors.append("ExportOptions manageAppVersionAndBuildNumber 必须为 <true/>")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
  )"; then
    gate_pass "ExportOptions-AppStore.plist 校验通过 (method=app-store-connect, destination=export, automatic signing, uploadSymbols=true)"
  else
    while IFS= read -r err_line; do
      [ -n "$err_line" ] && gate_fail "$err_line"
    done <<< "$EXPORT_ERR"
  fi
fi

# ==============================================================================
# 汇总 6 道铁闸预检结果
# ==============================================================================
echo ""
echo "======================================================================"
if [ "$PREFLIGHT_FAILURES" -gt 0 ]; then
  echo "  [BLOCKED] App Store 上传前预检未通过：共发现 $PREFLIGHT_FAILURES 项阻断问题！"
  echo "  请先修复上述 [FAIL] 项后再重新执行归档导出。"
  echo "======================================================================"
  exit 1
fi

echo "  [ALL 6 GATES PASSED] App Store Connect 静态合规铁闸全部绿灯通过！"
echo "======================================================================"

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  echo "已指定 --preflight-only，跳过 xcodebuild archive 与 IPA 导出。"
  exit 0
fi

# ==============================================================================
# 正式执行 Flutter Release 配置 + xcodebuild archive + -exportArchive
# ==============================================================================
SAFE_SLUG="$(printf '%s' "${DISPLAY_NAME:-$BUNDLE_ID}" | tr '[:space:].' '--' | tr -cd 'A-Za-z0-9_-')"
if [ -z "$SAFE_SLUG" ]; then
  SAFE_SLUG="AppStoreApp"
fi

ARCHIVE_PATH="$APPSTORE_DIST_DIR/${SAFE_SLUG}-${VERSION}-build${BUILD_NUMBER}.xcarchive"
EXPORT_DIR="$APPSTORE_DIST_DIR/export"
UPLOAD_EXPORT_DIR="$APPSTORE_DIST_DIR/upload"
FINAL_IPA="$APPSTORE_DIST_DIR/${SAFE_SLUG}-${VERSION}-build${BUILD_NUMBER}.ipa"

echo ""
echo "==> [Step 1/5] 准备隔离洁净构建环境..."
rm -rf "$ARCHIVE_DERIVED_DATA" "$ARCHIVE_PATH" "$EXPORT_DIR" "$UPLOAD_EXPORT_DIR"
mkdir -p "$APPSTORE_DIST_DIR" "$EXPORT_DIR"

echo "==> [Step 2/5] 生成 Flutter Release iOS 构建配置 (--no-pub, ATERMIUS_APPSTORE=true)..."
cd "$CLIENT_DIR"
flutter build ios --release --no-pub --config-only \
  --build-name="$VERSION" \
  --build-number="$BUILD_NUMBER" \
  --dart-define=ATERMIUS_APPSTORE=true

echo "==> [Step 3/5] 执行 xcodebuild archive (Bundle ID: $BUNDLE_ID, Team: $TEAM_ID)..."
XCODE_ARCHIVE_ARGS=(
  -workspace "$IOS_DIR/Runner.xcworkspace"
  -scheme Runner
  -configuration Release
  -sdk iphoneos
  -destination "generic/platform=iOS"
  -derivedDataPath "$ARCHIVE_DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  -allowProvisioningUpdates
  "CODE_SIGN_STYLE=Automatic"
  "DEVELOPMENT_TEAM=$TEAM_ID"
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
  "MARKETING_VERSION=$VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "FLUTTER_BUILD_NAME=$VERSION"
  "FLUTTER_BUILD_NUMBER=$BUILD_NUMBER"
)
if [ -d "$CLIENT_DIR/build/ios/SourcePackages" ]; then
  echo "  -> 复用本地 SwiftPM 源码包缓存: $CLIENT_DIR/build/ios/SourcePackages"
  XCODE_ARCHIVE_ARGS+=(-clonedSourcePackagesDirPath "$CLIENT_DIR/build/ios/SourcePackages")
fi

xcodebuild "${XCODE_ARCHIVE_ARGS[@]}" archive

ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/Runner.app"
if [ ! -d "$ARCHIVE_APP" ]; then
  echo "[ERROR] 归档失败：未找到 $ARCHIVE_APP" >&2
  exit 1
fi

# 若传入 --display-name，在不污染源码树的前提下覆写 .xcarchive 内 Info.plist 与四语 InfoPlist.strings，
# 随后由 xcodebuild -exportArchive 统一执行 Apple Distribution 重签名与 CodeResources 哈希封装。
if [ -n "$DISPLAY_NAME" ]; then
  echo "==> [Step 3b/5] 注入新 App 显示名称 (--display-name '$DISPLAY_NAME')..."
  /usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$ARCHIVE_APP/Info.plist"
  /usr/bin/plutil -replace CFBundleName -string "$DISPLAY_NAME" "$ARCHIVE_APP/Info.plist"
  /usr/bin/plutil -lint "$ARCHIVE_APP/Info.plist" >/dev/null
  for lproj_dir in "$ARCHIVE_APP"/*.lproj; do
    if [ -f "$lproj_dir/InfoPlist.strings" ]; then
      /usr/bin/plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$lproj_dir/InfoPlist.strings"
      /usr/bin/plutil -replace CFBundleName -string "$DISPLAY_NAME" "$lproj_dir/InfoPlist.strings"
      /usr/bin/plutil -lint "$lproj_dir/InfoPlist.strings" >/dev/null
    fi
  done
fi

echo "==> [Step 4/5] 执行 .xcarchive 归档产物洁净度与完整性门禁断言..."
if [ ! -f "$ARCHIVE_APP/PrivacyInfo.xcprivacy" ]; then
  echo "[ERROR] 归档阻断：$ARCHIVE_APP/PrivacyInfo.xcprivacy 缺失 (ITMS-91053)！" >&2
  exit 1
fi
if [ ! -f "$ARCHIVE_APP/Frameworks/atermius_rdp.framework/atermius_rdp" ]; then
  echo "[ERROR] 归档阻断：$ARCHIVE_APP 内未嵌入 atermius_rdp.framework！" >&2
  exit 1
fi
ARCHIVE_FW_ARCH="$(/usr/bin/lipo -archs "$ARCHIVE_APP/Frameworks/atermius_rdp.framework/atermius_rdp" | xargs)"
if [ "$ARCHIVE_FW_ARCH" != "arm64" ]; then
  echo "[ERROR] 归档阻断：嵌入的 atermius_rdp.framework 架构异常 ($ARCHIVE_FW_ARCH != arm64)！" >&2
  exit 1
fi

ARCHIVE_LEAKS="$(
  find "$ARCHIVE_APP" -type f \( \
    -name "atermius-local-seed.json" -o \
    -name "atermius-auto-import.json" -o \
    -name "termius-export*" -o \
    -name "termius-hosts*" -o \
    -name "termius-labeled-hosts*" -o \
    -name "termius-openssh-bundle*" -o \
    -name "ssh_config" \
  \) -print 2>/dev/null || true
)"
if [ -n "$ARCHIVE_LEAKS" ]; then
  echo "[ERROR] 严重安全阻断：.xcarchive 内检测到私有种子/主机导出文件！" >&2
  echo "$ARCHIVE_LEAKS" >&2
  rm -rf "$ARCHIVE_PATH"
  exit 1
fi

TOP_LEVEL_JSON="$(find "$ARCHIVE_APP" -maxdepth 1 -type f -name "*.json" -print 2>/dev/null || true)"
if [ -n "$TOP_LEVEL_JSON" ]; then
  echo "[ERROR] 归档阻断：Runner.app 顶层存在未授权 JSON 文件：" >&2
  echo "$TOP_LEVEL_JSON" >&2
  exit 1
fi

echo "==> [Step 5/5] 执行 xcodebuild -exportArchive 导出正式 App Store Connect IPA..."
RUNTIME_EXPORT_PLIST="$(mktemp "${TMPDIR:-/tmp}/ExportOptions-AppStore.XXXXXX.plist")"
RUNTIME_UPLOAD_PLIST=""
trap 'rm -f "$RUNTIME_EXPORT_PLIST" "${RUNTIME_UPLOAD_PLIST:-}"' EXIT
cp -f "$EXPORT_OPTIONS_PLIST" "$RUNTIME_EXPORT_PLIST"
/usr/bin/plutil -replace teamID -string "$TEAM_ID" "$RUNTIME_EXPORT_PLIST"
/usr/bin/plutil -lint "$RUNTIME_EXPORT_PLIST" >/dev/null

EXPORT_RC=0
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$RUNTIME_EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates || EXPORT_RC=$?

LOCAL_IPA_READY=0
if [ "$EXPORT_RC" -eq 0 ]; then
  EXPORTED_IPA="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name "*.ipa" | head -n 1)"
  if [ -z "$EXPORTED_IPA" ] || [ ! -f "$EXPORTED_IPA" ]; then
    echo "[ERROR] 导出失败：$EXPORT_DIR 下未生成 .ipa 文件！" >&2
    exit 1
  fi

  cp -f "$EXPORTED_IPA" "$FINAL_IPA"

  # 对最终导出的 .ipa 执行条目级黑白名单终检
  IPA_ENTRIES="$(/usr/bin/unzip -Z1 "$FINAL_IPA")"
  for required_entry in \
    "Payload/Runner.app/Info.plist" \
    "Payload/Runner.app/PrivacyInfo.xcprivacy" \
    "Payload/Runner.app/_CodeSignature/CodeResources"; do
    if ! printf '%s\n' "$IPA_ENTRIES" | grep -Fxq "$required_entry"; then
      echo "[ERROR] IPA 终检失败：缺失关键条目 $required_entry ($FINAL_IPA)" >&2
      exit 1
    fi
  done

  if printf '%s\n' "$IPA_ENTRIES" | grep -Eq '(^|/)(atermius-local-seed\.json|atermius-auto-import\.json|termius-export[^/]*|termius-hosts[^/]*|termius-labeled-hosts[^/]*|termius-openssh-bundle[^/]*|ssh_config)$|^Payload/Runner\.app/[^/]+\.json$'; then
    echo "[ERROR] 严重安全阻断：导出的 IPA 内检测到敏感文件或未知顶层 JSON！" >&2
    rm -f "$FINAL_IPA" "$EXPORTED_IPA"
    exit 1
  fi

  if printf '%s\n' "$IPA_ENTRIES" | grep -Eq '^Payload/Runner\.app/Frameworks/Flutter\.framework/(Headers|Modules)/'; then
    echo "[ERROR] IPA 终检失败：Flutter.framework 残留 Headers/Modules 目录！" >&2
    exit 1
  fi

  (cd "$APPSTORE_DIST_DIR" && shasum -a 256 "$(basename "$FINAL_IPA")" > "$(basename "$FINAL_IPA").sha256")
  LOCAL_IPA_READY=1
else
  echo "[WARN] 本地 IPA 导出阶段返回退出码 $EXPORT_RC。" >&2
  echo "  -> 合规洁净 .xcarchive 已完整就绪于: $ARCHIVE_PATH" >&2
  if [ "$UPLOAD_TO_ASC" -eq 0 ]; then
    echo "  -> 可直接双击上述 .xcarchive 在 Xcode Organizer 点击 Distribute App 自动创建云端证书并上传。" >&2
    exit "$EXPORT_RC"
  fi
  echo "  -> 已指定 --upload，继续尝试使用 destination=upload 执行云端自动签名直传 App Store Connect..." >&2
fi

UPLOAD_RC=0
if [ "$UPLOAD_TO_ASC" -eq 1 ]; then
  echo ""
  echo "==> [Step 5b/5] 执行 xcodebuild -exportArchive (destination=upload) 直传 App Store Connect..."
  mkdir -p "$UPLOAD_EXPORT_DIR"
  RUNTIME_UPLOAD_PLIST="$(mktemp "${TMPDIR:-/tmp}/ExportOptions-AppStore-Upload.XXXXXX.plist")"
  cp -f "$EXPORT_OPTIONS_PLIST" "$RUNTIME_UPLOAD_PLIST"
  /usr/bin/plutil -replace teamID -string "$TEAM_ID" "$RUNTIME_UPLOAD_PLIST"
  /usr/bin/plutil -replace destination -string upload "$RUNTIME_UPLOAD_PLIST"
  /usr/bin/plutil -lint "$RUNTIME_UPLOAD_PLIST" >/dev/null

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$RUNTIME_UPLOAD_PLIST" \
    -exportPath "$UPLOAD_EXPORT_DIR" \
    -allowProvisioningUpdates || UPLOAD_RC=$?
fi

if [ "$UPLOAD_TO_ASC" -eq 1 ] && [ "$UPLOAD_RC" -ne 0 ]; then
  echo "" >&2
  echo "======================================================================" >&2
  echo "  [UPLOAD ATTENTION] App Store Connect 直传返回退出码 $UPLOAD_RC" >&2
  echo "======================================================================" >&2
  echo "  XCArchive (已过门禁) : $ARCHIVE_PATH" >&2
  if [ "$LOCAL_IPA_READY" -eq 1 ]; then
    echo "  本地洁净 IPA 备份    : $FINAL_IPA" >&2
    echo "  SHA-256 校验         : $FINAL_IPA.sha256" >&2
  fi
  echo "  Bundle ID            : $BUNDLE_ID (Team: $TEAM_ID)" >&2
  echo "  版本信息             : $VERSION ($BUILD_NUMBER)" >&2
  echo "  提示：请检查上方 xcodebuild 输出的 App Store Connect 具体返回信息" >&2
  echo "  （如尚未在 App Store Connect 网页创建该 Bundle ID 的新 App 记录，或需在 Xcode Organizer 点 Distribute App 授权创建 Apple Distribution 证书）。" >&2
  echo "======================================================================" >&2
  exit "$UPLOAD_RC"
fi

if [ "$LOCAL_IPA_READY" -eq 0 ] && [ "$EXPORT_RC" -ne 0 ] && [ "$UPLOAD_TO_ASC" -eq 0 ]; then
  exit "$EXPORT_RC"
fi

echo ""
echo "======================================================================"
if [ "$UPLOAD_TO_ASC" -eq 1 ]; then
  echo "  [SUCCESS] App Store Connect 正式上架包构建、洁净度终检与直传全部完成！"
else
  echo "  [SUCCESS] App Store Connect 正式上架包构建与洁净度验证全部完成！"
fi
echo "======================================================================"
if [ "$LOCAL_IPA_READY" -eq 1 ]; then
  echo "  IPA 路径     : $FINAL_IPA"
  echo "  SHA-256 校验 : $FINAL_IPA.sha256"
fi
echo "  XCArchive    : $ARCHIVE_PATH"
echo "  Bundle ID    : $BUNDLE_ID (Team: $TEAM_ID)"
echo "  版本信息     : $VERSION ($BUILD_NUMBER)"
if [ "$UPLOAD_TO_ASC" -eq 1 ]; then
  echo "  ASC 直传状态 : 已通过 destination=upload 成功提交至 App Store Connect"
else
  echo ""
  echo "  上传方式 A — 脚本一键直传 App Store Connect："
  echo "    重新附加 --upload 参数运行本脚本，或使用下方已导出的洁净 IPA："
  echo ""
  echo "  上传方式 B — Apple Transporter App (推荐图形化上传)："
  echo "    直接打开 macOS 上的 Transporter.app，将以下文件拖入窗口并点击“交付”："
  echo "    $FINAL_IPA"
  echo ""
  echo "  上传方式 C — App Store Connect API 命令行上传 (xcrun altool)："
  echo "    xcrun altool --upload-app --type ios \\"
  echo "      -f \"$FINAL_IPA\" \\"
  echo "      --apiKey <YOUR_ASC_KEY_ID> \\"
  echo "      --apiIssuer <YOUR_ASC_ISSUER_ID>"
fi
echo "======================================================================"
