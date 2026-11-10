<#
.SYNOPSIS
    Setup Paperclip in WSL2 with Windows boot auto-start and Linux package patching

.DESCRIPTION
    Configures Paperclip running inside WSL2 Ubuntu so that it behaves like a native
    always-on desktop/background application on Windows:
    1. Cleans up any conflicting native Windows $env:USERPROFILE\.paperclip state
    2. Invokes scripts/linux/setup-paperclip-service.sh inside WSL2 to patch npm
       packaging bugs (PostgreSQL .so symlinks, embedded-postgres patch, Codex 0.160.0,
       systemd ~/.local/bin PATH) and ensure paperclipai.service is enabled & active
    3. Creates a runner script ($env:USERPROFILE\Scripts\Start-PaperclipWsl.ps1) and a
       Windows Startup shortcut (shell:startup\Start-PaperclipWsl.lnk) so Windows
       automatically wakes WSL2 and starts paperclipai.service in the background on boot

    This is a user-level script that does NOT require administrator privileges.

.PARAMETER Install
    Clean Windows residual state, ensure WSL service is patched/running, and register Windows Startup item

.PARAMETER Patch
    Re-apply WSL npm packaging & systemd PATH patches (useful after `paperclipai update`)

.PARAMETER Verify
    Verify Windows Startup configuration, WSL systemd service status, and http://127.0.0.1:3100/api/health

.PARAMETER Remove
    Remove Windows Startup shortcut and runner script (and optionally stop WSL systemd service)

.PARAMETER Force
    Force reconfiguration even if already installed

.PARAMETER NonInteractive
    No user prompts (for automation)

.EXAMPLE
    .\Setup-PaperclipWsl.ps1 -Install
    Configure WSL2 Paperclip service and Windows boot auto-start

.EXAMPLE
    .\Setup-PaperclipWsl.ps1 -Patch
    Re-apply WSL npm & PATH patches after updating Paperclip

.EXAMPLE
    .\Setup-PaperclipWsl.ps1 -Verify
    Verify WSL service and Windows localhost:3100 connectivity

.EXAMPLE
    .\Setup-PaperclipWsl.ps1 -Remove
    Remove Windows auto-start shortcut and runner script
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Install,

    [Parameter(Mandatory=$false)]
    [switch]$Patch,

    [Parameter(Mandatory=$false)]
    [switch]$Verify,

    [Parameter(Mandatory=$false)]
    [switch]$Remove,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

Write-Host "--- Paperclip WSL2 + Windows 開機自啟設置腳本 ---" -ForegroundColor Cyan

# 計算路徑
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $scriptPath
$repoRoot = Split-Path -Parent $scriptsDir
$linuxScriptWinPath = Join-Path $scriptsDir "linux\setup-paperclip-service.sh"

# 部署路徑
$userScriptsDir = Join-Path $env:USERPROFILE "Scripts"
$runnerScript = Join-Path $userScriptsDir "Start-PaperclipWsl.ps1"
$logFile = Join-Path $userScriptsDir "paperclip-wsl.log"
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupFolder "Start-PaperclipWsl.lnk"
$winPaperclipDir = Join-Path $env:USERPROFILE ".paperclip"
$defaultPort = 3100

# 處理互斥操作
$operations = @($Install, $Patch, $Verify, $Remove)
$operationCount = ($operations | Where-Object { $_ -eq $true }).Count

if ($operationCount -eq 0) {
    Write-Host "`n請指定操作：-Install, -Patch, -Verify, 或 -Remove" -ForegroundColor Red
    Write-Host ""
    Write-Host "使用範例：" -ForegroundColor Cyan
    Write-Host "   .\Setup-PaperclipWsl.ps1 -Install" -ForegroundColor White
    Write-Host "   .\Setup-PaperclipWsl.ps1 -Patch" -ForegroundColor White
    Write-Host "   .\Setup-PaperclipWsl.ps1 -Verify" -ForegroundColor White
    Write-Host "   .\Setup-PaperclipWsl.ps1 -Remove" -ForegroundColor White
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}

if ($operationCount -gt 1) {
    Write-Host "`n警告：只能同時使用一個操作參數" -ForegroundColor Yellow
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}

# 輔助函數：確保 Linux 腳本為 LF 換行並取得 WSL 路徑
function Get-WslLinuxScriptPath {
    if (-not (Test-Path $linuxScriptWinPath)) {
        throw "找不到 Linux 腳本：$linuxScriptWinPath"
    }
    # 強制轉換為 LF 換行，避免 Git autocrlf 造成 bash 執行錯誤
    $rawContent = [System.IO.File]::ReadAllText($linuxScriptWinPath)
    if ($rawContent.Contains("`r`n")) {
        $lfContent = $rawContent.Replace("`r`n", "`n")
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($linuxScriptWinPath, $lfContent, $utf8NoBom)
    }
    $wslPath = (wsl.exe -e wslpath -u ($linuxScriptWinPath -replace '\\', '/')).Trim()
    return $wslPath
}

# 步驟 1: 檢查 WSL2
Write-Host "`n1. 正在檢查 WSL2 環境..." -ForegroundColor Yellow
$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCommand) {
    Write-Host "   - 未找到 wsl.exe，請先啟用 WSL2" -ForegroundColor Red
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}

$wslCheck = wsl.exe -e bash -lc "echo WSL_OK" 2>$null
if ($LASTEXITCODE -ne 0 -or ($wslCheck -join "") -notmatch "WSL_OK") {
    Write-Host "   - WSL2 無法正常啟動，請確認已安裝 Ubuntu 發行版" -ForegroundColor Red
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 1
}
Write-Host "   - WSL2 運行正常 ✓" -ForegroundColor Green

# === 僅修補操作 (-Patch) ===
if ($Patch) {
    Write-Host "`n=== 正在透過 WSL2 執行套件與 PATH 修補 ===" -ForegroundColor Cyan
    $wslScript = Get-WslLinuxScriptPath
    wsl.exe -e bash -lc "chmod +x '$wslScript' && '$wslScript' patch"
    $exitCode = $LASTEXITCODE
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "按 Enter 鍵結束..."
    }
    exit $exitCode
}

# === 驗證操作 (-Verify) ===
if ($Verify) {
    Write-Host "`n=== 開始驗證 Paperclip WSL2 與 Windows 開機自啟狀態 ===" -ForegroundColor Cyan
    $allGood = $true

    Write-Host "`n2. 檢查 Windows 端殘留衝突目錄..." -ForegroundColor Yellow
    if (Test-Path $winPaperclipDir) {
        Write-Host "   - 警告：發現 Windows 原生目錄 $winPaperclipDir (可能與 WSL2 衝突)" -ForegroundColor Yellow
        $allGood = $false
    } else {
        Write-Host "   - Windows 原生 ~/.paperclip 已清空，無衝突 ✓" -ForegroundColor Green
    }

    Write-Host "`n3. 檢查 Windows 開機自啟配置..." -ForegroundColor Yellow
    if (Test-Path $runnerScript) {
        Write-Host "   - Runner 腳本存在：$runnerScript ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Runner 腳本不存在：$runnerScript" -ForegroundColor Red
        $allGood = $false
    }

    if (Test-Path $startupShortcut) {
        Write-Host "   - Windows Startup 捷徑存在：$startupShortcut ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Windows Startup 捷徑不存在：$startupShortcut" -ForegroundColor Red
        $allGood = $false
    }

    Write-Host "`n4. 檢查 WSL2 內部服務與修補狀態..." -ForegroundColor Yellow
    $wslScript = Get-WslLinuxScriptPath
    wsl.exe -e bash -lc "chmod +x '$wslScript' && '$wslScript' verify"
    if ($LASTEXITCODE -ne 0) {
        $allGood = $false
    }

    Write-Host "`n5. 從 Windows Host 測試 http://127.0.0.1:$defaultPort/api/health..." -ForegroundColor Yellow
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$defaultPort/api/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            Write-Host "   - Windows Host 連線正常 (HTTP 200)：$($resp.Content) ✓" -ForegroundColor Green
        } else {
            Write-Host "   - Windows Host 回應異常 (Status: $($resp.StatusCode))" -ForegroundColor Red
            $allGood = $false
        }
    } catch {
        Write-Host "   - Windows Host 無法連線至 http://127.0.0.1:$defaultPort/api/health：$($_.Exception.Message)" -ForegroundColor Red
        $allGood = $false
    }

    Write-Host ""
    if ($allGood) {
        Write-Host "所有檢查通過！Windows 重開機後可直接打開 http://127.0.0.1:$defaultPort/ 使用 ✓" -ForegroundColor Green
    } else {
        Write-Host "部分檢查未通過，請執行 .\Setup-PaperclipWsl.ps1 -Install 進行修復" -ForegroundColor Yellow
    }

    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "按 Enter 鍵結束..."
    }
    exit $(if ($allGood) { 0 } else { 1 })
}

# === 移除操作 (-Remove) ===
if ($Remove) {
    Write-Host "`n=== 開始移除 Paperclip Windows 開機自動啟動配置 ===" -ForegroundColor Cyan

    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "此操作將移除：" -ForegroundColor Yellow
        Write-Host "   - Windows Startup 啟動捷徑 ($startupShortcut)" -ForegroundColor White
        Write-Host "   - Windows Runner 腳本 ($runnerScript)" -ForegroundColor White
        Write-Host "   - Windows 啟動日誌 ($logFile)" -ForegroundColor White
        Write-Host ""
        $confirm = Read-Host "   確定要繼續嗎？(Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "   - 已取消操作" -ForegroundColor Yellow
            exit 0
        }
    }

    if (Test-Path $startupShortcut) {
        Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除啟動捷徑 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - 啟動捷徑不存在，跳過" -ForegroundColor Gray
    }

    if (Test-Path $runnerScript) {
        Remove-Item $runnerScript -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除 Runner 腳本 ✓" -ForegroundColor Green
    } else {
        Write-Host "   - Runner 腳本不存在，跳過" -ForegroundColor Gray
    }

    if (Test-Path $logFile) {
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
        Write-Host "   - 已刪除啟動日誌 ✓" -ForegroundColor Green
    }

    if (-not $NonInteractive) {
        $removeWslService = Read-Host "`n   是否也要一併停止並移除 WSL2 內的 paperclipai.service？(Y/N)"
        if ($removeWslService -eq 'Y' -or $removeWslService -eq 'y') {
            $wslScript = Get-WslLinuxScriptPath
            wsl.exe -e bash -lc "chmod +x '$wslScript' && '$wslScript' remove -y"
        }
    }

    Write-Host "`n移除完成！" -ForegroundColor Green
    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}

# === 安裝操作 (-Install) ===
if ($Install) {
    Write-Host "`n=== 開始設置 Paperclip WSL2 服務與 Windows 開機自啟 ===" -ForegroundColor Cyan

    # 步驟 2: 檢查並清理 Windows 原生 ~/.paperclip
    Write-Host "`n2. 檢查 Windows 原生 $winPaperclipDir 是否存在衝突..." -ForegroundColor Yellow
    if (Test-Path $winPaperclipDir) {
        $cleanWinDir = $true
        if (-not $Force -and -not $NonInteractive) {
            Write-Host "   - 發現 Windows 端殘留目錄：$winPaperclipDir" -ForegroundColor Yellow
            $ans = Read-Host "     是否刪除此 Windows 原生目錄以避免與 WSL2 衝突？(Y/N)"
            $cleanWinDir = ($ans -eq 'Y' -or $ans -eq 'y')
        }
        if ($cleanWinDir) {
            Remove-Item -LiteralPath $winPaperclipDir -Recurse -Force
            Write-Host "   - 已清理 Windows 原生 $winPaperclipDir ✓" -ForegroundColor Green
        } else {
            Write-Host "   - 保留 $winPaperclipDir (注意：請勿在 Windows 原生環境啟動 paperclipai)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   - 無 Windows 原生 ~/.paperclip 衝突 ✓" -ForegroundColor Green
    }

    # 步驟 3: 執行 WSL2 內部的 setup-paperclip-service.sh install
    Write-Host "`n3. 正在確認並修補 WSL2 內的 Paperclip 服務..." -ForegroundColor Yellow
    $wslScript = Get-WslLinuxScriptPath
    $forceFlag = if ($Force) { "--force" } else { "" }
    wsl.exe -e bash -lc "chmod +x '$wslScript' && '$wslScript' install $forceFlag"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n   - WSL2 內部設置失敗，請檢查上方輸出訊息" -ForegroundColor Red
        if (-not $NonInteractive) {
            Read-Host "按 Enter 鍵結束..."
        }
        exit 1
    }

    # 步驟 4: 創建 Windows 開機自動喚醒 Runner 腳本
    Write-Host "`n4. 正在創建 Windows 開機自動喚醒腳本..." -ForegroundColor Yellow
    if (-not (Test-Path $userScriptsDir)) {
        New-Item -ItemType Directory -Path $userScriptsDir -Force | Out-Null
        Write-Host "   - 已創建目錄：$userScriptsDir" -ForegroundColor Gray
    }

    $runnerContent = @"
# Start-PaperclipWsl.ps1
# Auto-generated by Setup-PaperclipWsl.ps1
# Wakes up WSL2 on Windows login and ensures paperclipai.service is running on http://127.0.0.1:$defaultPort/

`$logFile = "$($logFile -replace '\\', '\\')"
`$port = $defaultPort

`$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path `$logFile -Value ""
Add-Content -Path `$logFile -Value "=== [`$timestamp] Waking WSL2 and verifying paperclipai.service ==="

try {
    # 喚醒 WSL2 並確保 systemd user service 啟動
    `$wslOut = wsl.exe -e bash -lc 'export PATH="`$HOME/.local/bin:`$PATH"; if ! systemctl --user is-active paperclipai.service >/dev/null 2>&1; then systemctl --user start paperclipai.service; fi; systemctl --user is-active paperclipai.service' 2>&1
    Add-Content -Path `$logFile -Value "WSL service state: `$(`$wslOut -join ' ')"

    # 等待 localhost:`$port 健康端點就緒 (最多 45 秒)
    `$ready = `$false
    for (`$i = 0; `$i -lt 45; `$i++) {
        try {
            `$resp = Invoke-WebRequest -Uri "http://127.0.0.1:`$port/api/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if (`$resp.StatusCode -eq 200) {
                `$ready = `$true
                Add-Content -Path `$logFile -Value "Health check OK: `$(`$resp.Content)"
                break
            }
        } catch {}
        Start-Sleep -Seconds 1
    }

    if (-not `$ready) {
        Add-Content -Path `$logFile -Value "WARNING: Health check timed out after 45s"
    }
} catch {
    Add-Content -Path `$logFile -Value "ERROR: `$(`$_.Exception.Message)"
}
Add-Content -Path `$logFile -Value "=== Startup check finished ==="
"@

    Set-Content -Path $runnerScript -Value $runnerContent -Encoding UTF8
    Write-Host "   - 已創建 $runnerScript ✓" -ForegroundColor Green

    # 步驟 5: 創建 Windows Startup 啟動資料夾捷徑
    Write-Host "`n5. 正在配置 Windows Startup 啟動項..." -ForegroundColor Yellow
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($startupShortcut)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerScript`""
    $Shortcut.WorkingDirectory = $userScriptsDir
    $Shortcut.WindowStyle = 7  # 最小化並隱藏
    $Shortcut.Description = "Paperclip WSL2 Background Service Auto-Start"
    $Shortcut.Save()

    Write-Host "   - 已創建啟動捷徑：$startupShortcut ✓" -ForegroundColor Green

    # 步驟 6: 從 Windows Host 驗證 http://127.0.0.1:3100/api/health
    Write-Host "`n6. 正在從 Windows Host 驗證連線..." -ForegroundColor Yellow
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$defaultPort/api/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Host "   - Windows Host 連線成功：$($resp.Content) ✓" -ForegroundColor Green
    } catch {
        Write-Host "   - 警告：Windows Host 暫時無法連線至 http://127.0.0.1:$defaultPort/api/health" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║       Paperclip WSL2 + Windows 開機自啟設置完成！        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "配置資訊：" -ForegroundColor Cyan
    Write-Host "   - 本地網址：http://127.0.0.1:$defaultPort/" -ForegroundColor White
    Write-Host "   - Windows Runner：$runnerScript" -ForegroundColor White
    Write-Host "   - Windows 啟動項：$startupShortcut" -ForegroundColor White
    Write-Host "   - 啟動日誌：$logFile" -ForegroundColor White
    Write-Host ""
    Write-Host "常用指令：" -ForegroundColor Cyan
    Write-Host "   - 驗證狀態：.\scripts\windows\Setup-PaperclipWsl.ps1 -Verify" -ForegroundColor White
    Write-Host "   - 重新套用補丁：.\scripts\windows\Setup-PaperclipWsl.ps1 -Patch" -ForegroundColor White
    Write-Host "   - 移除自啟配置：.\scripts\windows\Setup-PaperclipWsl.ps1 -Remove" -ForegroundColor White
    Write-Host ""

    if (-not $NonInteractive) {
        Read-Host "按 Enter 鍵結束..."
    }
    exit 0
}
