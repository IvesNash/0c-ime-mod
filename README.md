# 0c-ime-mod

個人用的[靈犀注音](https://github.com/0c-biggo/0c-ime)改裝。官方出新版時自動套用修改、編譯成安裝包。

## 改了什麼

- **切換中英時結束組字**：按 Shift 切換時，懸浮的組字視窗直接關掉，之後的按鍵交給程式。
- **一律從英文開始的程式**：清單裡的程式（例如 AfterFX.exe）一開就是英文，也不做英文自動補字。

兩項都在「靈犀注音設定 → 輸入設定 → 中英切換（改裝）」。

## 安裝／更新

在 PowerShell 執行（會跳出系統管理員確認）：

```powershell
irm https://raw.githubusercontent.com/IvesNash/0c-ime-mod/main/install-mod.ps1 | iex
```

## 運作方式

- `patches/`：對官方原始碼的修改。
- `.github/workflows/build.yml`：每天檢查官方最新版，套用 patch、編譯、發布 Release。
- `MOD_VERSION`：改了 patch 就加 1，會重新發布。
- patch 套不上（官方改到同一段程式）時，Actions 會失敗並寄信通知；舊的改裝版照常能用。
