
Function Invoke-RefreshHost {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Refresh-Host")]
    Param(
        [Parameter(Position = 0)]
        [ValidateNotNullorEmpty()]
        [ValidateScript({Test-Path $_})]
        [string]$Destination = (Get-LabHostDefault).configurationpath
    )

    #test if a new version of lability is required
    if ($pscmdlet.ShouldProcess("version $LabilityVersion","Check for Lability Requirements")) {
        _LabilityCheck -requiredVersion $LabilityVersion
    }

    # Setup Path Variables
    $SourcePath = $ConfigurationPath

    Write-Host "Updating configuration files from $sourcePath" -ForegroundColor Cyan
    if ($pscmdlet.ShouldProcess($Destination, "Copy configurations")) {
        if (Test-Path $Destination) {
            Copy-Item -Path $SourcePath\* -recurse -Destination $Destination -force
        }
        else {
            Write-Warning "Can't find target path $Destination."
        }
    }

    Write-host "This process will not remove any configurations that have been deleted from the module." -ForegroundColor yellow
}

Function Invoke-SetupHost {
    [CmdletBinding(SupportsShouldProcess)]
    [alias("Setup-Host")]
    Param(
        [Parameter(HelpMessage = "Specify the parent path. The default is C:\Autolab. The command will create the folder.")]
        [string]$DestinationPath = "C:\Autolab"
    )

    # Setup Path Variables
    #use module defined variable
    $SourcePath = $ConfigurationPath

    Clear-Host

    Write-Host -ForegroundColor Green -Object @"

    This is the Setup-Host script. This script will perform the following:

    * For PowerShell Remoting, configure the host 'TrustedHosts' value to *
    * Install the Lability module from PSGallery
    * Install Hyper-V
    * Create the $DestinationPath folder (DO NOT DELETE)
    * Copy configurations and resources to $DestinationPath
    * You will then need to reboot the host before continuing

"@

    Write-Host -ForegroundColor Yellow -Object @"

    !!IMPORTANT SECURITY NOTE!!

    This module will set trusted hosts to connect to any machine on the local network. This is NOT a recommended
    security practice. It is assumed you are installing this module on a non-production machine
    and are willing to accept this potential risk for the sake of a training and test environment.

    If you do not want to proceed, press Ctrl-C.
"@

    Pause

    # For remoting commands to VM's - have the host set trustedhosts
    Enable-PSRemoting -force -SkipNetworkProfileCheck

    Write-Host -ForegroundColor Cyan -Object "Setting TrustedHosts so that remoting commands to VMs work properly"
    $trust = Get-Item -Path WSMan:\localhost\Client\TrustedHosts
    if (($Trust.Value -eq "*") -or ($trust.Value -match "<local>")) {
        Write-Host -ForegroundColor Green -Object "TrustedHosts is already set to *. No changes needed"
    }
    else {
        $add = '<local>' # Jeffs idea - 'DC,S*,Client*,192.168.3.' - need to automate this, not hard code
        Write-Host -ForegroundColor Cyan -Object "Adding $add to TrustedHosts"
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $add -Concatenate -force
    }

    # Lability install

    Get-PackageSource -Name PSGallery | Set-PackageSource -Trusted -Force -ForceBootstrap | Out-Null

    <#
 Test if the current version of Lability is already installed. If so, do nothing.
 If an older version is installed, update the version, otherwise install the latest version.
#>

    #use the module defined variable and a private function
    _LabilityCheck $LabilityVersion
    Import-Module Lability

    # Set Lability folder structure
    $DirDef = @{
        ConfigurationPath   = "$DestinationPath\Configurations"
        DifferencingVhdPath = "$DestinationPath\VMVirtualHardDisks"
        HotfixPath          = "$DestinationPath\Hotfixes"
        IsoPath             = "$DestinationPath\ISOs"
        ModuleCachePath     = "C:\ProgramData\Lability\Modules"
        ParentVhdPath       = "$DestinationPath\MasterVirtualHardDisks"
        ResourcePath        = "$DestinationPath\Resources"
    }

    Set-LabHostDefault @DirDef

    $HostStatus = Test-LabHostConfiguration
    If (-Not $HostStatus ) {
        Write-Host -ForegroundColor Cyan "Starting to Initialize host and install Hyper-V"
        if ($pscmdlet.shouldprocess($DirDef.ConfigurationPath)) {
            Start-LabHostConfiguration -ErrorAction SilentlyContinue
        }
    }

    ###### COPY Configs to host machine
    Write-Host -ForegroundColor Cyan -Object "Copying configs to $($DirDef.ConfigurationPath)"
    if ($pscmdlet.ShouldProcess($DirDef.ConfigurationPath, "Copy configurations")) {
        Copy-item -Path $SourcePath\* -recurse -Destination $DirDef.ConfigurationPath -force
    }

    if ($pscmdlet.ShouldProcess($env:computername, "Prompt for restart")) {

        Write-Host -ForegroundColor Green -Object @"

        The localhost is about to reboot.
        After the reboot, open a Windows PowerShell prompt, navigate to a configuration directory
        $($DirDef.ConfigurationPath)\<yourconfigfolder>
        And run:

        PS $($DirDef.ConfigurationPath)\<yourconfigfolder>Setup-Lab -ignorependingreboot
        or
        PS $($DirDef.ConfigurationPath)\<yourconfigfolder>Unattend-Lab -ignorependingreboot

"@

        Write-Warning "System needs to reboot, especially if you just installed Hyper-V."
        $reboot = Read-Host "Do you wish to reboot now? (y/n)"
        If ($reboot -eq 'y') {
            Write-Output "Rebooting now"
            Restart-Computer
        }
    } #whatif

}

#region Setup-Lab
Function Invoke-SetupLab {
    [cmdletbinding(SupportsShouldProcess)]
    [Alias("Setup-Lab")]
    Param (
        [string]$Path = ".",
        [switch]$IgnorePendingReboot
    )

    $labname = split-path (get-location) -leaf
    $LabData = Import-PowerShellDataFile -Path $(Join-Path $Path -childpath *.psd1)
    $DSCResources = $LabData.NonNodeData.Lability.DSCResource
    if (-Not $DSCResources) {
        Write-Warning "Failed to find DSC Resource information. Are you in a directory with configuration data .psd1 file?"
        #bail out
        return
    }

    Write-Host -ForegroundColor Green -Object @"

        This is the Setup-Lab script. This script will perform the following:

        * Run the configs to generate the required .mof files
        Note! - If there is an error creating the .mofs, the setup will fail

        * Run the lab setup
        Note! If this is the first time you have run this, it can take several
        hours to download the ISO files and resources depending on the configuration.
        You may also see new drives being added and removed as the ISO is mounted
        and converted. This step should only happen the first time you run this
        command.

        ** Possible problem
        If the downloads finish but the script doesn't continue (pauses),
        press the Enter key once and it should continue

        *You will be able to wipe and rebuild this lab without needing to perform
        the downloads again.
"@

    # Install DSC Resource modules specified in the .PSD1

    Write-Host -ForegroundColor Cyan -Object 'Installing required DSCResource modules from PSGallery'
    Write-Host -ForegroundColor Yellow -Object 'You may need to say "yes" to a Nuget Provider'

    Foreach ($DSCResource in $DSCResources) {
        #test if current version is installed otherwise update or install it
        $dscmod = Get-Module $DSCResource.name -ListAvailable | Sort-Object Version -Descending

        if ($dscmod[0].version -ne ($DSCResource.RequiredVersion -as [version])) {
            if ($pscmdlet.ShouldProcess($DSCResource.name, "Update-Module")) {
                Update-Module -Name $DSCResource.Name -RequiredVersion $DSCResource.RequiredVersion
            }
        }
        elseif (-not $dscmod) {
            if ($pscmdlet.ShouldProcess($DSCResource.name, "Install-Module")) {
                Install-Module -Name $DSCResource.Name -RequiredVersion $DSCResource.RequiredVersion
            }
        }

    }

    # Run the config to generate the .mof files
    Write-Host -ForegroundColor Cyan -Object 'Build the .Mof files from the configs'
    if ($PSCmdlet.ShouldProcess('.\VMConfiguration.ps1')) {
        .\VMConfiguration.ps1
    }
    # Build the lab without a snapshot
    #
    Write-Host -ForegroundColor Cyan -Object "Building the lab environment for $labname"
    # Creates the lab environment without making a Hyper-V Snapshot

    $Password = ConvertTo-SecureString -String "$($labdata.allnodes.labpassword)" -AsPlainText -Force
    $startParams = @{
        ConfigurationData   = ".\*.psd1"
        Path                = ".\"
        NoSnapshot          = $True
        Password            = $Password
        IgnorePendingReboot = $True
        WarningAction       = "SilentlyContinue"
    }

    $startParams | Out-String | Write-Host -ForegroundColor cyan
    if ($PSCmdlet.ShouldProcess($labname, "Start-LabConfiguration")) {
        Start-LabConfiguration @startParams
        # Disable secure boot for VM's
        Get-VM ( Get-LabVM -ConfigurationData .\*.psd1 ).Name -OutVariable vm
        Set-VMFirmware -VM $vm -EnableSecureBoot Off -SecureBootTemplate MicrosoftUEFICertificateAuthority

        Write-Host -ForegroundColor Green -Object @"

        Next Steps:

        When this task is complete, run:
        Run-Lab

        To enable Internet access for the VM's, run:
        Enable-Internet

        Run the following to validate when configurations have converged:
        Validate-Lab

        To stop the lab VM's:
        Shutdown-lab

        When the configurations have finished, you can checkpoint the VM's with:
        Snapshot-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

        To destroy the lab to build again:
        Wipe-Lab

"@

    } #should process

}
#endregion Setup-lab

#region Run-Lab
Function Invoke-RunLab {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Run-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This is the Run-Lab script. This script will perform the following:

        * Start the Lab environment

        Note! If this is the first time you have run this, it can take up to an hour
        for the DSC configurations to apply and converge.

"@

    $labname = split-path (get-location) -leaf
    Write-Host -ForegroundColor Cyan -Object 'Starting the lab environment'
    # Creates the lab environment without making a Hyper-V Snapshot
    if ($pscmdlet.ShouldProcess($labname, "Start Lab")) {

        try {
            Start-Lab -ConfigurationData .\*.psd1 -ErrorAction Stop
        }
        Catch {
            Write-Warning "Failed to start lab. Are you running this in the correct configuration directory? $($_.exception.message)"
            #bail out because no other commands are likely to work
            return
        }
        Write-Host -ForegroundColor Green -Object @"

        Next Steps:

        To enable Internet access for the VM's, run:
        Enable-Internet

        Run the following to validatae when configurations have converged:
        Validate-Lab

        To stop the lab VM's:
        Shutdown-lab

        When the configurations have finished, you can checkpoint the VM's with:
        Snapshot-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

        To destroy the lab to build again:
        Wipe-Lab


"@
    } #whatif
}
#endregion setup-lab

#region Enable-Internet
Function Enable-Internet {
    [cmdletbinding(SupportsShouldProcess)]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This is the Enable-Internet script. This script will perform the following:

        * Enable Internet to the VM's using NAT

        * Note! - If this generates an error, you are already enabled, or one of the default settings below
                  does not match your .PSD1 configuration

"@

    $LabData = Import-PowerShellDataFile -Path .\*.psd1
    $LabSwitchName = $labdata.NonNodeData.Lability.Network.name
    $GatewayIP = $Labdata.AllNodes.DefaultGateway
    $GatewayPrefix = $Labdata.AllNodes.SubnetMask
    $NatNetwork = $Labdata.AllNodes.IPnetwork
    $NatName = $Labdata.AllNodes.IPNatName

    $Index = Get-NetAdapter -name "vethernet ($LabSwitchName)" | Select-Object -ExpandProperty InterfaceIndex

    if ($pscmdlet.ShouldProcess("Interface index $index", "New-NetIPAddress")) {
        New-NetIPAddress -InterfaceIndex $Index -IPAddress $GatewayIP -PrefixLength $GatewayPrefix -ErrorAction SilentlyContinue
    }

    # Creating the NAT on Server 2016 -- maybe not work on 2012R2
    if ($pscmdlet.ShouldProcess($NatName, "New-NetNat")) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatNetwork -ErrorAction SilentlyContinue
    }

    Write-Host -ForegroundColor Green -Object @"

        Next Steps:

        When complete, run:
        Run-Lab

        And run:
        Validate-Lab

"@
}
#endregion Enable-Internet

#region Validate-Lab
Function Invoke-ValidateLab {
    [cmdletbinding()]
    [alias("Validate-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host "[$(Get-Date)] Starting the VM testing process. This could take some time complete. Errors are expected until all tests complete successfully." -ForegroundColor Cyan

    $Complete = $False

    do {

        $test = Invoke-Pester -Script .\VMValidate.Test.ps1 -Show none -PassThru

        if ($test.Failedcount -eq 0) {
            $Complete = $True
        }
        else {
            #test every 5 minutes
            300..1 | ForEach-Object {
                Write-Progress -Activity "VM Completion Test" -Status "Tests failed" -CurrentOperation "Waiting until next test run" -SecondsRemaining $_
                Start-sleep -Seconds 1
            }
        }
    } until ($Complete)

    #re-run test one more time to show everything that was tested.
    Invoke-Pester -Script .\VMValidate.Test.ps1

    Write-Progress -Activity "VM Completion Test" -Completed
    Write-Host "[$(Get-Date)] VM setup and configuration complete. It is recommended that you snapshot the VMs with Snapshot-Lab" -ForegroundColor Green

}
#endregion Validate-Lab

#region Shutdown-Lab
Function Invoke-ShutdownLab {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Shutdown-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This is the Shutdown-Lab script. This script will perform the following:

        * Shutdown the Lab environment:

"@

    $labname = split-path (get-location) -leaf
    Write-Host -ForegroundColor Cyan -Object 'Stopping the lab environment'
    # Creates the lab environment without making a Hyper-V Snapshot
    if ($pscmdlet.ShouldProcess($labname, "Stop-Lab")) {
        Try {
            Stop-Lab -ConfigurationData .\*.psd1 -erroraction Stop
        }
        Catch {
            Write-Warning "Failed to stop lab. Are you running this in the correct configuration directory? $($_.exception.message)"
            #bail out because no other commands are likely to work
            return
        }
    }

    Write-Host -ForegroundColor Green -Object @"

     Next Steps:

        When the configurations have finished, you can checkpoint the VM's with:
        Snapshot-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

        To start the lab environment:
        Run-Lab

        To destroy the lab environment:
        Wipe-Lab

"@
}
#endregion Shutdown-Lab

#region Snapshot-Lab
Function Invoke-SnapshotLab {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Snapshot-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This is the Snapshot-Lab script. This script will perform the following:

        * Snapshot the lab environment for easy and fast rebuilding

        Note! This should be done after the configurations have finished

"@
    $labname = split-path (get-location) -leaf
    Write-Host -ForegroundColor Cyan -Object 'Snapshot the lab environment'
    # Creates the lab environment without making a Hyper-V Snapshot
    if ($pscmdlet.ShouldProcess($labname, "Stop-Lab")) {

        Try {
            Stop-Lab -ConfigurationData .\*.psd1 -ErrorAction Stop
        }
        Catch {
            Write-Warning "Failed to stop lab. Are you running this in the correct configuration directory? $($_.exception.message)"
            #bail out because no other commands are likely to work
            return
        }

    }
    Checkpoint-Lab -ConfigurationData .\*.psd1 -SnapshotName LabConfigured

    Write-Host -ForegroundColor Green -Object @"

       Next Steps:

        To start the lab environment, run:
        Run-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

        To stop the lab environment, run:
        Shutdown-Lab

"@
}
#endregion

#region Refresh-Lab
Function Invoke-RefreshLab {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Refresh-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This command will perform the following:

        * Refresh the lab from a previous Snapshot

        Note! This can only be done if you created a snapshot!
        Snapshot-Lab

"@
    $labname = split-path (get-location) -leaf
    Write-Host -ForegroundColor Cyan -Object 'Restore the lab environment from a snapshot'
    # Creates the lab environment without making a Hyper-V Snapshot
    Try {
        if ($pscmdlet.ShouldProcess($labname, "Stop-Lab")) {
            Stop-Lab -ConfigurationData .\*.psd1 -ErrorAction Stop
        }
    }
    Catch {
        Write-Warning "Failed to stop lab. Are you running this in the correct configuration directory? $($_.exception.message)"
        #bail out because no other commands are likely to work
        return
    }

    if ($pscmdlet.ShouldProcess($labName, "Restore-Lab")) {
        Restore-Lab -ConfigurationData .\*.psd1 -SnapshotName LabConfigured -force
    }

    Write-Host -ForegroundColor Green -Object @"

        Next Steps:

        To start the lab environment, run:
        Run-Lab

        To stop the lab environment, run:
        Shutdown-Lab

        To destroy this lab, run:
        Wipe-Lab

"@
}
#endregion Refresh-Lab

#region Wipe-Lab
Function Invoke-WipeLab {
    [cmdletbinding()]
    [alias("Wipe-Lab")]
    Param (
        [string]$Path = $PSScriptRoot
    )

    Write-Host -ForegroundColor Green -Object @"

        This command will perform the following:

        * Wipe the lab and VM's from your system for this configuration

        If you intend to rebuild labs or run other configurations you
        do not need to remove the LabNat PolicyStore Local.

        Press Ctrl+C to abort this command.

"@

    Pause

    $labname = split-path (get-location) -leaf
    Write-Host -ForegroundColor Cyan -Object "Removing the lab environment for $labname"
    # Stop the VM's
    Try {
        Stop-Lab -ConfigurationData .\*.psd1 -ErrorAction Stop
    }
    Catch {
        Write-Warning "Failed to stop lab. Are you running this in the correct configuration directory? $($_.exception.message)"
        #bail out because no other commands are likely to work
        return
    }
    # Remove .mof iles
    Remove-Item -Path .\*.mof
    # Delete NAT
    $LabData = Import-PowerShellDataFile -Path .\*.psd1
    $NatName = $Labdata.AllNodes.IPNatName
    Remove-NetNat -Name $NatName
    # Delete vM's
    Remove-LabConfiguration -ConfigurationData .\*.psd1 -RemoveSwitch
    Remove-Item -Path "$((Get-LabHostDefault).DifferencingVHdPath)\*" -Force

    Write-Host -ForegroundColor Green -Object @"

        Next Steps:

        Run the following and follow the onscreen instructions:
        Setup-Lab

        When complete, run:
        Run-Lab

        Run the following to validate when configurations have converged:
        Validate-Lab

        To enable Internet access for the VM's, run:
        Enable-Internet

        To stop the lab VM's:
        Shutdown-lab

        When the configurations have finished, you can checkpoint the VM's with:
        Snapshot-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

        To destroy the lab to build again:
        Wipe-Lab


"@
}
#endregion Wipe-Lab

#region Unattend-Lab
Function Invoke-UnattendLab {
    [cmdletbinding(SupportsShouldProcess)]
    [alias("Unattend-Lab")]
    Param (
        [string]$Path = "."
    )

    Write-Host -ForegroundColor Green -Object @"

       This runs Setup-Lab, Run-Lab, and Validate-Lab

"@

    Write-Host -ForegroundColor Cyan -Object 'Starting the lab environment'

    if ($pscmdlet.ShouldProcess("Setup-Lab", "Run Unattended")) {
        Invoke-SetupLab @psboundparameters
    }
    if ($pscmdlet.ShouldProcess("Run-Lab", "Run Unattended")) {
        Invoke-RunLab
    }
    if ($pscmdlet.ShouldProcess("Enable-Internet", "Run Unattended")) {
        Enable-Internet
    }
    if ($pscmdlet.ShouldProcess("Validate-Lab", "Run Unattended")) {
        Invoke-ValidateLab
    }

    Write-Host -ForegroundColor Green -Object @"

        To stop the lab VM's:
        Shutdown-lab

        When the configurations have finished, you can checkpoint the VM's with:
        Snapshot-Lab

        To quickly rebuild the labs from the checkpoint, run:
        Refresh-Lab

"@

}
#endregion Unattend-Lab

