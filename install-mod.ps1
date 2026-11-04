# 下載並安裝最新的靈犀注音改裝版，並設定每天自動更新。需要系統管理員權限（更新輸入法 DLL）。
#
#   手動安裝／更新：irm https://api.github.com/repos/IvesNash/0c-ime-mod/contents/install-mod.ps1 -Headers @{Accept='application/vnd.github.raw'} | iex
#   自動更新（排程呼叫）：install-mod.ps1 -Auto
#     有新的改裝版就安裝；官方同版蓋掉改裝版時也會裝回改裝版。要回到官方版請先 -RemoveSchedule。
#   取消自動更新：& "$env:ProgramFiles\0c-ime-mod\install-mod.ps1" -RemoveSchedule
#
# 安全：排程以系統管理員權限執行，所以它執行的腳本與下載暫存都放在只有系統管理員能寫入的
# C:\Program Files\0c-ime-mod。排程用的腳本取自 Release（與安裝包一樣核對雜湊），不直接抓 main 分支。
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Argv = @($args)
$Repo = "IvesNash/0c-ime-mod"
$Auto = $Argv -contains "-Auto"
$TaskName = "0c-ime-mod 自動更新"
$Zuin = Join-Path $env:LOCALAPPDATA "Zuin"
$LogDir = Join-Path $env:LOCALAPPDATA "0c-ime-mod"   # 只放紀錄
$LogFile = Join-Path $LogDir "update.log"
$ProgDir = Join-Path $env:ProgramFiles "0c-ime-mod"  # 只有系統管理員能寫入
$Self = Join-Path $ProgDir "install-mod.ps1"
$WorkRoot = Join-Path $ProgDir "work"
$Receipt = Join-Path $Zuin "install-receipt.json"
$Updater = Join-Path $Zuin "bin\0c-update.exe"
$ScriptUrl = "https://api.github.com/repos/$Repo/contents/install-mod.ps1"
$Headers = @{ "User-Agent" = "0c-ime-mod" }

function Log($text) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $text
    Write-Host $text
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function InstalledVersion {
    if (-not (Test-Path $Receipt)) { return $null }
    try { return (Get-Content $Receipt -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { return $null }
}

# 版本的數字部分（0.2.6-mod.2 → 0.2.6）。
function BaseVersion($v) { try { [version](($v -split '-')[0]) } catch { $null } }

# 下載 Release 裡的檔案並核對雜湊；不符就刪掉並中止。
function Fetch($release, $name, $dir) {
    $file = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    $sum = $release.assets | Where-Object { $_.name -eq "$name.sha256" } | Select-Object -First 1
    if (-not $file -or -not $sum) { throw "Release $($release.tag_name) 沒有 $name" }
    $path = Join-Path $dir $name
    if ($file.size -gt 5MB) { Write-Host "下載 $name（$([math]::Round($file.size / 1MB)) MB）…" }
    Invoke-WebRequest $file.browser_download_url -OutFile $path -UseBasicParsing
    $content = (Invoke-WebRequest $sum.browser_download_url -UseBasicParsing).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $expected = ($content.Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Remove-Item $path -Force; throw "$name 雜湊不符，已刪除" }
    return $path
}

# 排程是否已經是新的設定（執行 Program Files 裡的腳本、每天一次）。
function ScheduleOk {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task -or -not (Test-Path $Self)) { return $false }
    if (-not (($task.Actions | Select-Object -First 1).Arguments -like "*$Self*")) { return $false }
    return -not ($task.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval })
}

# 把（已核對雜湊的）腳本放進 Program Files，建立每天的排程，並清掉舊版留在使用者資料夾的檔案。
function InstallSchedule($script) {
    Copy-Item $script $Self -Force
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Self`" -Auto"
    $daily = New-ScheduledTaskTrigger -Daily -At "10:47"   # GitHub 每天 10:17 編譯，30 分鐘後檢查
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($daily, $logon) -Principal $principal -Settings $settings -Force | Out-Null
    if (Test-Path $Updater) { & $Updater mode manual | Out-Null }   # 免得官方自動更新蓋掉改裝版
    # 舊版放在使用者可寫入位置的腳本與暫存（排程已改指向 Program Files 之後才刪）。
    foreach ($old in "install-mod.ps1", "admin-steps.ps1") {
        Remove-Item (Join-Path $LogDir $old) -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $env:TEMP -Directory -Filter "0c-ime-mod-*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Main {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        if ($Auto) { Log "沒有系統管理員權限，略過自動更新"; return }
        # 整個腳本以系統管理員身分重新執行，不經過使用者可寫入的中繼檔案。
        Write-Host "需要系統管理員權限，請在跳出的視窗按「是」。"
        if ($PSCommandPath) {
            $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Pause " + ($Argv -join " ")
        } else {
            $cmd = "irm '$ScriptUrl' -Headers @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = '0c-ime-mod' } | iex; Read-Host '按 Enter 結束'"
            $argLine = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        }
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $argLine
        return
    }

    if ($Argv -contains "-RemoveSchedule") {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $ProgDir) { Remove-Item $ProgDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "已取消自動更新。"
        return
    }

    $installed = InstalledVersion

    # 開機剛登入時網路可能還沒好：自動更新最多等 3 分鐘再放棄。
    $release = $null
    for ($try = 1; -not $release; $try++) {
        try {
            $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $Headers
        } catch {
            if (-not $Auto -or $try -ge 6) { Log "無法取得最新版本：$($_.Exception.Message)"; if ($Auto) { return } else { throw } }
            Start-Sleep -Seconds 30
        }
    }
    $latest = $release.tag_name -replace '^v', ''

    # 要不要安裝改裝版
    $install = $false
    if ($installed -eq $latest) {
        if (-not $Auto) { Write-Host "已經是最新的改裝版 $latest。" }
    } elseif ($Auto -and -not $installed) {
        Log "找不到已安裝的靈犀注音，不自動更新"
    } elseif ($Auto -and $installed -notlike "*-mod.*") {
        # 官方版蓋掉了改裝版（例如在設定程式按了更新）：官方版不比改裝版的基礎版本新時，自動把改裝版裝回去。
        # 官方版比較新時，等 GitHub 做出對應的改裝版再裝。
        $mine = BaseVersion $installed; $theirs = BaseVersion $latest
        if (-not $mine -or -not $theirs -or $mine -gt $theirs) { Log "目前是官方版 $installed，改裝版 $latest 還沒跟上，先不更新" }
        else { Log "官方版 $installed 蓋掉了改裝版，裝回改裝版"; $install = $true }
    } else {
        $install = $true
    }

    # 手動執行、安裝新版、或排程還是舊設定時，都從這個 Release 更新排程腳本。
    $schedule = (-not $Auto) -or $install -or -not (ScheduleOk)
    if (-not $install -and -not $schedule) { return }

    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    $work = Join-Path $WorkRoot $release.tag_name
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        if ($schedule) {
            InstallSchedule (Fetch $release "install-mod.ps1" $work)
            if (-not $Auto) { Log "排程已設定：每天 10:47 與登入時檢查改裝版更新" }
        }
        if ($install) {
            Log "安裝改裝版 $latest（目前 $installed）"
            $zipName = ($release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1).name
            if (-not $zipName) { throw "最新 Release 沒有安裝包：$($release.html_url)" }
            $zip = Fetch $release $zipName $work
            $bundle = Join-Path $work "bundle"
            Expand-Archive $zip -DestinationPath $bundle
            Get-ChildItem $bundle -Recurse | Unblock-File
            $inner = Get-ChildItem $bundle -Recurse -Filter install.ps1 | Select-Object -First 1
            if (-not $inner) { throw "安裝包裡沒有 install.ps1" }
            $bundleDir = $inner.Directory.FullName
            # 改裝版的版本號（0.2.6-mod.2）照版本規則比官方同版（0.2.6）舊，要明確允許「降級」。
            & (Join-Path $bundleDir "0c-update.exe") install -bundle $bundleDir -channel internal-preview -allow-downgrade
            if ($LASTEXITCODE -ne 0) { throw "安裝失敗，請查看上方錯誤" }
            $now = InstalledVersion
            if ($now -eq $latest) { Log "改裝版 $latest 安裝完成" }
            else { Log "改裝版 $latest 安裝失敗（目前仍是 $now），請把安裝視窗的錯誤訊息截圖" }
        }
    } catch {
        Log "更新出錯：$($_.Exception.Message)"
        if (-not $Auto) { throw }
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try { Main } finally { if ($Argv -contains "-Pause") { Read-Host "按 Enter 結束" } }
