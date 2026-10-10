# Quick start / 快速开始

## 简体中文

1. 从 Releases 下载 **windows-browser-association-fix-v0.1.0.zip**，右键「全部解压」。不要在 ZIP 内直接运行，也不要只复制一个文件。
2. 双击解压文件夹中的 **Start.cmd**。它会先检查状态，不会直接修复。
3. 如果新旧记录不一致，选择 **2 准备修复**。批准当前账户的管理员权限，在新窗口阅读提示，输入 **YES** 继续。不要输入另一个 Windows 账户的凭据。
4. 成功准备后，保存工作，自行重启并登录同一账户。登录任务会执行修复并恢复 UCPD 启动配置。
5. 再次打开 **Start.cmd** 检查状态。在原软件中测试链接。若提示保护尚未运行，再重启一次；只有 UCPD 正在运行、启动模式为 1，且阶段为 Complete，才表示完整修复流程完成。

**已一致时无需修复。** 本工具仅解决 HTTP/HTTPS 新旧关联不一致，其他原因或不支持的系统格式会拒绝修复。没有自动重启，也不会永久禁用 UCPD。

菜单 **3** 恢复保护，**4** 取消待执行修复，**5** 撤销已完成修复。撤销也需要受控重启流程。出错时保留完整错误信息，详见 [中文说明](README.zh-CN.md)。不要把本地账户状态、注册表备份或日志公开上传。

Start.cmd 为启动进程设置 Bypass 执行策略，以便运行下载的未签名菜单；不改变全局策略，不覆盖组织组策略。开始操作前会要求确认，之后只解除包内三个修复代码文件的下载标记，让登录任务可以使用 RemoteSigned。仅运行你信任并核对过的完整发布包。包没有代码签名，不会下载外部程序。

此版本为 **预发布版**：本地和自动测试覆盖两种 PowerShell；原修复方法已在一台 Windows 11 电脑验证，下载菜单包的完整重启流程尚未实机复测。

## English

1. Download **windows-browser-association-fix-v0.1.0.zip** from Releases and choose **Extract All**. Keep all files together; do not run inside the ZIP.
2. Double-click **Start.cmd**. It checks status first without changing settings.
3. If the old and current records differ, select **2 Prepare repair**. Approve elevation for your current Windows account, read the new window, and type **YES**. Do not supply another account's credentials.
4. After successful preparation, save your work, restart manually, and sign in to the same account. The logon task applies the repair and restores UCPD startup.
5. Open **Start.cmd** again and test a link in the affected app. Restart again if protection is stopped. The full repair is complete only when UCPD is running, startup is 1, and the phase is Complete.

**Aligned records need no repair.** This tool handles only mismatched legacy/current HTTP/HTTPS associations. Unsupported formats and other causes are refused. It never restarts automatically or permanently disables UCPD.

Menu **3** restores protection, **4** cancels a pending repair, and **5** stages undo through another controlled restart. Keep any error details and consult [the English guide](README.md). Never publish local account state, registry backups, or logs.

Start.cmd uses Bypass for its own process to run the unsigned downloaded menu; global policy is unchanged and organizational policy is respected. After explicit confirmation, only the three bundled repair code files are unblocked so the scheduled task can use RemoteSigned. Use a complete release package you trust and have checked. It is unsigned and downloads no external programs.

This is a **prerelease**: local and automated tests cover both PowerShell versions. The original repair method was verified on one Windows 11 machine; the full restart sequence of this downloadable menu package has not been retested on a live machine.
