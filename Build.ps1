# Build.ps1
# Run this whenever you update Lively-WallpaperManager.ps1 to recompile the .exe

$input  = "E:\Livecycle\Livecycle.ps1"
$output = "E:\Livecycle\Livecycle.exe"

Write-Host "Compiling $input..."

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe..."
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}

Invoke-PS2EXE -InputFile $input -OutputFile $output -NoConsole `
    -Title "Livecycle" -Version "1.0.0.0"

Write-Host "Done! Compiled to $output"
pause
