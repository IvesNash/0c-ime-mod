# 下載並安裝最新的靈犀注音改裝版。需要系統管理員權限（更新輸入法 DLL）。
$Repo = if ($env:ZC_MOD_REPO) { $env:ZC_MOD_REPO } else { "IvesNash/0c-ime-mod" }
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "0c-ime-mod" }
$zip = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
$sum = $release.assets | Where-Object { $_.name -like "*.zip.sha256" } | Select-Object -First 1
if (-not $zip -or -not $sum) { throw "最新 Release 沒有安裝包：$($release.html_url)" }
Write-Host "改裝版 $($release.tag_name)"

$work = Join-Path $env:TEMP ("0c-ime-mod-" + $release.tag_name)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zipPath = Join-Path $work $zip.name
if (-not (Test-Path $zipPath)) {
    Write-Host "下載 $($zip.name)（$([math]::Round($zip.size / 1MB)) MB）…"
    Invoke-WebRequest $zip.browser_download_url -OutFile $zipPath -UseBasicParsing
}
$expected = ((Invoke-WebRequest $sum.browser_download_url -UseBasicParsing).Content -split '\s+')[0].Trim().ToLower()
$actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { Remove-Item $zipPath; throw "雜湊不符，已刪除下載的檔案，請重新執行" }

$bundle = Join-Path $work "bundle"
if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
Expand-Archive $zipPath -DestinationPath $bundle
$install = Get-ChildItem $bundle -Recurse -Filter install.ps1 | Select-Object -First 1
if (-not $install) { throw "安裝包裡沒有 install.ps1" }
Get-ChildItem $bundle -Recurse | Unblock-File

# 安裝後把官方自動更新改成手動，免得官方版蓋掉改裝版。
$updater = Join-Path $env:LOCALAPPDATA "Zuin\bin\0c-update.exe"
$cmd = "& '$($install.FullName)' -Channel internal-preview; " +
       "if (Test-Path '$updater') { & '$updater' mode manual }; " +
       "Write-Host '完成，可以關閉這個視窗。'; Read-Host '按 Enter 結束'"
if ($admin) {
    Invoke-Expression $cmd
} else {
    Write-Host "需要系統管理員權限，請在跳出的視窗按「是」。"
    Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd) -Wait
}
