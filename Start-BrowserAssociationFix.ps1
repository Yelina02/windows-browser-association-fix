#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Prepare','Cancel','RestoreProtection','Rollback')]
    [string]$WorkerAction,
    [string]$ExpectedSid,
    [switch]$StatusOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [IntPtr]::Size -ne 8) {
    throw '64-bit Windows required / 需要 64 位 Windows'
}
$engine = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
$core = Join-Path $PSScriptRoot 'Fix-BrowserAssociation.ps1'
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Show-Status {
    $json = & $engine -NoProfile -ExecutionPolicy Bypass -File $core -Action Status -Json
    if ($LASTEXITCODE -ne 0) { throw 'Status check failed; no repair started / 状态检查失败，没有开始修复' }
    $report = ($json -join [Environment]::NewLine) | ConvertFrom-Json
    Write-Host ''
    foreach ($entry in $report.Associations) {
        Write-Host ($entry.Protocol.ToUpper() + ': ' + $entry.Legacy + ' -> ' + $entry.Latest)
        if ($entry.Aligned) { Write-Host '  Aligned / 新旧记录一致' -ForegroundColor Green }
        else { Write-Host '  Different / 新旧记录不一致' -ForegroundColor Yellow }
        if (-not $entry.LegacyHashValid) { Write-Host '  Invalid old hash; repair will refuse / 旧校验值无效，修复会停止' -ForegroundColor Yellow }
    }
    Write-Host ('UCPD running / UCPD 正在运行: ' + $report.UCPD.ProtectionRunning)
    Write-Host ('UCPD startup / UCPD 启动模式: ' + $report.UCPD.Start)
    Write-Host ('Phase / 阶段: ' + $report.Phase)
    switch ($report.Phase) {
        'AwaitingRepairRestart' { Write-Host 'Save your work, restart, and sign in to THIS account / 保存工作后重启并登录当前账户' -ForegroundColor Yellow }
        'AwaitingProtectionRestart' { Write-Host 'Restart once more to reload protection / 请再重启一次以重新加载保护' -ForegroundColor Yellow }
        'Complete' { Write-Host 'Repair and protection recovery complete / 修复及保护恢复已完成' -ForegroundColor Green }
        'RepairFailed' { Write-Host 'Repair failed. See the local result.json / 修复失败，请查看本地 result.json' -ForegroundColor Red }
        'ProtectionRestoreFailed' { Write-Host 'Restore protection using option 3 / 请使用选项 3 恢复保护' -ForegroundColor Red }
    }
    if ($report.UCPD.Start -eq 1 -and -not $report.UCPD.ProtectionRunning) {
        Write-Host 'Protection is configured but stopped. Restart Windows / 保护启动配置正常但尚未运行，请重启 Windows' -ForegroundColor Yellow
    }
    return $report
}
function Show-StatusSafely {
    try { $null = Show-Status }
    catch { Write-Host ('Status unavailable / 无法读取完整状态: ' + $_.Exception.Message) -ForegroundColor Yellow }
}
try {
    if ($WorkerAction) {
        if (-not $ExpectedSid -or $ExpectedSid -ne $currentSid) {
            throw 'Different account detected. Use an administrator account without switching users / 检测到账户改变，请用当前账户提权，不要输入其他账户凭据'
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator approval required / 需要管理员权限'
        }
        Write-Host ('Action / 操作: ' + $WorkerAction)
        $report = $null
        try { $report = Show-Status }
        catch {
            if ($WorkerAction -notin @('RestoreProtection','Cancel')) { throw }
            Write-Host 'Association status unavailable; protection recovery is still available / 关联状态不可读，仍可尝试恢复保护' -ForegroundColor Yellow
        }
        if ($WorkerAction -eq 'Prepare' -and @($report.Associations | Where-Object { -not $_.Aligned }).Count -eq 0) {
            Write-Host 'Already aligned; nothing changed / 已一致，没有修改任何设置'
        } else {
            if ($WorkerAction -in @('Prepare','Rollback')) {
                Write-Host 'This temporarily disables UCPD startup for a restart and schedules its restoration.'
                Write-Host '将临时关闭 UCPD 启动以便重启修复，并安排恢复启动配置。可能需要两次重启。'
            } else {
                Write-Host 'This restores UCPD startup and removes the pending repair task / 将恢复 UCPD 启动并移除待执行任务'
            }
            Write-Host 'The bundled PowerShell files will be unblocked for the scheduled repair / 将解除包内 PowerShell 文件的下载标记，以便登录任务运行'
            if ((Read-Host 'Type YES to continue / 输入 YES 继续，其他输入取消') -ceq 'YES') {
                foreach ($relative in @('Fix-BrowserAssociation.ps1','lib/BrowserAssociation.psm1','vendor/UserChoiceHash.ps1')) {
                    Unblock-File -LiteralPath (Join-Path $PSScriptRoot $relative)
                }
                & $engine -NoProfile -ExecutionPolicy RemoteSigned -File $core -Action $WorkerAction
                if ($LASTEXITCODE -ne 0) { throw 'Action failed. Read the error above / 操作失败，请查看上方错误' }
                Show-StatusSafely
            } else { Write-Host 'Canceled / 已取消' }
        }
        $null = Read-Host 'Press Enter to close / 按回车关闭'
        exit 0
    }
    if ($StatusOnly) { $null = Show-Status; exit 0 }
    Show-StatusSafely
    while ($true) {
        Write-Host "`nWindows browser association fix / Windows 浏览器关联修复"
        Write-Host '1  Check status / 检查状态（只读）'
        Write-Host '2  Prepare repair / 准备修复'
        Write-Host '3  Restore protection / 恢复保护'
        Write-Host '4  Cancel pending repair / 取消待执行修复'
        Write-Host '5  Undo completed repair / 撤销已完成修复'
        Write-Host '0  Exit / 退出'
        $choice = Read-Host 'Choose / 请选择'
        if ($choice -eq '0') { break }
        if ($choice -eq '1') { Show-StatusSafely; continue }
        $action = switch ($choice) { '2' { 'Prepare' } '3' { 'RestoreProtection' } '4' { 'Cancel' } '5' { 'Rollback' } default { $null } }
        if (-not $action) { Write-Host 'Invalid choice / 选项无效'; continue }
        Write-Host 'Approve Windows administrator prompt for THIS account / 请在 Windows 提示中批准当前账户的管理员权限'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -WorkerAction ' + $action + ' -ExpectedSid ' + $currentSid
        try { $null = Start-Process -FilePath $engine -ArgumentList $arguments -Verb RunAs -PassThru -Wait }
        catch { Write-Host ('Administrator launch canceled or failed / 提权已取消或失败: ' + $_.Exception.Message) -ForegroundColor Yellow }
        Show-StatusSafely
    }
} catch {
    Write-Host ('Error / 错误: ' + $_.Exception.Message) -ForegroundColor Red
    if (-not $StatusOnly) { $null = Read-Host 'Press Enter to close / 按回车关闭' }
    exit 1
}
