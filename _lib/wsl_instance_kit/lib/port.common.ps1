function Get-WslPortRulePrefix {
    $safeName = ($script:Config.Name -replace '[^A-Za-z0-9_.-]', '_')
    return "wsl_instance_kit-$safeName-port"
}


function Get-WslPortListenAddress {
    return "0.0.0.0"
}


function Get-WslPortRuleName {
    param(
        [string]$Protocol,
        [int]$ListenPort,
        [string]$ListenAddress = (Get-WslPortListenAddress)
    )

    $safeAddress = ($ListenAddress -replace '[^A-Za-z0-9_.-]', '_')
    return "$(Get-WslPortRulePrefix)-$($Protocol.ToLowerInvariant())-$safeAddress-$ListenPort"
}


function Resolve-WslPortNumber {
    param(
        [AllowNull()] [string]$Value,
        [string]$Label
    )

    $port = 0
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [int]::TryParse($Value.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Fail "$Label must be an integer from 1 to 65535."
        return $null
    }

    return $port
}


function ConvertTo-WslPortOptionMap {
    param([string[]]$Rest)

    $positionals = New-Object System.Collections.ArrayList
    $listenAddress = Get-WslPortListenAddress
    $protocol = "tcp"
    $dryRun = $false

    for ($i = 0; $i -lt $Rest.Count; $i++) {
        $item = $Rest[$i]
        switch -Regex ($item) {
            '^--dry-run$' {
                $dryRun = $true
                continue
            }
            '^--listen-address$' {
                Write-Fail "--listen-address is not supported. ctl port always exposes ${listenAddress}:<listen-port>."
                return $null
            }
            '^--protocol$' {
                if ($i + 1 -ge $Rest.Count) {
                    Write-Fail "--protocol requires a value."
                    return $null
                }
                $i += 1
                $protocol = $Rest[$i].Trim().ToLowerInvariant()
                continue
            }
            '^--' {
                Write-Fail "Unknown ctl port option: $item"
                return $null
            }
            default {
                [void]$positionals.Add($item)
            }
        }
    }

    if ($protocol -ne "tcp") {
        Write-Fail "ctl port currently supports only TCP."
        return $null
    }

    return [pscustomobject]@{
        Positionals   = @($positionals)
        ListenAddress = $listenAddress
        Protocol      = $protocol
        DryRun        = $dryRun
    }
}


function Remove-WslConfigInlineComment {
    param([string]$Value)

    return (($Value -replace '\s*[#;].*$', '').Trim())
}


function Get-WslConfiguredNetworkingMode {
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Mode = "nat"
            Source = "default"
            Path = $path
        }
    }

    $inWsl2 = $false
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $inWsl2 = ($Matches[1].Trim() -ieq "wsl2")
            continue
        }

        if ($inWsl2 -and $trimmed -match '^(?i)networkingMode\s*=\s*(.+?)\s*$') {
            $mode = (Remove-WslConfigInlineComment $Matches[1]).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($mode)) {
                $mode = "nat"
            }

            return [pscustomobject]@{
                Mode = $mode
                Source = "configured"
                Path = $path
            }
        }
    }

    return [pscustomobject]@{
        Mode = "nat"
        Source = "default"
        Path = $path
    }
}


function Test-WslKitAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }

    Write-Fail "This ctl port action requires an elevated shell."
    Write-Fail "Run the command again as Administrator."
    return $false
}


function Get-WslPortTargetIpAddress {
    $scriptText = @'
if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n 1
    exit 0
fi
if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null |
        while IFS= read -r line || [ -n "$line" ]; do
            set -- $line
            addr="$4"
            printf '%s\n' "${addr%%/*}"
        done |
        head -n 1
fi
'@

    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    try {
        $output = & wsl.exe @nativeArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $output) {
            $ip = (($output | ForEach-Object { ($_ -replace "`0", "").Trim() }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($ip)) {
                return [string]$ip
            }
        }
    } catch {
    }

    return ""
}

