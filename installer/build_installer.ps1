<#
.SYNOPSIS
    Automated Inno Setup installer generator for modernized WSA-pacman.
.DESCRIPTION
    Compiles the production Windows x64 binaries, embedded Android tools,
    assets, and Visual C++ redistributable into a single setup executable.
.PARAMETER Version
    The application version to embed in the installer (defaults to 1.6.0).
.PARAMETER SourceDir
    The source directory containing release binaries (defaults to ..\build\windows\x64\runner\Release).
.PARAMETER OutputDir
    The output directory where the installer .exe will be saved (defaults to ..\build\installer).
.PARAMETER BuildFlutter
    If specified, runs 'flutter build windows --release' before building the installer.
#>
[CmdletBinding()]
param(
    [string]$Version = "1.6.0",
    [string]$SourceDir = "",
    [string]$OutputDir = "",
    [switch]$BuildFlutter
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$repoDir = Split-Path -Parent $scriptDir

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path $repoDir "build\windows\x64\runner\Release"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoDir "build\installer"
}
$issScript = Join-Path $scriptDir "installer.iss"
$toolsDir = Join-Path $repoDir "embedded-tools"
$redistDir = Join-Path $scriptDir "redist"
$vcRedist = Join-Path $redistDir "VC_redist.x64.exe"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   WSA-pacman Automated Installer Builder (Inno Setup)   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Version:    $Version"
Write-Host "Repository: $repoDir"
Write-Host "Source Dir: $SourceDir"
Write-Host "Output Dir: $OutputDir"
Write-Host ""

# 1. Optionally build Flutter release binaries
if ($BuildFlutter -or -not (Test-Path $SourceDir)) {
    Write-Host "[1/5] Building Flutter Windows release binaries..." -ForegroundColor Yellow
    Push-Location $repoDir
    try {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[1/5] Release binaries found in $SourceDir (skipping flutter build)" -ForegroundColor Green
}

# 2. Verify prerequisites and assets
Write-Host "[2/5] Verifying toolchain and prerequisite files..." -ForegroundColor Yellow

if (-not (Test-Path (Join-Path $SourceDir "WSA-pacman.exe"))) {
    throw "WSA-pacman.exe not found in $SourceDir. Run with -BuildFlutter to build it."
}

if (-not (Test-Path (Join-Path $toolsDir "adb.exe"))) {
    throw "Embedded ADB not found in $toolsDir."
}

if (-not (Test-Path $vcRedist)) {
    throw "Visual C++ Redistributable not found at $vcRedist."
}
Write-Host "      Toolchain assets verified." -ForegroundColor Green

# 3. Locate Inno Setup Compiler (ISCC.exe)
Write-Host "[3/5] Locating Inno Setup Compiler (ISCC.exe)..." -ForegroundColor Yellow
$isccPath = $null

$candidates = @(
    (Get-Command iscc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)

foreach ($c in $candidates) {
    if (![string]::IsNullOrEmpty($c) -and (Test-Path $c)) {
        $isccPath = $c
        break
    }
}

if (-not $isccPath) {
    throw "Inno Setup Compiler (ISCC.exe) was not found. Please install Inno Setup 6 or run 'winget install JRSoftware.InnoSetup'."
}
Write-Host "      Found ISCC: $isccPath" -ForegroundColor Green

# 4. Compile Installer
Write-Host "[4/5] Compiling Inno Setup script..." -ForegroundColor Yellow
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$isccArgs = @(
    "/Qp",
    "/DAppVersion=$Version",
    "/Dreleasedir=$SourceDir",
    "/Dtoolsdir=$toolsDir",
    "/Dinstbuilddir=$OutputDir",
    $issScript
)

& $isccPath $isccArgs
if ($LASTEXITCODE -ne 0) {
    throw "ISCC compilation failed with exit code $LASTEXITCODE"
}

# 5. Output Verification
Write-Host "[5/5] Verifying generated installer..." -ForegroundColor Yellow
$installerFile = Join-Path $OutputDir "WSA-pacman-v$Version-installer.exe"
if (Test-Path $installerFile) {
    $item = Get-Item $installerFile
    $hash = Get-FileHash $installerFile -Algorithm SHA256
    $sizeMb = [math]::Round($item.Length / 1MB, 2)

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "   BUILD SUCCESSFUL! Installer is ready for deployment    " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "File:   $($item.FullName)"
    Write-Host "Size:   $($item.Length) bytes ($sizeMb MB)"
    Write-Host "SHA256: $($hash.Hash)"
    Write-Host ""
} else {
    throw "Installer binary was not found at expected location: $installerFile"
}
