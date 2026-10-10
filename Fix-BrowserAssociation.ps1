#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('Status','Prepare','Apply','RestoreProtection','Cancel','Rollback')]
    [string]$Action = 'Status',
    [string]$StateFile,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [IntPtr]::Size -ne 8) {
    throw '64-bit Windows required / 需要 64 位 Windows'
}
Import-Module (Join-Path $PSScriptRoot 'lib/BrowserAssociation.psm1') -Force
$sid = Get-CurrentSid
$dataBase = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsBrowserAssociationFix'
$dataRoot = Join-Path $dataBase $sid
$expectedState = Join-Path $dataRoot 'state.json'
if (-not $StateFile) { $StateFile = $expectedState }
if ([IO.Path]::GetFullPath($StateFile) -ne [IO.Path]::GetFullPath($expectedState)) {
    throw 'State must belong to the current account / 状态文件必须属于当前账户'
}
function Say([string]$Text) { if (-not $Json) { Write-Host $Text } }
function Require-Administrator {
    if (-not (Test-Administrator)) { throw 'Run as administrator using the SAME account / 请使用同一账户以管理员权限运行' }
}
function Assert-NoReparse([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Reparse point refused / 拒绝链接路径: $Path"
    }
}
function Secure-Directory([string]$Path) {
    Assert-NoReparse $Path
    $null = New-Item -ItemType Directory -Path $Path -Force
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($identity in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl',$inherit,'None','Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'ReadAndExecute',$inherit,'None','Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-State($State) {
    $temp = Join-Path $dataRoot ('state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StateFile -Force
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $State.RunDirectory 'result.json') -Encoding UTF8
}
function Read-State {
    Assert-NoReparse $dataBase
    Assert-NoReparse $dataRoot
    Assert-NoReparse $StateFile
    if (-not (Test-Path -LiteralPath $StateFile)) { throw 'No repair state found / 没有待处理的修复状态' }
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if ($state.SchemaVersion -ne 1 -or $state.Sid -ne $sid -or $state.OriginalStart -ne 1) { throw 'Unsupported or wrong-account state / 状态格式或账户不符' }
    $runPrefix = [IO.Path]::GetFullPath($dataRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($state.RunDirectory).StartsWith($runPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid run directory / 非法运行目录' }
    if ((Split-Path ([IO.Path]::GetFullPath($state.RunDirectory)) -Parent) -ne [IO.Path]::GetFullPath($dataRoot) -or (Split-Path $state.RunDirectory -Leaf) -notmatch '^[a-f0-9]{32}$') { throw 'Run directory must be a direct GUID child / 运行目录必须为直接 GUID 子目录' }
    Assert-NoReparse $state.RunDirectory
    foreach ($file in $state.Files) {
        if ($file.Path -notin @('Fix-BrowserAssociation.ps1','lib/BrowserAssociation.psm1','vendor/UserChoiceHash.ps1')) { throw 'Unexpected staged file / 出现未知暂存文件' }
        $path = Join-Path $state.RunDirectory $file.Path
        Assert-NoReparse (Split-Path $path -Parent)
        Assert-NoReparse $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Hash) { throw 'Staged code changed / 暂存代码已改变' }
    }
    if (@($state.Files).Count -ne 3 -or @($state.Files.Path | Select-Object -Unique).Count -ne 3) { throw 'Incomplete code snapshot / 代码快照不完整' }
    if (@($state.Entries).Count -ne 2 -or ((@($state.Entries.Protocol | Sort-Object -Unique) -join ',') -ne 'http,https')) { throw 'Invalid protocol plan / 协议计划不符' }
    $state
}
function Remove-RepairTask($State) {
    if ($State.TaskName -notmatch '^WindowsBrowserAssociationFix-[a-f0-9]{32}$') { throw 'Invalid task name / 任务名不合法' }
    if (Get-ScheduledTask -TaskName $State.TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $State.TaskName -Confirm:$false
    }
}
function Stage-Plan([object[]]$Entries,[object[]]$OriginalEntries,[string]$Mode) {
    $ucpd = Get-UcpdState
    if ($ucpd.Start -ne 1 -or -not $ucpd.ProtectionRunning) { throw 'Restore UCPD and reboot before preparing another repair / 请先恢复 UCPD 并重启' }
    if (Test-Path -LiteralPath $StateFile) {
        $previous = Read-State
        if ($previous.Phase -in @('AwaitingRepairRestart','ProtectionRestoreFailed')) { throw 'A repair is already pending / 已存在待处理修复' }
    }
    $runId = [Guid]::NewGuid().ToString('N')
    Secure-Directory $dataBase
    Secure-Directory $dataRoot
    $runDirectory = Join-Path $dataRoot $runId
    Secure-Directory $runDirectory
    $null = New-Item -ItemType Directory -Path (Join-Path $runDirectory 'lib'),(Join-Path $runDirectory 'vendor')
    $files = @()
    foreach ($relative in @('Fix-BrowserAssociation.ps1','lib/BrowserAssociation.psm1','vendor/UserChoiceHash.ps1')) {
        $source = Join-Path $PSScriptRoot $relative
        Assert-NoReparse $source
        $destination = Join-Path $runDirectory $relative
        Copy-Item -LiteralPath $source -Destination $destination
        $files += [pscustomobject]@{Path=$relative;Hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
    }
    foreach ($protocol in 'http','https') {
        & reg.exe export ('HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\' + $protocol) (Join-Path $runDirectory ($protocol + '-before.reg')) /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Association backup failed / 关联备份失败' }
    }
    & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\UCPD' (Join-Path $runDirectory 'ucpd-before.reg') /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'UCPD backup failed / UCPD 备份失败' }
    $state = [pscustomobject]@{
        SchemaVersion=1;Sid=$sid;OriginalStart=1;RunDirectory=$runDirectory;TaskName=('WindowsBrowserAssociationFix-'+$runId)
        Mode=$Mode;Phase='AwaitingRepairRestart';Entries=$Entries;OriginalEntries=$OriginalEntries;Files=$files
        AssociationSucceeded=$false;StartupRestored=$false;DriverRunning=$true;Error=$null;ProtectionError=$null;TaskError=$null;UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Write-State $state
    $registered = $false
    try {
        $engine = (Get-Process -Id $PID).Path
        $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + (Join-Path $runDirectory 'Fix-BrowserAssociation.ps1') + '" -Action Apply -StateFile "' + $StateFile + '"'
        $taskAction = New-ScheduledTaskAction -Execute $engine -Argument $arguments
        # Independent first action restores startup even if PowerShell cannot import
        # its module, the code snapshot is corrupt, or script execution is blocked.
        $recoveryAction = New-ScheduledTaskAction -Execute (Join-Path ([Environment]::GetFolderPath('System')) 'sc.exe') -Argument 'config UCPD start= system'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(3)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $state.TaskName -Action @($recoveryAction,$taskAction) -Trigger $trigger -Principal $principal -Settings $settings -Description 'Restore legacy HTTP/HTTPS records and immediately restore UCPD startup. / 修复旧关联并恢复 UCPD 启动配置。' | Out-Null
        $registered = $true
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name Start -Value 4
        if ((Get-UcpdState).Start -ne 4) { throw 'Cannot stage temporary UCPD startup change / 无法暂存 UCPD 启动变更' }
    } catch {
        $state.Error = $_.Exception.Message
        $state.Phase = 'PrepareFailed'
        try {
            $protection = Restore-UcpdProtection $state.OriginalStart
            $state.StartupRestored = ($protection.Start -eq $state.OriginalStart)
            $state.DriverRunning = $protection.ProtectionRunning
            $state.ProtectionError = $protection.LoadError
        } catch { $state.Phase='ProtectionRestoreFailed'; $state.ProtectionError=$_.Exception.Message }
        if ($registered -and $state.StartupRestored) { Remove-RepairTask $state }
        Write-State $state
        throw
    }
    Say 'Prepared. Save work, restart Windows, then sign in to this account. / 已准备好，请保存工作、重启，并登录当前账户。'
    Say 'A second reboot may be needed to reload UCPD. / 恢复 UCPD 运行可能还需要第二次重启。'
    Say ('Local backup / 本地备份: ' + $runDirectory)
}

try {
    switch ($Action) {
        'Status' {
            $associations = @(Get-BrowserAssociations)
            $ucpd = Get-UcpdState
            $phase = 'NoPlan'
            if (Test-Path -LiteralPath $StateFile) {
                $state = Read-State
                $phase = $state.Phase
                if ($state.AssociationSucceeded -and $phase -in @('Complete','AwaitingProtectionRestart')) {
                    $phase = Get-RepairCompletion $true ($ucpd.Start -eq $state.OriginalStart) $ucpd.ProtectionRunning
                }
            }
            $report = [pscustomobject]@{Associations=$associations;UCPD=$ucpd;Phase=$phase;StateFile=$StateFile}
            if ($Json) { $report | ConvertTo-Json -Depth 8 } else {
                Say 'Browser association status / 浏览器关联状态'
                $associations | Format-Table
                $ucpd | Format-List
                Say ('Repair phase / 修复阶段: ' + $phase)
            }
        }
        'Prepare' {
            $entries = @(New-AssociationPlan)
            if (@($entries | Where-Object { $_.Before -ne $_.Target }).Count -eq 0) {
                Say 'Already aligned; nothing changed. / 新旧记录已一致，没有修改任何设置。'
                break
            }
            if ($PSCmdlet.ShouldProcess('Legacy HTTP/HTTPS records and temporary UCPD startup / 旧关联及临时 UCPD 启动配置','Prepare repair / 准备修复')) {
                Require-Administrator
                Stage-Plan $entries $entries 'Repair'
            }
        }
        'Apply' {
            Require-Administrator
            $state = Read-State
            if ($state.Phase -ne 'AwaitingRepairRestart') { throw 'No pending repair to apply / 没有待执行修复' }
            if (-not $PSCmdlet.ShouldProcess('Legacy HTTP/HTTPS records / 旧版网页关联','Apply staged repair / 执行暂存修复')) { break }
            try {
                # Restore boot configuration FIRST: later failures cannot leave startup disabled.
                Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name Start -Value $state.OriginalStart
                if ((Get-UcpdState).Start -ne $state.OriginalStart) { throw 'Cannot restore startup / 无法恢复启动配置' }
                $state.StartupRestored = $true
                if ((Get-UcpdState).DriverState -ne 'Stopped') { throw 'UCPD still loaded; no associations changed / UCPD 仍已加载，没有修改关联' }
                foreach ($entry in $state.Entries) {
                    $legacy = Get-LegacyAssociation $entry.Protocol
                    if ($legacy.ProgId -ne $entry.Before -or -not $legacy.HashValid) { throw 'Legacy record changed after backup / 备份后旧记录已改变' }
                }
                Invoke-AssociationTransaction $state.Entries {param($protocol,$progId) Set-LegacyAssociation $protocol $progId} {param($protocol) Get-LatestProgId $protocol}
                Update-AssociationCache
                $state.AssociationSucceeded = $true
            } catch { $state.Error = $_.Exception.Message }
            finally {
                try {
                    $protection = Restore-UcpdProtection $state.OriginalStart
                    $state.StartupRestored = ($protection.Start -eq $state.OriginalStart)
                    $state.DriverRunning = $protection.ProtectionRunning
                    $state.ProtectionError = $protection.LoadError
                } catch { $state.StartupRestored=$false; $state.ProtectionError=$_.Exception.Message }
                $state.Phase = Get-RepairCompletion $state.AssociationSucceeded $state.StartupRestored $state.DriverRunning
                if ($state.StartupRestored) {
                    try { Remove-RepairTask $state } catch { $state.TaskError=$_.Exception.Message }
                }
                $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Write-State $state
            }
            Say ('Result / 结果: '+$state.Phase)
            if (-not $state.DriverRunning) { Say 'Restart again to restore running protection. / 请再重启一次，恢复正在运行的保护。' }
            if ($state.Error) { throw $state.Error }
            if (-not $state.StartupRestored) { throw 'RestoreProtection required / 需要执行 RestoreProtection' }
        }
        { $_ -in @('RestoreProtection','Cancel') } {
            if (-not $PSCmdlet.ShouldProcess('UCPD startup and repair task / UCPD 启动配置与修复任务','Restore protection / 恢复保护')) { break }
            Require-Administrator
            $state = Read-State
            $protection = Restore-UcpdProtection $state.OriginalStart
            $state.StartupRestored = ($protection.Start -eq $state.OriginalStart)
            $state.DriverRunning = $protection.ProtectionRunning
            $state.ProtectionError = $protection.LoadError
            Remove-RepairTask $state
            if ($Action -eq 'Cancel') { $state.Phase='Canceled' } else { $state.Phase=Get-RepairCompletion $state.AssociationSucceeded $state.StartupRestored $state.DriverRunning }
            $state.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
            Write-State $state
            Say 'Startup restored; pending task removed. / 已恢复启动配置并移除待执行任务。'
            if (-not $state.DriverRunning) { Say 'Restart to reload UCPD. / 请重启以重新加载 UCPD。' }
        }
        'Rollback' {
            $previous = Read-State
            if (-not $previous.AssociationSucceeded -or $previous.Mode -ne 'Repair') { throw 'No successful repair to roll back / 没有可撤销的成功修复' }
            $entries = @(foreach ($original in $previous.OriginalEntries) {
                $legacy = Get-LegacyAssociation $original.Protocol
                if (-not $legacy.HashValid -or $legacy.ProgId -ne $original.Target -or (Get-LatestProgId $original.Protocol) -ne $original.ExpectedLatest) { throw 'Associations changed; rollback refused / 关联已改变，拒绝撤销' }
                [pscustomobject]@{Protocol=$original.Protocol;Before=$legacy.ProgId;Target=$original.Before;ExpectedLatest=$original.ExpectedLatest}
            })
            if ($PSCmdlet.ShouldProcess('Original legacy records / 原始旧版记录','Prepare rollback / 准备撤销')) {
                Require-Administrator
                Stage-Plan $entries $previous.OriginalEntries 'Rollback'
            }
        }
    }
} catch {
    Write-Error ('Operation failed / 操作失败: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
