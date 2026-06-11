param (
    [string]$name = $(throw "input process name")
)

$procIds = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
if ($procIds) {
    Get-NetTCPConnection | Where-Object { $procIds -contains $_.OwningProcess } | Format-Table LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess -AutoSize
} else {
    Write-Host "Find no：$name"
}
