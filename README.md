# Windows Browser Association Fix

For a double-click menu, download the ZIP from [Releases](https://github.com/Yelina02/windows-browser-association-fix/releases), extract all files, and open **Start.cmd**. See [Quick start / 快速开始](QUICKSTART.md). The menu checks status first; repair requires administrator approval and confirmation.

[English](README.md) · [简体中文](README.zh-CN.md)

Repair stale HTTP/HTTPS associations used by legacy apps that open links in Edge despite another default browser. The tool synchronizes legacy **`UserChoice`** records with the user's existing **`UserChoiceLatest`** selection, with backups, valid legacy hashes, rollback, and UCPD restoration.

## Scope and requirements

This addresses a specific mismatch between new and old registry records, not every cause of links opening in Edge. The technique was verified on **Windows 11 26H2, build 26300.9457, with QQ 9.7.25.29417**. The generalized package has safe tests; its entire reboot sequence has not been rerun on that already repaired machine. Other builds and browsers are not guaranteed to behave the same way.

Requires 64-bit Windows, Windows PowerShell 5.1 or PowerShell 7, a running UCPD driver with `Start=1`, valid existing legacy hashes, a supported `UserChoiceLatest` layout, and a registered Win32 browser selected through Windows Settings. Unsupported data or changed defaults cause the tool to stop. Preparation and recovery require administrator access under the **same Windows account**.

See [Microsoft URL launch documentation](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-default-app) and [Mozilla's UserChoice protection documentation](https://firefox-source-docs.mozilla.org/widget/windows/shell/set-default.html).

## Usage

Download the whole repository, review the scripts, and open PowerShell in its directory. Keep `lib/` and `vendor/` alongside the entry script. If Windows blocks a trusted downloaded file, review and unblock it; no global execution-policy change is required.

If Windows PowerShell's local default policy is `Restricted`, launch the reviewed script with a process-only policy, for example `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Fix-BrowserAssociation.ps1 -Action Status`. The login task uses the same process-only policy for its protected local snapshot. Organization Group Policy is not overridden.

### 1. Inspect and preview

```powershell
.\Fix-BrowserAssociation.ps1 -Action Status
.\Fix-BrowserAssociation.ps1 -Action Status -Json
.\Fix-BrowserAssociation.ps1 -Action Prepare -WhatIf
```

`Status` is read-only and does not require elevation. If both protocols are aligned, `Prepare` returns without modifying anything. First confirm that Windows Settings shows the intended browser for HTTP/HTTPS.

### 2. Prepare from administrator PowerShell

```powershell
.\Fix-BrowserAssociation.ps1 -Action Prepare
```

The tool backs up both protocol records and UCPD configuration, snapshots its code, registers an elevated task for this account's next login, and temporarily disables UCPD startup. Private state and backups are stored under an ACL-protected directory:

```text
%ProgramData%\WindowsBrowserAssociationFix\<account SID>\
```

**Do not upload this runtime directory to GitHub.** It contains account information and real registry backups. The source package contains no actual account data.

### 3. Save work, restart, and sign in

Restart Windows yourself and sign in to the same account. The login task first uses a separate `sc.exe` action to restore UCPD startup, even if PowerShell cannot load the repair package. The repair action also verifies startup restoration **before any association write**, checks for unexpected changes, updates only legacy HTTP/HTTPS `ProgId` and `Hash`, and rolls back touched legacy records on failure. It leaves the modern choice intact, tries to load UCPD, records the result, and removes its task once startup is restored.

The script never restarts Windows automatically or permanently disables UCPD. **A second reboot may be required to reload the driver.**

### 4. Verify

```powershell
.\Fix-BrowserAssociation.ps1 -Action Status
```

Test a link in the affected app. `AwaitingProtectionRestart` means the association repair succeeded but UCPD is not running. Restart again, then confirm `ProtectionRunning=True`, `Start=1`, and phase `Complete`. If UCPD still fails to load, investigate the driver error; the repair is not fully finished.

## Cancel, recover, or roll back

Run under the same account in administrator PowerShell:

```powershell
# Cancel a pending repair; restore startup and remove its task.
.\Fix-BrowserAssociation.ps1 -Action Cancel

# Restore UCPD after an interrupted run, preserving browser records.
.\Fix-BrowserAssociation.ps1 -Action RestoreProtection

# Prepare restoration of the original legacy records after successful repair.
.\Fix-BrowserAssociation.ps1 -Action Rollback
```

`Cancel` does not undo completed association writes. `Rollback` uses another controlled reboot cycle and recalculates hashes instead of importing old ones. It refuses if defaults changed after repair. Wait until UCPD is running before preparing rollback. Each run retains original backups and `result.json` in its local run directory.

If the package/state is lost and UCPD originally used system startup (`1`), restore boot configuration from administrator PowerShell, then restart:

```powershell
sc.exe config UCPD start= system
```

This fallback does not restore browser records. Do not import the entire UCPD backup just to restore startup. Task cleanup errors appear in `TaskError`; remove only the exact task named in local `state.json` if necessary. Keep runtime snapshots while a task is pending.

## Testing

```powershell
.\tests\Test-Repair.ps1
```

Tests cover syntax, transaction success, partial-write rollback, concurrent default changes, rollback errors, native timestamps and hash minute boundaries, protection completion reporting, and source privacy. They create/delete only one GUID-named temporary registry key. They never stop UCPD, change browser associations, or register tasks. GitHub Actions tests Windows PowerShell and PowerShell 7.

## License

[MIT](LICENSE), with upstream hash attribution and license in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The repair scripts never download or run external executables.
