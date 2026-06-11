param(
    [Parameter(Mandatory = $true, HelpMessage = "Please specify a local port pattern, e.g. '80*' or '443'")]
    [string]$Pattern
)

# Load TCP and UDP endpoints
$tcpConns = Get-NetTCPConnection -ErrorAction SilentlyContinue
$udpConns = Get-NetUDPEndpoint  -ErrorAction SilentlyContinue

# Combine and filter by string‑matching the LocalPort
$matches = ($tcpConns + $udpConns) |
    Where-Object { $_.LocalPort.ToString() -like $Pattern }

if ($matches) {
    # Deduplicate by port + process
    $unique = $matches |
        Select-Object LocalPort, OwningProcess -Unique |
        Sort-Object LocalPort

    $unique | ForEach-Object {
        $processId   = $_.OwningProcess
        $portNumber  = $_.LocalPort
        try {
            $proc = Get-Process -Id $processId -ErrorAction Stop
            $name = $proc.ProcessName
        }
        catch {
            $name = "<Unknown>"
        }

        [PSCustomObject]@{
            Port        = $portNumber
            PID         = $processId
            ProcessName = $name
        }
    }
}
else {
    Write-Host "No listeners found for ports matching pattern '$Pattern'." -ForegroundColor Yellow
}
