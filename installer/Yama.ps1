param(
    [string]$GamePath,
    [string]$DocumentsPath,
    [switch]$Restore,
    [string]$BackupPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function SafePath([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw 'Paket içinde geçersiz dosya yolu var.' }
    $base = FullPath $Root
    $result = FullPath (Join-Path $base $Relative)
    if (-not $result.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dosya yolu izin verilen klasörün dışında.'
    }
    $scan = $result
    while ($scan) {
        if (Test-Path -LiteralPath $scan) {
            if ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Bağlantılı klasör veya dosya desteklenmiyor: $scan"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($scan)
        if ($parent -eq $scan) { break }
        $scan = $parent
    }
    return $result
}
function Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function CopyFile([string]$Source, [string]$Destination) {
    $dir = [IO.Path]::GetDirectoryName($Destination)
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}
function SaveRecord($Record, [string]$Folder) {
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Folder 'kurulum-kaydi.json') -Encoding UTF8
}
function UndoFile($Entry, [string]$Folder) {
    $target = SafePath $Entry.root $Entry.path
    if ($Entry.existed) {
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Hash $target) -eq $Entry.before) { return }
        CopyFile (SafePath $Folder $Entry.backup) $target
        if ((Hash $target) -ne $Entry.before) { throw "Yedek geri yüklenemedi: $target" }
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }
}

try {
    if (-not $GamePath) {
        Write-Host 'Battlefield V Türkçe Yama'
        $GamePath = (Read-Host 'bfv.exe dosyasının bulunduğu oyun klasörünü yazın').Trim('"')
    }
    $GamePath = FullPath $GamePath
    if (-not (Test-Path -LiteralPath (SafePath $GamePath 'bfv.exe') -PathType Leaf)) {
        throw 'Bu klasörde bfv.exe bulunamadı. Oyunun ana klasörünü seçin.'
    }
    if (Get-Process -Name 'bfv','bfvTrial' -ErrorAction SilentlyContinue) {
        throw 'Önce Battlefield V oyununu kapatın.'
    }
    if (-not $DocumentsPath) { $DocumentsPath = [Environment]::GetFolderPath('MyDocuments') }
    if (-not $DocumentsPath) { throw 'Belgeler klasörü bulunamadı.' }
    $DocumentsPath = FullPath $DocumentsPath

    if ($Restore) {
        if (-not $BackupPath) {
            $candidates = @(Get-ChildItem -LiteralPath $GamePath -Directory -Filter 'BFV-Yama-Yedek-*' |
                Sort-Object Name -Descending | Where-Object {
                    $recordFile = Join-Path $_.FullName 'kurulum-kaydi.json'
                    if (Test-Path -LiteralPath $recordFile) {
                        (Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8 | ConvertFrom-Json).status -eq 'installed'
                    }
                })
            if ($candidates.Count -eq 0) { throw 'Geri alınabilecek bir kurulum yedeği bulunamadı.' }
            $BackupPath = $candidates[0].FullName
        }
        $requestedBackup = FullPath $BackupPath
        $BackupPath = SafePath $GamePath ([IO.Path]::GetFileName($requestedBackup))
        if ($requestedBackup -ne $BackupPath -or [IO.Path]::GetFileName($BackupPath) -notlike 'BFV-Yama-Yedek-*') {
            throw 'Yedek klasörü seçilen oyun klasörünün içinde olmalı.'
        }
        $record = Get-Content -LiteralPath (Join-Path $BackupPath 'kurulum-kaydi.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.game -ne $GamePath -or $record.status -ne 'installed') { throw 'Bu yedek geçerli bir kurulum kaydı değil.' }
        foreach ($entry in $record.files) {
            if ($entry.root -ne $GamePath -and $entry.root -ne $record.documents) { throw 'Yedek kaydında geçersiz hedef var.' }
            $target = SafePath $entry.root $entry.path
            if (Test-Path -LiteralPath $target) {
                $currentHash = Hash $target
                if ($currentHash -ne $entry.after -and (-not $entry.existed -or $currentHash -ne $entry.before)) {
                    throw "Kurulumdan sonra değişen dosya bulundu; korunması için geri alma durduruldu: $target"
                }
            }
            if ($entry.existed -and (Hash (SafePath $BackupPath $entry.backup)) -ne $entry.before) {
                throw 'Yedek dosyasının bütünlük kontrolü başarısız.'
            }
        }
        foreach ($entry in $record.files) { UndoFile $entry $BackupPath }
        $record.status = 'restored'
        SaveRecord $record $BackupPath
        Write-Host 'Yama kaldırıldı; önceki dosyalar geri yüklendi.' -ForegroundColor Green
        exit 0
    }

    if (-not (Test-Path -LiteralPath (SafePath $GamePath 'Data/Win32/installation/patch35installpkg/cas_01.cas') -PathType Leaf)) {
        throw 'Yamanın beklediği oyun dosyası bulunamadı: patch35installpkg/cas_01.cas. Bu oyun sürümü desteklenmiyor olabilir.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dosyalar.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.Count -ne 9) { throw 'Paket dosya listesi eksik veya değiştirilmiş.' }
    $entries = @()
    $seen = @{}
    foreach ($file in $manifest) {
        $source = SafePath $PSScriptRoot $file.source
        if ((Hash $source) -ne $file.sha256 -or (Get-Item -LiteralPath $source).Length -ne $file.size) {
            throw "Paket dosyası eksik veya bozuk: $($file.source)"
        }
        if ($file.area -eq 'game') { $root = $GamePath }
        elseif ($file.area -eq 'documents') { $root = $DocumentsPath }
        else { throw 'Paket hedefi geçersiz.' }
        $target = SafePath $root $file.path
        if ($seen.ContainsKey($target)) { throw 'Paket içinde yinelenen dosya yolu var.' }
        $seen[$target] = $true
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Dosya yerine klasör bulundu: $target"
        }
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        $before = $null
        if ($existed) { $before = Hash $target }
        $entries += [PSCustomObject]@{ operation='install'; root=$root; path=$file.path; source=$file.source; existed=$existed;
            before=$before; after=$file.sha256; backup=('onceki/' + $file.area + '/' + $file.path) }
    }
    foreach ($launcher in @('EAAntiCheat.GameServiceLauncher.exe','EAAntiCheat.GameServiceLauncher.exe_b')) {
        $target = SafePath $GamePath $launcher
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Başlatıcı yerine klasör bulundu: $launcher" }
            $entries += [PSCustomObject]@{ operation='remove_launcher'; root=$GamePath; path=$launcher; source=$null;
                existed=$true; before=(Hash $target); after=$null; backup=('onceki/game/' + $launcher) }
        }
    }
    $different = @($entries | Where-Object { -not $_.existed -or $_.before -ne $_.after })
    if ($different.Count -eq 0) {
        Write-Host 'Bu yama zaten kurulu; tüm dosyalar doğrulandı.' -ForegroundColor Green
        exit 0
    }
    $backupName = 'BFV-Yama-Yedek-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $BackupPath = SafePath $GamePath $backupName
    [IO.Directory]::CreateDirectory($BackupPath) | Out-Null
    foreach ($entry in $entries) {
        if ($entry.existed) {
            $saved = SafePath $BackupPath $entry.backup
            CopyFile (SafePath $entry.root $entry.path) $saved
            if ((Hash $saved) -ne $entry.before) { throw 'Yedekleme sırasında dosya değişti; kurulum durduruldu.' }
        }
    }
    $record = [PSCustomObject]@{ version=2; status='installing'; game=$GamePath; documents=$DocumentsPath;
        date=(Get-Date).ToString('o'); files=$entries }
    SaveRecord $record $BackupPath
    $attempted = @()
    try {
        foreach ($entry in $entries) {
            $attempted += $entry
            $target = SafePath $entry.root $entry.path
            if ($entry.operation -eq 'remove_launcher') {
                if ((Hash $target) -ne $entry.before) { throw "Başlatıcı yedeklemeden sonra değişti: $($entry.path)" }
                Remove-Item -LiteralPath $target -Force
                if (Test-Path -LiteralPath $target) { throw "Başlatıcı kaldırılamadı: $($entry.path)" }
            } else {
                $source = SafePath $PSScriptRoot $entry.source
                CopyFile $source $target
                if ((Hash $target) -ne $entry.after) { throw "Kurulan dosya doğrulanamadı: $($entry.path)" }
            }
        }
        $record.status = 'installed'
        SaveRecord $record $BackupPath
    } catch {
        $installError = $_.Exception.Message
        [array]::Reverse($attempted)
        $rollbackErrors = @()
        foreach ($entry in $attempted) {
            try { UndoFile $entry $BackupPath } catch { $rollbackErrors += $_.Exception.Message }
        }
        $record.status = 'rolled_back'
        if ($rollbackErrors.Count) { $record.status = 'recovery_needed' }
        SaveRecord $record $BackupPath
        if ($rollbackErrors.Count) { throw "Kurulum başarısız: $installError. Yedekten elle kurtarma gerekli: $BackupPath. $($rollbackErrors -join '; ')" }
        throw "Kurulum tamamlanamadı; değişiklikler geri alındı. $installError"
    }
    Write-Host 'Türkçe yama kuruldu; 9 dosyanın tamamı doğrulandı.' -ForegroundColor Green
    Write-Host "Yedek: $BackupPath"
    Write-Host 'EA uygulamasını çevrimdışı moda alın. Oyunun metin dilini İngilizce seçin ve altyazıları açın.'
    Write-Host 'Çevrimiçi oynamadan önce Geri-Al.cmd ile yamayı kaldırın.'
    exit 0
} catch {
    Write-Host ("HATA: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Erişim reddedildiyse kurulum dosyasını yönetici olarak çalıştırın.'
    exit 1
}
