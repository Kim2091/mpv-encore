<#
.SYNOPSIS
    Register (or remove) Windows file associations so media files can be opened
    with mpv — the same thing mpv.net's setup does.

.DESCRIPTION
    Encore is a configuration package; it does NOT include mpv. This tool wires
    up YOUR existing mpv.exe as a handler for common video / audio / image file
    types so it appears in Windows' "Open with" lists and under
    Settings > Apps > Default apps.

    Everything is written under HKEY_CURRENT_USER, so:
      * no administrator rights are needed, and
      * it only affects the current user, and
      * it is fully reversible with  -Unregister.

    Windows 10/11 will not let any app silently steal the default for a file
    type — after registering, you confirm the defaults yourself in the Settings
    page this tool opens for you.

.PARAMETER MpvPath
    Full path to mpv.exe. If omitted, the tool looks for mpv.exe on PATH and
    otherwise prompts you for it.

.PARAMETER Unregister
    Remove everything this tool created.

.PARAMETER NoSettings
    Don't open the Windows "Default apps" settings page after registering.

.EXAMPLE
    .\Register-FileAssociations.ps1
.EXAMPLE
    .\Register-FileAssociations.ps1 -MpvPath "C:\Program Files\mpv\mpv.exe"
.EXAMPLE
    .\Register-FileAssociations.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string]$MpvPath,
    [switch]$Unregister,
    [switch]$NoSettings
)

$ErrorActionPreference = 'Stop'

$ProgId  = 'Encore.mpv'
$AppName = 'Encore'                              # RegisteredApplications entry
$AppRoot = 'HKCU:\Software\Encore'
$CapsKey = "$AppRoot\Capabilities"
$AppDesc = 'Play media files with mpv (set up by Encore).'

# Media extensions to claim (no leading dot). Mirrors mpv / mpv.net's lists.
$Exts = @(
    # video
    '3g2','3gp','asf','avi','divx','f4v','flv','m2ts','m2v','m4v','mj2','mkv',
    'mov','mp4','mpeg','mpg','mts','ogv','rm','rmvb','ts','vob','webm','wmv','y4m',
    # audio
    'aac','ac3','aiff','ape','au','dts','eac3','flac','m4a','mka','mp3','oga',
    'ogg','ogm','opus','thd','wav','wma','wv',
    # image
    'avif','bmp','gif','j2k','jp2','jpeg','jpg','jxl','png','svg','tga','tif','tiff','webp'
)

# Tell the shell that associations changed so it refreshes without a re-login.
function Update-ShellAssociations {
    try {
        if (-not ('Win32.Shell' -as [type])) {
            Add-Type -Namespace Win32 -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int eventId, int flags, System.IntPtr item1, System.IntPtr item2);
'@
        }
        # SHCNE_ASSOCCHANGED = 0x08000000
        [Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

function Register-Associations([string]$mpv) {
    # 1) A ProgId describing how to open a media file with mpv.
    $progKey = "HKCU:\Software\Classes\$ProgId"
    New-Item -Path $progKey -Force -Value 'Media file' | Out-Null
    New-Item -Path "$progKey\DefaultIcon" -Force -Value "$mpv,0" | Out-Null
    New-Item -Path "$progKey\shell\open\command" -Force -Value ("`"$mpv`" `"%1`"") | Out-Null

    # 2) Application capabilities -> shows up in Settings > Default apps.
    New-Item -Path $CapsKey -Force | Out-Null
    Set-ItemProperty -Path $CapsKey -Name 'ApplicationName'        -Value 'Encore (mpv)'
    Set-ItemProperty -Path $CapsKey -Name 'ApplicationDescription' -Value $AppDesc
    New-Item -Path "$CapsKey\FileAssociations" -Force | Out-Null

    foreach ($e in $Exts) {
        $dot = ".$e"
        # Add mpv to the file type's "Open with" list (additive — we never touch
        # the extension's existing default).
        $owp = "HKCU:\Software\Classes\$dot\OpenWithProgids"
        New-Item -Path $owp -Force | Out-Null
        New-ItemProperty -Path $owp -Name $ProgId -Value '' -PropertyType String -Force | Out-Null
        # Advertise the association under our capabilities.
        Set-ItemProperty -Path "$CapsKey\FileAssociations" -Name $dot -Value $ProgId
    }

    # 3) Register the application so Windows lists it in Default apps.
    New-Item -Path 'HKCU:\Software\RegisteredApplications' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' `
        -Name $AppName -Value 'Software\Encore\Capabilities'

    Update-ShellAssociations
}

function Unregister-Associations {
    Remove-Item -Path "HKCU:\Software\Classes\$ProgId" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $AppRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' `
        -Name $AppName -ErrorAction SilentlyContinue
    foreach ($e in $Exts) {
        $owp = "HKCU:\Software\Classes\.$e\OpenWithProgids"
        if (Test-Path $owp) {
            Remove-ItemProperty -Path $owp -Name $ProgId -ErrorAction SilentlyContinue
        }
    }
    Update-ShellAssociations
}

# --------------------------------------------------------------------------
if ($Unregister) {
    Unregister-Associations
    Write-Host "Removed Encore/mpv file associations." -ForegroundColor Green
    return
}

# Resolve mpv.exe: parameter -> PATH -> prompt.
if (-not $MpvPath) {
    $found = Get-Command 'mpv.exe' -ErrorAction SilentlyContinue
    if ($found) { $MpvPath = $found.Source }
}
if (-not $MpvPath) {
    Write-Host "mpv.exe was not found on your PATH."
    $MpvPath = Read-Host "Enter the full path to mpv.exe"
}
$MpvPath = $MpvPath.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $MpvPath)) {
    throw "mpv.exe not found at: $MpvPath"
}
$MpvPath = (Resolve-Path -LiteralPath $MpvPath).Path

Register-Associations $MpvPath
Write-Host ""
Write-Host "Registered mpv for $($Exts.Count) media file types." -ForegroundColor Green
Write-Host "  mpv.exe: $MpvPath"
Write-Host ""
Write-Host "Windows won't let an app set itself as default automatically. To finish:"
Write-Host "  In the Default apps page, search a type (e.g. .mkv) or pick" -ForegroundColor Yellow
Write-Host "  'Encore (mpv)', and set it as the default." -ForegroundColor Yellow
Write-Host ""
Write-Host "Run with -Unregister to undo all of this."

if (-not $NoSettings) {
    Start-Process 'ms-settings:defaultapps'
}
