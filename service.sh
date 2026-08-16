#!/system/bin/sh

MODDIR=${0%/*}

# 按 Magisk 标准目录结构：system / system_ext 平级放置
# 所有 chcon / start hyos_spawner 都加了存在性判断，缺路径不会报错。

# --- system 分区（system/lib64） ---
if [ -d "$MODDIR/system" ]; then
  if [ -d "$MODDIR/system/lib64" ]; then
    chcon u:object_r:system_lib_file:s0 "$MODDIR"/system/lib64/*.so 2>/dev/null
  fi
fi

# --- system_ext 分区（独立平级目录，包含 Rust Runtime 主体） ---
if [ -d "$MODDIR/system_ext" ]; then
  if [ -f "$MODDIR/system_ext/bin/hyos_spawner" ]; then
    chcon u:object_r:zygote_exec:s0   "$MODDIR/system_ext/bin/hyos_spawner" 2>/dev/null
  fi
  if [ -d "$MODDIR/system_ext/lib64" ]; then
    chcon u:object_r:system_lib_file:s0 "$MODDIR"/system_ext/lib64/*.so 2>/dev/null
  fi
  if [ -d "$MODDIR/system_ext/framework" ]; then
    chcon u:object_r:system_file:s0    "$MODDIR"/system_ext/framework/*.jar 2>/dev/null
  fi
  # 只要 system_ext/ 存在（即 Rust Runtime 主体存在），就激活运行时标志
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

# hyos_spawner 在 system_ext 下（平级目录），且 runtime 已激活才启动
if [ -f "$MODDIR/system_ext/bin/hyos_spawner" ] && [ "$(getprop rust.runtime_active)" = "1" ]; then
  start hyos_spawner >/dev/null 2>&1
fi
