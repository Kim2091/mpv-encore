<#
.SYNOPSIS
    Register (or remove) Windows file associations so media files and streaming
    URLs open with mpv - a port of how mpv.net's setup registers itself.

.DESCRIPTION
    Encore is a configuration package; it does NOT include mpv. This tool points
    Windows at YOUR existing mpv.exe.

    It mirrors mpv.net's FileAssociation registration (per-extension ProgIDs,
    PerceivedType, an Applications\mpv.exe entry with FriendlyAppName +
    SupportedTypes, App Paths, the ytdl/rtsp/srt/srtp URL protocols, the
    video/audio/image OpenWithList, and Capabilities + RegisteredApplications so
    it appears under Settings > Default apps).

    Unlike mpv.net it writes everything under HKEY_CURRENT_USER, so it needs no
    administrator rights, only affects the current user, and is fully reversible
    with -Unregister. It is also non-destructive: it never overwrites the
    handler an extension already has, so your existing associations are kept.
    (Windows still has you confirm the per-type default in Settings - no app may
    steal that silently.)

.PARAMETER MpvPath
    Full path to mpv.exe. Auto-detected on PATH, otherwise prompted.
.PARAMETER Unregister
    Remove everything this tool created.
.PARAMETER NoSettings
    Do not open the Windows "Default apps" page afterwards.
#>
[CmdletBinding()]
param(
    [string]$MpvPath,
    [switch]$Unregister,
    [switch]$NoSettings
)

$ErrorActionPreference = 'Stop'

# All per-user. HKCU\Software\Classes is the user's half of HKCR.
$Classes  = 'HKCU:\Software\Classes'
$AppName  = 'Encore'
$AppRoot  = 'HKCU:\Software\Clients\Media\Encore'
$Caps     = "$AppRoot\Capabilities"
$RegApps  = 'HKCU:\Software\RegisteredApplications'
$AppPaths = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
$Friendly = 'mpv (Encore)'
$Desc     = 'Play media files with mpv, set up by Encore.'
$ProgPrefix = 'Encore'                       # per-ext ProgID = Encore.<ext>
$Protocols  = @('ytdl','rtsp','srt','srtp')

# Media extensions grouped by Windows "perceived type". Superset of mpv.net's
# and Encore's own video/audio/image lists.
$Media = @(
    @{ type = 'video'; exts = @(
        '264','265','3g2','3gp','asf','avc','avi','dav','divx','f4v','flv','h264',
        'h265','hevc','m2t','m2ts','m2v','m4v','mj2','mkv','mov','mp4','mpeg','mpg',
        'mts','ogv','rm','rmvb','ts','vob','webm','wmv','y4m') }
    @{ type = 'audio'; exts = @(
        'aac','ac3','aiff','ape','au','dts','dtshd','dtshr','dtsma','eac3','flac',
        'm4a','mka','mp2','mp3','mpa','mpc','oga','ogg','ogm','opus','thd','w64',
        'wav','wma','wv') }
    @{ type = 'image'; exts = @(
        'avif','bmp','gif','j2k','jp2','jpeg','jpg','jxl','png','svg','tga','tif',
        'tiff','webp') }
)

# ---- registry helpers (key default value via Set-Item; named via New-ItemProperty)
function Ensure-Key($k) { if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null } }
function Set-Default($k, $v) { Ensure-Key $k; Set-Item -LiteralPath $k -Value $v }
function Set-Named($k, $n, $v) { Ensure-Key $k; New-ItemProperty -LiteralPath $k -Name $n -Value $v -PropertyType String -Force | Out-Null }

# Tell the shell associations changed so icons/menus refresh without a re-login.
function Update-Shell {
    try {
        if (-not ('Win32.Shell' -as [type])) {
            $sig = '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, int flags, System.IntPtr a, System.IntPtr b);'
            Add-Type -Namespace Win32 -Name Shell -MemberDefinition $sig
        }
        [Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) # SHCNE_ASSOCCHANGED
    } catch { }
}

function Register-Associations([string]$mpv) {
    $exe  = Split-Path $mpv -Leaf            # mpv.exe
    $cmd  = "`"$mpv`" `"%1`""
    $icon = "$mpv,0"

    # Remember which mpv.exe we wired up, so -Unregister can clean its keys.
    Set-Named $AppRoot 'MpvPath' $mpv

    # URL protocols (streaming): ytdl:// rtsp:// srt:// srtp://
    foreach ($p in $Protocols) {
        $k = "$Classes\$p"
        Set-Default $k "URL:$p Protocol"
        Set-Named   $k 'URL Protocol' ''
        Set-Default "$k\DefaultIcon" $icon
        Set-Default "$k\shell\open\command" $cmd
    }

    # "mpv" runnable from the Run dialog / start.
    Set-Default "$AppPaths\$exe" $mpv

    # Applications\mpv.exe - drives the "Open with" entry + friendly name.
    $appKey = "$Classes\Applications\$exe"
    Set-Named   $appKey 'FriendlyAppName' $Friendly
    Set-Default "$appKey\DefaultIcon" $icon
    Set-Default "$appKey\shell\open\command" $cmd

    # Capabilities -> Settings > Default apps lists "mpv (Encore)".
    Set-Named $Caps 'ApplicationName' $Friendly
    Set-Named $Caps 'ApplicationDescription' $Desc
    Set-Named $RegApps $AppName 'Software\Clients\Media\Encore\Capabilities'

    foreach ($grp in $Media) {
        $pt = $grp.type
        # add mpv to the perceived-type "Open with" list
        Set-Default "$Classes\SystemFileAssociations\$pt\OpenWithList\$exe" ''
        foreach ($e in $grp.exts) {
            $dot = ".$e"
            $progId = "$ProgPrefix$dot"               # Encore.mkv
            $progKey = "$Classes\$progId"
            # a ProgID that opens the file with mpv (+ icon + a friendly type name)
            Set-Default $progKey ("{0} file (mpv)" -f $pt)
            Set-Default "$progKey\DefaultIcon" $icon
            Set-Default "$progKey\shell\open\command" $cmd
            # wire the extension to it - additively. We deliberately DO NOT set
            # the extension's default handler: that would erase the user's
            # existing association (mpv.net's, or whatever). The user picks mpv
            # as default in Settings; our Capabilities entry makes that one click.
            $extKey = "$Classes\$dot"
            if (-not (Get-ItemProperty -LiteralPath $extKey -Name 'PerceivedType' -ErrorAction SilentlyContinue)) {
                Set-Named $extKey 'PerceivedType' $pt
            }
            Set-Named "$extKey\OpenWithProgids" $progId ''
            # advertise the type under the app + capabilities
            Set-Named "$appKey\SupportedTypes" $dot ''
            Set-Named "$Caps\FileAssociations" $dot $progId
        }
    }

    Update-Shell
    return ($Media | ForEach-Object { $_.exts.Count } | Measure-Object -Sum).Sum
}

function Unregister-Associations {
    $saved = $null
    if (Test-Path -LiteralPath $AppRoot) {
        $saved = (Get-ItemProperty -LiteralPath $AppRoot -Name 'MpvPath' -ErrorAction SilentlyContinue).MpvPath
    }
    $exe = if ($saved) { Split-Path $saved -Leaf } else { 'mpv.exe' }

    # Remove every ProgID we created (Encore.<ext>) in one sweep.
    Get-ChildItem -LiteralPath $Classes -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$ProgPrefix.*" } |
        ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }

    foreach ($grp in $Media) {
        foreach ($e in $grp.exts) {
            $owp = "$Classes\.$e\OpenWithProgids"
            if (Test-Path -LiteralPath $owp) {
                Remove-ItemProperty -LiteralPath $owp -Name "$ProgPrefix.$e" -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath "$Classes\SystemFileAssociations\$($grp.type)\OpenWithList\$exe" -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($p in $Protocols) { Remove-Item -LiteralPath "$Classes\$p" -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath "$Classes\Applications\$exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$AppPaths\$exe" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AppRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $RegApps -Name $AppName -ErrorAction SilentlyContinue
    # We never set an extension's default handler, so nothing there to restore.
    Update-Shell
}

# --------------------------------------------------------------------------
if ($Unregister) {
    Unregister-Associations
    Write-Host "Removed Encore/mpv file associations." -ForegroundColor Green
    return
}

if (-not $MpvPath) {
    $found = Get-Command 'mpv.exe' -ErrorAction SilentlyContinue
    if ($found) { $MpvPath = $found.Source }
}
if (-not $MpvPath) {
    Write-Host "mpv.exe was not found on your PATH."
    $MpvPath = Read-Host "Enter the full path to mpv.exe"
}
$MpvPath = $MpvPath.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $MpvPath)) { throw "mpv.exe not found at: $MpvPath" }
$MpvPath = (Resolve-Path -LiteralPath $MpvPath).Path

$count = Register-Associations $MpvPath
Write-Host ""
Write-Host "Registered mpv for $count media types + $($Protocols.Count) stream protocols." -ForegroundColor Green
Write-Host "  mpv.exe: $MpvPath"
Write-Host ""
Write-Host "To finish, set the defaults you want. Windows will not let an app do"
Write-Host "it automatically: in Default apps, search a type (e.g. .mkv) or pick" -ForegroundColor Yellow
Write-Host "'mpv (Encore)' and set it as default." -ForegroundColor Yellow
Write-Host ""
Write-Host "Run with -Unregister (or the Unregister script) to undo all of this."

if (-not $NoSettings) { Start-Process 'ms-settings:defaultapps' }
