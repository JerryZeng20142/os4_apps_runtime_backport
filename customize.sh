#!/system/bin/sh

SKIPUNZIP=0

MODID=os4_apps_runtime_backport

# ============================================================
# 【音量键选择 1/2】是否将系统版本伪装为 HyperOS 4
# ============================================================
volkey_choose_spoof() {
  local TIMEOUT_SEC=12
  local i=0
  local ev=""
  SPOOF_CHOICE=0

  ui_print " "
  ui_print " "
  ui_print "[选择1/2] 是否伪装 HyperOS 版本为 OS 4？"
  ui_print "[请注意] 启用伪装能解锁更完整的体验（如柔光玻璃），但会使所有 APP 将系统识别为 OS 4（这将导致 HyperCeiler 等软件拒绝提供服务）。"
  ui_print "  音量+  => 启用伪装"
  ui_print "  音量-  => 不启用 / 取消已有伪装"
  ui_print "  ${TIMEOUT_SEC}s 后无操作 => 默认不启用"
  ui_print " "

  if command -v keycheck >/dev/null 2>&1; then
    keycheck $TIMEOUT_SEC
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      SPOOF_CHOICE=1; return
    elif [ "$rc" -eq 1 ]; then
      SPOOF_CHOICE=0; return
    fi
  fi

  if command -v getevent >/dev/null 2>&1; then
    while [ "$i" -lt "$TIMEOUT_SEC" ]; do
      ev=$(getevent -lc 1 2>/dev/null)
      if echo "$ev" | grep -qiE 'KEY_VOLUMEUP|0073[[:space:]]+00000001|0073.*DOWN'; then
        SPOOF_CHOICE=1; return
      fi
      if echo "$ev" | grep -qiE 'KEY_VOLUMEDOWN|0072[[:space:]]+00000001|0072.*DOWN'; then
        SPOOF_CHOICE=0; return
      fi
      i=$((i + 1))
      sleep 1
    done
  fi

  SPOOF_CHOICE=0
}

# ============================================================
# 【音量键选择 2/2】是否移除桌面 APK 中的 uses-library 限制
# ============================================================
volkey_choose_homepatch() {
  local TIMEOUT_SEC=12
  local i=0
  local ev=""
  HOMEPATCH_CHOICE=0

  ui_print " "
  ui_print " "
  ui_print "[选择2/2] 是否移除系统桌面 (MiuiHome) 的 uses-library 限制？"
  ui_print "[原理] 将桌面 APK AndroidManifest 中 <uses-library required=\"true\">"
  ui_print "       替换为 required=\"false\"，即使系统缺失对应 shared-library"
  ui_print "       声明也能启动桌面（仅针对 com.miui.home）。"
  ui_print "[注意] 若同时安装了本模块的 v3/v4/v5 XML 权限声明，可不选。"
  ui_print "       但 OS4 新桌面还可能声明额外的 uses-library，这时选此项可兜底。"
  ui_print "  音量+  => 启用 APK Patch（修改桌面 manifest）"
  ui_print "  音量-  => 不修改（推荐，更稳妥）"
  ui_print "  ${TIMEOUT_SEC}s 后无操作 => 默认不修改"
  ui_print " "

  if command -v keycheck >/dev/null 2>&1; then
    keycheck $TIMEOUT_SEC
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      HOMEPATCH_CHOICE=1; return
    elif [ "$rc" -eq 1 ]; then
      HOMEPATCH_CHOICE=0; return
    fi
  fi

  if command -v getevent >/dev/null 2>&1; then
    while [ "$i" -lt "$TIMEOUT_SEC" ]; do
      ev=$(getevent -lc 1 2>/dev/null)
      if echo "$ev" | grep -qiE 'KEY_VOLUMEUP|0073[[:space:]]+00000001|0073.*DOWN'; then
        HOMEPATCH_CHOICE=1; return
      fi
      if echo "$ev" | grep -qiE 'KEY_VOLUMEDOWN|0072[[:space:]]+00000001|0072.*DOWN'; then
        HOMEPATCH_CHOICE=0; return
      fi
      i=$((i + 1))
      sleep 1
    done
  fi

  HOMEPATCH_CHOICE=0
}

# ============================================================
# 移除桌面 uses-library 的二进制 patch 实现
# ============================================================
patch_miuihome_uses_library() {
  local PATCH_TARGETS="
    /product/priv-app/MiuiHome/MiuiHome.apk
  "
  local patched_any=0
  local total_scanned=0

  local DATA_APK=""
  if [ -d /data/app ]; then
    DATA_APK=$(find /data/app -maxdepth 3 -name 'base.apk' -path '*com.miui.home*' 2>/dev/null | head -n1)
  fi

  if [ -n "$DATA_APK" ]; then
    PATCH_TARGETS="$PATCH_TARGETS $DATA_APK"
  fi

  for APK in $PATCH_TARGETS; do
    [ -z "$APK" ] && continue
    if [ ! -f "$APK" ]; then
      continue
    fi
    local BAK="${APK}.os4patch.bak"
    total_scanned=$((total_scanned + 1))

    if [ -f "$BAK" ]; then
      ui_print "  ~ 已存在备份，跳过: $APK"
      continue
    fi

    if grep -qa 'uses-library' "$APK"; then
      ui_print "  -> 正在处理: $APK"
      cp -af "$APK" "$BAK" 2>/dev/null
      if [ "$?" -ne 0 ] || [ ! -f "$BAK" ]; then
        ui_print "     ! 备份失败（可能是只读分区），跳过此文件"
        continue
      fi
      local TMPDIR=$(mktemp -d)
      (
        cd "$TMPDIR"
        unzip -o "$BAK" AndroidManifest.xml >/dev/null 2>&1
        if [ -f AndroidManifest.xml ]; then
          local BEFORE_1=$(md5sum AndroidManifest.xml 2>/dev/null | awk '{print $1}')
          if command -v perl >/dev/null 2>&1; then
            perl -i -0pe 's/\x28\x00\x01\x01\x12\x00\x00\x00\x01\x00\x00\x00/\x28\x00\x01\x01\x12\x00\x00\x00\x00\x00\x00\x00/g;
                          s/\x28\x00\x01\x01\x12\x00\x00\x00\xff\xff\xff\xff/\x28\x00\x01\x01\x12\x00\x00\x00\x00\x00\x00\x00/g' AndroidManifest.xml
          else
            :
          fi
          local AFTER_1=$(md5sum AndroidManifest.xml 2>/dev/null | awk '{print $1}')
          if [ "$BEFORE_1" != "$AFTER_1" ]; then
            ui_print "     + Manifest 已修改（required=true -> false）"
            if command -v zip >/dev/null 2>&1; then
              cp -af "$BAK" "$APK.tmp"
              zip -q -u "$APK.tmp" AndroidManifest.xml 2>/dev/null
              if [ -f "$APK.tmp" ]; then
                if cat "$APK.tmp" > "$APK" 2>/dev/null; then
                  ui_print "     + APK 回写成功"
                  patched_any=$((patched_any + 1))
                else
                  ui_print "     ! APK 回写失败（挂载只读），仅保留 .bak + TMP:"
                  ui_print "       $APK.tmp"
                fi
                rm -f "$APK.tmp"
              fi
            fi
          else
            ui_print "     ~ 未检测到 uses-library required=true 字节，APK 无需修改"
          fi
        fi
      )
      rm -rf "$TMPDIR"
    fi
  done

  ui_print " "
  if [ "$patched_any" -gt 0 ]; then
    ui_print "[APK Patch] 完成：共修改 $patched_any / 扫描 $total_scanned 个桌面 APK"
    touch "$MODPATH/homepatch_applied"
    set_perm "$MODPATH/homepatch_applied" 0 0 0644
  else
    ui_print "[APK Patch] 扫描 $total_scanned 个 APK："
    if [ "$total_scanned" -eq 0 ]; then
      ui_print "       没有在已知位置找到 com.miui.home（可能安装在 /data/app，需手动指定）"
    else
      ui_print "       均已合规、或无可写权限（已保留 .bak 以防万一）"
    fi
    ui_print "[APK Patch] 无需修改（扫描 $total_scanned 个 APK 均已合规或无可写权限）"
  fi
}

# ============================================================
# 运行时符号完整性自检
# ============================================================
RUST_SYMBOL_SELFCHECK() {
  ui_print " "
  ui_print "========== 运行时库符号自检 (OS4 兼容性) =========="

  local MUST_SYMBOLS="
    ComponentName_get_descriptor
    Intent_get_descriptor
    Bundle_get_descriptor
    ApplicationInfo_get_descriptor
    ClipData_get_descriptor
    Notification_get_descriptor
  "
  local MISSING_COUNT=0
  local MISSING_LIST=""
  local TOTAL_SO=0
  local _f
  for _f in "$MODPATH"/system/system_ext/lib64/libhyper_os_*.so; do
    [ -e "$_f" ] && TOTAL_SO=$((TOTAL_SO + 1))
  done

  for SYM in $MUST_SYMBOLS; do
    if grep -Rqa "$SYM" "$MODPATH/system/system_ext/lib64/" 2>/dev/null; then
      ui_print "  [OK]  $SYM  (found)"
    else
      ui_print "  [WARN] $SYM  (MISSING in all libhyper_os_*.so)"
      MISSING_COUNT=$((MISSING_COUNT + 1))
      if [ -z "$MISSING_LIST" ]; then
        MISSING_LIST="$SYM"
      else
        MISSING_LIST="$MISSING_LIST, $SYM"
      fi
    fi
  done

  ui_print " "
  ui_print "  扫描了 $TOTAL_SO 个 libhyper_os_*.so 文件"
  if [ "$MISSING_COUNT" -gt 0 ]; then
    ui_print "  结果：缺失 $MISSING_COUNT 个 OS4 导出符号 ($MISSING_LIST)"
  else
    ui_print "  [OK] 全部关键符号已就位，OS4 桌面应能正常加载。"
  fi
}

# ============================================================
# 主流程
# ============================================================

ui_print " "
ui_print "HyperOS Rust Runtime v3~v5 + Vulkan 1.3"
ui_print " "

ABI="$(getprop ro.product.cpu.abi)"
SDK="$(getprop ro.build.version.sdk)"
OS_CODE="$(getprop ro.mi.os.version.code)"

if [ "$ABI" != "arm64-v8a" ]; then
  abort "Unsupported ABI: $ABI (arm64-v8a required)."
fi
if [ "$SDK" != "36" ]; then
  ui_print "[WARN] Android SDK=$SDK (build target=36 for HyperOS 3). Continue at own risk."
fi
if [ "$OS_CODE" != "3" ] && [ "$OS_CODE" != "4" ]; then
  ui_print "[WARN] ro.mi.os.version.code=$OS_CODE. HyperOS 3/4 expected."
fi

RUST_SYMBOL_SELFCHECK

ui_print " "
ui_print "Setting permissions and SELinux labels..."

set_perm_recursive "$MODPATH/system" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/system_ext" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/product" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/vendor" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/system_ext/lib64" 0 0 0755 0644 u:object_r:system_lib_file:s0
set_perm_recursive "$MODPATH/system/lib64" 0 0 0755 0644 u:object_r:system_lib_file:s0

set_perm "$MODPATH/system/system_ext/bin/hyos_spawner" 0 2000 0755 u:object_r:zygote_exec:s0
set_perm "$MODPATH/system/system_ext/etc/init/init.hyos_spawner.rc" 0 0 0644
set_perm "$MODPATH/system/system_ext/framework/hyperos.rustruntime.jar" 0 0 0644

set_perm "$MODPATH/system/product/etc/permissions/hyperos.rustruntime_v3_v4_v5.xml" 0 0 0644
if [ -f "$MODPATH/system/product/etc/permissions/hyperos.rustruntime_v5.xml" ]; then
  set_perm "$MODPATH/system/product/etc/permissions/hyperos.rustruntime_v5.xml" 0 0 0644
fi
if [ -f "$MODPATH/system/product/etc/permissions/hyperos_extra_sharedlibs_stubs.xml" ]; then
  set_perm "$MODPATH/system/product/etc/permissions/hyperos_extra_sharedlibs_stubs.xml" 0 0 0644
fi
for _vk_xml in android.hardware.vulkan.version-1_1.xml android.hardware.vulkan.version-1_3.xml; do
  if [ -f "$MODPATH/system/vendor/etc/permissions/$_vk_xml" ]; then
    set_perm "$MODPATH/system/vendor/etc/permissions/$_vk_xml" 0 0 0644
  fi
done

if [ -f "$MODPATH/system.prop" ]; then
  set_perm "$MODPATH/system.prop" 0 0 0644
fi

# ---------- 完整性校验 ----------
CHECK_FILES="
  system/system_ext/lib64/libhyper_os_schema_public.so
  system/system_ext/lib64/libhyper_os_flutter.so
  system/system_ext/lib64/libmisqlite3.so
  system/system_ext/lib64/librust_maml_sdk.so
  system/lib64/libhex.dylib.so
  system/lib64/libsysinfo.dylib.so
  system/lib64/v5_std.dylib.so
  system/lib64/v5_hwui.so
  system/system_ext/bin/hyos_spawner
  system/system_ext/etc/init/init.hyos_spawner.rc
  system/system_ext/framework/hyperos.rustruntime.jar
  system/product/etc/permissions/hyperos.rustruntime_v3_v4_v5.xml
  system/product/etc/permissions/hyperos_extra_sharedlibs_stubs.xml
  system/vendor/etc/permissions/android.hardware.vulkan.version-1_3.xml
  system.prop
"

for F in $CHECK_FILES; do
  if [ -f "$MODPATH/$F" ]; then
    ui_print "  OK: $F"
  else
    ui_print "  ERROR: missing $F"
    abort "Module package is incomplete."
  fi
done

if [ "$KSU" = "true" ]; then
  ui_print "[INFO] KernelSU detected: ensure a system-mount metamodule (e.g. meta-overlayfs) is active."
fi

# ---------- 版本伪装开关（音量键选择 1/2）----------
volkey_choose_spoof

if [ "$SPOOF_CHOICE" = "1" ]; then
  ui_print "=> [版本伪装] 已启用 (enable_version_spoof 已创建)"
  touch "$MODPATH/enable_version_spoof"
  set_perm "$MODPATH/enable_version_spoof" 0 0 0644
else
  ui_print "=> [版本伪装] 未启用 / 已取消"
  rm -f "$MODPATH/enable_version_spoof"
fi

# ---------- 桌面 uses-library 移除（音量键选择 2/2）----------
volkey_choose_homepatch

if [ "$HOMEPATCH_CHOICE" = "1" ]; then
  ui_print " "
  ui_print "=> [APK Patch] 正在处理 MiuiHome 桌面（若可写）..."
  patch_miuihome_uses_library
else
  ui_print "=> [APK Patch] 未启用（如需移除桌面 uses-library 限制可重刷选 音量+）"
fi

ui_print " "
ui_print "【版本伪装开关的两种修改方法，均须重启后生效】"
ui_print " "
ui_print "  方法一【添加空文件】："
ui_print "    直接在模块安装目录下操作（模块启用时才有效）："
ui_print "    · 启用伪装：在 /data/adb/modules/${MODID}/ 下创建一个空文件"
ui_print "                文件名 -> enable_version_spoof  （内容任意，只要存在即可）"
ui_print "                例：touch /data/adb/modules/${MODID}/enable_version_spoof"
ui_print "    · 关闭伪装：删除上述 enable_version_spoof 文件"
ui_print "                例：rm  /data/adb/modules/${MODID}/enable_version_spoof"
ui_print "    · 操作完成后重启生效"
ui_print " "
ui_print "  方法二【重刷模块】："
ui_print "    重刷本模块："
ui_print "    · 刷写过程中出现选择菜单时："
ui_print "        音量+  -> 启用伪装（自动创建 enable_version_spoof）"
ui_print "        音量-  -> 不启用 / 取消已有伪装（自动删除 enable_version_spoof）"
ui_print "    · 重新做个决定"
ui_print "    · 刷完重启生效"
ui_print " "

ui_print " "
ui_print "Static package complete. Reboot required."
