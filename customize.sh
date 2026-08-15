#!/system/bin/sh

SKIPUNZIP=0

MODID=os4_apps_runtime_backport

# ============================================================
# 通用音量键选择工具：30s 倒计时 + 节点(30/25/20/15/10/5)打印
# 全局输出变量: $VOLKEY_RESULT
#   1 = 音量+ (KEY_VOLUMEUP   / 0x73)
#   0 = 音量- (KEY_VOLUMEDOWN / 0x72)
# 参数:
#   $1 = 超时默认值 (0 或 1)
#   $2 = 默认项的文字描述 (如 "不启用伪装")，用于倒计时显示
# 依赖: keycheck (Magisk)  或  getevent (KernelSU/Recovery)
# ============================================================
volkey_prompt() {
  local DEFAULT=$1
  local DEFAULT_TEXT=$2
  local TIMEOUT_SEC=30
  local REMAIN=$TIMEOUT_SEC
  local NEXT_PRINT=30
  local rc=""
  local tmp_ev=""
  local child_pid=""

  VOLKEY_RESULT=$DEFAULT

  # ============================================================
  # 阶段 0：排空事件队列 + 等待按键物理释放（最多 2 秒）
  # 防止上一次按键产生的 EV_KEY 事件残留在内核 /dev/input 队列里，
  # 导致第一次选的按键立刻「再次被」下一次选择吃到。
  # 实现：用一个后台短读 getevent，读到事件则杀进程重来，
  #       连续 0.4s 没事件 => 认为队列空了 + 用户松键了。
  # ============================================================
  local DRAIN_TRY=5
  local d_ok=0
  local q_pid=""
  while [ "$DRAIN_TRY" -gt 0 ]; do
    tmp_ev=$(mktemp -d "$TMPDIR/vkdrain.XXXXXX" 2>/dev/null || echo "/tmp/vkdrain$$")
    if [ -d "$tmp_ev" ]; then
      rmdir "$tmp_ev" 2>/dev/null
    fi
    tmp_ev="${tmp_ev}.log"
    : > "$tmp_ev"

    d_ok=1
    if command -v getevent >/dev/null 2>&1; then
      # 0.4s 内短读：后台启动 getevent -lc 1 -> tmpfile，400ms 后没读完就杀掉
      ( getevent -lc 1 > "$tmp_ev" 2>/dev/null ) &
      q_pid=$!
      usleep 400000 2>/dev/null || sleep 1
      if kill -0 "$q_pid" 2>/dev/null; then
        kill -9 "$q_pid" 2>/dev/null
        wait "$q_pid" 2>/dev/null
      fi
      if [ -s "$tmp_ev" ]; then
        d_ok=0
      fi
    else
      # 纯 keycheck 环境：只能 sleep 等用户松手
      sleep 1
    fi
    rm -f "$tmp_ev"
    if [ "$d_ok" -eq 1 ]; then
      break
    fi
    DRAIN_TRY=$((DRAIN_TRY - 1))
  done

  # ============================================================
  # 方案 A：Magisk keycheck（如果可用）
  # ============================================================
  if command -v keycheck >/dev/null 2>&1; then
    while [ "$REMAIN" -gt 0 ]; do
      if [ "$REMAIN" -eq "$NEXT_PRINT" ]; then
        ui_print "  ${REMAIN}s 后未操作自动选择：${DEFAULT_TEXT}"
        NEXT_PRINT=$((NEXT_PRINT - 5))
      fi
      keycheck 1 2>/dev/null
      rc=$?
      if [ "$rc" -eq 0 ]; then
        VOLKEY_RESULT=1; return
      elif [ "$rc" -eq 1 ]; then
        VOLKEY_RESULT=0; return
      fi
      REMAIN=$((REMAIN - 1))
    done
    ui_print "  [超时] ${TIMEOUT_SEC}s 内未操作，自动选择：${DEFAULT_TEXT}"
    return
  fi

  # ============================================================
  # 方案 B：KernelSU / Recovery getevent 兜底
  # 实现：每秒 1 轮 (轮询 + sleep 1)，
  #       每轮启动后台 getevent -lc 1 写入 tmpfile，
  #       800ms 后 getevent 还在跑就 kill 掉（没按键），
  #       否则读 tmpfile 判断是 VOL+/VOL- 哪个事件。
  # ============================================================
  if command -v getevent >/dev/null 2>&1; then
    while [ "$REMAIN" -gt 0 ]; do
      if [ "$REMAIN" -eq "$NEXT_PRINT" ]; then
        ui_print "  ${REMAIN}s 后未操作自动选择：${DEFAULT_TEXT}"
        NEXT_PRINT=$((NEXT_PRINT - 5))
      fi

      # 建临时文件（每轮干净）
      tmp_ev=$(mktemp -d "$TMPDIR/vkq.XXXXXX" 2>/dev/null || echo "/tmp/vkq$$")
      if [ -d "$tmp_ev" ]; then rmdir "$tmp_ev" 2>/dev/null; fi
      tmp_ev="${tmp_ev}.log"
      : > "$tmp_ev"

      # 后台启动 getevent（一次读 1 个按键事件 -> 写入 tmpfile）
      ( getevent -lc 1 > "$tmp_ev" 2>/dev/null ) &
      child_pid=$!

      # 最多 800ms 等按键事件，到点不读完就强杀（本秒无按键）
      i=0
      while [ "$i" -lt 8 ]; do
        if kill -0 "$child_pid" 2>/dev/null; then
          usleep 100000 2>/dev/null || sleep 1
          i=$((i + 1))
        else
          break
        fi
      done
      if kill -0 "$child_pid" 2>/dev/null; then
        kill -9 "$child_pid" 2>/dev/null
        wait "$child_pid" 2>/dev/null
      fi

      # 有文件内容说明读到了一次事件 -> 解析类型
      if [ -s "$tmp_ev" ]; then
        local content=""
        content=$(cat "$tmp_ev" 2>/dev/null)
        if [ -n "$content" ]; then
          if echo "$content" | grep -qiE 'KEY_VOLUMEUP|0073[[:space:]]+00000001|0073[[:space:]]+[0-9a-fA-F]+[[:space:]]+00000001|0073.*DOWN'; then
            rm -f "$tmp_ev"
            VOLKEY_RESULT=1; return
          fi
          if echo "$content" | grep -qiE 'KEY_VOLUMEDOWN|0072[[:space:]]+00000001|0072[[:space:]]+[0-9a-fA-F]+[[:space:]]+00000001|0072.*DOWN'; then
            rm -f "$tmp_ev"
            VOLKEY_RESULT=0; return
          fi
        fi
      fi
      rm -f "$tmp_ev"

      REMAIN=$((REMAIN - 1))
      # 补足 1s 整轮（前面 800ms wait + 这里 sleep 200ms = ~1s 一轮）
      usleep 200000 2>/dev/null || true
    done
    ui_print "  [超时] ${TIMEOUT_SEC}s 内未操作，自动选择：${DEFAULT_TEXT}"
    return
  fi

  # ============================================================
  # 兜底：既没有 keycheck 也没有 getevent => 直接默认值
  # ============================================================
  ui_print "  [!] 当前环境没有 keycheck 和 getevent，无法检测按键，自动选择：${DEFAULT_TEXT}"
  VOLKEY_RESULT=$DEFAULT
}

# ============================================================
# 【音量键选择 1/2】是否将系统版本伪装为 HyperOS 4
# ============================================================
volkey_choose_spoof() {
  SPOOF_CHOICE=0

  ui_print " "
  ui_print " "
  ui_print "[选择1/2] 是否伪装 HyperOS 版本为 OS 4？"
  ui_print "[请注意] 启用伪装能解锁更完整的体验（如柔光玻璃），但会使所有 APP 将系统识别为 OS 4（这将导致 HyperCeiler 等软件拒绝提供服务）。"
  ui_print "  音量+  => 启用伪装"
  ui_print "  音量-  => 不启用 / 取消已有伪装"
  ui_print " "

  volkey_prompt 0 "不启用伪装"
  SPOOF_CHOICE=$VOLKEY_RESULT
}

# ============================================================
# 【音量键选择 2/2】是否移除桌面 APK 中的 uses-library 限制
# ============================================================
volkey_choose_homepatch() {
  HOMEPATCH_CHOICE=0

  ui_print " "
  ui_print " "
  ui_print "[选择2/2] 是否移除系统桌面 (MiuiHome) 的 uses-library 限制？"
  ui_print "  音量+  => 启用 APK Patch（修改桌面 manifest）"
  ui_print "  音量-  => 不修改（推荐，更稳妥）"
  ui_print " "

  volkey_prompt 0 "不修改桌面"
  HOMEPATCH_CHOICE=$VOLKEY_RESULT
}

# ============================================================
# 移除桌面 uses-library 的二进制 patch 实现
# ============================================================
patch_miuihome_uses_library() {
  local PATCH_TARGETS="
    /product/priv-app/MiuiHome/MiuiHome.apk
  "
  local patched_any=0
  local attempted=0
  local total_scanned=0

  local DATA_APK=""
  if [ -d /data/app ]; then
    DATA_APK=$(find /data/app -maxdepth 3 -name 'base.apk' -path '*com.miui.home*' 2>/dev/null | head -n1)
  fi

  if [ -n "$DATA_APK" ]; then
    PATCH_TARGETS="$PATCH_TARGETS $DATA_APK"
  fi

  # 备份目录放到模块目录里（持久化，不会被系统重启清掉）
  local BAK_DIR="$MODPATH/backups"
  mkdir -p "$BAK_DIR" 2>/dev/null

  for APK in $PATCH_TARGETS; do
    [ -z "$APK" ] && continue
    if [ ! -f "$APK" ]; then
      continue
    fi
    total_scanned=$((total_scanned + 1))
    attempted=$((attempted + 1))

    ui_print "  -> 正在处理: $APK"

    # 基于 APK basename 生成一个安全的备份名
    local SAFE_NAME=""
    SAFE_NAME=$(echo "$APK" | tr '/ ' '__' 2>/dev/null || basename "$APK")
    local BAK="$BAK_DIR/${SAFE_NAME}.os4patch.bak"
    local PREV_BAK="$BAK_DIR/${SAFE_NAME}.os4patch_prev.bak"

    # 旧备份存档（若存在）
    if [ -f "$BAK" ]; then
      ui_print "     + 发现既有备份，保留为 _prev.bak，本次用当前 APK 重新备份 + Patch"
      cp -af "$BAK" "$PREV_BAK" 2>/dev/null
      rm -f "$BAK"
    fi

    # ① 先备份 APK 到模块目录
    cp -af "$APK" "$BAK" 2>/dev/null
    if [ "$?" -ne 0 ] || [ ! -f "$BAK" ]; then
      ui_print "     ! 备份失败（cp 返回错误或备份不存在），跳过此 APK。"
      continue
    fi

    # ② 建临时目录，不要 subshell（括号）——防止 patched_any/md5 结果传不出
    local TMPDIR2=""
    TMPDIR2=$(mktemp -d 2>/dev/null || echo "/tmp/homepatch$$")
    mkdir -p "$TMPDIR2" 2>/dev/null

    local MANIFEST="$TMPDIR2/AndroidManifest.xml"
    local APK_TMP="$TMPDIR2/patched.apk"
    local BEFORE_1=""
    local AFTER_1=""
    local MODIFIED=""

    # 解压 AndroidManifest
    unzip -o -d "$TMPDIR2" "$BAK" AndroidManifest.xml >/dev/null 2>&1
    if [ ! -f "$MANIFEST" ]; then
      ui_print "     ! 无法从 APK 中解压出 AndroidManifest.xml（非标准 APK）"
      rm -rf "$TMPDIR2"
      continue
    fi

    BEFORE_1=$(md5sum "$MANIFEST" 2>/dev/null | awk '{print $1}')

    # ③ 精准 AXML 二进制 patch（修 Bug #1/#5/#6）
    # AXML <uses-library required="true"> 的 attribute 在二进制中共占 12 字节：
    #   [第1-4字节: rawValue StringPool ref]  => 不同 APK index 不同，绝对不能硬编码为 0！
    #   [第5-12字节: typedValue Res_value(8字节)] => 固定格式: size=0x0008 + res0=0x00 + dataType=0x12(INT_BOOLEAN) + data(4字节)
    #     - required="true" 时，data = 0xFFFFFFFF
    #     - required="false" 时，data = 0x00000000
    # 替换策略：原样保留前 4 字节（rawValue），只改后 8 字节里的 data(最后4字节) FF→00
    # 加 /s 让 . 也匹配 \x0A 等二进制字节；加 use bytes pragma 避免 UTF-8 宽字符把单个字节拆散
    if command -v perl >/dev/null 2>&1; then
      perl -i -0777 -pe 'BEGIN { use bytes; } s/(.{4})(\x08\x00\x00\x12)\xff\xff\xff\xff/$1$2\x00\x00\x00\x00/gs' "$MANIFEST" 2>/dev/null
    else
      ui_print "     [!] 环境缺少 perl，无法做 AXML 二进制替换（请改用 KernelSU 内置 perl 或 Recovery 环境）"
    fi

    AFTER_1=$(md5sum "$MANIFEST" 2>/dev/null | awk '{print $1}')

    MODIFIED=0
    if [ "$BEFORE_1" != "$AFTER_1" ]; then
      ui_print "     + Manifest 字节已替换（uses-library required=true -> false）"
      MODIFIED=1
    else
      ui_print "     = manifest 前后未变（该 APK 未使用 required=true 的 uses-library；或已在之前 patch 过）"
      ui_print "       已保留备份到模块目录 $BAK"
    fi

    # ④ 如果 manifest 被修改了 → 必须回写 APK
    #    回写方式【修 Bug #2】：
    #    绝不 cat > 系统 APK！而是：
    #      a) 先 cp BAK -> APK_TMP（保留所有 entry）
    #      b) zip -u 把新 Manifest 加进 APK_TMP
    #      c) 【关键】去除 APK v2/v3 签名块（Signing Block），
    #         否则 PackageParser 因签名 digest 与新 Manifest 不一致直接拒杀。
    #      d) 【关键】最终不写真实分区，而是把 patch 好的 APK 放到
    #         模块的 $MODPATH/system/<原始相对路径> 下，
    #         让 Magisk/KernelSU 启动时用 overlay mount 自动替换系统 APK。
    if [ "$MODIFIED" -eq 1 ] && command -v zip >/dev/null 2>&1; then
      cp -af "$BAK" "$APK_TMP" 2>/dev/null
      if [ -f "$APK_TMP" ]; then
        # 把新 manifest 塞进去（工作目录切到 TMPDIR2 保证 zip 的相对路径对）
        ( cd "$TMPDIR2" && zip -q -u "$APK_TMP" AndroidManifest.xml ) >/dev/null 2>&1
        if [ -f "$APK_TMP" ]; then
          # 去除 APK Signing Block（v2/v3 签名块在 "APK Signing Block" 标记附近）：
          # 方法 = 从尾往前找 Central Directory 位置，截断 CD 之后所有字节（就是 Signing Block + EOCD 的位置保留 CD 前面的，再拼 EOCD）。
          # 这里用一个简单鲁棒的等价方法：把所有 zip entry 用 perl 按标准 zip 格式重写为 v1-only（无 extra/扩展块），
          # 用 zip -0 转储全部 + 过滤 zip -X（no eXtra），
          # 或者更粗暴通用有效：直接 zip 重打包为只保留 entry。
          local APK_CLEAN="$TMPDIR2/clean.apk"
          local EXDIR="$TMPDIR2/ex"
          mkdir -p "$EXDIR" 2>/dev/null
          ( cd "$EXDIR" && unzip -o -q "$APK_TMP" ) >/dev/null 2>&1
          if [ -d "$EXDIR" ] && [ -n "$(ls -A "$EXDIR" 2>/dev/null)" ]; then
            rm -f "$APK_CLEAN"
            ( cd "$EXDIR" && zip -q -X -r "$APK_CLEAN" . ) >/dev/null 2>&1
            if [ -f "$APK_CLEAN" ]; then
              # ⑤ 【关键】通过模块 overlay mount 替换 → 写到 $MODPATH/system/<原始路径>
              #    这样永远不写真实系统分区，不会丢 SELinux label，重启自动生效。
              local REL=""
              case "$APK" in
                /product/*|/system_ext/*|/vendor/*|/system/*)
                  REL="${APK#/}"
                  ;;
                /data/app/*)
                  # /data/app 的 base.apk overlay 比较特殊，一般不做 overlay，
                  # 尝试直接 cp -f 原位置（/data 通常可写），但要 set_perm。
                  REL=""
                  ;;
                *)
                  # /other 也按 /system 下拼接
                  REL="system/${APK#/}"
                  ;;
              esac

              local DEST_APK=""
              if [ -n "$REL" ]; then
                DEST_APK="$MODPATH/$REL"
                mkdir -p "$(dirname "$DEST_APK")" 2>/dev/null
                cp -af "$APK_CLEAN" "$DEST_APK" 2>/dev/null
                if [ -f "$DEST_APK" ]; then
                  ui_print "     + APK 已 patch 并放入模块 overlay: $DEST_APK（重启后 overlay 生效，不写真实分区）"
                  patched_any=$((patched_any + 1))
                else
                  # 【绝不再写真实系统分区！】
                  # 即便模块 overlay 写失败（/data/adb 空间满/权限异常），也绝对不能 cp 覆盖 /product/priv-app 等真实系统 APK，
                  # 否则即便日后 disable/卸载模块也无法恢复。把 patch 好的 APK 留到 backups 目录，
                  # 由用户确认空间后再手动挪动或重刷模块。
                  local FALLBACK_APK="$BAK_DIR/${SAFE_NAME}.patched_fallback.apk"
                  cp -af "$APK_CLEAN" "$FALLBACK_APK" 2>/dev/null
                  ui_print "     ! 模块 overlay 写入 $DEST_APK 失败（可能 /data/adb 空间不足或权限问题）。"
                  ui_print "       【绝对安全兜底】未写真实系统分区，已把 patch 好的 APK 保留在: $FALLBACK_APK"
                  ui_print "       可清理空间后重刷模块，或手动把上述 APK 移到 $MODPATH/$REL（重启生效）。"
                fi
              else
                # /data/app 的 base.apk：绝不 cp 覆盖用户数据目录 APK！
                # 原 /data/app/base.apk 一旦被写 patch 版（strip 了签名）PackageManager 会因为签名不一致杀进程并移除 app，
                # 导致后续 disable 模块也恢复不了。
                # 正确做法：/data/app 来源的 base.apk 说明是更新版 MiuiHome，先降级卸载更新（恢复读 /product/priv-app）才是正道
                # 这里把 patch 好的 APK 保留到 backups，供后续手动用 pm install 正常方式安装（不破坏原 /data/app）
                local FALLBACK_APK="$BAK_DIR/${SAFE_NAME}.data_app_patched.apk"
                cp -af "$APK_CLEAN" "$FALLBACK_APK" 2>/dev/null
                ui_print "     => 检测到来源为 /data/app/base.apk（用户更新版 MiuiHome）"
                ui_print "        【绝对安全兜底】不覆盖原 /data/app（否则会杀 app + 签名不一致），已把 patch 好的 APK 保留在:"
                ui_print "           $FALLBACK_APK"
                ui_print "        如想生效请先  设置->应用->桌面->卸载更新  恢复到 /product 版，再重刷模块选 APK Patch。"
              fi
            fi
          fi
          rm -rf "$EXDIR" "$APK_CLEAN"
        fi
      fi
    elif [ "$MODIFIED" -eq 1 ]; then
      ui_print "     [!] 环境缺少 zip，无法把 manifest 回写进 APK（需要 busybox zip）"
    fi

    # ⑥ 不管改没改，保留备份在模块目录
    ui_print "     + 备份保留在: $BAK"

    rm -rf "$TMPDIR2"
  done

  ui_print " "
  if [ "$patched_any" -gt 0 ]; then
    ui_print "[APK Patch] 完成：已修改 $patched_any / 尝试 $attempted / 扫描 $total_scanned 个桌面 APK"
    ui_print "     [重要] 所有修改均写入 $MODPATH/system/... overlay 目录（不破坏原系统 APK），"
    ui_print "           重启后 Magisk/KernelSU 自动 mount 替换，卸载模块即 100% 恢复原状。"
  else
    ui_print "[APK Patch] 流程完成：尝试 $attempted / 扫描 $total_scanned 个桌面 APK"
    if [ "$total_scanned" -eq 0 ]; then
      ui_print "       未在常见路径找到 com.miui.home"
    else
      ui_print "       全部 APK manifest 均无需修改（没有 required=true 的 uses-library 或已 patch 过）；已在模块目录保留备份"
    fi
  fi
  touch "$MODPATH/homepatch_applied"
  set_perm "$MODPATH/homepatch_applied" 0 0 0644
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
ui_print "HyperOS Rust Runtime v3~v5"
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
