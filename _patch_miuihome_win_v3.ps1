param(
  [string]$Root,
  [string]$SrcApk,
  [string]$OutApk,
  [int]$Align = 4
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Root
Add-Type -AssemblyName System.IO.Compression.FileSystem

$soDir   = Join-Path $Root 'system_ext\lib64'
$soFiles = @('libmisqlite3.so','librust_maml_sdk.so','libhyper_os_flutter.so')

Write-Host "=== Patch desktop APK (Full Repack + zipAlign $Align, no Signing Block residue) ==="
Write-Host ("  src  = {0}" -f $SrcApk)
Write-Host ("  dst  = {0}" -f $OutApk)
foreach($s in $soFiles){ if(-not (Test-Path -LiteralPath (Join-Path $soDir $s))){ throw "missing $s in $soDir" } }

# 1. 全量解包到 staging
$tmpEx = Join-Path $env:TEMP ("mh3_"+[guid]::NewGuid().ToString("N").Substring(0,8))
try {
  Write-Host ("`n--- 1. Extract source APK -> staging: {0}" -f $tmpEx)
  New-Item -ItemType Directory -Path $tmpEx -Force | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory($SrcApk, $tmpEx)

  $libDst = Join-Path $tmpEx (Join-Path 'lib' 'arm64-v8a')
  New-Item -ItemType Directory -Path $libDst -Force | Out-Null

  # 2. 复制 3 个 so，如有同名则覆盖
  Write-Host "--- 2. Copy 3 target .so into staging lib/arm64-v8a/"
  foreach($s in $soFiles){
    $dst = Join-Path $libDst $s
    if(Test-Path -LiteralPath $dst){ Remove-Item -LiteralPath $dst -Force }
    Copy-Item -LiteralPath (Join-Path $soDir $s) -Destination $dst -Force
    $sz = (Get-Item $dst).Length
    Write-Host ("  {0}  size={1:N0}" -f $s,$sz)
  }

  # 3. 决定哪些 entry 要 STORED + zipAlign：
  #    规则 Android 标准：lib/**/*.so / assets 等非压缩大文件等
  #    这里简单：所有 **/*.so 都 STORED，其他 Optimal。
  Write-Host ("`n--- 3. Build aligned ZIP (align=$Align) ---")
  if(Test-Path -LiteralPath $OutApk){ Remove-Item -LiteralPath $OutApk -Force }

  # 遍历所有文件（排序保证顺序与原尽量一致），按名分类压缩方法
  $allFiles = Get-ChildItem -LiteralPath $tmpEx -File -Recurse | Sort-Object FullName
  $soExt = [System.Collections.Generic.HashSet[string]]::new([string[]]$soFiles)

  $outFs = [IO.File]::Create($OutApk)
  try {
    $cdBuf = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($cdBuf)
    $cdEntries = 0
    $utf8 = [Text.Encoding]::UTF8

    foreach($f in $allFiles){
      $rel = $f.FullName.Substring($tmpEx.Length+1).Replace('\','/')
      $nameBytes = $utf8.GetBytes($rel)
      $nameLen = $nameBytes.Length

      # 决定压缩方法
      $isSo = $rel.StartsWith('lib/') -and $rel.EndsWith('.so')
      if($isSo){ $method = [UInt16]0 } # STORED
      else     { $method = [UInt16]8 } # DEFLATE

      # 先把文件内容压缩到临时 MemoryStream（按 method）
      $dataMs = New-Object System.IO.MemoryStream
      try {
        if($method -eq 0){
          $fs = [IO.File]::OpenRead($f.FullName)
          try { $fs.CopyTo($dataMs) } finally { $fs.Dispose() }
        } else {
          $fs = [IO.File]::OpenRead($f.FullName)
          try {
            $ds = New-Object System.IO.Compression.DeflateStream($dataMs, [System.IO.Compression.CompressionLevel]::Optimal, $true)
            try { $fs.CopyTo($ds) } finally { $ds.Dispose() }
          } finally { $fs.Dispose() }
        }
        $compressed = $dataMs.ToArray()
      } finally { $dataMs.Dispose() }

      $uncomprSize = [UInt32]$f.Length
      $comprSize   = [UInt32]$compressed.Length
      if($method -eq 0){ $comprSize = $uncomprSize }

      # 计算 local header 位置 + 需要的 padding（仅 STORED 且为 lib/*.so 时对齐）
      $lOff = [int]$outFs.Position
      $nameLen16 = [UInt16]$nameLen
      $headerBase = 30 + $nameLen16  # 30 固定头 + filename length (extraLen=0 now)

      $extraPad = 0
      if($isSo){
        $dataStart = $lOff + $headerBase
        $mod = $dataStart % $Align
        if($mod -ne 0){ $extraPad = ($Align - $mod) }
      }
      $extraLen = [UInt16]$extraPad

      # 写 Local File Header (30 bytes)
      $lhCrc32 = 0
      # 算 CRC32 (自己实现 .NET 没有内置)
      $mask = [UInt32]([Convert]::ToUInt32(4294967295))    # 0xFFFFFFFF
      $poly = [UInt32]([Convert]::ToUInt32(3988292384))    # 0xEDB88320
      $crc = $mask
      $fs2 = [IO.File]::OpenRead($f.FullName)
      try {
        $buf = New-Object byte[] 65536
        while(($read = $fs2.Read($buf,0,$buf.Length)) -gt 0){
          for($k=0; $k -lt $read; $k++){
            $crc = ($crc -bxor ([UInt32]$buf[$k]))
            for($r=0; $r -lt 8; $r++){
              if(($crc -band ([UInt32]1)) -ne 0){ $crc = (($crc -shr 1) -bxor $poly) } else { $crc = ($crc -shr 1) }
            }
          }
        }
      } finally { $fs2.Dispose() }
      $lhCrc32 = ($crc -bxor $mask)

      # LF 签名 0x04034b50
      [void]$outFs.Write([BitConverter]::GetBytes([UInt32]0x04034B50),0,4)
      [void]$outFs.Write([BitConverter]::GetBytes([UInt16]20),0,2)         # version need (2.0)
      [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0x0800),0,2)       # flags: UTF-8
      [void]$outFs.Write([BitConverter]::GetBytes($method),0,2)              # compression method
      [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0),0,2)            # last mod time
      [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0),0,2)            # last mod date
      [void]$outFs.Write([BitConverter]::GetBytes([UInt32]$lhCrc32),0,4)     # crc32
      [void]$outFs.Write([BitConverter]::GetBytes($comprSize),0,4)           # compressed size
      [void]$outFs.Write([BitConverter]::GetBytes($uncomprSize),0,4)         # uncompressed size
      [void]$outFs.Write([BitConverter]::GetBytes($nameLen16),0,2)           # filename length
      [void]$outFs.Write([BitConverter]::GetBytes($extraLen),0,2)            # extra field length (padding)
      [void]$outFs.Write($nameBytes,0,$nameLen)                              # filename
      if($extraPad -gt 0){
        $zeros = New-Object byte[] $extraPad
        [void]$outFs.Write($zeros,0,$extraPad)
      }
      # payload
      [void]$outFs.Write($compressed,0,$compressed.Length)

      # 记录 Central Directory (46 bytes + name)
      $crcCd = [UInt32]$lhCrc32
      [void]$bw.Write([UInt32]0x02014B50)
      [void]$bw.Write([UInt16]20)          # version made by (DOS)
      [void]$bw.Write([UInt16]20)          # version need
      [void]$bw.Write([UInt16]0x0800)      # flags UTF-8
      [void]$bw.Write($method)             # compression
      [void]$bw.Write([UInt16]0)           # mod time
      [void]$bw.Write([UInt16]0)           # mod date
      [void]$bw.Write([UInt32]$crcCd)
      [void]$bw.Write([UInt32]$comprSize)
      [void]$bw.Write([UInt32]$uncomprSize)
      [void]$bw.Write([UInt16]$nameLen)
      [void]$bw.Write([UInt16]$extraLen)   # extra field in CD
      [void]$bw.Write([UInt16]0)           # comment length
      [void]$bw.Write([UInt16]0)           # disk number
      [void]$bw.Write([UInt16]0)           # internal attr
      [void]$bw.Write([UInt32]0)           # external attr
      [void]$bw.Write([UInt32]$lOff)
      [void]$bw.Write($nameBytes,0,$nameLen)
      if($extraPad -gt 0){ $bw.Write((New-Object byte[] $extraPad),0,$extraPad) }
      $cdEntries++
    }

    # 写 CD
    $cdOff = [int]$outFs.Position
    $cdBuf.Position = 0
    $cdBuf.CopyTo($outFs)
    $cdSize = [UInt32]([int]$outFs.Position - $cdOff)

    # 写标准 EOCD（不写 ZIP64，避免 locator 混淆）
    [void]$outFs.Write([BitConverter]::GetBytes([UInt32]0x06054B50),0,4)
    [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0),0,2)            # disk num
    [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0),0,2)            # cd disk num
    [void]$outFs.Write([BitConverter]::GetBytes([UInt16]$cdEntries),0,2)   # entries this disk
    [void]$outFs.Write([BitConverter]::GetBytes([UInt16]$cdEntries),0,2)   # entries total
    [void]$outFs.Write([BitConverter]::GetBytes([UInt32]$cdSize),0,4)      # cd size
    [void]$outFs.Write([BitConverter]::GetBytes([UInt32]$cdOff),0,4)       # cd offset
    [void]$outFs.Write([BitConverter]::GetBytes([UInt16]0),0,2)            # comment len
  } finally { $outFs.Dispose(); $bw.Dispose() }

  # 4. 验证：用 ZipFile.OpenRead 查 entry 对齐/大小
  Write-Host "`n--- 4. Verify (entries, sizes, zipAlign $Align) ---"
  $z=[System.IO.Compression.ZipFile]::OpenRead($OutApk)
  try {
    $badAlign=0; $badSize=0
    $soEntries = @()
    foreach($entry in $z.Entries){
      if([string]$entry.FullName -and $entry.FullName.StartsWith('lib/arm64-v8a/') -and $entry.FullName.EndsWith('.so')){
        $soEntries += $entry
      }
    }
    Write-Host ("  found {0} .so entries in lib/arm64-v8a/" -f $soEntries.Count)
    foreach($e in $soEntries){
      $lOff = 0
      # ZipArchiveEntry doesn't expose RelativeOffset directly; read LF offset from our written bytes via reflection (safer: reopen, parse local header via reading bytes using the CentralDir we generated)
      # 直接用 BinaryReader 从文件读 CD 拿 offset，再算对齐（标准方式）
      $name = $e.FullName
      $uLen = $e.Length; $cLenB = $e.CompressedLength
      $srcSize = if($soExt.Contains([IO.Path]::GetFileName($name))){ (Get-Item -LiteralPath (Join-Path $soDir ([IO.Path]::GetFileName($name)))).Length } else { (Get-Item -LiteralPath (Join-Path $tmpEx ($name.Replace('/','\')))).Length }
      $sizeOK = ($uLen -eq $srcSize)
      if(-not $sizeOK){ $badSize++ }
      Write-Host ("  {0}  uncompr={1} srcSize={2}  [SRC_MATCH={3}]" -f $name,$uLen,$srcSize,$sizeOK)
    }
    Write-Host ("  total entries in new zip = {0}" -f $z.Entries.Count)
  } finally { $z.Dispose() }

  # 5. 读新 ZIP，解析 LF 计算 alignment（用 CD offset → Local Header）
  Write-Host "`n--- 5. Raw zipAlign $Align check via parsing new ZIP ---"
  $bytes = [IO.File]::ReadAllBytes($OutApk)
  # 标准 EOCD
  $nn = $bytes.Length
  $eocd = -1
  for($o = $nn-22; $o -ge 0; $o--){
    if($bytes[$o] -eq 0x50 -and $bytes[$o+1] -eq 0x4b -and $bytes[$o+2] -eq 0x05 -and $bytes[$o+3] -eq 0x06){ $eocd = $o; break }
  }
  if($eocd -lt 0){ throw "EOCD not found in output APK" }
  $startCD  = [int][BitConverter]::ToUInt32($bytes, ($eocd+16))
  $entries = [BitConverter]::ToUInt16($bytes, ($eocd+10))
  Write-Host ("  EOCD @ 0x{0:X8}  CD @ 0x{1:X8}  entries={2}" -f $eocd,$startCD,$entries)
  $pos = $startCD
  $soResults = New-Object System.Collections.Generic.List[object]
  for($i=0; $i -lt $entries; $i++){
    $sig = [BitConverter]::ToUInt32($bytes,$pos)
    if($sig -ne 0x02014B50){ break }
    $nLen = [BitConverter]::ToUInt16($bytes,($pos+28))
    $eLen = [BitConverter]::ToUInt16($bytes,($pos+30))
    $cLen = [BitConverter]::ToUInt16($bytes,($pos+32))
    $off  = [int][BitConverter]::ToUInt32($bytes,($pos+42))
    $name = [Text.Encoding]::UTF8.GetString($bytes,($pos+46),$nLen)
    if($name.StartsWith('lib/arm64-v8a/') -and $name.EndsWith('.so')){
      # local header
      $nl2 = [BitConverter]::ToUInt16($bytes,($off+26))
      $el2 = [BitConverter]::ToUInt16($bytes,($off+28))
      $dataStart = $off + 30 + $nl2 + $el2
      $a4 = ($dataStart % 4 -eq 0)
      $a8 = ($dataStart % 8 -eq 0)
      $soResults.Add([PSCustomObject]@{N=$name;DS=('0x{0:X8}' -f $dataStart);A4=$a4;A8=$a8})
    }
    $pos += 46 + $nLen + $eLen + $cLen
  }
  $soResults | Format-Table N,DS,A4,A8 -AutoSize | Out-String | Write-Host
  $bad4 = ($soResults | Where-Object {-not $_.A4}).Count
  $fiI = Get-Item $SrcApk; $fiO = Get-Item $OutApk
  $hO  = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutApk).Hash.Substring(0,12)
  Write-Host "`n=== Final ==="
  Write-Host ("  before: {0} bytes ({1:N2} MB)" -f $fiI.Length,($fiI.Length/1MB))
  Write-Host ("  after : {0} bytes ({1:N2} MB)  SHA[:12]={2}" -f $fiO.Length,($fiO.Length/1MB),$hO)
  if($bad4 -eq 0){ Write-Host "  ALIGN  OK (all 4-aligned, ZIP64-free pure standard EOCD)" } else { Write-Host ("  ALIGN FAIL: {0}/7 .so not 4-aligned (will res=-2)" -f $bad4) }
} finally {
  if(Test-Path -LiteralPath $tmpEx){ Remove-Item -LiteralPath $tmpEx -Recurse -Force -ErrorAction SilentlyContinue }
}
