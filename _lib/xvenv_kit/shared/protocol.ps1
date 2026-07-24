Set-StrictMode -Version 2.0

function ConvertTo-XvenvArgumentPayload {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $Parts = [Collections.Generic.List[string]]::new()
    [void]$Parts.Add('xvenv.args.v1')
    [void]$Parts.Add($Arguments.Count.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    ))
    foreach ($Argument in $Arguments) {
        [void]$Parts.Add([Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes([string]$Argument)
        ))
    }
    return [string]::Join(';', $Parts.ToArray())
}

function ConvertFrom-XvenvArgumentPayload {
    param([Parameter(Mandatory = $true)][string]$Payload)

    $Parts = [string[]]$Payload.Split(
        [char[]]@(';'),
        [StringSplitOptions]::None
    )
    [int]$ArgumentCount = 0
    if ($Parts.Count -lt 2 -or
        $Parts[0] -cne 'xvenv.args.v1' -or
        -not [int]::TryParse($Parts[1], [ref]$ArgumentCount) -or
        $ArgumentCount -lt 0 -or
        $Parts.Count -ne $ArgumentCount + 2) {
        throw 'The internal xvenv argument payload is invalid.'
    }

    $Arguments = [Collections.Generic.List[string]]::new()
    for ($Index = 0; $Index -lt $ArgumentCount; $Index++) {
        try {
            $Value = [Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($Parts[$Index + 2])
            )
        } catch {
            throw 'The internal xvenv argument payload is invalid.'
        }
        [void]$Arguments.Add($Value)
    }
    return $Arguments.ToArray()
}

function Write-XvenvJsonOutput {
    param([Parameter(Mandatory = $true)][object]$Value)

    $Json = $Value | ConvertTo-Json -Depth 10 -Compress
    # Do not put protocol output on the PowerShell success pipeline. The entry
    # point reserves that pipeline for the command's integer exit code.
    [Console]::Out.WriteLine([string]$Json)
}
