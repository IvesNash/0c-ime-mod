# 下載並安裝最新的靈犀注音改裝版，並設定每天自動更新。需要系統管理員權限（更新輸入法 DLL）。
#
#   手動安裝／更新：irm https://raw.githubusercontent.com/IvesNash/0c-ime-mod/main/install-mod.ps1 | iex
#   自動更新（排程呼叫）：install-mod.ps1 -Auto
#     只在目前裝的是改裝版（版本含 -mod.）而且有新版時才安裝；裝回官方版之後自動停止。
#   取消自動更新：install-mod.ps1 -RemoveSchedule
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = if ($env:ZC_MOD_REPO) { $env:ZC_MOD_REPO } else { "IvesNash/0c-ime-mod" }
$Auto = $args -contains "-Auto"
$TaskName = "0c-ime-mod 自動更新"
$Zuin = Join-Path $env:LOCALAPPDATA "Zuin"
$ModDir = Join-Path $env:LOCALAPPDATA "0c-ime-mod"
$LogFile = Join-Path $ModDir "update.log"

function Log($text) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $text
    Write-Host $text
    New-Item -ItemType Directory -Force -Path $ModDir | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

if ($args -contains "-RemoveSchedule") {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已取消自動更新。"
    return
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# 目前安裝的版本（官方安裝收據）
$installed = $null
$receipt = Join-Path $Zuin "install-receipt.json"
if (Test-Path $receipt) {
    try { $installed = (Get-Content $receipt -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
}

try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "0c-ime-mod" }
} catch {
    Log "無法取得最新版本：$($_.Exception.Message)"
    if ($Auto) { return } else { throw }
}
$latest = $release.tag_name -replace '^v', ''

if ($Auto) {
    if (-not $installed -or $installed -notlike "*-mod.*") { Log "目前不是改裝版（$installed），不自動更新"; return }
    if ($installed -eq $latest) { return }
} elseif ($installed -eq $latest) {
    Write-Host "已經是最新的改裝版 $latest。"
}

$zip = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
$sum = $release.assets | Where-Object { $_.name -like "*.zip.sha256" } | Select-Object -First 1
if (-not $zip -or -not $sum) { Log "最新 Release 沒有安裝包：$($release.html_url)"; if ($Auto) { return } else { throw "沒有安裝包" } }

if ($installed -ne $latest) {
    Log "安裝改裝版 $latest（目前 $installed）"
    $work = Join-Path $env:TEMP ("0c-ime-mod-" + $release.tag_name)
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zipPath = Join-Path $work $zip.name
    if (-not (Test-Path $zipPath)) {
        Write-Host "下載 $($zip.name)（$([math]::Round($zip.size / 1MB)) MB）…"
        Invoke-WebRequest $zip.browser_download_url -OutFile $zipPath -UseBasicParsing
    }
    $sumContent = (Invoke-WebRequest $sum.browser_download_url -UseBasicParsing).Content
    if ($sumContent -is [byte[]]) { $sumContent = [Text.Encoding]::UTF8.GetString($sumContent) }
    $expected = ($sumContent.Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Remove-Item $zipPath; Log "雜湊不符，已刪除下載的檔案"; if ($Auto) { return } else { throw "雜湊不符，請重新執行" } }

    $bundle = Join-Path $work "bundle"
    if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
    Expand-Archive $zipPath -DestinationPath $bundle
    Get-ChildItem $bundle -Recurse | Unblock-File
    $install = Get-ChildItem $bundle -Recurse -Filter install.ps1 | Select-Object -First 1
    if (-not $install) { Log "安裝包裡沒有 install.ps1"; if ($Auto) { return } else { throw "安裝包不完整" } }
} else {
    $install = $null
}

# 系統管理員要做的事：安裝、官方自動更新改成手動、建立每天的自動更新排程。
$self = Join-Path $ModDir "install-mod.ps1"
$updater = Join-Path $Zuin "bin\0c-update.exe"
$steps = @()
if ($install) {
    $steps += "& '$($install.FullName)' -Channel internal-preview"
}
$steps += "if (Test-Path '$updater') { & '$updater' mode manual | Out-Null }"
$steps += @"
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$self" -Auto'
`$triggers = @((New-ScheduledTaskTrigger -Daily -At 12:30), (New-ScheduledTaskTrigger -AtLogOn -User '$env:USERDOMAIN\$env:USERNAME'))
`$principal = New-ScheduledTaskPrincipal -UserId '$env:USERDOMAIN\$env:USERNAME' -LogonType Interactive -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName '$TaskName' -Action `$action -Trigger `$triggers -Principal `$principal -Settings `$settings -Force | Out-Null
"@

# 把這個腳本存一份在本機，排程執行的是這份（每次安裝都更新成最新的）。
New-Item -ItemType Directory -Force -Path $ModDir | Out-Null
try {
    $source = Invoke-WebRequest "https://raw.githubusercontent.com/$Repo/main/install-mod.ps1" -UseBasicParsing
    [IO.File]::WriteAllText($self, [Text.Encoding]::UTF8.GetString($source.RawContentStream.ToArray()), (New-Object Text.UTF8Encoding $true))
} catch {
    if ($PSCommandPath -and $PSCommandPath -ne $self) { Copy-Item $PSCommandPath $self -Force }
}

if ($admin) {
    foreach ($step in $steps) { Invoke-Expression $step }
    if ($install) { Log "改裝版 $latest 安裝完成" }
    if (-not $Auto) { Write-Host "完成。之後每天 12:30 與登入時會自動檢查改裝版更新（紀錄：$LogFile）。" }
} elseif ($Auto) {
    Log "沒有系統管理員權限，略過自動更新"
} else {
    $script = Join-Path $ModDir "admin-steps.ps1"
    $body = ($steps -join "`r`n") + "`r`nWrite-Host '完成，之後每天 12:30 與登入時會自動檢查改裝版更新。'`r`nRead-Host '按 Enter 結束'"
    [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding $true))
    Write-Host "需要系統管理員權限，請在跳出的視窗按「是」。"
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script)
    if ($install) { Log "改裝版 $latest 安裝完成" }
}
