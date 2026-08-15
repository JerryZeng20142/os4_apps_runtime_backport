#!/system/bin/sh

MODDIR=${0%/*}

chcon u:object_r:zygote_exec:s0   "$MODDIR/system/system_ext/bin/hyos_spawner" 2>/dev/null
chcon u:object_r:system_lib_file:s0 "$MODDIR"/system/system_ext/lib64/*.so 2>/dev/null
chcon u:object_r:system_file:s0    "$MODDIR"/system/system_ext/framework/*.jar 2>/dev/null
chcon u:object_r:system_lib_file:s0 "$MODDIR"/system/lib64/*.so 2>/dev/null

setprop rust.runtime_version 3.1.0
setprop rust.runtime_active 1

if [ -f "$MODDIR/enable_version_spoof" ]; then
  resetprop -n ro.mi.os.version.code 4 2>/dev/null
  resetprop -n ro.mi.os.version.incremental 4.0.0.0 2>/dev/null
  resetprop -n ro.mi.os.version.name 4.0 2>/dev/null
fi
