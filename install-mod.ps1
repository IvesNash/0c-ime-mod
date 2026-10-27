# 下載並安裝最新的靈犀注音改裝版，並設定每天自動更新。需要系統管理員權限（更新輸入法 DLL）。
#
#   手動安裝／更新：irm https://raw.githubusercontent.com/IvesNash/0c-ime-mod/main/install-mod.ps1 | iex
#   自動更新（排程呼叫）：install-mod.ps1 -Auto
#     有新的改裝版就安裝；官方同版蓋掉改裝版時也會裝回改裝版。要回到官方版請先 -RemoveSchedule。
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

# 開機剛登入時網路可能還沒好：自動更新最多等 3 分鐘再放棄。
$release = $null
for ($try = 1; -not $release; $try++) {
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "0c-ime-mod" }
    } catch {
        if (-not $Auto -or $try -ge 6) {
            Log "無法取得最新版本：$($_.Exception.Message)"
            if ($Auto) { return } else { throw }
        }
        Start-Sleep -Seconds 30
    }
}
$latest = $release.tag_name -replace '^v', ''

# 版本的數字部分（0.2.6-mod.2 → 0.2.6）。
function BaseVersion($v) { try { [version](($v -split '-')[0]) } catch { $null } }

if ($Auto) {
    if (-not $installed) { Log "找不到已安裝的靈犀注音，不自動更新"; return }
    if ($installed -eq $latest) { return }
    # 官方版蓋掉了改裝版（例如在設定程式按了更新）：官方版不比改裝版的基礎版本新時，自動把改裝版裝回去。
    # 官方版比較新時，等 GitHub 做出對應的改裝版再裝。
    if ($installed -notlike "*-mod.*") {
        $mine = BaseVersion $installed; $theirs = BaseVersion $latest
        if (-not $mine -or -not $theirs -or $mine -gt $theirs) { Log "目前是官方版 $installed，改裝版 $latest 還沒跟上，先不更新"; return }
        Log "官方版 $installed 蓋掉了改裝版，裝回改裝版"
    }
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
    # 改裝版的版本號（0.2.6-mod.2）照版本規則比官方同版（0.2.6）舊，要明確允許「降級」。
    $bundleDir = $install.Directory.FullName
    $bundleUpdater = Join-Path $bundleDir "0c-update.exe"
    $steps += "& '$bundleUpdater' install -bundle '$bundleDir' -channel internal-preview -allow-downgrade; if (`$LASTEXITCODE -ne 0) { throw '安裝失敗，請查看上方錯誤' }"
}
$steps += "if (Test-Path '$updater') { & '$updater' mode manual | Out-Null }"
$steps += @"
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$self" -Auto'
`$every = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(12).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 3650)
`$triggers = @(`$every, (New-ScheduledTaskTrigger -AtLogOn -User '$env:USERDOMAIN\$env:USERNAME'))
`$principal = New-ScheduledTaskPrincipal -UserId '$env:USERDOMAIN\$env:USERNAME' -LogonType Interactive -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName '$TaskName' -Action `$action -Trigger `$triggers -Principal `$principal -Settings `$settings -Force | Out-Null
"@

# 把這個腳本存一份在本機，排程執行的是這份（每次安裝都更新成最新的）。
New-Item -ItemType Directory -Force -Path $ModDir | Out-Null
try {
    # 用 API 取，不經過 raw.githubusercontent.com 的快取（剛推上去的幾分鐘內會拿到舊版）。
    $source = Invoke-WebRequest "https://api.github.com/repos/$Repo/contents/install-mod.ps1" -UseBasicParsing `
        -Headers @{ "User-Agent" = "0c-ime-mod"; "Accept" = "application/vnd.github.raw" }
    [IO.File]::WriteAllText($self, [Text.Encoding]::UTF8.GetString($source.RawContentStream.ToArray()), (New-Object Text.UTF8Encoding $true))
} catch {
    if ($PSCommandPath -and $PSCommandPath -ne $self) { Copy-Item $PSCommandPath $self -Force }
}

# 安裝是否真的成功：看安裝收據的版本有沒有換成改裝版。
function CheckInstalled {
    if (-not $install) { return }
    $now = $null
    try { $now = (Get-Content $receipt -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
    if ($now -eq $latest) { Log "改裝版 $latest 安裝完成" }
    else { Log "改裝版 $latest 安裝失敗（目前仍是 $now），請把安裝視窗的錯誤訊息截圖" }
}

if ($admin) {
    try { foreach ($step in $steps) { Invoke-Expression $step } } catch { Log "安裝過程出錯：$($_.Exception.Message)" }
    CheckInstalled
    if (-not $Auto) { Write-Host "完成。之後每 2 小時與登入時會自動檢查改裝版更新（紀錄：$LogFile）。" }
} elseif ($Auto) {
    Log "沒有系統管理員權限，略過自動更新"
} else {
    $script = Join-Path $ModDir "admin-steps.ps1"
    $body = ($steps -join "`r`n") + "`r`nWrite-Host '完成，之後每 2 小時與登入時會自動檢查改裝版更新。'`r`nRead-Host '按 Enter 結束'"
    [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding $true))
    Write-Host "需要系統管理員權限，請在跳出的視窗按「是」。"
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script)
    CheckInstalled
}
