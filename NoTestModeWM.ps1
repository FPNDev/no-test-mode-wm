# No Test Mode Watermark - hides or restores the Windows "Test Mode" desktop watermark that appears while
# Windows test signing (test mode) is on. It repoints the Explorer CLSID_ExplorerHostCreator in-process COM
# server at ntmwm.dll (which forwards everything to the real ExplorerFrame.dll and only stops the three
# watermark lines from being drawn), backing up the original registration and restoring it on request.
# Needs administrator rights; it self-elevates. See README.md for the full warnings.
$ErrorActionPreference = 'Stop'

# Relaunch elevated if we are not already: the GUI and all registry work need administrator rights.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    } catch {
        # The user declined the elevation prompt; nothing to do.
    }
    exit
}

$dll = Join-Path $PSScriptRoot 'ntmwm.dll'
# InProcServer32 of CLSID_ExplorerHostCreator. Default value is normally the expandable string
# %SystemRoot%\System32\ExplorerFrame.dll; the key is owned by TrustedInstaller, so the script must take
# ownership before it can write.
$clsidPath = 'SOFTWARE\Classes\CLSID\{ab0b37ec-56f6-4a0e-a8fd-7a8bf7c2da96}\InProcServer32'
$backupPath = 'SOFTWARE\NoTestModeWM'
# Owner, Group and Access only: the SACL would need SeSecurityPrivilege and is not ours to touch.
$sddlSections = [System.Security.AccessControl.AccessControlSections]'Owner, Group, Access'

# SeTakeOwnershipPrivilege and SeRestorePrivilege sit in an administrator token but disabled; .NET does not
# enable them on its own, so enable them by hand before changing the owner or restoring a foreign one.
Add-Type -Namespace NTMWM -Name Priv -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true)]
static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
static extern bool LookupPrivilegeValue(string host, string name, out long luid);
[DllImport("advapi32.dll", SetLastError = true)]
static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length, IntPtr prev, IntPtr prevLength);
[DllImport("kernel32.dll")]
static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll", SetLastError = true)]
static extern bool CloseHandle(IntPtr handle);

[StructLayout(LayoutKind.Sequential, Pack = 4)]
struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attributes; }

public static void Enable(string name)
{
    IntPtr token;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28 /* ADJUST_PRIVILEGES | QUERY */, out token))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    try
    {
        long luid;
        if (!LookupPrivilegeValue(null, name, out luid))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        var tp = new TOKEN_PRIVILEGES { Count = 1, Luid = luid, Attributes = 0x2 /* ENABLED */ };
        if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        int err = Marshal.GetLastWin32Error();
        if (err != 0)
            throw new System.ComponentModel.Win32Exception(err);
    }
    finally { CloseHandle(token); }
}
'@

$admins = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

function Open-Clsid([System.Security.AccessControl.RegistryRights]$Rights) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $clsidPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $Rights)
    if (-not $key) {
        throw "Registry key HKLM\$clsidPath does not exist."
    }
    $key
}

# Make Administrators the owner, then grant them full control. Both are idempotent once we own the key.
function Grant-Write {
    [NTMWM.Priv]::Enable('SeTakeOwnershipPrivilege')
    $key = Open-Clsid ([System.Security.AccessControl.RegistryRights]::TakeOwnership)
    try {
        $own = New-Object System.Security.AccessControl.RegistrySecurity
        $own.SetOwner($admins)
        $key.SetAccessControl($own)
    } finally { $key.Close() }

    $key = Open-Clsid ([System.Security.AccessControl.RegistryRights]::ChangePermissions)
    try {
        $acl = $key.GetAccessControl()
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
        $key.SetAccessControl($acl)
    } finally { $key.Close() }
}

# Points the in-proc server at ntmwm.dll, capturing the pristine value, type and security descriptor once so a
# repeat never records our own DLL as the "original".
function Install-Hook {
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw "ntmwm.dll was not found next to this script: $dll"
    }
    if (-not [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($backupPath)) {
        $read = Open-Clsid ([System.Security.AccessControl.RegistryRights]::ReadKey)
        try {
            $origValue = $read.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $origValue) {
                throw "HKLM\$clsidPath has no default value to back up."
            }
            $origKind = $read.GetValueKind('')
            $origSddl = $read.GetAccessControl($sddlSections).GetSecurityDescriptorSddlForm($sddlSections)
        } finally { $read.Close() }

        Grant-Write

        $bk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($backupPath)
        try {
            $bk.SetValue('OriginalValue', $origValue, [Microsoft.Win32.RegistryValueKind]::String)
            $bk.SetValue('OriginalKind', $origKind.ToString(), [Microsoft.Win32.RegistryValueKind]::String)
            $bk.SetValue('OriginalSddl', $origSddl, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $bk.Close() }
    } else {
        Grant-Write
    }

    $key = Open-Clsid ([System.Security.AccessControl.RegistryRights]::SetValue)
    try {
        $key.SetValue('', $dll, [Microsoft.Win32.RegistryValueKind]::String)
    } finally { $key.Close() }
}

# Restores the original value, its type and the key's security descriptor, then drops the marker. No-op if the
# watermark was never hidden.
function Remove-Hook {
    $bk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($backupPath)
    if (-not $bk) {
        return
    }
    try {
        $origValue = $bk.GetValue('OriginalValue')
        $origKind = [Microsoft.Win32.RegistryValueKind]($bk.GetValue('OriginalKind'))
        $origSddl = $bk.GetValue('OriginalSddl')
    } finally { $bk.Close() }

    [NTMWM.Priv]::Enable('SeTakeOwnershipPrivilege')
    [NTMWM.Priv]::Enable('SeRestorePrivilege')   # needed to hand ownership back to TrustedInstaller
    Grant-Write

    if ($null -ne $origValue) {
        $key = Open-Clsid ([System.Security.AccessControl.RegistryRights]::SetValue)
        try {
            $key.SetValue('', $origValue, $origKind)
        } finally { $key.Close() }
    }

    if ($origSddl) {
        $key = Open-Clsid ([System.Security.AccessControl.RegistryRights]'TakeOwnership, ChangePermissions')
        try {
            $sec = New-Object System.Security.AccessControl.RegistrySecurity
            $sec.SetSecurityDescriptorSddlForm($origSddl, $sddlSections)
            $key.SetAccessControl($sec)
        } finally { $key.Close() }
    }

    [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($backupPath, $false)
}

function Restart-Explorer {
    # Windows auto-restarts the shell (as the signed-in user) when explorer.exe stops.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}

function Test-HookInstalled {
    [bool][Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($backupPath)
}

# ---- GUI ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$red = [System.Drawing.Color]::Firebrick
$green = [System.Drawing.Color]::ForestGreen
$gray = [System.Drawing.Color]::DimGray

$warning = @'
This hides or restores the "Test Mode" watermark that Windows shows in the bottom-right corner of
the desktop while test signing (test mode) is on.

How it works: it loads a small component (ntmwm.dll) into Windows Explorer that stops only those
watermark lines from being drawn, and forwards everything else to Windows unchanged. To do that it
takes ownership of a protected system registry key, backs up the original, and restores it when you
restore the watermark.

Please read before using:
  - This needs administrator rights and restarts Windows Explorer (your taskbar will blink).
  - It may be unreliable or stop working after a Windows update.
  - In rare cases Explorer or File Explorer can fail to open ("Server execution failed") until you
    restart Windows. Restarting Windows fixes it; there is no lasting damage.
  - It only matters while Windows is in test mode; it does not turn test mode on or off.
  - Use at your own risk. See README.md.
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = 'No Test Mode Watermark'
$form.ClientSize = New-Object System.Drawing.Size(560, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$info = New-Object System.Windows.Forms.TextBox
$info.Multiline = $true
$info.ReadOnly = $true
$info.ScrollBars = 'Vertical'
$info.Text = $warning
$info.SetBounds(12, 12, 536, 270)
$info.BackColor = [System.Drawing.SystemColors]::Window
$form.Controls.Add($info)

$remove = New-Object System.Windows.Forms.Button
$remove.Text = 'Remove test mode watermark'
$remove.SetBounds(12, 296, 266, 44)
$form.Controls.Add($remove)

$restore = New-Object System.Windows.Forms.Button
$restore.Text = 'Restore test mode watermark'
$restore.SetBounds(282, 296, 266, 44)
$form.Controls.Add($restore)

$status = New-Object System.Windows.Forms.Label
$status.SetBounds(12, 352, 536, 56)
$form.Controls.Add($status)

function Set-Status([string]$text, $color) {
    $status.ForeColor = $color
    $status.Text = $text
}

function Set-Busy([bool]$busy) {
    $remove.Enabled = (-not $busy) -and (Test-Path -LiteralPath $dll -PathType Leaf)
    $restore.Enabled = -not $busy
}

$remove.Add_Click({
    Set-Busy $true
    Set-Status 'Hiding the watermark and restarting Explorer...' $gray
    $form.Refresh()
    try {
        Install-Hook
        Restart-Explorer
        Set-Status 'Done. The watermark is hidden and Explorer was restarted.' $green
    } catch {
        Set-Status "Could not hide the watermark: $($_.Exception.Message)" $red
    }
    Set-Busy $false
})

$restore.Add_Click({
    Set-Busy $true
    Set-Status 'Restoring the watermark and restarting Explorer...' $gray
    $form.Refresh()
    try {
        Remove-Hook
        Restart-Explorer
        Set-Status 'Done. The watermark is restored and Explorer was restarted.' $green
    } catch {
        Set-Status "Could not restore the watermark: $($_.Exception.Message)" $red
    }
    Set-Busy $false
})

if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
    $remove.Enabled = $false
    Set-Status "ntmwm.dll was not found next to this script, so the watermark cannot be hidden. Expected: $dll" $red
} elseif (Test-HookInstalled) {
    Set-Status 'Current state: the watermark is hidden.' $green
} else {
    Set-Status 'Current state: the watermark is shown (while Windows is in test mode).' $gray
}

[void]$form.ShowDialog()
