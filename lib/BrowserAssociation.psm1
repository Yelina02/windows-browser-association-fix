Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'vendor/UserChoiceHash.ps1')

function Initialize-AssociationNative {
    if ('WBaf.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using Microsoft.Win32;
using System.Runtime.InteropServices;
namespace WBaf {
 public static class Native {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
  private static extern int RegQueryInfoKey(IntPtr key, IntPtr cls, IntPtr clsLen, IntPtr reserved, IntPtr subkeys, IntPtr maxSubkey, IntPtr maxClass, IntPtr values, IntPtr maxName, IntPtr maxLen, IntPtr security, out long time);
  [DllImport("shell32.dll")]
  private static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
  public static long Timestamp(string path) {
   using(var key=Registry.CurrentUser.OpenSubKey(path)) {
    if(key==null) throw new Exception("Missing registry key: "+path);
    long time;
    int error=RegQueryInfoKey(key.Handle.DangerousGetHandle(),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out time);
    if(error!=0) throw new Exception("RegQueryInfoKey error: "+error);
    return time;
   }
  }
  public static void Refresh() { SHChangeNotify(0x08000000,0,IntPtr.Zero,IntPtr.Zero); }
 }
}
'@
}

function Get-CurrentSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-LegacyPath([string]$Protocol) {
    if ($Protocol -notin @('http','https')) { throw 'Unsupported protocol / 不支持的协议' }
    'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\' + $Protocol + '\UserChoice'
}
function Get-AssociationHash([string]$Protocol,[string]$ProgId,[long]$FileTime) {
    if (-not (Get-Variable Experience -Scope Script -ErrorAction SilentlyContinue)) {
        $shell = Join-Path ([Environment]::GetFolderPath('SystemX86')) 'shell32.dll'
        $data = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($shell))
        $match = [regex]::Match($data,'User Choice set via Windows User Experience \{[0-9A-Fa-f-]{36}\}')
        if (-not $match.Success) { throw 'Unsupported hash experience string / 不支持的关联校验格式' }
        $script:Experience = $match.Value
    }
    $minute = $FileTime - ($FileTime % 600000000)
    $inputText = ($Protocol + (Get-CurrentSid) + $ProgId + $minute.ToString('x16') + $script:Experience).ToLowerInvariant()
    Get-UserChoiceHash $inputText
}
function Get-LatestProgId([string]$Protocol) {
    $path = 'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\' + $Protocol + '\UserChoiceLatest'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
    if ($null -eq $key) { throw "UserChoiceLatest missing for $Protocol / 缺少新版关联记录" }
    try {
        $value = $key.GetValue('ProgId',$null)
        if ($value -is [string] -and $value.Length) { return $value }
    } finally { $key.Dispose() }
    $child = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path + '\ProgId')
    if ($null -eq $child) { throw "Unsupported latest association layout: $Protocol / 不支持的新版记录格式" }
    try {
        $value = $child.GetValue('ProgId',$null)
        if ($value -isnot [string] -or -not $value.Length) { throw 'Missing latest ProgId / 缺少新版 ProgId' }
        return $value
    } finally { $child.Dispose() }
}
function Get-LegacyAssociation([string]$Protocol) {
    Initialize-AssociationNative
    $path = Get-LegacyPath $Protocol
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
    if ($null -eq $key) { throw "Missing legacy association: $Protocol / 缺少旧版关联记录" }
    try {
        $progId = [string]$key.GetValue('ProgId','')
        $hash = [string]$key.GetValue('Hash','')
    } finally { $key.Dispose() }
    if (-not $progId -or -not $hash) { throw 'Incomplete legacy association / 旧版关联记录不完整' }
    [pscustomobject]@{
        Protocol = $Protocol
        ProgId = $progId
        Hash = $hash
        HashValid = ((Get-AssociationHash $Protocol $progId ([WBaf.Native]::Timestamp($path))) -ceq $hash)
    }
}
function Get-BrowserAssociations {
    foreach ($protocol in 'http','https') {
        $legacy = Get-LegacyAssociation $protocol
        $latest = Get-LatestProgId $protocol
        [pscustomobject]@{Protocol=$protocol;Legacy=$legacy.ProgId;Latest=$latest;Aligned=($legacy.ProgId -eq $latest);LegacyHashValid=$legacy.HashValid}
    }
}
function Assert-Win32ProgId([string]$ProgId) {
    if ($ProgId -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unsupported ProgId / 不支持的 ProgId' }
    $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($ProgId + '\shell\open\command')
    if ($null -eq $key) { throw "Not a registered Win32 browser: $ProgId / 不是已注册的桌面浏览器" }
    try {
        if (-not $key.GetValue('','')) { throw 'Empty browser command / 浏览器启动命令为空' }
    } finally { $key.Dispose() }
}
function Set-LegacyAssociation([string]$Protocol,[string]$ProgId) {
    Assert-Win32ProgId $ProgId
    Initialize-AssociationNative
    $path = Get-LegacyPath $Protocol
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$true)
    if ($null -eq $key) { throw 'Missing legacy key / 缺少旧版关联键' }
    try {
        $key.SetValue('ProgId',$ProgId,[Microsoft.Win32.RegistryValueKind]::String)
        for ($attempt=0;$attempt -lt 3;$attempt++) {
            $hash = Get-AssociationHash $Protocol $ProgId ([WBaf.Native]::Timestamp($path))
            $key.SetValue('Hash',$hash,[Microsoft.Win32.RegistryValueKind]::String)
            $key.Flush()
            $after = Get-LegacyAssociation $Protocol
            if ($after.ProgId -eq $ProgId -and $after.HashValid) { return }
        }
        throw 'Hash verification failed / 校验值验证失败'
    } finally { $key.Dispose() }
}
function New-AssociationPlan {
    foreach ($protocol in 'http','https') {
        $legacy = Get-LegacyAssociation $protocol
        if (-not $legacy.HashValid) { throw "Invalid existing hash: $protocol / 现有校验值无效，停止修复" }
        $target = Get-LatestProgId $protocol
        Assert-Win32ProgId $target
        Assert-Win32ProgId $legacy.ProgId
        [pscustomobject]@{Protocol=$protocol;Before=$legacy.ProgId;Target=$target;ExpectedLatest=$target}
    }
}
function Invoke-AssociationTransaction {
    param([object[]]$Entries,[scriptblock]$Writer,[scriptblock]$LatestReader)
    # Track an entry before writing: even a partial failed write must be rolled back.
    $touched = [Collections.Generic.List[object]]::new()
    try {
        foreach ($entry in $Entries) {
            if ((& $LatestReader $entry.Protocol) -ne $entry.ExpectedLatest) { throw 'Default browser changed / 默认浏览器已改变' }
        }
        foreach ($entry in $Entries) {
            $touched.Add($entry)
            & $Writer $entry.Protocol $entry.Target
            foreach ($check in $Entries) {
                if ((& $LatestReader $check.Protocol) -ne $check.ExpectedLatest) { throw 'Modern association changed during repair / 修复期间新版关联已改变' }
            }
        }
    } catch {
        $originalError = $_.Exception.Message
        $rollbackErrors = @()
        foreach ($entry in $touched) {
            try { & $Writer $entry.Protocol $entry.Before } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw ($originalError + '; Rollback failed / 撤销失败: ' + ($rollbackErrors -join '; ')) }
        throw ($originalError + '; touched legacy records restored / 已恢复受影响的旧记录')
    }
}
function Get-UcpdState {
    $driver = Get-CimInstance Win32_SystemDriver -Filter "Name='UCPD'"
    if ($null -eq $driver) { throw 'UCPD not found / 未找到 UCPD' }
    $start = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD').Start
    [pscustomobject]@{DriverState=[string]$driver.State;Start=[int]$start;ProtectionRunning=($driver.State -eq 'Running')}
}
function Restore-UcpdProtection([int]$OriginalStart) {
    if ($OriginalStart -ne 1) { throw 'Unsupported original startup mode / 不支持的原启动模式' }
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name Start -Value $OriginalStart
    if ((Get-UcpdState).Start -ne $OriginalStart) { throw 'UCPD startup restoration failed / 启动配置恢复失败' }
    $loadError = $null
    if (-not (Get-UcpdState).ProtectionRunning) {
        try {
            Start-Service UCPD -ErrorAction Stop
            (Get-Service UCPD).WaitForStatus('Running',[TimeSpan]::FromSeconds(10))
        } catch {
            # A boot-loaded driver can require a second reboot. Do not misreport success.
            $loadError = $_.Exception.Message
        }
    }
    $report = Get-UcpdState
    $report | Add-Member -NotePropertyName LoadError -NotePropertyValue $loadError
    $report
}
function Get-RepairCompletion([bool]$AssociationSucceeded,[bool]$StartupRestored,[bool]$DriverRunning) {
    if (-not $StartupRestored) { return 'ProtectionRestoreFailed' }
    if (-not $AssociationSucceeded) { return 'RepairFailed' }
    if (-not $DriverRunning) { return 'AwaitingProtectionRestart' }
    'Complete'
}
function Update-AssociationCache { Initialize-AssociationNative; [WBaf.Native]::Refresh() }
Export-ModuleMember -Function Get-CurrentSid,Test-Administrator,Get-BrowserAssociations,Get-LegacyAssociation,Get-LatestProgId,Get-AssociationHash,New-AssociationPlan,Set-LegacyAssociation,Invoke-AssociationTransaction,Get-UcpdState,Restore-UcpdProtection,Get-RepairCompletion,Update-AssociationCache
