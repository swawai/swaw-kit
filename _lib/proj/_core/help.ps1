Set-StrictMode -Version 2.0

$script:ProjHelpMarkers = @('.help', '.h', '-h', '--help')

function Test-ProjHelpMarker {
    param([AllowEmptyString()][string]$Value)

    return $script:ProjHelpMarkers -ccontains $Value
}

function Get-ProjHelpParentAddress {
    param([Parameter(Mandatory = $true)][object]$Node)

    $Address = [string]$Node.Address
    if ([string]::IsNullOrEmpty($Address)) {
        return $null
    }

    $LastSeparator = $Address.LastIndexOf('.')
    if ($Node.Source -ceq 'Kernel') {
        if ($LastSeparator -le 0) {
            return ''
        }
        return $Address.Substring(0, $LastSeparator)
    }
    if ($LastSeparator -lt 0) {
        return ''
    }
    return $Address.Substring(0, $LastSeparator)
}

function Get-ProjLocalHelp {
    param([Parameter(Mandatory = $true)][string]$CommandDirectory)

    $HelpDirectories = @(Get-ChildItem `
        -LiteralPath $CommandDirectory `
        -Directory `
        -Force | Where-Object {
            $_.Name.Equals('_help', [StringComparison]::OrdinalIgnoreCase)
        })
    if ($HelpDirectories.Count -eq 0) {
        return $null
    }
    if ($HelpDirectories.Count -gt 1) {
        throw "Help directory name collision below '$CommandDirectory'."
    }

    $HelpDirectory = $HelpDirectories[0]
    if ($HelpDirectory.Name -cne '_help') {
        throw "Non-canonical help directory '$($HelpDirectory.Name)'; expected '_help'."
    }
    if (($HelpDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Help directory cannot be a reparse point: $($HelpDirectory.FullName)"
    }

    $HelpFiles = @(Get-ChildItem `
        -LiteralPath $HelpDirectory.FullName `
        -File `
        -Force | Where-Object {
            $_.Name.Equals('zh-CN.txt', [StringComparison]::OrdinalIgnoreCase)
        })
    if ($HelpFiles.Count -eq 0) {
        return $null
    }
    if ($HelpFiles.Count -gt 1) {
        throw "Help file name collision below '$($HelpDirectory.FullName)'."
    }

    $HelpFile = $HelpFiles[0]
    if ($HelpFile.Name -cne 'zh-CN.txt') {
        throw "Non-canonical help file '$($HelpFile.Name)'; expected 'zh-CN.txt'."
    }
    if (($HelpFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Help file cannot be a reparse point: $($HelpFile.FullName)"
    }

    $Utf8 = [Text.UTF8Encoding]::new($false, $true)
    $Text = [IO.File]::ReadAllText($HelpFile.FullName, $Utf8)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "Help file is empty: $($HelpFile.FullName)"
    }
    $Summary = @($Text -split '\r?\n' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1)[0].Trim()

    return [pscustomobject]@{
        Path = $HelpFile.FullName
        Text = $Text
        Summary = $Summary
    }
}

function Find-ProjHelpNode {
    param(
        [Parameter(Mandatory = $true)][object[]]$Discoveries,
        [AllowEmptyString()][string]$TargetAddress
    )

    $Matches = @(if ([string]::IsNullOrEmpty($TargetAddress)) {
        $Discoveries | Where-Object {
            $_.Source -ceq 'Kernel' -and $_.Address -ceq ''
        }
    } else {
        $Discoveries | Where-Object { $_.Address -ceq $TargetAddress }
    })
    if ($Matches.Count -eq 0) {
        return $null
    }
    if ($Matches.Count -gt 1) {
        throw "Ambiguous help target: $TargetAddress"
    }
    return $Matches[0]
}

function Test-ProjUsesLocalHelp {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [AllowEmptyString()][string]$TargetAddress
    )

    $Target = Resolve-ProjCommandNode `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address $TargetAddress
    return $null -ne (
        Get-ProjLocalHelp -CommandDirectory $Target.Directory
    )
}

function Expand-ProjHelpText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowEmptyString()][string]$Address
    )

    $Invocation = if ([string]::IsNullOrEmpty($Address)) {
        $CommandName
    } else {
        "$CommandName $Address"
    }
    return $Text.
        Replace('{{COMMAND}}', $CommandName).
        Replace('{{ADDRESS}}', $Address).
        Replace('{{INVOCATION}}', $Invocation)
}

function Get-ProjHelpSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [Parameter(Mandatory = $true)][string]$CommandName
    )

    try {
        $Document = Get-ProjLocalHelp -CommandDirectory $Node.Directory
    } catch {
        return "[help protocol error] $($_.Exception.Message)"
    }
    if ($null -ne $Document) {
        return Expand-ProjHelpText `
            -Text $Document.Summary `
            -CommandName $CommandName `
            -Address $Node.Address
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Node.Diagnostic)) {
        return "[protocol error] $($Node.Diagnostic)"
    }
    if ($Node.Executable) {
        return '[help handled by command]'
    }
    return '[command group; no Proj help]'
}

function Write-ProjHelpRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Nodes,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowEmptyString()][string]$TargetAddress
    )

    foreach ($Node in @($Nodes | Sort-Object Address)) {
        if (
            [string]::IsNullOrEmpty($TargetAddress) -and
            (Test-ProjHelpMarker -Value $Node.Address) -and
            $Node.Address -cne '.help'
        ) {
            continue
        }

        $DisplayAddress = [string]$Node.Address
        if (
            [string]::IsNullOrEmpty($TargetAddress) -and
            $DisplayAddress -ceq '.help'
        ) {
            $DisplayAddress = '.help (.h, -h, --help)'
        }
        $Invocation = "$CommandName $DisplayAddress"
        $Summary = Get-ProjHelpSummary -Node $Node -CommandName $CommandName
        [Console]::Out.WriteLine(('  {0,-34} {1}' -f $Invocation, $Summary))
    }
}

function Write-ProjHelp {
    param(
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowEmptyString()][string]$TargetAddress = ''
    )

    $Discoveries = @(Get-ProjCommandDiscoveries `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot)
    $Target = Find-ProjHelpNode `
        -Discoveries $Discoveries `
        -TargetAddress $TargetAddress
    if ($null -eq $Target) {
        throw "Help target not found: $TargetAddress"
    }
    $Document = Get-ProjLocalHelp -CommandDirectory $Target.Directory
    if ($null -eq $Document) {
        throw "Proj help is not enabled for '$TargetAddress'."
    }
    $Text = Expand-ProjHelpText `
        -Text $Document.Text `
        -CommandName $CommandName `
        -Address $TargetAddress
    [Console]::Out.WriteLine($Text.TrimEnd())

    $Children = [Collections.Generic.List[object]]::new()
    foreach ($Candidate in $Discoveries) {
        $ParentAddress = Get-ProjHelpParentAddress -Node $Candidate
        if ($null -ne $ParentAddress -and $ParentAddress -ceq $TargetAddress) {
            $Children.Add($Candidate)
        }
    }
    if ($Children.Count -eq 0) {
        return
    }

    [Console]::Out.WriteLine()
    if ([string]::IsNullOrEmpty($TargetAddress)) {
        $KernelChildren = @($Children | Where-Object { $_.Source -ceq 'Kernel' })
        if ($KernelChildren.Count -gt 0) {
            [Console]::Out.WriteLine('Commands:')
            Write-ProjHelpRows `
                -Nodes $KernelChildren `
                -CommandName $CommandName `
                -TargetAddress $TargetAddress
        }
        $ActionChildren = @($Children | Where-Object { $_.Source -ceq 'Action' })
        if ($ActionChildren.Count -gt 0) {
            [Console]::Out.WriteLine()
            [Console]::Out.WriteLine('Project Actions:')
            Write-ProjHelpRows `
                -Nodes $ActionChildren `
                -CommandName $CommandName `
                -TargetAddress $TargetAddress
        }
    } else {
        [Console]::Out.WriteLine('Subcommands:')
        Write-ProjHelpRows `
            -Nodes $Children.ToArray() `
            -CommandName $CommandName `
            -TargetAddress $TargetAddress
    }
}
