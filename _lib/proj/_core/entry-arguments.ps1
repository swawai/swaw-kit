Set-StrictMode -Version 2.0

function Get-ProjEntryArguments {
    param(
        [AllowEmptyCollection()]
        [string[]]$DirectArguments = @()
    )

    $ProtocolName = 'SWAWKIT_PROJ_ARGV_PROTOCOL'
    $CountName = 'SWAWKIT_PROJ_ARGV_COUNT'
    $Protocol = [Environment]::GetEnvironmentVariable($ProtocolName, 'Process')
    if ($null -eq $Protocol) {
        return [string[]]@($DirectArguments)
    }
    if ($Protocol -cne '1') {
        throw "Unsupported project argv relay protocol '$Protocol'."
    }

    $CountText = [Environment]::GetEnvironmentVariable($CountName, 'Process')
    [int]$Count = 0
    if (
        -not [int]::TryParse(
            $CountText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$Count
        ) -or
        $Count -lt 0
    ) {
        throw "Invalid project argv relay count '$CountText'."
    }

    $Result = [Collections.Generic.List[string]]::new($Count)
    try {
        for ($Index = 1; $Index -le $Count; $Index++) {
            $Name = "SWAWKIT_PROJ_ARGV_$Index"
            $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
            if ($null -eq $Value) {
                $Value = ''
            }
            $Result.Add($Value)
        }
        return [string[]]$Result.ToArray()
    } finally {
        [Environment]::SetEnvironmentVariable($ProtocolName, $null, 'Process')
        [Environment]::SetEnvironmentVariable($CountName, $null, 'Process')
        for ($Index = 1; $Index -le $Count; $Index++) {
            [Environment]::SetEnvironmentVariable(
                "SWAWKIT_PROJ_ARGV_$Index",
                $null,
                'Process'
            )
        }
    }
}
