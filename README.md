# 0c-ime-mod

個人用的[靈犀注音](https://github.com/0c-biggo/0c-ime)改裝。官方出新版時自動套用修改、編譯成安裝包。

## 改了什麼

- **切換中英時結束組字**：按 Shift 切換時，懸浮的組字視窗直接關掉，之後的按鍵交給程式。
- **大寫字母後接注音**：中英混打時打「輸入P的話」，P 後面的注音照樣組成中文（官方版會整串變英文）。
- **Shift＋- 打底線**：中文模式打半形 _，不是破折號「——」。
- **一律從英文開始的程式**：清單裡的程式（例如 AfterFX.exe）一開就是英文，也不做英文自動補字。

兩項都在「靈犀注音設定 → 輸入設定 → 中英切換（改裝）」。

## 安裝

在 PowerShell 執行一次（會跳出系統管理員確認）：

```powershell
irm https://api.github.com/repos/IvesNash/0c-ime-mod/contents/install-mod.ps1 -Headers @{Accept='application/vnd.github.raw'} | iex
```

安裝後會建立 Windows 排程「0c-ime-mod 自動更新」：每 2 小時與登入時檢查，有新的改裝版就自動安裝；在設定程式手動裝了官方同版、蓋掉改裝版時，也會自動裝回改裝版（紀錄在 `%LOCALAPPDATA%\0c-ime-mod\update.log`）。0c 內建的官方自動更新會改成手動，免得官方版蓋掉改裝版。

- 取消自動更新：`powershell -File $env:LOCALAPPDATA\0c-ime-mod\install-mod.ps1 -RemoveSchedule`
- 回到官方版：先取消自動更新（上一行），再從官網重新安裝。

## 運作方式

- `patches/`：對官方原始碼的修改。
- `.github/workflows/build.yml`：每天檢查官方最新版，套用 patch、編譯、發布 Release。
- `MOD_VERSION`：改了 patch 就加 1，會重新發布。
- patch 套不上（官方改到同一段程式）時，Actions 會失敗並寄信通知；舊的改裝版照常能用。
