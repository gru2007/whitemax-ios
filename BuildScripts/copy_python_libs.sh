#!/bin/bash
set -e

# Скрипт для копирования Python стандартной библиотеки и pymax в app bundle

PROJECT_DIR="${PROJECT_DIR:-${SRCROOT}}"
PYMAX_DIR="${PROJECT_DIR}/pymax"
PYTHON_XCFRAMEWORK="${PROJECT_DIR}/Python.xcframework"
# Корень app bundle (WhiteMax.app). В Archive/Install это MUST быть внутри .app
if [ -n "${WRAPPER_NAME}" ]; then
    BUNDLE_ROOT="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
else
    BUNDLE_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
fi

# App python content lives in <App>.app/app
APP_DIR="${BUNDLE_ROOT}/app"

# Frameworks директория MUST быть внутри app bundle: <App>.app/Frameworks
FRAMEWORKS_DIR="${BUNDLE_ROOT}/Frameworks"

echo "Copying Python libraries..."
echo "PROJECT_DIR: ${PROJECT_DIR}"
echo "APP_DIR: ${APP_DIR}"

# Определяем identity для подписи один раз
SIGN_IDENTITY="${CODE_SIGN_IDENTITY}"
if [ -z "${SIGN_IDENTITY}" ] || [ "${SIGN_IDENTITY}" == "" ]; then
    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
fi
if [ -z "${SIGN_IDENTITY}" ] || [ "${SIGN_IDENTITY}" == "" ]; then
    SIGN_IDENTITY="-"
    echo "Using ad-hoc code signing (-)"
else
    echo "Using code signing identity: ${SIGN_IDENTITY}"
fi

# --- Helpers for App Store compliance ---
# iOS App Store policy: бинарные Python-модули (.so) нельзя хранить прямо на sys.path.
# Они должны быть упакованы как .framework в папке Frameworks, а на месте .so должен быть .fwork marker.
# См. Python docs (AppleFrameworkLoader) и требования Apple.
sanitize_bundle_id_component() {
    # Convert any unsupported characters for CFBundleIdentifier component.
    # Allowed: A-Z a-z 0-9 . -
    echo "$1" | sed -E 's/[^A-Za-z0-9\.\-]/-/g'
}

strip_extension_suffix() {
    # Strip Python extension suffix from filename to obtain module basename.
    # Examples:
    #   _socket.cpython-312-iphoneos.so -> _socket
    #   _whiz.abi3.so -> _whiz
    local fname="$1"
    fname="${fname%.so}"
    fname="${fname%.abi3}"
    # Remove cpython tag if present
    fname="$(echo "$fname" | sed -E 's/\.cpython-[0-9]+-(iphoneos|iphonesimulator)$//')"
    echo "$fname"
}

derive_module_dotted_name() {
    # Determine module import dotted name from a .so absolute path.
    # - lib-dynload: _socket.cpython-...so -> _socket
    # - site-packages: lz4/block/_block.cpython-...so -> lz4.block._block
    local so_path="$1"
    local rel=""
    local dotted=""

    if [[ "$so_path" == *"/site-packages/"* ]]; then
        rel="${so_path#*"/site-packages/"}"
        # Remove suffix
        local base="${rel##*/}"
        local base_noext
        base_noext="$(strip_extension_suffix "$base")"
        local dir="${rel%/*}"
        if [ "$dir" == "$rel" ]; then
            dotted="$base_noext"
        else
            dotted="$(echo "$dir" | tr '/' '.')"
            dotted="${dotted}.${base_noext}"
        fi
    else
        # lib-dynload or other root: use basename
        local base="${so_path##*/}"
        dotted="$(strip_extension_suffix "$base")"
    fi

    echo "$dotted"
}

process_python_binary_module() {
    local so_path="$1"

    # Skip macOS binaries
    if echo "$so_path" | grep -qiE 'darwin|macosx'; then
        echo "Skipping macOS binary: ${so_path}"
        return 0
    fi

    local dotted
    dotted="$(derive_module_dotted_name "$so_path")"

    if [ -z "$dotted" ]; then
        echo "Warning: Could not derive module name for $so_path"
        return 0
    fi

    local framework_dir="${FRAMEWORKS_DIR}/${dotted}.framework"
    local framework_bin="${framework_dir}/${dotted}"
    local framework_plist="${framework_dir}/Info.plist"
    local framework_privacy_manifest="${framework_dir}/PrivacyInfo.xcprivacy"

    # App Store validation requires MinimumOSVersion in every embedded framework Info.plist.
    # Prefer the app deployment target provided by Xcode; fall back to Python's minimum (matches Python.xcframework).
    local min_os_version="${IPHONEOS_DEPLOYMENT_TARGET}"
    if [ -z "${min_os_version}" ]; then
        min_os_version="13.0"
    fi

    # Use correct supported platform for the current build.
    local supported_platform="iPhoneOS"
    if [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
        supported_platform="iPhoneSimulator"
    fi

    # The .fwork marker must replace the original .so on sys.path.
    local fwork_path="${so_path%.so}.fwork"

    # .origin file must sit next to the binary; AppleFrameworkLoader reads "<binary>.origin"
    local origin_path="${framework_bin}.origin"

    # Relative paths are relative to the app bundle root (bundle_path = dirname(sys.executable))
    local fwork_rel="${fwork_path#${BUNDLE_ROOT}/}"
    local framework_bin_rel="Frameworks/${dotted}.framework/${dotted}"

    mkdir -p "${FRAMEWORKS_DIR}"
    mkdir -p "${framework_dir}"

    # Move the actual binary into the framework (rename from *.so to framework executable name)
    if [ -f "${framework_bin}" ]; then
        rm -f "${framework_bin}" 2>/dev/null || true
    fi
    mv "${so_path}" "${framework_bin}"
    chmod 755 "${framework_bin}" 2>/dev/null || true

    # Write Info.plist for the framework
    local bundle_id_component
    bundle_id_component="$(sanitize_bundle_id_component "${dotted}")"
    cat > "${framework_plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${dotted}</string>
  <key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.python.${bundle_id_component}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${dotted}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>${supported_platform}</string>
  </array>
  <key>MinimumOSVersion</key><string>${min_os_version}</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
EOF

    # Apple (ITMS-91061) requires a privacy manifest for certain commonly-used SDK signatures (e.g. BoringSSL)
    # that may be detected inside these Python extension modules (notably _ssl, _hashlib).
    # We provide a conservative manifest declaring no tracking, no collected data, and no "required reason" APIs.
    cat > "${framework_privacy_manifest}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array/>
</dict>
</plist>
EOF

    # Write .origin file (relative path to .fwork marker)
    echo "${fwork_rel}" > "${origin_path}"

    # Write .fwork marker file (relative path to framework binary)
    echo "${framework_bin_rel}" > "${fwork_path}"

    # codesign framework binary and framework bundle
    codesign --force --sign "${SIGN_IDENTITY}" "${framework_bin}" 2>/dev/null || true
    codesign --force --sign "${SIGN_IDENTITY}" "${framework_dir}" 2>/dev/null || true

    echo "✓ Packaged binary module: ${dotted} (framework + fwork marker)"
}

process_all_python_binaries() {
    echo ""
    echo "Processing Python binary modules (.so) into Frameworks/ + .fwork markers (App Store compliance)..."
    mkdir -p "${FRAMEWORKS_DIR}"

    # 1) Purge any macOS binaries accidentally installed into site-packages
    if [ -d "${SITE_PACKAGES_DIR}" ]; then
        echo "Purging macOS binaries from site-packages..."
        find "${SITE_PACKAGES_DIR}" -type f -name "*.so" | grep -iE 'darwin|macosx|cpython-39-darwin|cpython-312-darwin' | while read -r mac_so; do
            echo "  Removing macOS binary: ${mac_so}"
            rm -f "${mac_so}" 2>/dev/null || true
        done
    fi

    # 2) Convert remaining .so files (stdlib lib-dynload + iOS wheels like lz4) into frameworks
    # Stdlib binaries
    local dynload_dir="${PYTHON_LIB_DEST}/lib-dynload"
    if [ -d "${dynload_dir}" ]; then
        find "${dynload_dir}" -type f -name "*.so" | while read -r so_file; do
            process_python_binary_module "${so_file}"
        done
    fi

    # Third-party binaries
    if [ -d "${SITE_PACKAGES_DIR}" ]; then
        find "${SITE_PACKAGES_DIR}" -type f -name "*.so" | while read -r so_file; do
            process_python_binary_module "${so_file}"
        done
    fi

    echo "✓ Python binary module processing completed"
    echo ""

    # 3) Safety check: ensure no standalone .so remain outside Frameworks
    echo "Verifying no standalone .so remain outside Frameworks..."
    remaining_so=$(find "${BUNDLE_ROOT}" -type f -name "*.so" ! -path "${FRAMEWORKS_DIR}/*" 2>/dev/null | head -50)
    if [ -n "${remaining_so}" ]; then
        # In DEBUG builds, standalone .so files are allowed (development only)
        # If CONFIGURATION is not set, treat as RELEASE for safety
        if [ "${CONFIGURATION}" = "Debug" ]; then
            echo "⚠️  WARNING: Found standalone .so files outside Frameworks (allowed in DEBUG builds):"
            echo "${remaining_so}"
            echo "Note: These will cause App Store rejection in RELEASE builds."
        else
            echo "❌ ERROR: Found standalone .so files outside Frameworks (App Store will reject):"
            echo "${remaining_so}"
            echo "Please ensure all third-party binaries are iOS-compatible and processed into frameworks."
            exit 1
        fi
    else
        echo "✓ No standalone .so files remain outside Frameworks"
    fi
}
# Создаем директорию app в bundle если её нет
mkdir -p "${APP_DIR}"

# Определяем путь к Python платформе в зависимости от архитектуры
if [[ "$PLATFORM_NAME" == "iphonesimulator" ]]; then
    PYTHON_PLATFORM="${PYTHON_XCFRAMEWORK}/ios-arm64_x86_64-simulator"
    PYTHON_FRAMEWORK="${PYTHON_PLATFORM}/Python.framework"
else
    PYTHON_PLATFORM="${PYTHON_XCFRAMEWORK}/ios-arm64"
    PYTHON_FRAMEWORK="${PYTHON_PLATFORM}/Python.framework"
fi

if [ ! -d "${PYTHON_FRAMEWORK}" ]; then
    echo "Error: Python.framework not found at ${PYTHON_FRAMEWORK}"
    exit 1
fi

# Копируем Python стандартную библиотеку
# В xcframework стандартная библиотека находится в lib/python3.13, а не в Python.framework/lib
PYTHON_LIB="${PYTHON_PLATFORM}/lib/python3.13"
PYTHON_LIB_DEST="${APP_DIR}/python/lib/python3.13"

if [ -d "${PYTHON_LIB}" ]; then
    echo "Copying Python standard library from ${PYTHON_LIB}..."
    mkdir -p "${APP_DIR}/python/lib"
    cp -R "${PYTHON_LIB}" "${PYTHON_LIB_DEST}"
    
    # Копируем platform-config если есть
    PLATFORM_CONFIG="${PYTHON_PLATFORM}/platform-config"
    if [ -d "${PLATFORM_CONFIG}" ]; then
        mkdir -p "${APP_DIR}/python/platform-config"
        cp -R "${PLATFORM_CONFIG}"/* "${APP_DIR}/python/platform-config/"
    fi
    
    # Подписываем все бинарные модули (.so файлы) в lib-dynload
    # iOS требует, чтобы все динамические библиотеки были подписаны кодом
    LIB_DYNLOAD_DIR="${PYTHON_LIB_DEST}/lib-dynload"
    if [ -d "${LIB_DYNLOAD_DIR}" ]; then
        echo "Code signing Python binary modules in lib-dynload..."
        
        # Подписываем все .so файлы
        # Используем while loop правильно с find
        so_files=($(find "${LIB_DYNLOAD_DIR}" -name "*.so" -type f))
        if [ ${#so_files[@]} -eq 0 ]; then
            echo "  Warning: No .so files found in lib-dynload"
        else
            for so_file in "${so_files[@]}"; do
                echo "  Signing: $(basename "${so_file}")"
                codesign --force --sign "${SIGN_IDENTITY}" "${so_file}" 2>&1 || true
            done
        fi
        echo "✓ Python binary modules signed successfully"
    fi
    
    echo "✓ Python standard library copied successfully"
else
    echo "Error: Python library not found at ${PYTHON_LIB}"
    exit 1
fi

# Устанавливаем зависимости pymax в site-packages
# Это нужно сделать до копирования pymax, так как pymax зависит от этих библиотек
SITE_PACKAGES_DIR="${APP_DIR}/python/lib/python3.13/site-packages"
if [ -d "${PYTHON_LIB_DEST}" ]; then
    echo "Installing pymax dependencies to site-packages..."
    mkdir -p "${SITE_PACKAGES_DIR}"
    
    # Используем системный Python для установки зависимостей pymax
    # Устанавливаем все зависимости из pyproject.toml
    # Некоторые пакеты могут содержать бинарные модули, которые нужно собрать для iOS отдельно
    
    # Сначала проверяем наличие собранных iOS wheels (до проверки pip)
    WHEEL_DIR="${PROJECT_DIR}/BuildScripts"
    LZ4_WHEEL=$(find "${WHEEL_DIR}" -name "lz4-*.whl" -type f 2>/dev/null | head -1)
    PYDANTIC_CORE_WHEEL=$(find "${WHEEL_DIR}" -name "pydantic_core-*.whl" -type f 2>/dev/null | head -1)
    MSGPACK_WHEEL=$(find "${WHEEL_DIR}" -name "msgpack-*.whl" -type f 2>/dev/null | head -1)
    
    # Проверяем наличие pip
    if command -v pip3 &> /dev/null || python3 -m pip --version &> /dev/null; then
        echo "Installing pymax dependencies..."
        
        # Определяем, нужны ли бинарные модули для iOS (исключаем из pip установки на iOS)
        INSTALL_LZ4_VIA_PIP=true
        INSTALL_PYDANTIC_CORE_VIA_PIP=true
        INSTALL_MSGPACK_VIA_PIP=true
        if [ "${PLATFORM_NAME}" = "iphoneos" ] || [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
            INSTALL_LZ4_VIA_PIP=false
            INSTALL_PYDANTIC_CORE_VIA_PIP=false
            INSTALL_MSGPACK_VIA_PIP=false
            
            # Устанавливаем lz4 iOS wheel
            if [ -n "${LZ4_WHEEL}" ]; then
                echo "Found pre-built lz4 wheel: $(basename "${LZ4_WHEEL}")"
                echo "Installing iOS-compatible lz4 wheel..."
                
                # Распаковываем iOS wheel вручную, так как pip не может установить iOS wheels на macOS
                echo "Extracting iOS lz4 wheel manually (pip cannot install iOS wheels on macOS)..."
                TEMP_WHEEL_DIR=$(mktemp -d)
                trap "rm -rf ${TEMP_WHEEL_DIR}" EXIT 2>/dev/null || true
                
                # Распаковываем wheel (wheel - это zip файл)
                if unzip -q "${LZ4_WHEEL}" -d "${TEMP_WHEEL_DIR}" 2>/dev/null; then
                    # Wheel содержит папку с именем пакета (lz4) и dist-info
                    # Ищем папку lz4 в распакованном wheel
                    WHEEL_LZ4_DIR=$(find "${TEMP_WHEEL_DIR}" -type d -name "lz4" | head -1)
                    WHEEL_DIST_INFO=$(find "${TEMP_WHEEL_DIR}" -type d -name "*.dist-info" | head -1)
                    
                    if [ -n "${WHEEL_LZ4_DIR}" ] && [ -d "${WHEEL_LZ4_DIR}" ]; then
                        # Создаем site-packages директорию если её нет
                        mkdir -p "${SITE_PACKAGES_DIR}"
                        
                        # Копируем lz4 модуль в site-packages
                        cp -R "${WHEEL_LZ4_DIR}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        
                        # Копируем dist-info если есть
                        if [ -n "${WHEEL_DIST_INFO}" ]; then
                            cp -R "${WHEEL_DIST_INFO}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        fi
                        
                        # Проверяем что iOS бинарники скопировались
                        IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/lz4" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ')
                        if [ "${IOS_BINARIES}" -gt 0 ]; then
                            echo "✓ iOS lz4 wheel extracted successfully (${IOS_BINARIES} iOS binary modules found)"
                            INSTALL_LZ4_VIA_PIP=false
                        elif [ -d "${SITE_PACKAGES_DIR}/lz4" ]; then
                            echo "⚠️  Warning: lz4 extracted but no iOS binaries found"
                            INSTALL_LZ4_VIA_PIP=true
                        else
                            echo "⚠️  Warning: Failed to extract lz4 from wheel"
                            INSTALL_LZ4_VIA_PIP=true
                        fi
                    else
                        echo "⚠️  Warning: Could not find lz4 directory in wheel"
                        INSTALL_LZ4_VIA_PIP=true
                    fi
                    
                    # Очищаем временную директорию
                    rm -rf "${TEMP_WHEEL_DIR}"
                else
                    echo "⚠️  Warning: Failed to extract wheel file"
                    INSTALL_LZ4_VIA_PIP=true
                fi
            else
                echo "⚠️  Warning: No pre-built lz4 wheel found in BuildScripts/"
                echo "  Looking for: ${WHEEL_DIR}/lz4-*.whl"
                echo "  lz4 will not work on iOS without a pre-built wheel"
            fi
            
            # Устанавливаем pydantic-core iOS wheel
            if [ -n "${PYDANTIC_CORE_WHEEL}" ]; then
                echo "Found pre-built pydantic-core wheel: $(basename "${PYDANTIC_CORE_WHEEL}")"
                echo "Installing iOS-compatible pydantic-core wheel..."
                
                # Распаковываем iOS wheel вручную, так как pip не может установить iOS wheels на macOS
                echo "Extracting iOS pydantic-core wheel manually (pip cannot install iOS wheels on macOS)..."
                TEMP_WHEEL_DIR=$(mktemp -d)
                trap "rm -rf ${TEMP_WHEEL_DIR}" EXIT 2>/dev/null || true
                
                # Распаковываем wheel (wheel - это zip файл)
                if unzip -q "${PYDANTIC_CORE_WHEEL}" -d "${TEMP_WHEEL_DIR}" 2>/dev/null; then
                    # Wheel содержит папку с именем пакета (pydantic_core) и dist-info
                    # Ищем папку pydantic_core в распакованном wheel
                    WHEEL_PYDANTIC_CORE_DIR=$(find "${TEMP_WHEEL_DIR}" -type d -name "pydantic_core" | head -1)
                    WHEEL_DIST_INFO=$(find "${TEMP_WHEEL_DIR}" -type d -name "*.dist-info" | head -1)
                    
                    if [ -n "${WHEEL_PYDANTIC_CORE_DIR}" ] && [ -d "${WHEEL_PYDANTIC_CORE_DIR}" ]; then
                        # Создаем site-packages директорию если её нет
                        mkdir -p "${SITE_PACKAGES_DIR}"
                        
                        # Копируем pydantic_core модуль в site-packages
                        cp -R "${WHEEL_PYDANTIC_CORE_DIR}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        
                        # Копируем dist-info если есть
                        if [ -n "${WHEEL_DIST_INFO}" ]; then
                            cp -R "${WHEEL_DIST_INFO}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        fi
                        
                        # Проверяем что iOS бинарники скопировались
                        IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ')
                        if [ "${IOS_BINARIES}" -gt 0 ]; then
                            echo "✓ iOS pydantic-core wheel extracted successfully (${IOS_BINARIES} iOS binary modules found)"
                            INSTALL_PYDANTIC_CORE_VIA_PIP=false
                        elif [ -d "${SITE_PACKAGES_DIR}/pydantic_core" ]; then
                            echo "⚠️  Warning: pydantic-core extracted but no iOS binaries found"
                            INSTALL_PYDANTIC_CORE_VIA_PIP=true
                        else
                            echo "⚠️  Warning: Failed to extract pydantic-core from wheel"
                            INSTALL_PYDANTIC_CORE_VIA_PIP=true
                        fi
                    else
                        echo "⚠️  Warning: Could not find pydantic_core directory in wheel"
                        INSTALL_PYDANTIC_CORE_VIA_PIP=true
                    fi
                    
                    # Очищаем временную директорию
                    rm -rf "${TEMP_WHEEL_DIR}"
                else
                    echo "⚠️  Warning: Failed to extract wheel file"
                    INSTALL_PYDANTIC_CORE_VIA_PIP=true
                fi
            else
                echo "⚠️  ⚠️  ⚠️  WARNING: No pre-built pydantic-core wheel found in BuildScripts/"
                echo "  Looking for: ${WHEEL_DIR}/pydantic_core-*.whl"
                echo "  ⚠️  CRITICAL: pydantic/sqlmodel will NOT work on iOS without iOS-compatible pydantic-core"
                INSTALL_PYDANTIC_CORE_VIA_PIP=true
            fi
            
            # Устанавливаем msgpack iOS wheel
            if [ -n "${MSGPACK_WHEEL}" ]; then
                echo "Found pre-built msgpack wheel: $(basename "${MSGPACK_WHEEL}")"
                echo "Installing iOS-compatible msgpack wheel..."
                
                # Распаковываем iOS wheel вручную, так как pip не может установить iOS wheels на macOS
                echo "Extracting iOS msgpack wheel manually (pip cannot install iOS wheels on macOS)..."
                TEMP_WHEEL_DIR=$(mktemp -d)
                trap "rm -rf ${TEMP_WHEEL_DIR}" EXIT 2>/dev/null || true
                
                # Распаковываем wheel (wheel - это zip файл)
                if unzip -q "${MSGPACK_WHEEL}" -d "${TEMP_WHEEL_DIR}" 2>/dev/null; then
                    # Wheel содержит папку с именем пакета (msgpack) и dist-info
                    # Ищем папку msgpack в распакованном wheel
                    WHEEL_MSGPACK_DIR=$(find "${TEMP_WHEEL_DIR}" -type d -name "msgpack" | head -1)
                    WHEEL_DIST_INFO=$(find "${TEMP_WHEEL_DIR}" -type d -name "*.dist-info" | head -1)
                    
                    if [ -n "${WHEEL_MSGPACK_DIR}" ] && [ -d "${WHEEL_MSGPACK_DIR}" ]; then
                        # Создаем site-packages директорию если её нет
                        mkdir -p "${SITE_PACKAGES_DIR}"
                        
                        # Копируем msgpack модуль в site-packages
                        cp -R "${WHEEL_MSGPACK_DIR}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        
                        # Копируем dist-info если есть
                        if [ -n "${WHEEL_DIST_INFO}" ]; then
                            cp -R "${WHEEL_DIST_INFO}" "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
                        fi
                        
                        # Проверяем что iOS бинарники скопировались
                        IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/msgpack" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ')
                        if [ "${IOS_BINARIES}" -gt 0 ]; then
                            echo "✓ iOS msgpack wheel extracted successfully (${IOS_BINARIES} iOS binary modules found)"
                            INSTALL_MSGPACK_VIA_PIP=false
                        elif [ -d "${SITE_PACKAGES_DIR}/msgpack" ]; then
                            echo "⚠️  Warning: msgpack extracted but no iOS binaries found"
                            INSTALL_MSGPACK_VIA_PIP=true
                        else
                            echo "⚠️  Warning: Failed to extract msgpack from wheel"
                            INSTALL_MSGPACK_VIA_PIP=true
                        fi
                    else
                        echo "⚠️  Warning: Could not find msgpack directory in wheel"
                        INSTALL_MSGPACK_VIA_PIP=true
                    fi
                    
                    # Очищаем временную директорию
                    rm -rf "${TEMP_WHEEL_DIR}"
                else
                    echo "⚠️  Warning: Failed to extract wheel file"
                    INSTALL_MSGPACK_VIA_PIP=true
                fi
            else
                echo "⚠️  Warning: No pre-built msgpack wheel found in BuildScripts/"
                echo "  Looking for: ${WHEEL_DIR}/msgpack-*.whl"
                echo "  msgpack will use pure-Python fallback on iOS without a pre-built wheel"
                INSTALL_MSGPACK_VIA_PIP=true
            fi
        elif [ -n "${LZ4_WHEEL}" ] || [ -n "${PYDANTIC_CORE_WHEEL}" ] || [ -n "${MSGPACK_WHEEL}" ]; then
            if [ -n "${LZ4_WHEEL}" ]; then
                echo "Found pre-built lz4 wheel, but platform is ${PLATFORM_NAME} (not iOS)"
                echo "Will install lz4 via pip for ${PLATFORM_NAME}"
            fi
            if [ -n "${PYDANTIC_CORE_WHEEL}" ]; then
                echo "Found pre-built pydantic-core wheel, but platform is ${PLATFORM_NAME} (not iOS)"
                echo "Will install pydantic-core via pip for ${PLATFORM_NAME}"
            fi
            if [ -n "${MSGPACK_WHEEL}" ]; then
                echo "Found pre-built msgpack wheel, but platform is ${PLATFORM_NAME} (not iOS)"
                echo "Will install msgpack via pip for ${PLATFORM_NAME}"
            fi
        fi
        
        # Создаем временную директорию для установки
        TEMP_DEPS_DIR=$(mktemp -d)
        trap "rm -rf ${TEMP_DEPS_DIR}" EXIT 2>/dev/null || true
        
        # Устанавливаем все зависимости из pyproject.toml pymax одной командой
        # pip автоматически установит все транзитивные зависимости
        echo "Installing pymax dependencies (this may take a while)..."
        
        # Основные зависимости из pyproject.toml
        # pip автоматически установит все подзависимости (sqlalchemy через sqlmodel, и т.д.)
        # Устанавливаем pure-Python версии где возможно, чтобы избежать проблем с бинарными модулями
        # lz4 необходим для Socket клиента (распаковка сжатых данных)
        # ВАЖНО: lz4 требует C расширений, которые нужно компилировать для iOS отдельно
        # На iOS бинарники из macOS не будут работать
        if [ "${INSTALL_LZ4_VIA_PIP}" = "true" ]; then
            PYMAX_DEPS="requests sqlmodel>=0.0.24 websockets>=15.0 msgpack>=1.1.1 aiohttp>=3.12.15 aiofiles>=24.1.0 qrcode>=8.2 ua-generator>=2.0.19 lz4>=4.4.4"
        else
            # Исключаем lz4 из установки через pip на iOS, так как используем pre-built wheel
            PYMAX_DEPS="requests sqlmodel>=0.0.24 websockets>=15.0 msgpack>=1.1.1 aiohttp>=3.12.15 aiofiles>=24.1.0 qrcode>=8.2 ua-generator>=2.0.19"
            echo "Skipping lz4 in pip install (using pre-built iOS wheel)"
        fi
        
        if [ "${INSTALL_LZ4_VIA_PIP}" = "true" ]; then
            echo "Installing dependencies (including binaries for macOS, will need iOS-specific binaries)..."
        else
            echo "Installing dependencies (lz4 skipped, using pre-built iOS wheel)..."
        fi
        # Устанавливаем все зависимости с их транзитивными зависимостями
        # Используем --ignore-installed чтобы установить в целевую директорию
        # Примечание: бинарные модули будут для macOS архитектуры
        # Для iOS их нужно будет собрать отдельно:
        #   - lz4: обрабатывается отдельно через pre-built iOS wheel (строки 336-395)
        #   - pydantic-core: КРИТИЧЕСКИ необходим для iOS (pydantic 2.x требует его обязательно)
        #   - msgpack: может работать в pure-Python режиме (бинарная версия быстрее, но опциональна)
        # ВАЖНО (App Store + iOS): запрещаем сборку/установку C-extension speedups для пакетов,
        # которые имеют pure-Python fallback. Иначе pip на macOS поставит/соберёт darwin *.so,
        # и Transporter/Apple отклонит сборку.
        export AIOHTTP_NO_EXTENSIONS=1
        export YARL_NO_EXTENSIONS=1
        export MULTIDICT_NO_EXTENSIONS=1
        export FROZENLIST_NO_EXTENSIONS=1
        export PROPCACHE_NO_EXTENSIONS=1

        if python3 -m pip install --target "${TEMP_DEPS_DIR}" --ignore-installed ${PYMAX_DEPS} 2>&1 | tail -15; then
            echo "✓ All dependencies installed successfully"
        else
            echo "Warning: Some dependencies may have failed to install"
            echo "This is expected for packages with binary dependencies on iOS"
        fi

        # greenlet почти всегда тянется как бинарная зависимость (и часто не нужна для нашего use-case).
        # Удаляем, чтобы не заносить darwin *.so и не ломать App Store validation.
        if [ -d "${TEMP_DEPS_DIR}/greenlet" ]; then
            echo "Removing greenlet (binary dependency) to keep bundle App Store-compliant..."
            rm -rf "${TEMP_DEPS_DIR}/greenlet" 2>/dev/null || true
            find "${TEMP_DEPS_DIR}" -maxdepth 1 -type d -name "greenlet-*.dist-info" -exec rm -rf {} \; 2>/dev/null || true
        fi
        
        # Проверяем наличие pydantic-core (КРИТИЧЕСКИ необходим для iOS)
        # pydantic 2.x требует pydantic-core обязательно - без него pydantic/sqlmodel не работают
        if [ "${INSTALL_PYDANTIC_CORE_VIA_PIP}" = "false" ]; then
            # iOS wheel уже установлен, проверяем его
            if [ -d "${SITE_PACKAGES_DIR}/pydantic_core" ]; then
                IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ')
                if [ "${IOS_BINARIES}" -gt 0 ]; then
                    echo "✓ pydantic-core iOS wheel already installed (${IOS_BINARIES} iOS binary modules)"
                else
                    echo "⚠️  Warning: pydantic-core iOS wheel installed but no iOS binaries found"
                fi
            else
                echo "⚠️  Warning: pydantic-core iOS wheel should be installed but directory not found"
            fi
        elif [ -d "${TEMP_DEPS_DIR}/pydantic_core" ]; then
            echo "✓ pydantic-core installed via pip (binary module, macOS architecture)"
            # Проверяем наличие бинарного модуля
            if find "${TEMP_DEPS_DIR}/pydantic_core" -name "_pydantic_core*.so" -o -name "_pydantic_core*.dylib" | grep -q .; then
                if [ "${PLATFORM_NAME}" = "iphoneos" ] || [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
                    echo "  ⚠️  Binary module found (macOS architecture)"
                    echo "  ⚠️  CRITICAL: iOS requires pydantic-core wheel built for iphoneos/iphonesimulator"
                    echo "  ⚠️  pydantic/sqlmodel will NOT work on iOS without iOS-compatible pydantic-core"
                    echo "  ⚠️  Place iOS wheel in BuildScripts/ directory"
                fi
            fi
        else
            if [ "${PLATFORM_NAME}" = "iphoneos" ] || [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
                echo "❌ ERROR: pydantic-core not found (pydantic/sqlmodel will not work)"
                echo "  ⚠️  Place iOS wheel in BuildScripts/ directory"
            else
                echo "⚠️  Warning: pydantic-core not found (pydantic/sqlmodel may not work)"
            fi
        fi
        
        # Копируем установленные пакеты в site-packages
        if [ -d "${TEMP_DEPS_DIR}" ] && [ "$(ls -A ${TEMP_DEPS_DIR} 2>/dev/null)" ]; then
            echo "Copying installed packages to site-packages..."
            # Копируем все установленные пакеты, но не перезаписываем iOS wheels если уже установлены
            if [ -d "${SITE_PACKAGES_DIR}/lz4" ] && [ "${INSTALL_LZ4_VIA_PIP}" = "false" ]; then
                echo "  Preserving pre-installed iOS lz4, skipping macOS version from pip"
                # Удаляем macOS версию lz4 из временной директории чтобы не перезаписать iOS версию
                if [ -d "${TEMP_DEPS_DIR}/lz4" ]; then
                    rm -rf "${TEMP_DEPS_DIR}/lz4"
                    echo "    Removed macOS lz4 from pip install to preserve iOS version"
                fi
                # Также удаляем dist-info для macOS lz4 если есть
                if find "${TEMP_DEPS_DIR}" -type d -name "lz4-*.dist-info" | grep -q .; then
                    find "${TEMP_DEPS_DIR}" -type d -name "lz4-*.dist-info" -exec rm -rf {} \; 2>/dev/null || true
                    echo "    Removed macOS lz4 dist-info to preserve iOS version"
                fi
            fi
            
            if [ -d "${SITE_PACKAGES_DIR}/pydantic_core" ] && [ "${INSTALL_PYDANTIC_CORE_VIA_PIP}" = "false" ]; then
                echo "  Preserving pre-installed iOS pydantic-core, skipping macOS version from pip"
                # Удаляем macOS версию pydantic_core из временной директории чтобы не перезаписать iOS версию
                if [ -d "${TEMP_DEPS_DIR}/pydantic_core" ]; then
                    rm -rf "${TEMP_DEPS_DIR}/pydantic_core"
                    echo "    Removed macOS pydantic_core from pip install to preserve iOS version"
                fi
                # Также удаляем dist-info для macOS pydantic_core если есть
                if find "${TEMP_DEPS_DIR}" -type d -name "pydantic_core-*.dist-info" | grep -q .; then
                    find "${TEMP_DEPS_DIR}" -type d -name "pydantic_core-*.dist-info" -exec rm -rf {} \; 2>/dev/null || true
                    echo "    Removed macOS pydantic_core dist-info to preserve iOS version"
                fi
            fi
            
            if [ -d "${SITE_PACKAGES_DIR}/msgpack" ] && [ "${INSTALL_MSGPACK_VIA_PIP}" = "false" ]; then
                echo "  Preserving pre-installed iOS msgpack, skipping macOS version from pip"
                # Удаляем macOS версию msgpack из временной директории чтобы не перезаписать iOS версию
                if [ -d "${TEMP_DEPS_DIR}/msgpack" ]; then
                    rm -rf "${TEMP_DEPS_DIR}/msgpack"
                    echo "    Removed macOS msgpack from pip install to preserve iOS version"
                fi
                # Также удаляем dist-info для macOS msgpack если есть
                if find "${TEMP_DEPS_DIR}" -type d -name "msgpack-*.dist-info" | grep -q .; then
                    find "${TEMP_DEPS_DIR}" -type d -name "msgpack-*.dist-info" -exec rm -rf {} \; 2>/dev/null || true
                    echo "    Removed macOS msgpack dist-info to preserve iOS version"
                fi
            fi
            # Копируем все установленные пакеты
            cp -R "${TEMP_DEPS_DIR}"/* "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
            
            # Подписываем бинарные модули в site-packages (lz4, msgpack и т.д.)
            if [ -d "${SITE_PACKAGES_DIR}" ]; then
                echo "Code signing binary modules in site-packages (lz4, msgpack, etc.)..."
                
                # Проверяем наличие lz4 и его бинарных модулей
                if [ -d "${SITE_PACKAGES_DIR}/lz4" ]; then
                    echo "  Checking lz4 module..."
                    LZ4_BINARIES=$(find "${SITE_PACKAGES_DIR}/lz4" -name "*.so" -o -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ')
                    if [ "${LZ4_BINARIES}" -gt 0 ]; then
                        echo "    Found ${LZ4_BINARIES} lz4 binary module(s)"
                        # Проверяем архитектуру бинарных модулей lz4
                        find "${SITE_PACKAGES_DIR}/lz4" -name "*.so" -o -name "*.dylib" | while read -r so_file; do
                            BINARY_NAME=$(basename "${so_file}")
                            # Проверяем, это macOS или iOS бинарник
                            if echo "${BINARY_NAME}" | grep -q "\.cpython-.*-darwin\.so\|\.darwin\.so"; then
                                echo "      ⚠️  Warning: macOS binary detected: ${BINARY_NAME}"
                                echo "      ⚠️  iOS requires: .cpython-312-iphoneos.so or .cpython-39-iphoneos.so"
                                echo "      ⚠️  This binary will NOT work on iOS device/simulator"
                            elif echo "${BINARY_NAME}" | grep -q "iphoneos\|iphonesimulator"; then
                                echo "      ✓ iOS binary found: ${BINARY_NAME}"
                            fi
                        done
                    else
                        echo "    ⚠️  No binary modules found in lz4 (may be pure-Python or missing)"
                    fi
                fi
                
                # Проверяем наличие pydantic-core и его бинарных модулей
                if [ -d "${SITE_PACKAGES_DIR}/pydantic_core" ]; then
                    echo "  Checking pydantic-core module..."
                    PYDANTIC_CORE_BINARIES=$(find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*.so" -o -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ')
                    if [ "${PYDANTIC_CORE_BINARIES}" -gt 0 ]; then
                        echo "    Found ${PYDANTIC_CORE_BINARIES} pydantic-core binary module(s)"
                        # Проверяем архитектуру бинарных модулей pydantic-core
                        find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*.so" -o -name "*.dylib" | while read -r so_file; do
                            BINARY_NAME=$(basename "${so_file}")
                            # Проверяем, это macOS или iOS бинарник
                            if echo "${BINARY_NAME}" | grep -q "\.cpython-.*-darwin\.so\|\.darwin\.so"; then
                                echo "      ⚠️  Warning: macOS binary detected: ${BINARY_NAME}"
                                echo "      ⚠️  iOS requires: .cpython-313-iphoneos.so or .cpython-39-iphoneos.so"
                                echo "      ⚠️  This binary will NOT work on iOS device/simulator"
                            elif echo "${BINARY_NAME}" | grep -q "iphoneos\|iphonesimulator"; then
                                echo "      ✓ iOS binary found: ${BINARY_NAME}"
                            fi
                        done
                    else
                        echo "    ⚠️  No binary modules found in pydantic-core (may be pure-Python or missing)"
                    fi
                fi
                
                # Проверяем наличие msgpack и его бинарных модулей
                if [ -d "${SITE_PACKAGES_DIR}/msgpack" ]; then
                    echo "  Checking msgpack module..."
                    MSGPACK_BINARIES=$(find "${SITE_PACKAGES_DIR}/msgpack" -name "*.so" -o -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ')
                    if [ "${MSGPACK_BINARIES}" -gt 0 ]; then
                        echo "    Found ${MSGPACK_BINARIES} msgpack binary module(s)"
                        # Проверяем архитектуру бинарных модулей msgpack
                        find "${SITE_PACKAGES_DIR}/msgpack" -name "*.so" -o -name "*.dylib" | while read -r so_file; do
                            BINARY_NAME=$(basename "${so_file}")
                            # Проверяем, это macOS или iOS бинарник
                            if echo "${BINARY_NAME}" | grep -q "\.cpython-.*-darwin\.so\|\.darwin\.so"; then
                                echo "      ⚠️  Warning: macOS binary detected: ${BINARY_NAME}"
                                echo "      ⚠️  iOS requires: .cpython-313-iphoneos.so or .cpython-39-iphoneos.so"
                                echo "      ⚠️  This binary will NOT work on iOS device/simulator"
                            elif echo "${BINARY_NAME}" | grep -q "iphoneos\|iphonesimulator"; then
                                echo "      ✓ iOS binary found: ${BINARY_NAME}"
                            fi
                        done
                    else
                        echo "    ⚠️  No binary modules found in msgpack (using pure-Python fallback)"
                    fi
                fi
                
                # Подписываем все .so файлы в site-packages (lz4, msgpack и другие бинарные модули)
                # Пропускаем macOS-специфичные бинарники на iOS
                find "${SITE_PACKAGES_DIR}" -name "*.so" -type f | while read -r so_file; do
                    # Пропускаем macOS-специфичные бинарники на iOS
                    if echo "${so_file}" | grep -q "\.cpython-.*-darwin\.so\|\.darwin\.so"; then
                        if [ "${PLATFORM_NAME}" = "iphoneos" ] || [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
                            echo "    Skipping macOS binary on iOS: $(basename "${so_file}")"
                            continue
                        fi
                    fi
                    
                    if codesign --force --sign "${SIGN_IDENTITY}" "${so_file}" 2>&1; then
                        echo "    ✓ Signed $(basename "${so_file}")"
                    else
                        echo "    Warning: Failed to sign $(basename "${so_file}"), trying ad-hoc..."
                        codesign --force --sign - "${so_file}" 2>&1 || true
                    fi
                done
            fi
            
            # Показываем количество установленных пакетов
            PKG_COUNT=$(find "${SITE_PACKAGES_DIR}" -maxdepth 1 -type d -name "*.dist-info" -o -type d ! -name "__pycache__" ! -name "." | wc -l | tr -d ' ')
            echo "✓ ${PKG_COUNT} packages copied to site-packages"
        else
            echo "Warning: No packages found in temporary directory"
        fi
        
        # Очищаем временную директорию
        rm -rf "${TEMP_DEPS_DIR}" 2>/dev/null || true
    else
        echo "Warning: pip not found, skipping dependency installation"
    fi
    
    # Если есть предустановленные зависимости в Python.xcframework, копируем их
    # Это важно, так как там могут быть iOS-совместимые бинарники
    XCFRAMEWORK_SITE_PACKAGES="${PYTHON_PLATFORM}/lib/python3.13/site-packages"
    if [ -d "${XCFRAMEWORK_SITE_PACKAGES}" ]; then
        echo "Copying pre-installed packages from xcframework..."
        cp -R "${XCFRAMEWORK_SITE_PACKAGES}"/* "${SITE_PACKAGES_DIR}/" 2>/dev/null || true
        
        # Проверяем наличие lz4 в xcframework
        if [ -d "${XCFRAMEWORK_SITE_PACKAGES}/lz4" ]; then
            echo "  ✓ lz4 found in xcframework, copied to site-packages"
            # Проверяем наличие iOS-совместимых бинарников
            LZ4_IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/lz4" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ')
            if [ "${LZ4_IOS_BINARIES}" -gt 0 ]; then
                echo "    ✓ Found ${LZ4_IOS_BINARIES} iOS-compatible lz4 binary module(s)"
            else
                echo "    ⚠️  No iOS-compatible lz4 binaries found in xcframework"
                echo "    ⚠️  lz4 needs to be compiled for iOS separately"
            fi
        fi
    fi
    
    # Финальная проверка lz4 для iOS
    if [ "${PLATFORM_NAME}" = "iphoneos" ] || [ "${PLATFORM_NAME}" = "iphonesimulator" ]; then
        if [ -d "${SITE_PACKAGES_DIR}/lz4" ]; then
            LZ4_IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/lz4" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            LZ4_MACOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/lz4" -name "*darwin*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            
            if [ "${LZ4_IOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "✓ lz4 iOS installation successful: ${LZ4_IOS_BINARIES} iOS binary module(s) found"
                if [ "${LZ4_MACOS_BINARIES}" -gt 0 ]; then
                    echo "  ⚠️  Warning: Also found ${LZ4_MACOS_BINARIES} macOS binary module(s) (these will be ignored on iOS)"
                fi
            elif [ "${LZ4_MACOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "⚠️  ⚠️  ⚠️  WARNING: Only macOS lz4 binaries found! ⚠️  ⚠️  ⚠️"
                echo "Found ${LZ4_MACOS_BINARIES} macOS binary module(s), but 0 iOS binaries."
                echo "macOS binaries (.cpython-*-darwin.so) will NOT work on iOS."
                echo ""
                echo "To fix this:"
                echo "  1. Build lz4 for iOS using mobile-forge"
                echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
                echo "  3. The script will automatically install it on next build"
                echo ""
                if [ -z "${LZ4_WHEEL}" ]; then
                    echo "  Expected location: ${WHEEL_DIR}/lz4-*.whl"
                else
                    echo "  Found wheel but installation may have failed: ${LZ4_WHEEL}"
                fi
                echo "  4. The Socket client will fail to decompress compressed payloads without iOS lz4"
                echo ""
            else
                echo ""
                echo "⚠️  ⚠️  ⚠️  WARNING: lz4 not found! ⚠️  ⚠️  ⚠️"
                echo "lz4 directory exists but no binary modules found."
                echo ""
                echo "To fix this:"
                echo "  1. Build lz4 for iOS using mobile-forge"
                echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
                echo ""
                if [ -z "${LZ4_WHEEL}" ]; then
                    echo "  Expected location: ${WHEEL_DIR}/lz4-*.whl"
                fi
                echo ""
            fi
        else
            echo ""
            echo "⚠️  ⚠️  ⚠️  WARNING: lz4 not installed! ⚠️  ⚠️  ⚠️"
            echo "lz4 requires C extensions compiled for iOS architecture (arm64 iphoneos)."
            echo ""
            echo "To fix this:"
            echo "  1. Build lz4 for iOS using mobile-forge"
            echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
            echo "  3. The script will automatically install it on next build"
            echo ""
            if [ -z "${LZ4_WHEEL}" ]; then
                echo "  Expected location: ${WHEEL_DIR}/lz4-*.whl"
            fi
            echo ""
        fi
        
        # Финальная проверка pydantic-core для iOS
        if [ -d "${SITE_PACKAGES_DIR}/pydantic_core" ]; then
            PYDANTIC_CORE_IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            PYDANTIC_CORE_MACOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/pydantic_core" -name "*darwin*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            
            if [ "${PYDANTIC_CORE_IOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "✓ pydantic-core iOS installation successful: ${PYDANTIC_CORE_IOS_BINARIES} iOS binary module(s) found"
                if [ "${PYDANTIC_CORE_MACOS_BINARIES}" -gt 0 ]; then
                    echo "  ⚠️  Warning: Also found ${PYDANTIC_CORE_MACOS_BINARIES} macOS binary module(s) (these will be ignored on iOS)"
                fi
            elif [ "${PYDANTIC_CORE_MACOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "⚠️  ⚠️  ⚠️  WARNING: Only macOS pydantic-core binaries found! ⚠️  ⚠️  ⚠️"
                echo "Found ${PYDANTIC_CORE_MACOS_BINARIES} macOS binary module(s), but 0 iOS binaries."
                echo "macOS binaries (.cpython-*-darwin.so) will NOT work on iOS."
                echo "⚠️  CRITICAL: pydantic/sqlmodel will NOT work on iOS without iOS-compatible pydantic-core"
                echo ""
                echo "To fix this:"
                echo "  1. Build pydantic-core for iOS using mobile-forge"
                echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
                echo "  3. The script will automatically install it on next build"
                echo ""
                if [ -z "${PYDANTIC_CORE_WHEEL}" ]; then
                    echo "  Expected location: ${WHEEL_DIR}/pydantic_core-*.whl"
                else
                    echo "  Found wheel but installation may have failed: ${PYDANTIC_CORE_WHEEL}"
                fi
                echo ""
            else
                echo ""
                echo "⚠️  ⚠️  ⚠️  WARNING: pydantic-core not found! ⚠️  ⚠️  ⚠️"
                echo "pydantic-core directory exists but no binary modules found."
                echo "⚠️  CRITICAL: pydantic/sqlmodel will NOT work on iOS without pydantic-core"
                echo ""
                echo "To fix this:"
                echo "  1. Build pydantic-core for iOS using mobile-forge"
                echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
                echo ""
                if [ -z "${PYDANTIC_CORE_WHEEL}" ]; then
                    echo "  Expected location: ${WHEEL_DIR}/pydantic_core-*.whl"
                fi
                echo ""
            fi
        else
            echo ""
            echo "⚠️  ⚠️  ⚠️  WARNING: pydantic-core not installed! ⚠️  ⚠️  ⚠️"
            echo "pydantic-core requires C extensions compiled for iOS architecture (arm64 iphoneos)."
            echo "⚠️  CRITICAL: pydantic/sqlmodel will NOT work on iOS without pydantic-core"
            echo ""
            echo "To fix this:"
            echo "  1. Build pydantic-core for iOS using mobile-forge"
            echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
            echo "  3. The script will automatically install it on next build"
            echo ""
            if [ -z "${PYDANTIC_CORE_WHEEL}" ]; then
                echo "  Expected location: ${WHEEL_DIR}/pydantic_core-*.whl"
            fi
            echo ""
        fi
        
        # Финальная проверка msgpack для iOS
        if [ -d "${SITE_PACKAGES_DIR}/msgpack" ]; then
            MSGPACK_IOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/msgpack" -name "*iphoneos*.so" -o -name "*iphonesimulator*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            MSGPACK_MACOS_BINARIES=$(find "${SITE_PACKAGES_DIR}/msgpack" -name "*darwin*.so" 2>/dev/null | wc -l | tr -d ' ' 2>/dev/null || echo "0")
            
            if [ "${MSGPACK_IOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "✓ msgpack iOS installation successful: ${MSGPACK_IOS_BINARIES} iOS binary module(s) found"
                if [ "${MSGPACK_MACOS_BINARIES}" -gt 0 ]; then
                    echo "  ⚠️  Warning: Also found ${MSGPACK_MACOS_BINARIES} macOS binary module(s) (these will be ignored on iOS)"
                fi
            elif [ "${MSGPACK_MACOS_BINARIES}" -gt 0 ]; then
                echo ""
                echo "⚠️  Warning: Only macOS msgpack binaries found (will use pure-Python fallback on iOS)"
                echo "Found ${MSGPACK_MACOS_BINARIES} macOS binary module(s), but 0 iOS binaries."
                echo "macOS binaries (.cpython-*-darwin.so) will NOT work on iOS."
                echo "msgpack will work in pure-Python mode on iOS, but binary version is faster."
                echo ""
                echo "To fix this (optional, for better performance):"
                echo "  1. Build msgpack for iOS using mobile-forge"
                echo "  2. Place the wheel file (.whl) in BuildScripts/ directory"
                echo "  3. The script will automatically install it on next build"
                echo ""
                if [ -z "${MSGPACK_WHEEL}" ]; then
                    echo "  Expected location: ${WHEEL_DIR}/msgpack-*.whl"
                else
                    echo "  Found wheel but installation may have failed: ${MSGPACK_WHEEL}"
                fi
                echo ""
            else
                echo ""
                echo "⚠️  Info: msgpack installed without binary modules (using pure-Python mode)"
                echo "msgpack will work, but binary version is faster. Optional: build iOS wheel for better performance."
                echo ""
            fi
        fi
    fi
    
    echo "Site-packages directory: ${SITE_PACKAGES_DIR}"

    # После установки/копирования пакетов: переводим все бинарные модули в Frameworks/ + .fwork
    # (иначе App Store/Transporter отклоняет сборку из-за .so в app bundle)
    process_all_python_binaries
fi

# Копируем pymax из pymax/src/pymax в app/pymax
# Исключаем git-связанные файлы и другие ненужные файлы (git submodule)
PYMAX_SRC="${PYMAX_DIR}/src/pymax"
PYMAX_DEST="${APP_DIR}/pymax"

if [ -d "${PYMAX_SRC}" ]; then
    echo "Copying pymax library from ${PYMAX_SRC}..."
    mkdir -p "${APP_DIR}"
    
    # Удаляем старую версию если есть
    if [ -d "${PYMAX_DEST}" ]; then
        rm -rf "${PYMAX_DEST}"
    fi
    
    # Используем rsync если доступен (лучше для исключений), иначе find + cp
    if command -v rsync &> /dev/null; then
        echo "  Using rsync to copy pymax (excluding git files and cache)..."
        rsync -av --exclude='.git' \
              --exclude='.gitignore' \
              --exclude='.gitmodules' \
              --exclude='.gitattributes' \
              --exclude='__pycache__' \
              --exclude='*.pyc' \
              --exclude='*.pyo' \
              --exclude='.pytest_cache' \
              --exclude='.mypy_cache' \
              --exclude='.ruff_cache' \
              --exclude='.DS_Store' \
              --exclude='*.swp' \
              --exclude='*.swo' \
              --exclude='*~' \
              "${PYMAX_SRC}/" "${PYMAX_DEST}/"
    else
        echo "  Using find + cp to copy pymax (excluding git files and cache)..."
        # Создаем структуру директорий
        find "${PYMAX_SRC}" -type d ! -path '*/.git*' ! -path '*/__pycache__*' ! -path '*/.pytest_cache*' ! -path '*/.mypy_cache*' ! -path '*/.ruff_cache*' | while read -r dir; do
            rel_dir="${dir#${PYMAX_SRC}/}"
            mkdir -p "${PYMAX_DEST}/${rel_dir}" 2>/dev/null || true
        done
        
        # Копируем файлы, исключая ненужные
        find "${PYMAX_SRC}" -type f \
             ! -path '*/.git*' \
             ! -name '.gitignore' \
             ! -name '.gitmodules' \
             ! -name '.gitattributes' \
             ! -path '*/__pycache__*' \
             ! -name '*.pyc' \
             ! -name '*.pyo' \
             ! -path '*/.pytest_cache*' \
             ! -path '*/.mypy_cache*' \
             ! -path '*/.ruff_cache*' \
             ! -name '.DS_Store' \
             ! -name '*.swp' \
             ! -name '*.swo' \
             ! -name '*~' | while read -r file; do
            rel_file="${file#${PYMAX_SRC}/}"
            cp "${file}" "${PYMAX_DEST}/${rel_file}" 2>/dev/null || true
        done
    fi
    
    # Удаляем любые .git директории, которые могли попасть (на всякий случай)
    find "${PYMAX_DEST}" -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true
    find "${PYMAX_DEST}" -name ".gitignore" -delete 2>/dev/null || true
    find "${PYMAX_DEST}" -name ".gitmodules" -delete 2>/dev/null || true
    find "${PYMAX_DEST}" -name ".gitattributes" -delete 2>/dev/null || true
    
    # Проверяем что скопировалось
    if [ -d "${PYMAX_DEST}" ] && [ -f "${PYMAX_DEST}/__init__.py" ]; then
        echo "✓ pymax library copied successfully"
        
        # Проверяем что .git не попал
        if find "${PYMAX_DEST}" -type d -name ".git" | grep -q .; then
            echo "⚠️  Warning: Found .git directories in pymax, removing..."
            find "${PYMAX_DEST}" -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true
        fi
    else
        echo "Warning: pymax may not have copied correctly"
    fi
    
    # Копируем __init__.py если есть на верхнем уровне
    if [ -f "${PYMAX_DIR}/src/__init__.py" ]; then
        mkdir -p "${APP_DIR}/src"
        cp "${PYMAX_DIR}/src/__init__.py" "${APP_DIR}/src/"
    fi
else
    echo "Warning: pymax source not found at ${PYMAX_SRC}"
fi

# Копируем Python обертку
WRAPPER_SRC="${PROJECT_DIR}/whitemax/app/max_client_wrapper.py"
if [ -f "${WRAPPER_SRC}" ]; then
    echo "Copying max_client_wrapper.py..."
    cp "${WRAPPER_SRC}" "${APP_DIR}/"
    if [ -f "${APP_DIR}/max_client_wrapper.py" ]; then
        echo "✓ max_client_wrapper.py copied successfully"
    else
        echo "Warning: max_client_wrapper.py may not have copied correctly"
    fi
else
    echo "Warning: max_client_wrapper.py not found at ${WRAPPER_SRC}"
fi

# Копируем Python.framework из xcframework в <App>.app/Frameworks
PYTHON_FRAMEWORK_SRC="${PYTHON_FRAMEWORK}"

if [ -d "${PYTHON_FRAMEWORK_SRC}" ]; then
    echo "Copying Python.framework to Frameworks..."
    echo "Source: ${PYTHON_FRAMEWORK_SRC}"
    echo "Destination: ${FRAMEWORKS_DIR}"
    mkdir -p "${FRAMEWORKS_DIR}"
    if [ -d "${FRAMEWORKS_DIR}/Python.framework" ]; then
        rm -rf "${FRAMEWORKS_DIR}/Python.framework"
    fi
    cp -R "${PYTHON_FRAMEWORK_SRC}" "${FRAMEWORKS_DIR}/"
    
    # Подписываем framework (требуется для iOS)
    echo "Code signing Python.framework..."
    
    # Подписываем бинарный файл framework
    codesign --force --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/Python.framework/Python" 2>/dev/null || {
        echo "Warning: Failed to sign Python.framework/Python"
    }
    
    # Также подписываем весь framework
    codesign --force --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/Python.framework" 2>/dev/null || {
        echo "Warning: Failed to sign Python.framework"
    }
    
    echo "✓ Python.framework signed successfully"
    
    echo "Python.framework copied successfully"
fi

echo "Python libraries copied successfully!"
