# Windows 浏览器关联修复

[English](README.md) · [简体中文](README.zh-CN.md)

处理 Windows 默认浏览器已设为 Chrome 等浏览器，但旧软件点击链接仍打开 Edge 的问题。脚本将过时的 **HTTP/HTTPS `UserChoice` 记录**同步为用户已选好的 **`UserChoiceLatest` 关联**，包含备份、有效校验值、撤销和 UCPD 恢复。

## 适用范围与条件

本工具针对新旧注册表记录不一致，无法解决所有链接打开 Edge 的情况。修复方法已在 **Windows 11 26H2，内部版本 26300.9457，QQ 9.7.25.29417** 上验证。通用脚本包具有无系统设置变更的测试；为了避免再次改动已修好的电脑，没有重新执行整个打包版本的重启流程。其他 Windows 版本和浏览器不保证有相同行为。

需要 64 位 Windows、Windows PowerShell 5.1 或 PowerShell 7、正在运行且原启动模式为 `Start=1` 的 UCPD、有效的旧关联校验值、受支持的 `UserChoiceLatest` 格式，以及通过 Windows 设置选好的注册完整的 Win32 桌面浏览器。脚本不硬编码浏览器名称。遇到不支持的数据或默认浏览器已改变，会停止。准备修复和恢复时，需要使用**同一个 Windows 账户**的管理员权限。

相关资料：[微软的网页链接打开机制](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-default-app)、[Mozilla 对 UserChoice 保护的说明](https://firefox-source-docs.mozilla.org/widget/windows/shell/set-default.html)。

## 使用步骤

下载完整仓库，检查脚本后，在仓库目录中打开 PowerShell。保留入口脚本旁的 `lib/` 和 `vendor/`。如果 Windows 阻止可信的下载文件，请先检查再解除下载标记，无需修改全局执行策略。

若 Windows PowerShell 的本地默认策略为 `Restricted`，可使用仅对当前进程生效的策略运行已检查的脚本，例如 `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Fix-BrowserAssociation.ps1 -Action Status`。登录任务也会为受保护的本地代码快照使用此进程级策略，不覆盖组织的组策略。

### 1. 查看状态并预览

```powershell
.\Fix-BrowserAssociation.ps1 -Action Status
.\Fix-BrowserAssociation.ps1 -Action Status -Json
.\Fix-BrowserAssociation.ps1 -Action Prepare -WhatIf
```

`Status` 只读取状态，不需提权。新旧记录一致时，`Prepare` 直接返回，不修改任何设置。请先确认 Windows 默认应用中的 HTTP、HTTPS 是你想用的浏览器。

### 2. 在管理员 PowerShell 中准备

```powershell
.\Fix-BrowserAssociation.ps1 -Action Prepare
```

脚本备份两种协议及 UCPD 配置，保存代码快照，注册当前账户下次登录时执行的提权任务，最后临时禁用 UCPD 启动。本地状态和备份存放在受 ACL 保护的目录：

```text
%ProgramData%\WindowsBrowserAssociationFix\<账户 SID>\
```

**不要把运行目录上传到 GitHub。** 它包含账户信息及真实注册表备份。源码包没有实际账户数据。

### 3. 保存工作，重启并登录

自行重启 Windows，再登录同一账户。登录任务首先通过独立的 `sc.exe` 动作恢复 UCPD 启动模式，即使 PowerShell 无法加载修复包，也会先执行这一恢复动作。修复动作还会在**修改任何关联之前**验证启动模式已恢复，检查意外变更，然后仅更新 HTTP、HTTPS 旧记录的 `ProgId` 和 `Hash`。写入失败时恢复受影响的旧记录。新版关联保持原选择。任务尝试加载 UCPD、记录结果，并在启动模式恢复后移除自身。

脚本不会自动重启电脑，也不会永久禁用 UCPD。**驱动可能需要第二次重启才会恢复运行。**

### 4. 验证

```powershell
.\Fix-BrowserAssociation.ps1 -Action Status
```

在原来有问题的软件里测试一个链接。`AwaitingProtectionRestart` 表示关联已修复，但 UCPD 未运行。请再重启一次，确认 `ProtectionRunning=True`、`Start=1`、阶段为 `Complete`。如果驱动仍无法加载，应调查驱动错误，不能视为完全收尾。

## 取消、恢复和撤销

在同一账户的管理员 PowerShell 中执行：

```powershell
# 取消待执行修复，恢复启动配置并移除任务。
.\Fix-BrowserAssociation.ps1 -Action Cancel

# 中断后恢复 UCPD，保留浏览器记录。
.\Fix-BrowserAssociation.ps1 -Action RestoreProtection

# 成功修复后，准备恢复最初的旧记录。
.\Fix-BrowserAssociation.ps1 -Action Rollback
```

`Cancel` 不撤销已完成的关联修改。`Rollback` 会安排另一次受控重启流程，重新计算校验值，不直接导入过时的 Hash。默认浏览器在修复后改变时，它会拒绝撤销。准备撤销前，请先确保 UCPD 正在运行。每次运行的原始备份和 `result.json` 都保留在对应的本地运行目录。

若源码包或状态文件丢失，且原 UCPD 启动模式确实为系统启动（`1`），可在管理员 PowerShell 中恢复后重启：

```powershell
sc.exe config UCPD start= system
```

该应急操作仅恢复启动配置，不恢复浏览器记录。不要为了恢复启动模式而导入整个 UCPD 备份。任务清理失败会记录在 `TaskError` 中；必要时只移除本地 `state.json` 指定的确切任务。任务仍待执行时，请保留运行快照。

## 测试

```powershell
.\tests\Test-Repair.ps1
```

测试覆盖语法、事务成功、部分失败撤销、默认浏览器中途改变、撤销错误、原生时间戳与分钟边界校验、保护恢复状态、源码隐私。测试只创建并删除一个随机 GUID 临时注册表键，不停止 UCPD、不修改浏览器关联、不注册任务。GitHub Actions 分别使用 Windows PowerShell 和 PowerShell 7 运行。

## 许可

[MIT](LICENSE)。提取的算法保留上游作者及许可，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。修复脚本不会下载或运行外部可执行文件。
