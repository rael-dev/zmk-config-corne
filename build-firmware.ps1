[CmdletBinding()]
param(
    [string]$Board = "nice_nano_v2",
    [string]$ConfigDir = "config",
    [string]$OutputDir = "firmware",
    [string]$SdkDir = "",
    [string]$Pristine = "true",
    [string]$DrawKeymap = "true"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Resolve-RelativePath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Get-PythonCommand {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @("python")
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @("py", "-3")
    }

    throw "Python was not found. Install Python 3.11+ and retry."
}

function Invoke-West {
    param(
        [string[]]$PythonCmd,
        [string[]]$WestArgs
    )

    if ($PythonCmd.Length -gt 1) {
        & $PythonCmd[0] $PythonCmd[1..($PythonCmd.Length - 1)] -m west @WestArgs
    } else {
        & $PythonCmd[0] -m west @WestArgs
    }
    if ($LASTEXITCODE -ne 0) {
        throw "west command failed: $($WestArgs -join ' ')"
    }
}

function Resolve-SdkPath {
    param([string]$RequestedSdk)

    if ($RequestedSdk) {
        $sdkPath = Resolve-RelativePath $RequestedSdk
        if (-not (Test-Path $sdkPath)) {
            throw "Requested SDK path not found: $sdkPath"
        }

        return (Resolve-Path $sdkPath).Path
    }

    $preferred = Join-Path $repoRoot ".tooling/zephyr-sdk-0.16.8"
    if (Test-Path $preferred) {
        return (Resolve-Path $preferred).Path
    }

    $toolingDir = Join-Path $repoRoot ".tooling"
    if (-not (Test-Path $toolingDir)) {
        throw "No SDK found. Expected $preferred or another zephyr-sdk-* directory in .tooling/."
    }

    $candidates = Get-ChildItem -Path $toolingDir -Directory -Filter "zephyr-sdk-*" | Sort-Object Name -Descending
    if (-not $candidates) {
        throw "No SDK found. Expected a zephyr-sdk-* directory in .tooling/."
    }

    return $candidates[0].FullName
}

function ConvertTo-Bool {
    param([string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    switch -Regex ($normalized) {
        '^(1|true|t|yes|y|on)$' { return $true }
        '^(0|false|f|no|n|off)$' { return $false }
        default { throw "Invalid value for -Pristine: '$Value'. Use true/false or 1/0." }
    }
}

function Get-KeymapDrawerCommand {
    $cmd = Get-Command keymap -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Invoke-KeymapDrawer {
    param(
        [string[]]$PythonCmd,
        [string]$DrawerConfig,
        [string[]]$DrawerArgs,
        [string]$OutputPath
    )

    $keymapCmd = Get-KeymapDrawerCommand

    if ($keymapCmd) {
        & $keymapCmd -c $DrawerConfig @DrawerArgs | Out-File -FilePath $OutputPath -Encoding utf8
    } elseif ($PythonCmd.Length -gt 1) {
        & $PythonCmd[0] $PythonCmd[1..($PythonCmd.Length - 1)] -m keymap_drawer -c $DrawerConfig @DrawerArgs | Out-File -FilePath $OutputPath -Encoding utf8
    } else {
        & $PythonCmd[0] -m keymap_drawer -c $DrawerConfig @DrawerArgs | Out-File -FilePath $OutputPath -Encoding utf8
    }

    if ($LASTEXITCODE -ne 0) {
        throw "keymap-drawer command failed: $($DrawerArgs -join ' ')"
    }
}

$pythonCmd = Get-PythonCommand
$configPath = Resolve-RelativePath $ConfigDir
$outputPath = Resolve-RelativePath $OutputDir
$sdkPath = Resolve-SdkPath $SdkDir
$configPathCMake = $configPath -replace "\\", "/"
$runDraw = ConvertTo-Bool $DrawKeymap

if (-not (Test-Path $configPath)) {
    throw "Config directory not found: $configPath"
}

if (-not (Test-Path (Join-Path $repoRoot ".west"))) {
    throw "Missing .west directory. Run 'python -m west init -l config' first."
}

if (-not (Test-Path (Join-Path $repoRoot "zmk/app"))) {
    throw "Missing zmk sources. Run 'python -m west update' first."
}

$env:ZEPHYR_TOOLCHAIN_VARIANT = "zephyr"
$env:ZEPHYR_SDK_INSTALL_DIR = $sdkPath

if (-not (Test-Path $outputPath)) {
    New-Item -Path $outputPath -ItemType Directory | Out-Null
}

$builds = @(
    @{
        Name = "left"
        BuildDir = "build/left"
        Shield = "corne_left nice_view_adapter nice_view_mix"
        Output = "left.uf2"
    },
    @{
        Name = "right"
        BuildDir = "build/right"
        Shield = "corne_right nice_view_adapter nice_view_mix"
        Output = "right.uf2"
    },
    @{
        Name = "reset"
        BuildDir = "build/settings_reset"
        Shield = "settings_reset"
        Output = "reset.uf2"
    }
)

$usePristine = ConvertTo-Bool $Pristine
$pristineMode = if ($usePristine) { "always" } else { "auto" }

Write-Host "Using SDK: $sdkPath"
Write-Host "Using config: $configPath"
Write-Host "Output folder: $outputPath"

foreach ($build in $builds) {
    Write-Host ""
    Write-Host "Building $($build.Name)..."

    $westArgs = @(
        "build",
        "-p", $pristineMode,
        "-d", $build.BuildDir,
        "-s", "zmk/app",
        "-b", $Board,
        "--",
        "-DSHIELD=$($build.Shield)",
        "-DZMK_CONFIG=$configPathCMake"
    )

    Invoke-West -PythonCmd $pythonCmd -WestArgs $westArgs

    $sourceUf2 = Join-Path $repoRoot "$($build.BuildDir)/zephyr/zmk.uf2"
    if (-not (Test-Path $sourceUf2)) {
        throw "Expected artifact missing: $sourceUf2"
    }

    $targetUf2 = Join-Path $outputPath $build.Output
    Copy-Item -Path $sourceUf2 -Destination $targetUf2 -Force

    $artifact = Get-Item $targetUf2
    Write-Host "Copied: $($artifact.FullName) ($($artifact.Length) bytes)"
}

if ($runDraw) {
    $drawDir = Join-Path $repoRoot "draw"
    $drawerConfig = Join-Path $repoRoot "keymap_drawer.config.yaml"
    $sourceKeymap = Join-Path $configPath "corne.keymap"
    $drawYaml = Join-Path $drawDir "corne.yaml"
    $drawSvg = Join-Path $drawDir "corne.svg"
    if (-not (Test-Path $sourceKeymap)) {
        throw "Expected keymap file not found: $sourceKeymap"
    }
    if (-not (Test-Path $drawerConfig)) {
        throw "Expected keymap drawer config not found: $drawerConfig"
    }
    if (-not (Test-Path $drawDir)) {
        New-Item -Path $drawDir -ItemType Directory | Out-Null
    }

    Write-Host ""
    Write-Host "Updating keymap drawing..."

    Invoke-KeymapDrawer -PythonCmd $pythonCmd -DrawerConfig $drawerConfig -DrawerArgs @("parse", "-z", $sourceKeymap) -OutputPath $drawYaml
    Invoke-KeymapDrawer -PythonCmd $pythonCmd -DrawerConfig $drawerConfig -DrawerArgs @("draw", $drawYaml) -OutputPath $drawSvg

    Write-Host "Updated: $drawYaml"
    Write-Host "Updated: $drawSvg"
}

Write-Host ""
Write-Host "Done. Firmware artifacts are in: $outputPath"
