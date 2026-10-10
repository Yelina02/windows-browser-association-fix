#requires -Version 5.1
# These tests never stop UCPD, change associations, or register scheduled tasks.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
function Test-Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host ('PASS / 通过: '+$Name) }
    catch { $script:failures.Add($Name+': '+$_.Exception.Message); Write-Host ('FAIL / 失败: '+$Name) }
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
Test-Case 'PowerShell syntax / 语法检查' {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -in @('.ps1','.psm1')) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ($file.Name+': '+($errors -join '; '))
    }
}
Import-Module (Join-Path $root 'lib/BrowserAssociation.psm1') -Force
Test-Case 'Running protection is required for complete / 完成必须有运行中的保护' {
    Assert ((Get-RepairCompletion $true $true $false) -eq 'AwaitingProtectionRestart') 'Stopped driver incorrectly treated as complete.'
    Assert ((Get-RepairCompletion $true $true $true) -eq 'Complete') 'Running protection not recognized.'
    Assert ((Get-RepairCompletion $true $false $true) -eq 'ProtectionRestoreFailed') 'Startup restore failure hidden.'
    Assert ((Get-RepairCompletion $false $true $true) -eq 'RepairFailed') 'Association failure hidden.'
}
$entries = @(
    [pscustomobject]@{Protocol='http';Before='EdgeOld';Target='ChromeNew';ExpectedLatest='ChromeNew'},
    [pscustomobject]@{Protocol='https';Before='EdgeOld';Target='ChromeNew';ExpectedLatest='ChromeNew'}
)
Test-Case 'Transaction success / 修复事务成功' {
    $writes=[Collections.Generic.List[string]]::new()
    Invoke-AssociationTransaction $entries {param($protocol,$progId) $writes.Add($protocol+':'+$progId)} {param($protocol) 'ChromeNew'}
    Assert (($writes -join ',') -eq 'http:ChromeNew,https:ChromeNew') 'Unexpected write sequence.'
}
Test-Case 'Partial write rollback / 部分写入失败撤销' {
    $writes=[Collections.Generic.List[string]]::new()
    $caught=$false
    try {
        Invoke-AssociationTransaction $entries {
            param($protocol,$progId)
            $writes.Add($protocol+':'+$progId)
            if ($protocol -eq 'https' -and $progId -eq 'ChromeNew') { throw 'Simulated partial hash write failure' }
        } {param($protocol) 'ChromeNew'}
    } catch { $caught=$true }
    Assert $caught 'Partial failure did not abort.'
    Assert (($writes -join ',') -eq 'http:ChromeNew,https:ChromeNew,http:EdgeOld,https:EdgeOld') 'Failed entry was not rolled back.'
}
Test-Case 'Changed default aborts before writing / 默认已改变则不写入' {
    $writes=[Collections.Generic.List[string]]::new()
    $caught=$false
    try { Invoke-AssociationTransaction $entries {param($protocol,$progId) $writes.Add($protocol)} {param($protocol) 'DifferentBrowser'} }
    catch { $caught=$true }
    Assert ($caught -and $writes.Count -eq 0) 'A changed default was overwritten.'
}
Test-Case 'Changed default during transaction triggers rollback / 事务期间默认改变则撤销' {
    $writes=[Collections.Generic.List[string]]::new()
    $caught=$false
    try {
        Invoke-AssociationTransaction $entries {param($protocol,$progId) $writes.Add($protocol+':'+$progId)} {
            param($protocol)
            if ($writes.Count -eq 0) { 'ChromeNew' } else { 'DifferentBrowser' }
        }
    } catch { $caught=$true }
    Assert ($caught -and (($writes -join ',') -eq 'http:ChromeNew,http:EdgeOld')) 'Concurrent default change did not restore touched records.'
}
Test-Case 'Rollback failure remains visible / 撤销失败不能隐藏' {
    $caught=''
    try {
        Invoke-AssociationTransaction $entries {param($protocol,$progId) throw 'Simulated access denied'} {param($protocol) 'ChromeNew'}
    } catch { $caught=$_.Exception.Message }
    Assert ($caught -match 'Rollback failed') 'Rollback error was hidden.'
}
Test-Case 'Native timestamps and minute-boundary hash / 原生时间戳与分钟校验' {
    $module=Get-Module BrowserAssociation
    & $module { Initialize-AssociationNative }
    $path='Software\WindowsBrowserAssociationFix.Tests\'+[Guid]::NewGuid().ToString('N')
    Assert ($path.StartsWith('Software\WindowsBrowserAssociationFix.Tests\')) 'Unsafe test registry path.'
    try {
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
        $key.SetValue('Synthetic','test')
        $key.Dispose()
        $time=[WBaf.Native]::Timestamp($path)
        Assert ($time -gt 0) 'Timestamp missing.'
        $minute=$time-($time%600000000)
        $hash1=Get-AssociationHash 'http' 'SyntheticBrowser' $minute
        $hash2=Get-AssociationHash 'http' 'SyntheticBrowser' ($minute+599999999)
        $hash3=Get-AssociationHash 'http' 'SyntheticBrowser' ($minute+600000000)
        Assert ($hash1 -ceq $hash2 -and $hash1 -cne $hash3) 'Minute normalization incorrect.'
        Assert (([Convert]::FromBase64String($hash1)).Length -eq 8) 'Invalid output size.'
    } finally {
        # Remove only the exact GUID key that this test created; never delete an ancestor.
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($path,$false)
    }
}
Test-Case 'Privacy: no local account or backups in tracked source / 无个人路径或备份' {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
        Assert ($file.Extension -ne '.reg') 'A real registry backup was included.'
        $text=Get-Content -LiteralPath $file.FullName -Raw
        Assert ($text -notmatch '[A-Za-z]:\\Users\\[^\\\s]+\\') 'A private absolute user path was included.'
        Assert ($text -notmatch 'S-1-5-21-\d+-\d+-\d+-\d+') 'A private account SID was included.'
    }
}
Write-Host ('Passed / 通过: '+$passed+'; Failed / 失败: '+$failures.Count)
if ($failures.Count) { $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }; exit 1 }
