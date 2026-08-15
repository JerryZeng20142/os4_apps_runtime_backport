#!/system/bin/sh

MODDIR=${0%/*}

# 注意：v0.2.9 起按你的要求删除了 hyperos-v5-runtime-v1.1 + Vulkan etc 全部 system/ 内容，
# 所以 system/ 树默认不存在。下面所有 chcon / start hyos_spawner 都加了存在性判断，
# 如果之后你把 system/ 加回模块，这些操作会自动生效。
if [ -d "$MODDIR/system" ]; then
  if [ -f "$MODDIR/system/system_ext/bin/hyos_spawner" ]; then
    chcon u:object_r:zygote_exec:s0   "$MODDIR/system/system_ext/bin/hyos_spawner" 2>/dev/null
  fi
  if [ -d "$MODDIR/system/system_ext/lib64" ]; then
    chcon u:object_r:system_lib_file:s0 "$MODDIR"/system/system_ext/lib64/*.so 2>/dev/null
  fi
  if [ -d "$MODDIR/system/system_ext/framework" ]; then
    chcon u:object_r:system_file:s0    "$MODDIR"/system/system_ext/framework/*.jar 2>/dev/null
  fi
  if [ -d "$MODDIR/system/lib64" ]; then
    chcon u:object_r:system_lib_file:s0 "$MODDIR"/system/lib64/*.so 2>/dev/null
  fi
  # 只有 system/ 存在的情况下，才认为有 Rust Runtime 需要激活：
  setprop rust.runtime_version 3.1.0
  setprop rust.runtime_active 1
fi

if [ -f "$MODDIR/enable_version_spoof" ]; then
  resetprop -n ro.mi.os.version.code 4 2>/dev/null
  resetprop -n ro.mi.os.version.incremental 4.0.0.0 2>/dev/null
  resetprop -n ro.mi.os.version.name 4.0 2>/dev/null
fi

i=0
while [ "$i" -lt 30 ] && [ "$(getprop init.svc.zygote)" != "running" ]; do
  sleep 1
  i=$((i + 1))
done

# 只有在 hyos_spawner 确实存在（即用户后续把 system/ 加回模块）时才 start
if [ -f "$MODDIR/system/system_ext/bin/hyos_spawner" ] && [ "$(getprop rust.runtime_active)" = "1" ]; then
  start hyos_spawner >/dev/null 2>&1
fi
