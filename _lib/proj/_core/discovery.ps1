Set-StrictMode -Version 2.0

function ConvertTo-ProjKernelChildAddress {
    param(
        [AllowEmptyString()][string]$ParentAddress,
        [Parameter(Mandatory = $true)][string]$DirectoryName,
        [Parameter(Mandatory = $true)][bool]$IsRootChild
    )

    if ($DirectoryName.StartsWith('_')) {
        return $null
    }
    if ($IsRootChild) {
        if ($DirectoryName.StartsWith('.')) {
            $Segment = $DirectoryName.Substring(1)
            if (-not (Test-ProjNormalSegment -Segment $Segment)) {
                return $null
            }
            return $DirectoryName
        }
        if ($DirectoryName.StartsWith('-') -and
            (Test-ProjKernelRootLiteralSegment -Segment $DirectoryName)) {
            return $DirectoryName
        }
        return $null
    }
    if (-not (Test-ProjNormalSegment -Segment $DirectoryName)) {
        return $null
    }
    return "$ParentAddress.$DirectoryName"
}

function ConvertTo-ProjActionChildAddress {
    param(
        [AllowEmptyString()][string]$ParentAddress,
        [Parameter(Mandatory = $true)][string]$DirectoryName
    )

    if ($DirectoryName.StartsWith('_') -or
        -not (Test-ProjNormalSegment -Segment $DirectoryName)) {
        return $null
    }
    if ([string]::IsNullOrEmpty($ParentAddress)) {
        return $DirectoryName
    }
    return "$ParentAddress.$DirectoryName"
}

function Get-ProjCommandDiscoveries {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [AllowNull()][string]$ActionRoot
    )

    $RootPath = [IO.Path]::GetFullPath($KernelRoot)
    Assert-ProjNoReparsePoint -Root $RootPath -PhysicalSegments @()
    $Queue = [Collections.Generic.Queue[object]]::new()
    $Queue.Enqueue([pscustomobject]@{
        Directory = $RootPath
        Address = ''
        Source = 'Kernel'
        IsRoot = $true
    })
    if (-not [string]::IsNullOrWhiteSpace($ActionRoot) -and
        [IO.Directory]::Exists($ActionRoot)) {
        Assert-ProjNoReparsePoint -Root $ActionRoot -PhysicalSegments @()
        $Queue.Enqueue([pscustomobject]@{
            Directory = [IO.Path]::GetFullPath($ActionRoot)
            Address = ''
            Source = 'Action'
            IsRoot = $true
        })
    }
    $Results = [Collections.Generic.List[object]]::new()

    while ($Queue.Count -gt 0) {
        $Current = $Queue.Dequeue()
        try {
            $Entry = Get-ProjEntryResolution -Directory $Current.Directory
            if ($Current.Source -eq 'Kernel' -or -not $Current.IsRoot) {
                $Results.Add([pscustomobject]@{
                    Address = $Current.Address
                    Source = $Current.Source
                    Directory = $Current.Directory
                    Executable = $null -ne $Entry.Selected
                    Entry = if ($null -ne $Entry.Selected) { $Entry.Selected.Name } else { $null }
                    Adapter = if ($null -ne $Entry.Selected) { $Entry.Selected.Adapter } else { $null }
                    Unsupported = @($Entry.Unsupported | ForEach-Object Name)
                    Diagnostic = $null
                })
            }
        } catch {
            if ($Current.Source -eq 'Kernel' -or -not $Current.IsRoot) {
                $Results.Add([pscustomobject]@{
                    Address = $Current.Address
                    Source = $Current.Source
                    Directory = $Current.Directory
                    Executable = $false
                    Entry = $null
                    Adapter = $null
                    Unsupported = @()
                    Diagnostic = $_.Exception.Message
                })
            }
        }

        $Children = @(Get-ChildItem -LiteralPath $Current.Directory -Directory -Force |
            Sort-Object Name)
        foreach ($Child in $Children) {
            if (($Child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            $ChildAddress = if ($Current.Source -eq 'Kernel') {
                ConvertTo-ProjKernelChildAddress `
                    -ParentAddress $Current.Address `
                    -DirectoryName $Child.Name `
                    -IsRootChild $Current.IsRoot
            } else {
                ConvertTo-ProjActionChildAddress `
                    -ParentAddress $Current.Address `
                    -DirectoryName $Child.Name
            }
            if ($null -eq $ChildAddress) {
                continue
            }
            $Queue.Enqueue([pscustomobject]@{
                Directory = $Child.FullName
                Address = $ChildAddress
                Source = $Current.Source
                IsRoot = $false
            })
        }
    }

    return @($Results | Sort-Object Source, Address)
}
