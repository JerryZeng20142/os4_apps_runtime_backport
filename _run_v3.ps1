$d='c:\Users\jerry\OneDrive\Desktop\偷渡OS4所需的库'
$dl='D:\Users\jerry\Downloads\Telegram Desktop'
Write-Host "=== looking for latest 系统桌面 APK in $dl ==="
$candidates = Get-ChildItem -LiteralPath $dl -File -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -like '*系统桌面*RELEASE-8*.apk' -or $_.Name -like '*miuihome*RELEASE-8*.apk'
} | Sort-Object LastWriteTime -Descending
if($candidates -and $candidates.Count -gt 0){
  $src = $candidates[0].FullName
  Write-Host ("LATEST: {0}  size={1:N2}MB" -f $src, ($candidates[0].Length/1MB))
} else {
  throw "No RELEASE-8 APK found in $dl"
}
Write-Host "Copy to $d\miuihome_os4_src.apk"
Copy-Item -LiteralPath $src -Destination (Join-Path $d 'miuihome_os4_src.apk') -Force
Set-Location -LiteralPath $d
& (Join-Path $d '_patch_miuihome_win_v3.ps1') -Root $d -SrcApk (Join-Path $d 'miuihome_os4_src.apk') -OutApk (Join-Path $d 'miuihome_os4_patched.apk') -Align 4
if($LASTEXITCODE -ne 0){ Write-Host "SCRIPT FAIL exit=$LASTEXITCODE" ; exit 1 }
Write-Host "`n--- extra: sha of src 3 so ---"
$soDir=Join-Path $d 'system_ext\lib64'
@('libmisqlite3.so','librust_maml_sdk.so','libhyper_os_flutter.so') | ForEach-Object {
  $f=Join-Path $soDir $_
  Write-Host ("  {0} size={1:N0}  sha[:12]={2}" -f $_, (Get-Item $f).Length, (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.Substring(0,12))
}
Write-Host "`n--- extract patched apk libs to tmp, verify SHA match ---"
$tmpv = Join-Path $env:TEMP ("mh3_verify_"+[guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmpv -Force | Out-Null
try {
  $z=[System.IO.Compression.ZipFile]::OpenRead((Join-Path $d 'miuihome_os4_patched.apk'))
  try {
    @('libmisqlite3.so','librust_maml_sdk.so','libhyper_os_flutter.so') | ForEach-Object {
      $entry = $z.GetEntry(('lib/arm64-v8a/'+$_))
      $target = Join-Path $tmpv $_
      $s=$entry.Open(); try { $fs=[IO.File]::Create($target); try { $s.CopyTo($fs) } finally { $fs.Dispose() } } finally { $s.Dispose() }
      $srcSha=(Get-FileHash -LiteralPath (Join-Path $soDir $_) -Algorithm SHA256).Hash
      $extSha=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
      $ok = $srcSha -eq $extSha
      Write-Host ("  SHA256 match [{0}]  {1}  {2}" -f $ok, $_, ($extSha.Substring(0,16)))
      if(-not $ok){ throw "SHA mismatch for $_" }
    }
  } finally { $z.Dispose() }
} finally { Remove-Item -LiteralPath $tmpv -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`nAll verification PASSED. Cleanup temp files."
Remove-Item -LiteralPath (Join-Path $d 'miuihome_os4_src.apk') -Force
Remove-Item -LiteralPath (Join-Path $d '_patch_miuihome_win_v3.ps1') -Force
Write-Host "DONE."
