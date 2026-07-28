Set-StrictMode -Version 2.0

# This is a recognized-name set, not a fallback order.
# A command directory may contain at most one run.* entry.
$script:ProjEntryProtocol = @(
    [pscustomobject]@{ Name = 'run.exe'; Adapter = 'exe' },
    [pscustomobject]@{ Name = 'run.ts'; Adapter = 'bun' },
    [pscustomobject]@{ Name = 'run.py'; Adapter = 'python' },
    [pscustomobject]@{ Name = 'run.ps1'; Adapter = 'powershell' },
    [pscustomobject]@{ Name = 'run.cmd'; Adapter = 'cmd' }
)

function Test-ProjWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-ProjAdapterSupported {
    param([Parameter(Mandatory = $true)][string]$Adapter)

    switch ($Adapter) {
        'exe' { return Test-ProjWindows }
        'cmd' { return Test-ProjWindows }
        'powershell' { return Test-ProjWindows }
        'bun' { return Test-ProjWindows }
        'python' { return Test-ProjWindows }
        default { return $false }
    }
}

function Get-ProjEntryResolution {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $FileNames = if ([IO.Directory]::Exists($Directory)) {
        @([IO.Directory]::EnumerateFiles($Directory) | ForEach-Object {
            [IO.Path]::GetFileName($_)
        })
    } else {
        @()
    }

    $Existing = [Collections.Generic.List[object]]::new()
    foreach ($Spec in $script:ProjEntryProtocol) {
        $Matches = @($FileNames | Where-Object {
            $_.Equals($Spec.Name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($Matches.Count -gt 1) {
            throw "Entry name collision in '$Directory': $($Matches -join ', ')"
        }
        if ($Matches.Count -eq 0) {
            continue
        }
        if (-not $Matches[0].Equals($Spec.Name, [StringComparison]::Ordinal)) {
            throw "Non-canonical entry name '$($Matches[0])' in '$Directory'; expected '$($Spec.Name)'."
        }
        $EntryPath = Join-Path $Directory $Spec.Name
        $EntryItem = Get-Item -LiteralPath $EntryPath -Force
        if (($EntryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Command entry cannot be a reparse point: $EntryPath"
        }
        $Existing.Add([pscustomobject]@{
            Name = $Spec.Name
            Adapter = $Spec.Adapter
            Path = $EntryPath
            Supported = Test-ProjAdapterSupported -Adapter $Spec.Adapter
        })
    }

    if ($Existing.Count -gt 1) {
        $Names = @($Existing | ForEach-Object Name) -join ', '
        throw "Command directory '$Directory' contains multiple run entries: $Names. Exactly one run.* is allowed."
    }
    $SelectedEntry = if ($Existing.Count -eq 1 -and $Existing[0].Supported) {
        $Existing[0]
    } else {
        $null
    }

    $ViewMatches = @($FileNames | Where-Object {
        $_.Equals('index.html', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($ViewMatches.Count -gt 1) {
        throw "GUI view name collision in '$Directory': $($ViewMatches -join ', ')"
    }
    $HasView = $ViewMatches.Count -eq 1
    if ($HasView) {
        if (-not $ViewMatches[0].Equals('index.html', [StringComparison]::Ordinal)) {
            throw "Non-canonical GUI view '$($ViewMatches[0])' in '$Directory'; expected 'index.html'."
        }
        $ViewPath = Join-Path $Directory 'index.html'
        $ViewItem = Get-Item -LiteralPath $ViewPath -Force
        if (($ViewItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "GUI view cannot be a reparse point: $ViewPath"
        }
    }

    return [pscustomobject]@{
        Selected = $SelectedEntry
        Unsupported = @($Existing | Where-Object { -not $_.Supported })
        Existing = @($Existing)
        HasView = $HasView
    }
}

function Test-ProjNormalSegment {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Segment
    )

    if ([string]::IsNullOrEmpty($Segment) -or
        $Segment -cnotmatch '^[a-z][a-z0-9-]*$') {
        return $false
    }
    return $Segment -notin @(
        'con', 'prn', 'aux', 'nul',
        'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
        'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9'
    )
}

function Test-ProjKernelRootLiteralSegment {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Segment
    )

    return $Segment -cmatch '^-{1,2}[a-z][a-z0-9-]*$'
}

function Assert-ProjPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $RootPath = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $TargetPath = [IO.Path]::GetFullPath($Path)
    $Comparison = if (Test-ProjWindows) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    if ($TargetPath.Equals($RootPath, $Comparison)) {
        return
    }
    $RootPrefix = $RootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $TargetPath.StartsWith($RootPrefix, $Comparison)) {
        throw "Resolved command path escapes its root: $TargetPath"
    }
}

function Assert-ProjNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PhysicalSegments
    )

    $Current = [IO.Path]::GetFullPath($Root)
    if ([IO.Directory]::Exists($Current)) {
        $RootItem = Get-Item -LiteralPath $Current -Force
        if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Command root cannot be a reparse point: $Current"
        }
    }
    foreach ($Segment in $PhysicalSegments) {
        $Matches = @(Get-ChildItem -LiteralPath $Current -Directory -Force |
            Where-Object {
                $_.Name.Equals($Segment, [StringComparison]::OrdinalIgnoreCase)
            })
        if ($Matches.Count -gt 1) {
            throw "Command directory name collision below '$Current': $Segment"
        }
        if ($Matches.Count -eq 0) {
            return
        }
        $Item = $Matches[0]
        if (-not $Item.Name.Equals($Segment, [StringComparison]::Ordinal)) {
            throw "Non-canonical command directory '$($Item.Name)'; expected '$Segment'."
        }
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Command path cannot contain a reparse point: $($Item.FullName)"
        }
        $Current = $Item.FullName
    }
}

function Resolve-ProjCommandNode {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [AllowEmptyString()][string]$Address
    )

    $Source = 'Kernel'
    $Root = $KernelRoot
    [string[]]$LogicalSegments = @()
    [string[]]$PhysicalSegments = @()

    if (-not [string]::IsNullOrEmpty($Address)) {
        if ($Address.StartsWith('.')) {
            $Body = $Address.Substring(1)
            if ([string]::IsNullOrWhiteSpace($Body)) {
                throw "Invalid kernel command address '$Address'."
            }
            $LogicalSegments = @($Body.Split('.'))
            for ($Index = 0; $Index -lt $LogicalSegments.Count; $Index++) {
                if (-not (Test-ProjNormalSegment -Segment $LogicalSegments[$Index])) {
                    throw "Invalid kernel command segment '$($LogicalSegments[$Index])'."
                }
            }
            $PhysicalSegments = @(".$($LogicalSegments[0])")
            if ($LogicalSegments.Count -gt 1) {
                $PhysicalSegments += $LogicalSegments[1..($LogicalSegments.Count - 1)]
            }
        } elseif ($Address.StartsWith('-')) {
            $LogicalSegments = @($Address.Split('.'))
            if (-not (Test-ProjKernelRootLiteralSegment -Segment $LogicalSegments[0])) {
                throw "Invalid kernel root command segment '$($LogicalSegments[0])'."
            }
            if ($LogicalSegments.Count -gt 1) {
                foreach ($Segment in $LogicalSegments[1..($LogicalSegments.Count - 1)]) {
                    if (-not (Test-ProjNormalSegment -Segment $Segment)) {
                        throw "Invalid kernel root command segment '$Segment'."
                    }
                }
            }
            $PhysicalSegments = $LogicalSegments
        } else {
            $Source = 'Action'
            $Root = $ActionRoot
            $LogicalSegments = @($Address.Split('.'))
            foreach ($Segment in $LogicalSegments) {
                if (-not (Test-ProjNormalSegment -Segment $Segment)) {
                    throw "Invalid Action command segment '$Segment'."
                }
            }
            $PhysicalSegments = $LogicalSegments
        }
    }

    $Directory = [IO.Path]::GetFullPath($Root)
    foreach ($Segment in $PhysicalSegments) {
        $Directory = Join-Path $Directory $Segment
    }
    Assert-ProjPathInsideRoot -Root $Root -Path $Directory
    Assert-ProjNoReparsePoint -Root $Root -PhysicalSegments $PhysicalSegments

    if (-not [IO.Directory]::Exists($Directory)) {
        $DisplayAddress = if ([string]::IsNullOrEmpty($Address)) { '<root>' } else { $Address }
        throw "Command not found: $DisplayAddress"
    }

    $Entry = Get-ProjEntryResolution -Directory $Directory

    return [pscustomobject]@{
        Address = $Address
        Segments = $LogicalSegments
        Source = $Source
        Root = [IO.Path]::GetFullPath($Root)
        Directory = $Directory
        Entry = $Entry.Selected
        Unsupported = $Entry.Unsupported
        HasView = $Entry.HasView
    }
}

function Resolve-ProjCommand {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [AllowEmptyString()][string]$Address
    )

    $Node = Resolve-ProjCommandNode `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address $Address
    if ($null -ne $Node.Entry) {
        return $Node
    }
    if ($Node.Unsupported.Count -gt 0) {
        $Names = @($Node.Unsupported | ForEach-Object Name) -join ', '
        throw "Command '$Address' exists, but this Core does not support its entries: $Names"
    }
    if ($Node.HasView) {
        throw "Command '$Address' is a GUI-only node and has no executable entry."
    }
    throw "Command '$Address' has no recognized executable entry."
}
