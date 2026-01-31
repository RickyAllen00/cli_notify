#requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('on','off','status')]
  [string]$Action = 'status'
)

$flag = Join-Path $PSScriptRoot "notify.disabled"

switch ($Action) {
  'off' {
    New-Item -ItemType File -Path $flag -Force | Out-Null
    Write-Host "Notifications: OFF"
  }
  'on' {
    if (Test-Path $flag) { Remove-Item $flag -Force }
    Write-Host "Notifications: ON"
  }
  'status' {
    if (Test-Path $flag) { Write-Host "Notifications: OFF" } else { Write-Host "Notifications: ON" }
  }
}
