$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$src = "C:\Users\jerry\OneDrive\Desktop\偷渡OS4所需的库"
$outDir = Join-Path $src ("crash_logs_" + $stamp)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Write-Host ("[DIR] " + $outDir)

Write-Host ""
Write-Host "Step 1: adb devices"
adb devices -l

$ok = $false
$out = (adb devices -l 2>$null)
foreach ($ln in $out) {
  if ($ln -match '^\S+\s+device\s*$') { $ok = $true ; break }
  if ($ln -match '^\S+\s+device\s+') { $ok = $true ; break }
}
if (-not $ok) {
  Write-Host ""
  Write-Host "[!!!] 未检测到已授权手机（state 必须是 device，不能是 unauthorized/offline）"
  Write-Host "     请：1) 拔线重插 2) 手机弹框点『一律允许』3) 设备管理器确认 ADB 驱动正常"
  exit 1
}
Write-Host "[OK] 手机已连接 (state=device)"

Write-Host ""
Write-Host "Step 2: 拉取 6 份日志"

Write-Host "  1/6 logcat full..."
$f = Join-Path $outDir "01_logcat_full.log"
& adb shell "logcat -v threadtime -b all -d" | Out-File -LiteralPath $f -Encoding utf8
Write-Host ("        -> OK ({0} bytes)" -f (Get-Item $f).Length)

Write-Host "  2/6 logcat fatal only..."
$fullLog = Get-Content -LiteralPath (Join-Path $outDir "01_logcat_full.log") -ErrorAction SilentlyContinue
$f = Join-Path $outDir "02_logcat_fatal_only.log"
$sw = [System.IO.StreamWriter]::new($f, $false, [System.Text.UTF8Encoding]::new($false))
$patterns = @("FATAL EXCEPTION","AndroidRuntime","PackageParser","PackageManager","Failed to parse","No implementation found","java.lang.","android.content.pm.","SELinux","avc: denied","libc: Fatal signal","DEBUG: ***","signal ","BEGIN crash","MiuiHome","com.miui.home","Process","has died")
foreach ($ln in $fullLog) {
  foreach ($p in $patterns) { if ($ln.Contains($p)) { $sw.WriteLine($ln) ; break } }
}
$sw.Dispose()
Write-Host ("        -> OK ({0} bytes, {1} matches)" -f (Get-Item $f).Length, ((Get-Content $f | Measure-Object -Line).Lines))

Write-Host "  3/6 tombstones / dropbox..."
$f = Join-Path $outDir "03_tombstones_or_dropbox.txt"
$cmd = 'echo "=== /data/tombstones list ==="; ls -la /data/tombstones/ 2>/dev/null; echo; echo "=== /data/system/dropbox last crash entries (head 120 each) ==="; for f in /data/system/dropbox/*SYSTEM_TOMBSTONE* /data/system/dropbox/*system_app_crash* /data/system/dropbox/*data_app_crash* /data/system/dropbox/*system_server_anr*; do echo "----- $f -----"; zcat "$f" 2>/dev/null | head -n 120 || cat "$f" 2>/dev/null | head -n 120; echo; done'
& adb shell $cmd | Out-File -LiteralPath $f -Encoding utf8
Write-Host ("        -> OK ({0} bytes)" -f (Get-Item $f).Length)

Write-Host "  4/6 dmesg + pstore..."
$f = Join-Path $outDir "04_dmesg_pstore.log"
$cmd = 'echo "=== uname ==="; uname -a; echo "=== dmesg ==="; dmesg 2>/dev/null; echo; echo "=== /sys/fs/pstore ==="; for f in /sys/fs/pstore/*; do echo "----- $f -----"; head -n 400 "$f" 2>/dev/null; echo; done'
& adb shell $cmd | Out-File -LiteralPath $f -Encoding utf8
Write-Host ("        -> OK ({0} bytes)" -f (Get-Item $f).Length)

Write-Host "  5/6 dumpsys package MiuiHome..."
$f = Join-Path $outDir "05_dumpsys_package_MiuiHome.txt"
& adb shell dumpsys package com.miui.home | Out-File -LiteralPath $f -Encoding utf8
Write-Host ("        -> OK ({0} bytes)" -f (Get-Item $f).Length)

Write-Host "  6/6 mounts + modules + MiuiHome"
$f = Join-Path $outDir "06_mounts_modules_MiuiHome.txt"
$cmd = 'echo "=== /proc/mounts ==="; cat /proc/mounts 2>/dev/null; echo; echo "=== /product/priv-app/MiuiHome ls -laZ ==="; ls -laZ /product/priv-app/MiuiHome/ 2>/dev/null; echo; echo "=== /data/adb/modules tree (head -n 200) ==="; ls -laR /data/adb/modules/ 2>/dev/null | head -n 200; echo; echo "=== find MiuiHome.apk inside modules ==="; find /data/adb/modules -name "MiuiHome.apk" 2>/dev/null'
& adb shell $cmd | Out-File -LiteralPath $f -Encoding utf8
Write-Host ("        -> OK ({0} bytes)" -f (Get-Item $f).Length)

Write-Host ""
Write-Host "Step 3: 日志目录"
Get-ChildItem -LiteralPath $outDir | Sort-Object Name | ForEach-Object {
  $t = if ($_.PSIsContainer) { "[DIR] " } else { "[FILE]" }
  ("  {0} {1,-45} {2,14:N0} bytes" -f $t, $_.Name, $_.Length)
}
Write-Host ""
Write-Host "Step 4: Fatal-only 预览 (前 60 行)"
$fatalLog = Get-Content -LiteralPath (Join-Path $outDir "02_logcat_fatal_only.log") -TotalCount 60 -ErrorAction SilentlyContinue
if (-not $fatalLog -or $fatalLog.Count -eq 0) {
  Write-Host "  (空)"
  Write-Host "  如果锁屏刚刚崩溃过但这里为空 → 说明 adb 抓的时候 logcat buffer 被清了，请："
  Write-Host "  ① 重启手机，等它锁屏崩完 20~30 秒后再运行此脚本一次；"
  Write-Host "  ② 或在崩溃循环期间，电脑跑个实时的：adb shell logcat -v threadtime -b all > C:\实时.txt（让它崩 2 分钟就 Ctrl+C 结束）"
} else {
  $fatalLog | ForEach-Object { ("  " + $_) }
}
Write-Host ""
Write-Host ("[DONE] 全部日志在：" + $outDir)
Write-Host "       请把整个目录打包 zip 发给我，或直接贴 02_logcat_fatal_only.log / 05_dumpsys_package_MiuiHome.txt / 06_mounts_modules_MiuiHome.txt 三个文件内容过来！"
