. (Join-Path $PSScriptRoot "..\editor_kit\windows.ps1")

$script:EditorLeasePropertyName = "swaw-kit-git.identity-window.v3"

function Get-EditorWindows {
    param([string]$Tool)

    return @(Get-EditorKitWindows $Tool | ForEach-Object {
        $_ | Add-Member -NotePropertyName Marker -NotePropertyValue (
            [SwawKit.EditorKit.NativeWindows]::GetProp(
                [IntPtr]::new([long]$_.Hwnd),
                $script:EditorLeasePropertyName
            ).ToInt64()
        ) -PassThru
    })
}

function Set-EditorWindowMarker {
    param([long]$Handle)

    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 4
        do {
            $random.GetBytes($bytes)
            $marker = [long]([BitConverter]::ToUInt32($bytes, 0) -band 0x7fffffff)
        } while ($marker -eq 0)
    } finally {
        $random.Dispose()
    }

    $written = [SwawKit.EditorKit.NativeWindows]::SetProp(
        [IntPtr]::new($Handle),
        $script:EditorLeasePropertyName,
        [IntPtr]::new($marker)
    )
    if (-not $written) {
        throw "The editor window could not be marked as identity-owned."
    }
    return $marker
}

function Clear-EditorWindowMarker {
    param([long]$Handle)
    [void][SwawKit.EditorKit.NativeWindows]::RemoveProp(
        [IntPtr]::new($Handle),
        $script:EditorLeasePropertyName
    )
}
