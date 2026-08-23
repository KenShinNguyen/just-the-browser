#Requires -RunAsAdministrator
#Requires -Version 4.0

# GitHub requires TLS v1.2, but it's not enabled by default in PowerShell v5.0 and older releases
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

# Allow alternate base URL as first command-line argument, for testing and development
if ($args.Count -eq 0) {
    $BaseURL = "https://raw.githubusercontent.com/KenShinNguyen/just-the-browser/main"
} else {
    $BaseURL = $args[0]
}

$OS = Get-CimInstance Win32_OperatingSystem
$MicrosoftEdgeInstallRegistry = "$BaseURL/edge/install.reg"
$MicrosoftEdgeUninstallRegistry = "$BaseURL/edge/uninstall.reg"
$GoogleChromeInstallRegistry = "$BaseURL/chrome/install.reg"
$GoogleChromeUninstallRegistry = "$BaseURL/chrome/uninstall.reg"
$FirefoxInstallRegistry = "$BaseURL/firefox/install.reg"
$FirefoxUninstallRegistry = "$BaseURL/firefox/uninstall.reg"
$BraveInstallRegistry = "$BaseURL/brave/install.reg"
$BraveUninstallRegistry = "$BaseURL/brave/uninstall.reg"

# Render initial interface for all pages
function Show-Header {
    Clear-Host
    Write-Host "`nJust the Browser ($($OS.Caption) Build $($OS.BuildNumber))`n========`n"
}

# Download a registry file and import it with reg.exe
# The downloaded file is always deleted again, so temporary files are not left behind
function Import-RemoteRegistryFile {
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [String]$Uri,
        [Parameter(Position = 1, Mandatory = $true)]
        [String]$FileName,
        [Parameter(Position = 2, Mandatory = $true)]
        [String]$SuccessMessage
    )
    $LocalPath = Join-Path $env:LocalAppData $FileName
    Write-Host "Downloading registry file, please wait..."
    try {
        # Download file
        # -UseBasicParsing is required on systems where Internet Explorer has never been configured
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $LocalPath -UseBasicParsing
        }
        catch {
            Read-Host -Prompt "Download failed! Press Enter/Return to continue" | Out-Null
            return
        }
        # Import file
        $Import = Start-Process "reg.exe" -ArgumentList "import `"$LocalPath`"" -WindowStyle Hidden -Wait -PassThru
        if ($Import.ExitCode -eq 0) {
            Read-Host -Prompt "$SuccessMessage Press Enter/Return to continue" | Out-Null
        }
        else {
            Read-Host -Prompt "Registry import failed with exit code $($Import.ExitCode)! Press Enter/Return to continue" | Out-Null
        }
    }
    finally {
        Remove-Item -Path $LocalPath -Force -ErrorAction SilentlyContinue
    }
}

# Remove Firefox JSON file if it exists, so it does not conflict with registry entries
# Previous versions of Just the Browser used the JSON method
function Uninstall-FirefoxJSON {
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [String]$InstallPath
    )
    if (Test-Path "$InstallPath\distribution\policies.json") {
        Write-Host "Previous Firefox policies.json file found, deleting..."
        Remove-Item -Path "$InstallPath\distribution\policies.json" -Force
    }
}

# Install Google Chrome settings
function Install-Chrome {
    Show-Header
    Import-RemoteRegistryFile $GoogleChromeInstallRegistry "chrome.reg" "Updated Google Chrome settings."
}

# Remove Google Chrome settings
function Uninstall-Chrome {
    Show-Header
    Import-RemoteRegistryFile $GoogleChromeUninstallRegistry "chrome.reg" "Removed Google Chrome settings."
}

# Install Microsoft Edge settings
function Install-Edge {
    Show-Header
    Import-RemoteRegistryFile $MicrosoftEdgeInstallRegistry "edge.reg" "Updated Microsoft Edge settings."
}

# Remove Microsoft Edge settings
function Uninstall-Edge {
    Show-Header
    Import-RemoteRegistryFile $MicrosoftEdgeUninstallRegistry "edge.reg" "Removed Microsoft Edge settings."
}

# Install Brave settings
function Install-Brave {
    Show-Header
    Import-RemoteRegistryFile $BraveInstallRegistry "brave.reg" "Updated Brave settings."
}

# Remove Brave settings
function Uninstall-Brave {
    Show-Header
    Import-RemoteRegistryFile $BraveUninstallRegistry "brave.reg" "Removed Brave settings."
}

# Install Firefox settings
function Install-Firefox {
    Param(
        [Parameter(Position = 0)]
        [String]$InstallPath
    )
    Show-Header
    # Delete old JSON configuration if the Firefox registry path was found, and if the JSON file exists
    if ($InstallPath) {
        Uninstall-FirefoxJSON "$InstallPath"
    }
    Import-RemoteRegistryFile $FirefoxInstallRegistry "firefox.reg" "Updated Mozilla Firefox settings."
}

# Remove Firefox settings
function Uninstall-Firefox {
    Param(
        [Parameter(Position = 0)]
        [String]$InstallPath
    )
    Show-Header
    # Delete old JSON configuration if the Firefox registry path was found, and if the JSON file exists
    if ($InstallPath) {
        Uninstall-FirefoxJSON "$InstallPath"
    }
    Import-RemoteRegistryFile $FirefoxUninstallRegistry "firefox.reg" "Removed Mozilla Firefox settings."
}


# Main menu selection
function Show-Menu {
    # The menu is rebuilt on every pass, so the "Remove settings" options appear
    # or disappear as soon as a configuration is installed or removed
    while ($true) {
        # Create list for menu options
        $options = New-Object System.Collections.Generic.List[psobject]
        # Google Chrome without settings applied
        $options.Add(@{
                Label  = "Google Chrome: Update settings"
                Action = { Install-Chrome }
            })
        # Google Chrome with settings applied
        if (Test-Path "HKLM:\SOFTWARE\Policies\Google\Chrome") {
            $GoogleChromeCheck = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -ErrorAction SilentlyContinue).AIModeSettings
            if ($null -ne $GoogleChromeCheck) {
                $options.Add(@{
                        Label  = "Google Chrome: Remove settings"
                        Action = { Uninstall-Chrome }
                    })
            }
        }
        # Microsoft Edge without settings applied
        $options.Add(@{
                Label  = "Microsoft Edge: Update settings"
                Action = { Install-Edge }
            })
        # Microsoft Edge with settings applied
        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge") {
            $MicrosoftEdgeCheck = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -ErrorAction SilentlyContinue).HideFirstRunExperience
            if ($null -ne $MicrosoftEdgeCheck) {
                $options.Add(@{
                        Label  = "Microsoft Edge: Remove settings"
                        Action = { Uninstall-Edge }
                    })
            }
        }
        # Brave without settings applied
        $options.Add(@{
                Label  = "Brave: Update settings"
                Action = { Install-Brave }
            })
        # Brave with settings applied
        if (Test-Path "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave") {
            $BraveCheck = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" -ErrorAction SilentlyContinue).BraveAIChatEnabled
            if ($null -ne $BraveCheck) {
                $options.Add(@{
                        Label  = "Brave: Remove settings"
                        Action = { Uninstall-Brave }
                    })
            }
        }
        # Mozilla Firefox
        if (Test-Path "HKLM:\SOFTWARE\Mozilla\Mozilla Firefox") {
            # Find the current version installed, like: 147.0.1 (AArch64 en-US)
            $FirefoxVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\Mozilla Firefox" -ErrorAction SilentlyContinue).CurrentVersion
            # Find the registry values for the specified version
            if (Test-Path "HKLM:\SOFTWARE\Mozilla\Mozilla Firefox\$FirefoxVersion\Main") {
                # Finds the installation path, like: C:\Program Files\Mozilla Firefox
                $FirefoxPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\Mozilla Firefox\$FirefoxVersion\Main" -ErrorAction SilentlyContinue)."Install Directory"
                # Firefox without settings alreay applied
                $options.Add(@{
                        Label  = "Mozilla Firefox: Update settings"
                        Action = { Install-Firefox "$FirefoxPath" }
                    })
                # Firefox with settings already applied
                # This script previously used the JSON file for Firefox, so that must be checked in addition to the registry method
                if ((Test-Path "$FirefoxPath\distribution\policies.json") -or (Test-Path "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxHome")) {
                    $options.Add(@{
                            Label  = "Mozilla Firefox: Remove settings"
                            Action = { Uninstall-Firefox "$FirefoxPath" }
                        })
                }
            }
            else {
                $options.Add(@{
                        Label  = "Mozilla Firefox: Update settings"
                        Action = { Install-Firefox }
                    })
                if (Test-Path "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxHome") {
                    $options.Add(@{
                            Label  = "Mozilla Firefox: Remove settings"
                            Action = { Uninstall-Firefox }
                        })
                }
            }
        }
        # Exit option
        $options.Add(@{
                Label = "Exit"; Action = { exit }
            })
        # Show main menu
        Show-Header
        Write-Host "Select an option by typing the number, then pressing Return/Enter on your keyboard to confirm.`n`nYou will need to restart your browser for changes to take effect.`n"
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host "[$($i + 1)] $($options[$i].Label)"
        }
        $selection = Read-Host "`n#"
        # Process menu selections
        # The input has to be compared as a number, otherwise PowerShell compares it as
        # text, and a negative index would silently select the last option in the list
        if ($selection -match '^\d+$') {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $options.Count) {
                & $options[$index].Action
            }
        }
    }
}

Show-Menu
