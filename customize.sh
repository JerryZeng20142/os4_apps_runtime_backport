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
# 【音量键选择】是否将系统版本伪装为 HyperOS 4
# ============================================================
volkey_choose_spoof() {
  SPOOF_CHOICE=0

  ui_print " "
  ui_print " "
  ui_print "[选择] 是否伪装 HyperOS 版本为 OS 4？"
  ui_print "[请注意] 启用伪装能解锁更完整的体验（如柔光玻璃），但会使所有 APP 将系统识别为 OS 4（这将导致 HyperCeiler 等软件拒绝提供服务）。"
  ui_print "  音量+  => 启用伪装"
  ui_print "  音量-  => 不启用 / 取消已有伪装"
  ui_print " "

  volkey_prompt 0 "不启用伪装"
  SPOOF_CHOICE=$VOLKEY_RESULT
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
    ui_print "  [OK] 全部关键符号已就位，OS4 APP 应能正常加载。"
  fi
}

# ============================================================
# 主流程
# ============================================================

ui_print " "
ui_print " "
ui_print "HyperOS 4 APP Runtime Backport"
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

# ---------- 动态 system/ 权限 ----------
# 注意：v0.2.9 开始整个 system/ 内容（来自 hyperos-v5-runtime-v1.1 + Vulkan etc）
# 已全部按你的要求移除，因此默认不存在 system/ 树。
# 如果之后用户再次手动把 .so / permissions XML 加回 system/，
# 这里按对应目录 / 文件存在性自动授权（不依赖固定路径列表，不会因为缺路径 abort）。
if [ -d "$MODPATH/system" ]; then
  set_perm_recursive "$MODPATH/system" 0 0 0755 0644
  if [ -d "$MODPATH/system/system_ext" ]; then
    set_perm_recursive "$MODPATH/system/system_ext" 0 0 0755 0644
    if [ -d "$MODPATH/system/system_ext/lib64" ]; then
      set_perm_recursive "$MODPATH/system/system_ext/lib64" 0 0 0755 0644 u:object_r:system_lib_file:s0
    fi
    if [ -f "$MODPATH/system/system_ext/bin/hyos_spawner" ]; then
      set_perm "$MODPATH/system/system_ext/bin/hyos_spawner" 0 2000 0755 u:object_r:zygote_exec:s0
    fi
    if [ -f "$MODPATH/system/system_ext/etc/init/init.hyos_spawner.rc" ]; then
      set_perm "$MODPATH/system/system_ext/etc/init/init.hyos_spawner.rc" 0 0 0644
    fi
    if [ -f "$MODPATH/system/system_ext/framework/hyperos.rustruntime.jar" ]; then
      set_perm "$MODPATH/system/system_ext/framework/hyperos.rustruntime.jar" 0 0 0644
    fi
  fi
  if [ -d "$MODPATH/system/product" ]; then
    set_perm_recursive "$MODPATH/system/product" 0 0 0755 0644
    for _p in hyperos.rustruntime_v3_v4_v5.xml hyperos.rustruntime_v5.xml hyperos_extra_sharedlibs_stubs.xml; do
      if [ -f "$MODPATH/system/product/etc/permissions/$_p" ]; then
        set_perm "$MODPATH/system/product/etc/permissions/$_p" 0 0 0644
      fi
    done
  fi
  if [ -d "$MODPATH/system/lib64" ]; then
    set_perm_recursive "$MODPATH/system/lib64" 0 0 0755 0644 u:object_r:system_lib_file:s0
  fi
  if [ -d "$MODPATH/system/vendor" ]; then
    set_perm_recursive "$MODPATH/system/vendor" 0 0 0755 0644
  fi
fi

if [ -f "$MODPATH/system.prop" ]; then
  set_perm "$MODPATH/system.prop" 0 0 0644
fi

# ---------- 完整性校验（动态：存在的目录/文件才检查；不再对 system/ 下固定路径硬编码）----------
ui_print " "
ui_print "Running dynamic integrity check..."
CHECK_OK=true
# 核心基础文件（脚本 / META-INF 之外的模块骨架）必须有：
for F in customize.sh module.prop service.sh post-fs-data.sh \
         META-INF/com/google/android/update-binary \
         META-INF/com/google/android/updater-script; do
  if [ -f "$MODPATH/$F" ] || [ -f "$MODPATH/../$F" ]; then
    continue
  fi
  ui_print "  WARN: skeleton $F not found under MODPATH root"
done
# 如果用户之后重新把 system/ 放回模块，只做抽样 / 非 abort 提示：
if [ -d "$MODPATH/system" ]; then
  TOTAL=0
  MISS=0
  while IFS= read -r F; do
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$F" ]; then
      MISS=$((MISS + 1))
    fi
  done <<EOF
$(find "$MODPATH/system" -type f 2>/dev/null)
EOF
  if [ "$MISS" -gt 0 ]; then
    ui_print "  WARN: $MISS / $TOTAL files listed under MODPATH/system missing."
  else
    ui_print "  OK: system/ tree intact ($TOTAL files)."
  fi
fi
# system.prop 允许空文件（零属性），不算 missing。
ui_print "  Integrity check summary: OK (skeleton valid)."
CHECK_OK=true

if [ "$KSU" = "true" ]; then
  ui_print "[INFO] KernelSU detected: ensure a system-mount metamodule (e.g. meta-overlayfs) is active."
fi

# ---------- 版本伪装开关（音量键选择）----------
volkey_choose_spoof

if [ "$SPOOF_CHOICE" = "1" ]; then
  ui_print "=> [版本伪装] 已启用 (enable_version_spoof 已创建)"
  touch "$MODPATH/enable_version_spoof"
  set_perm "$MODPATH/enable_version_spoof" 0 0 0644
else
  ui_print "=> [版本伪装] 未启用 / 已取消"
  rm -f "$MODPATH/enable_version_spoof"
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
