param(
    [string]$repoOwner,
    [string]$repoName
)

Write-Host "Starting Hyper-V bootstrap..."

# Run install-hyper-v.ps1
Write-Host "Installing Hyper-V..."
.\install-hyper-v.ps1

if ($LASTEXITCODE -ne 0) {
    Write-Error "install-hyper-v.ps1 failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Run create-guest-vms.ps1 with parameters
Write-Host "Creating guest VMs..."
.\create-guest-vms.ps1 -repoOwner $repoOwner -repoName $repoName

if ($LASTEXITCODE -ne 0) {
    Write-Error "create-guest-vms.ps1 failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "Bootstrap completed successfully."
exit 0
