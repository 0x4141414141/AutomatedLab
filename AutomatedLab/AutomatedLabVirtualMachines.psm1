﻿#region New-LabVM
function New-LabVM
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string[]]$Name,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [switch]$CreateCheckPoints,

        [int]$ProgressIndicator = 20
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $machines = Get-LabVM -ComputerName $Name -IncludeLinux -ErrorAction Stop | Where-Object { -not $_.SkipDeployment } 

    if (-not $machines)
    {
        $message = 'No machine found to create. Either the given name is wrong or there is no machine defined yet'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    $jobs = @()

    if ($lab.DefaultVirtualizationEngine -eq 'Azure')
    {
        Write-ScreenInfo -Message 'Creating Azure load balancer for the newly created machines' -TaskStart
        New-LWAzureLoadBalancer -ConnectedMachines ($machines.Where({ $_.HostType -eq 'Azure' })) -Wait
        Write-ScreenInfo -Message 'Done' -TaskEnd
    }

    foreach ($machine in $machines)
    {
        $fdvDenyWriteAccess = (Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE -Name FDVDenyWriteAccess -ErrorAction SilentlyContinue).FDVDenyWriteAccess
        if ($fdvDenyWriteAccess) {
            Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE -Name FDVDenyWriteAccess -Value 0
        }
        
        Write-ScreenInfo -Message "Creating $($machine.HostType) machine '$machine'" -TaskStart -NoNewLine

        if ($machine.HostType -eq 'HyperV')
        {
            $result = New-LWHypervVM -Machine $machine

            if ('RootDC' -in $machine.Roles.Name)
            {
                Start-LabVM -ComputerName $machine.Name -NoNewline
            }

            if ($result)
            {
                Write-ScreenInfo -Message 'Done' -TaskEnd
            }
            else
            {
                Write-ScreenInfo -Message "Could not create $($machine.HostType) machine '$machine'" -TaskEnd -Type Error
            }
        }
        elseif ($machine.HostType -eq 'VMWare')
        {
            $vmImageName = (New-Object AutomatedLab.OperatingSystem($machine.OperatingSystem)).VMWareImageName
            if (-not $vmImageName)
            {
                Write-Error "The VMWare image for operating system '$($machine.OperatingSystem)' is not defined in AutomatedLab. Cannot install the machine."
                continue
            }

            New-LWVMWareVM -Name $machine.Name -ReferenceVM $vmImageName -AdminUserName $machine.InstallationUser.UserName -AdminPassword $machine.InstallationUser.Password `
            -DomainName $machine.DomainName -DomainJoinCredential $machine.GetCredential($lab)

            Start-LabVM -ComputerName $machine
        }
        elseif ($machine.HostType -eq 'Azure')
        {
            $jobs += New-LWAzureVM -Machine $machine

            Write-ScreenInfo -Message 'Done' -TaskEnd
        }
        if ($fdvDenyWriteAccess) {
            Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE -Name FDVDenyWriteAccess -Value $fdvDenyWriteAccess
        }
    }

    #test if the machine creation jobs succeeded
    Write-ScreenInfo -Message 'Waiting for all machines to finish installing' -TaskStart
    $jobs | Wait-Job | Out-Null
    $failedJobs = $jobs | Where-Object State -eq 'Failed'
    $completedJobs = $jobs | Where-Object State -eq 'Completed'
    Write-ScreenInfo -Message 'Done' -TaskEnd

    if ($failedJobs)
    {
        $failedJobs | Receive-Job -Keep
        throw "Failed to create the Azure machines mentioned in the errors above."
    }

    $azureVms = $machines | Where-Object HostType -eq Azure

    if ($azureVMs)
    {
        Write-ScreenInfo -Message 'Initializing machines' -TaskStart

        Write-PSFMessage -Message 'Calling Enable-PSRemoting on machines'
        Enable-LWAzureWinRm -Machine $azureVMs -Wait

        Write-PSFMessage -Message 'Setting lab DNS servers for newly created machines'
        Set-LWAzureDnsServer -VirtualNetwork $lab.VirtualNetworks

        Write-PSFMessage -Message 'Restarting machines to apply DNS settings'
        Restart-LabVM -ComputerName $azureVMs -Wait -ProgressIndicator 10

        Write-PSFMessage -Message 'Executing initialization script on machines'
        Initialize-LWAzureVM -Machine $azureVMs

        Write-ScreenInfo -Message 'Done' -TaskEnd
    }

    $vmwareVMs = $machines | Where-Object HostType -eq VMWare

    if ($vmwareVMs)
    {
        throw New-Object System.NotImplementedException
    }

    Write-LogFunctionExit
}
#endregion New-LabVM

#region Start-LabVM
function Start-LabVM
{
    
    [cmdletBinding(DefaultParameterSetName = 'ByName')]
    param (
        [Parameter(ParameterSetName = 'ByName', Position = 0)]
        [string[]]$ComputerName,

        [Parameter(Mandatory, ParameterSetName = 'ByRole')]
        [AutomatedLab.Roles]$RoleName,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [switch]$Wait,

        [switch]$DoNotUseCredSsp,

        [switch]$NoNewline,

        [int]$DelayBetweenComputers = 0,
        
        [int]$TimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_StartLabMachine_Online),

        [int]$StartNextMachines,

        [int]$StartNextDomainControllers,

        [string]$Domain,

        [switch]$RootDomainMachines,

        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),

        [int]$PreDelaySeconds = 0,

        [int]$PostDelaySeconds = 0
    )

    begin
    {
        Write-LogFunctionEntry

        if (-not $PSBoundParameters.ContainsKey('ProgressIndicator')) { $PSBoundParameters.Add('ProgressIndicator', $ProgressIndicator) } #enables progress indicator

        $lab = Get-Lab

        $vms = @()
        $availableVMs = $lab.Machines
    }

    process
    {

        if (-not $lab.Machines)
        {
            $message = 'No machine definitions imported, please use Import-Lab first'
            Write-Error -Message $message
            Write-LogFunctionExitWithError -Message $message
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByName' -and -not $StartNextMachines -and -not $StartNextDomainControllers)
        {
            $vms = Get-LabVM -ComputerName $ComputerName -IncludeLinux
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByRole' -and -not $StartNextMachines -and -not $StartNextDomainControllers)
        {
            #get all machines that have a role assigned and the machine's role name is part of the parameter RoleName
            $vms = $lab.Machines | Where-Object { $_.Roles.Name } |
            Where-Object { ($_.Roles | Where-Object { $RoleName.HasFlag([AutomatedLab.Roles]$_.Name) }) -and (-not $_.SkipDeployment) }

            if (-not $vms)
            {
                Write-Error "There is no machine in the lab with the role '$RoleName'"
                return
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByRole' -and $StartNextMachines -and -not $StartNextDomainControllers)
        {
            $vms = $lab.Machines | Where-Object { $_.Roles.Name -and ((Get-LabVMStatus -ComputerName $_.Name) -ne 'Started')} |
            Where-Object { $_.Roles | Where-Object { $RoleName.HasFlag([AutomatedLab.Roles]$_.Name) } }

            if (-not $vms)
            {
                Write-Error "There is no machine in the lab with the role '$RoleName'"
                return
            }
            $vms = $vms | Select-Object -First $StartNextMachines
        }
        elseif (-not ($PSCmdlet.ParameterSetName -eq 'ByRole') -and -not $RootDomainMachines -and -not $StartNextMachines -and $StartNextDomainControllers)
        {
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'FirstChildDC' }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'DC' }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'CaRoot' -and (-not $_.DomainName) }
            $vms = $vms | Where-Object { (Get-LabVMStatus -ComputerName $_.Name) -ne 'Started' } | Select-Object -First $StartNextDomainControllers
        }
        elseif (-not ($PSCmdlet.ParameterSetName -eq 'ByRole') -and -not $RootDomainMachines -and $StartNextMachines -and -not $StartNextDomainControllers)
        {
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'CaRoot' -and $_.DomainName -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'CaSubordinate' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -like 'SqlServer*' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'WebServer' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'Orchestrator' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'VisualStudio2013' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'VisualStudio2015' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'Office2013' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { -not $_.Roles.Name -and $_ -notin $vms }
            $vms = $vms | Where-Object { (Get-LabVMStatus -ComputerName $_.Name) -ne 'Started' } | Select-Object -First $StartNextMachines

            if ($Domain)
            {
                $vms = $vms | Where-Object { (Get-LabVM -ComputerName $_) -eq $Domain }
            }
        }
        elseif (-not ($PSCmdlet.ParameterSetName -eq 'ByRole') -and -not $RootDomainMachines -and $StartNextMachines -and -not $StartNextDomainControllers)
        {
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -like 'SqlServer*' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'WebServer' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'Orchestrator' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'VisualStudio2013' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'VisualStudio2015' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'Office2013' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { -not $_.Roles.Name -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'CaRoot' -and $_ -notin $vms }
            $vms += Get-LabVM -IncludeLinux | Where-Object { $_.Roles.Name -eq 'CaSubordinate' -and $_ -notin $vms }
            $vms = $vms | Where-Object { (Get-LabVMStatus -ComputerName $_.Name) -ne 'Started' } | Select-Object -First $StartNextMachines

            if ($Domain)
            {
                $vms = $vms | Where-Object { (Get-LabVM -IncludeLinux -ComputerName $_) -eq $Domain }
            }
        }
        elseif (-not ($PSCmdlet.ParameterSetName -eq 'ByRole') -and $RootDomainMachines -and -not $StartNextDomainControllers)
        {
            $vms = Get-LabVM -IncludeLinux | Where-Object { $_.DomainName -in (Get-LabVM -Role RootDC).DomainName } | Where-Object { $_.Name -notin (Get-LabVM -Role RootDC).Name -and $_.Roles.Name -notlike '*DC' }
            $vms = $vms | Select-Object -First $StartNextMachines
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'All')
        {
            $vms = $availableVMs | Where-Object { -not $_.SkipDeployment }
        }
    }

    end
    {
        #if there are no VMs to start, just write a warning
        if (-not $vms)
        {
            return
        }

        $vmsCopy = $vms

        #filtering out all machines that are already running
        $vmStates = Get-LabVMStatus -ComputerName $vms -AsHashTable
        foreach ($vmState in $vmStates.GetEnumerator())
        {
            if ($vmState.Value -eq 'Started')
            {
                $vms = $vms | Where-Object Name -ne $vmState.Name
                Write-Debug "Machine '$($vmState.Name)' is already running, removing it from the list of machines to start"
            }
        }

        Write-PSFMessage "Starting VMs '$($vms.Name -join ', ')'"

        $hypervVMs = $vms | Where-Object HostType -eq 'HyperV'
        if ($hypervVMs)
        {
            Start-LWHypervVM -ComputerName $hypervVMs -DelayBetweenComputers $DelayBetweenComputers -ProgressIndicator $ProgressIndicator -PreDelaySeconds $PreDelaySeconds -PostDelaySeconds $PostDelaySeconds -NoNewLine:$NoNewline
        }

        $azureVms = $vms | Where-Object HostType -eq 'Azure'
        if ($azureVms)
        {
            Start-LWAzureVM -ComputerName $azureVms -DelayBetweenComputers $DelayBetweenComputers -ProgressIndicator $ProgressIndicator -NoNewLine:$NoNewline
        }

        $vmwareVms = $vms | Where-Object HostType -eq 'VmWare'
        if ($vmwareVms)
        {
            Start-LWVMWareVM -ComputerName $vmwareVms -DelayBetweenComputers $DelayBetweenComputers
        }

        if ($Wait)
        {
            Wait-LabVM -ComputerName ($vmsCopy) -Timeout $TimeoutInMinutes -DoNotUseCredSsp:$DoNotUseCredSsp -ProgressIndicator $ProgressIndicator -NoNewLine
        }

        Write-ProgressIndicatorEnd

        Write-LogFunctionExit
    }
}
#endregion Start-LabVM

#region Save-LabVM
function Save-LabVM
{
    

    [cmdletBinding(DefaultParameterSetName = 'ByName')]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'ByName', Position = 0)]
        [string[]]$Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'ByRole')]
        [AutomatedLab.Roles]$RoleName,

        [Parameter(ValueFromPipelineByPropertyName = $true, ParameterSetName = 'All')]
        [switch]$All
    )

    begin
    {
        Write-LogFunctionEntry

        $lab = Get-Lab

        $vms = @()
        $availableVMs = $lab.Machines.Name
    }

    process
    {

        if (-not $lab.Machines)
        {
            $message = 'No machine definitions imported, please use Import-Lab first'
            Write-Error -Message $message
            Write-LogFunctionExitWithError -Message $message
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByName')
        {
            $Name | ForEach-Object {
                if ($_ -in $availableVMs)
                {
                    $vms += $_
                }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByRole')
        {
            #get all machines that have a role assigned and the machine's role name is part of the parameter RoleName
            $machines = ($lab.Machines |
                Where-Object { $_.Roles.Name } |
            Where-Object { $_.Roles | Where-Object { $RoleName.HasFlag([AutomatedLab.Roles]$_.Name) } }).Name
            $vms = $machines
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'All')
        {
            $vms = $availableVMs
        }
    }

    end
    {
        $vms = Get-LabVM -ComputerName $vms -IncludeLinux

        #if there are no VMs to start, just write a warning
        if (-not $vms)
        {
            Write-ScreenInfo 'There is no machine to start' -Type Warning
            return
        }

        Write-PSFMessage -Message "Saving VMs '$($vms -join ',')"
        switch ($lab.DefaultVirtualizationEngine)
        {
            'HyperV' { Save-LWHypervVM -ComputerName $vms}
            'VMWare' { Save-LWVMWareVM -ComputerName $vms}
            'Azure'  { Write-PSFMessage -Level Warning -Message "Skipping Azure VMs '$($vms -join ',')' as suspending the VMs is not supported on Azure."}
        }

        Write-LogFunctionExit
    }
}
#endregion Start-LabVM

#region Restart-LabVM
function Restart-LabVM
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,

        [switch]$Wait,
        
        [double]$ShutdownTimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_RestartLabMachine_Shutdown),

        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),

        [switch]$NoDisplay,

        [switch]$NoNewLine
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab.Machines)
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $machines = Get-LabVM -ComputerName $ComputerName

    if (-not $machines)
    {
        Write-Error "The machines '$($ComputerName -join ', ')' could not be found in the lab."
        return
    }

    Write-PSFMessage "Stopping machine '$ComputerName' and waiting for shutdown"
    Stop-LabVM -ComputerName $ComputerName -ShutdownTimeoutInMinutes $ShutdownTimeoutInMinutes -Wait -ProgressIndicator $ProgressIndicator -NoNewLine -KeepAzureVmProvisioned
    Write-PSFMessage "Machine '$ComputerName' is stopped"

    Write-Debug 'Waiting 10 seconds'
    Start-Sleep -Seconds 10

    Write-PSFMessage "Starting machine '$ComputerName' and waiting for availability"
    Start-LabVM -ComputerName $ComputerName -Wait:$Wait -ProgressIndicator $ProgressIndicator -NoNewline:$NoNewLine
    Write-PSFMessage "Machine '$ComputerName' is started"

    Write-LogFunctionExit
}
#endregion Restart-LabVM

#region Stop-LabVM
function Stop-LabVM
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [string[]]$ComputerName,
        
        [double]$ShutdownTimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_StopLabMachine_Shutdown),

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [switch]$Wait,

        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),

        [switch]$NoNewLine,

        [switch]$KeepAzureVmProvisioned
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab.Machines)
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    if ($ComputerName)
    {
        $machines = Get-LabVM -ComputerName $ComputerName -IncludeLinux
    }
    elseif ($All)
    {
        $machines = Get-LabVM -IncludeLinux | Where-Object { -not $_.SkipDeployment }
    }

    #filtering out all machines that are already stopped
    $vmStates = Get-LabVMStatus -ComputerName $machines -AsHashTable
    foreach ($vmState in $vmStates.GetEnumerator())
    {
        if ($vmState.Value -eq 'Stopped')
        {
            $machines = $machines | Where-Object Name -ne $vmState.Name
            Write-Debug "Machine $($vmState.Name) is already stopped, removing it from the list of machines to stop"
        }
    }

    if (-not $machines)
    {
        return
    }

    Remove-LabPSSession -ComputerName $machines

    $hypervVms = $machines | Where-Object HostType -eq 'HyperV'
    $azureVms = $machines | Where-Object HostType -eq 'Azure'
    $vmwareVms = $machines | Where-Object HostType -eq 'VMWare'

    if ($hypervVms)
    {
        Stop-LWHypervVM -ComputerName $hypervVms -TimeoutInMinutes $ShutdownTimeoutInMinutes -ProgressIndicator $ProgressIndicator -NoNewLine:$NoNewLine `
        -ErrorVariable hypervErrors -ErrorAction SilentlyContinue
    }
    if ($azureVms)
    {
        $stayProvisioned = if ($KeepAzureVmProvisioned)
        {
            $true
        }
        else
        {
            $false
        }
        Stop-LWAzureVM -ComputerName $azureVms -ErrorVariable azureErrors -ErrorAction SilentlyContinue -StayProvisioned $KeepAzureVmProvisioned
    }
    if ($vmwareVms)
    {
        Stop-LWVMWareVM -ComputerName $vmwareVms -ErrorVariable vmwareErrors -ErrorAction SilentlyContinue
    }

    $remainingTargets = @()
    if ($hypervErrors) { $remainingTargets += $hypervErrors.TargetObject }
    if ($azureErrors) { $remainingTargets + $azureErrors.TargetObject }
    if ($vmwareErrors) { $remainingTargets + $vmwareErrors.TargetObject }
    if ($remainingTargets) { Stop-LabVM2 -ComputerName $remainingTargets }

    if ($Wait)
    {
        Wait-LabVMShutdown -ComputerName $machines -TimeoutInMinutes $ShutdownTimeoutInMinutes
    }

    Write-LogFunctionExit
}
#endregion Stop-LabVM

#region Stop-LabVM2
function Stop-LabVM2
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [string[]]$ComputerName,
        
        [int]$ShutdownTimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_StopLabMachine_Shutdown)
    )

    $scriptBlock = {
        $sessions = quser.exe
        $sessionNames = $sessions |
        Select-Object -Skip 1 |
        ForEach-Object -Process {
            ($_.Trim() -split ' +')[2]
        }

        Write-Verbose -Message "There are $($sessionNames.Count) open sessions"
        foreach ($sessionName in $sessionNames)
        {
            Write-Verbose -Message "Closing session '$sessionName'"
            logoff.exe $sessionName
        }

        Start-Sleep -Seconds 2

        Write-Verbose -Message 'Stopping machine forcefully'
        Stop-Computer -Force
    }

    $jobs = Invoke-LabCommand -ComputerName $ComputerName -ActivityName Shutdown -NoDisplay -ScriptBlock $scriptBlock -AsJob -PassThru
    $jobs | Wait-Job -Timeout ($ShutdownTimeoutInMinutes * 60) | Out-Null

    if ($jobs.Count -ne ($jobs | Where-Object State -eq Completed).Count)
    {
        Write-ScreenInfo "Not all machines stopped in the timeout of $ShutdownTimeoutInMinutes" -Type Warning
    }
}
#endregion Stop-LabVM2

#region Wait-LabVM
function Wait-LabVM
{
    
    param (
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,
        
        [double]$TimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_WaitLabMachine_Online),

        [int]$PostDelaySeconds = 0,

        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),
        
        [switch]$DoNotUseCredSsp,

        [switch]$NoNewLine
    )

    if (-not $PSBoundParameters.ContainsKey('ProgressIndicator')) { $PSBoundParameters.Add('ProgressIndicator', $ProgressIndicator) } #enables progress indicator

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $jobs = @()

    $vms = Get-LabVM -ComputerName $ComputerName -IncludeLinux

    if (-not $vms)
    {
        Write-Error 'None of the given machines could be found'
        return
    }

    foreach ($vm in $vms)
    {
        $session = $null
        #remove the existing sessions to ensure a new one is created and the existing one not reused.
        Remove-LabPSSession -ComputerName $vm

        netsh.exe interface ip delete arpcache | Out-Null

        #if called without using DoNotUseCredSsp and the machine is not yet configured for CredSsp, call Wait-LabVM again but with DoNotUseCredSsp. Wait-LabVM enables CredSsp if called with DoNotUseCredSsp switch.
        if ($lab.DefaultVirtualizationEngine -eq 'HyperV')
        {
            $machineMetadata = Get-LWHypervVMDescription -ComputerName $vm
            if (($machineMetadata.InitState -band [AutomatedLab.LabVMInitState]::EnabledCredSsp) -ne [AutomatedLab.LabVMInitState]::EnabledCredSsp -and -not $DoNotUseCredSsp)
            {
                Wait-LabVM -ComputerName $vm -TimeoutInMinutes $TimeoutInMinutes -PostDelaySeconds $PostDelaySeconds -ProgressIndicator $ProgressIndicator -DoNotUseCredSsp -NoNewLine:$NoNewLine
            }
        }

        $session = New-LabPSSession -ComputerName $vm -UseLocalCredential -Retries 1 -DoNotUseCredSsp:$DoNotUseCredSsp -ErrorAction SilentlyContinue

        if ($session)
        {
            Write-PSFMessage "Computer '$vm' was reachable"
            $jobs += Start-Job -Name "Waiting for machine '$vm'" -ScriptBlock {
                param (
                    [string]$ComputerName
                )

                $ComputerName
            } -ArgumentList $vm.Name
        }
        else
        {
            Write-PSFMessage "Computer '$($vm.ComputerName)' was not reachable, waiting..."
            $jobs += Start-Job -Name "Waiting for machine '$vm'" -ScriptBlock {
                param(
                    [Parameter(Mandatory)]
                    [byte[]]$LabBytes,

                    [Parameter(Mandatory)]
                    [string]$ComputerName,

                    [Parameter(Mandatory)]
                    [bool]$DoNotUseCredSsp
                )

                $VerbosePreference = $using:VerbosePreference

                Import-Module -Name Azure* -ErrorAction SilentlyContinue
                Import-Module -Name AutomatedLab.Common -ErrorAction Stop
                Write-Verbose "Importing Lab from $($LabBytes.Count) bytes"
                Import-Lab -LabBytes $LabBytes -NoValidation -NoDisplay

                #do 5000 retries. This job is cancelled anyway if the timeout is reached
                Write-Verbose "Trying to create session to '$ComputerName'"
                $session = New-LabPSSession -ComputerName $ComputerName -UseLocalCredential  -Retries 5000 -DoNotUseCredSsp:$DoNotUseCredSsp

                return $ComputerName
            } -ArgumentList $lab.Export(), $vm.Name, $DoNotUseCredSsp
        }
    }

    Write-PSFMessage "Waiting for $($jobs.Count) machines to respond in timeout ($TimeoutInMinutes minute(s))"

    Wait-LWLabJob -Job $jobs -ProgressIndicator $ProgressIndicator -NoNewLine:$NoNewLine -NoDisplay -Timeout $TimeoutInMinutes

    $completed = $jobs | Where-Object State -eq Completed | Receive-Job -ErrorAction SilentlyContinue -Verbose:$VerbosePreference

    if ($completed)
    {
        $notReadyMachines = (Compare-Object -ReferenceObject $completed -DifferenceObject $vms.Name).InputObject
        $jobs | Remove-Job -Force
    }
    else
    {
        $notReadyMachines = $vms.Name
    }

    if ($notReadyMachines)
    {
        $message = "The following machines are not ready: $($notReadyMachines -join ', ')"
        Write-LogFunctionExitWithError -Message $message
    }
    else
    {
        Write-PSFMessage "The following machines are ready: $($completed -join ', ')"

        foreach ($machine in $completed)
        {
            if ((Get-LabVM -ComputerName $machine).HostType -eq 'HyperV')
            {
                $machineMetadata = Get-LWHypervVMDescription -ComputerName $machine
                if ($machineMetadata.InitState -eq [AutomatedLab.LabVMInitState]::Uninitialized)
                {
                    $machineMetadata.InitState = [AutomatedLab.LabVMInitState]::ReachedByAutomatedLab
                    Set-LWHypervVMDescription -Hashtable $machineMetadata -ComputerName $machine
                }

                if ($DoNotUseCredSsp -and ($machineMetadata.InitState -band [AutomatedLab.LabVMInitState]::EnabledCredSsp) -ne [AutomatedLab.LabVMInitState]::EnabledCredSsp)
                {
                    $credSspEnabled = Invoke-LabCommand -ComputerName $machine -ScriptBlock {

                        if ($PSVersionTable.PSVersion.Major -eq 2)
                        {
                            $d = "{0:HH:mm}" -f (Get-Date).AddMinutes(1)
                            $jobName = "AL_EnableCredSsp"
                            $Path = 'PowerShell'
                            $CommandLine = '-Command Enable-WSManCredSSP -Role Server -Force; Get-WSManCredSSP | Out-File -FilePath C:\EnableCredSsp.txt'
                            schtasks.exe /Create /SC ONCE /ST $d /TN $jobName /TR "$Path $CommandLine" | Out-Null
                            schtasks.exe /Run /TN $jobName | Out-Null
                            Start-Sleep -Seconds 1
                            while ((schtasks.exe /Query /TN $jobName) -like '*Running*')
                            {
                                Write-Host '.' -NoNewline
                                Start-Sleep -Seconds 1
                            }
                            Start-Sleep -Seconds 1
                            schtasks.exe /Delete /TN $jobName /F | Out-Null

                            Start-Sleep -Seconds 5

                            [bool](Get-Content -Path C:\EnableCredSsp.txt | Where-Object { $_ -eq 'This computer is configured to receive credentials from a remote client computer.' })
                        }
                        else
                        {
                            Enable-WSManCredSSP -Role Server -Force | Out-Null
                            [bool](Get-WSManCredSSP | Where-Object { $_ -eq 'This computer is configured to receive credentials from a remote client computer.' })
                        }


                    } -PassThru -DoNotUseCredSsp -NoDisplay

                    if ($credSspEnabled)
                    {
                        $machineMetadata.InitState = $machineMetadata.InitState -bor [AutomatedLab.LabVMInitState]::EnabledCredSsp
                    }
                    else
                    {
                        Write-ScreenInfo "CredSsp could not be enabled on machine '$machine'" -Type Warning
                    }

                    Set-LWHypervVMDescription -Hashtable $machineMetadata -ComputerName $machine
                }
            }
        }

        Write-LogFunctionExit
    }

    if ($PostDelaySeconds)
    {
        $job = Start-Job -Name "Wait $PostDelaySeconds seconds" -ScriptBlock { Start-Sleep -Seconds $Using:PostDelaySeconds }
        Wait-LWLabJob -Job $job -ProgressIndicator $ProgressIndicator -NoDisplay -NoNewLine:$NoNewLine
    }
}
#endregion Wait-LabVM

function Wait-LabVMRestart
{
    
    param (
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,

        [switch]$DoNotUseCredSsp,
        
        [double]$TimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_WaitLabMachine_Online),
        
        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),
        
        [AutomatedLab.Machine[]]$StartMachinesWhileWaiting,

        [switch]$NoNewLine,

        $MonitorJob,

        [DateTime]$MonitoringStartTime = (Get-Date)
    )

    Write-LogFunctionEntry

    if (-not $PSBoundParameters.ContainsKey('ProgressIndicator')) { $PSBoundParameters.Add('ProgressIndicator', $ProgressIndicator) } #enables progress indicator

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $vms = Get-LabVM -ComputerName $ComputerName

    $azureVms = $vms | Where-Object HostType -eq 'Azure'
    $hypervVms = $vms | Where-Object HostType -eq 'HyperV'
    $vmwareVms = $vms | Where-Object HostType -eq 'VMWare'

    if ($azureVms)
    {
        Wait-LWAzureRestartVM -ComputerName $azureVms -DoNotUseCredSsp:$DoNotUseCredSsp -TimeoutInMinutes $TimeoutInMinutes `
        -ProgressIndicator $ProgressIndicator -NoNewLine:$NoNewLine -ErrorAction SilentlyContinue -ErrorVariable azureWaitError -MonitoringStartTime $MonitoringStartTime
    }

    if ($hypervVms)
    {
        Wait-LWHypervVMRestart -ComputerName $hypervVms -TimeoutInMinutes $TimeoutInMinutes -ProgressIndicator $ProgressIndicator -NoNewLine:$NoNewLine -StartMachinesWhileWaiting $StartMachinesWhileWaiting -ErrorAction SilentlyContinue -ErrorVariable hypervWaitError -MonitorJob $MonitorJob
    }

    if ($vmwareVms)
    {
        Wait-LWVMWareRestartVM -ComputerName $vmwareVms -TimeoutInMinutes $TimeoutInMinutes -ProgressIndicator $ProgressIndicator -ErrorAction SilentlyContinue -ErrorVariable vmwareWaitError
    }

    $waitError = New-Object System.Collections.ArrayList
    if ($azureWaitError) { $waitError.AddRange($azureWaitError) }
    if ($hypervWaitError) { $waitError.AddRange($hypervWaitError) }
    if ($vmwareWaitError) { $waitError.AddRange($vmwareWaitError) }

    $waitError = $waitError | Where-Object { $_.Exception.Message -like 'Timeout while waiting for computers to restart*' }
    if ($waitError)
    {
        $nonRestartedMachines = $waitError.TargetObject

        Write-Error "The following machines have not restarted in the timeout of $TimeoutInMinutes minute(s): $($nonRestartedMachines -join ', ')"
    }

    Write-LogFunctionExit
}
#endregion Wait-LabVMRestart

#region Wait-LabVMShutdown
function Wait-LabVMShutdown
{
    
    param (
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,
        
        [double]$TimeoutInMinutes = (Get-LabConfigurationItem -Name Timeout_WaitLabMachine_Online),

        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator),
        
        [switch]$NoNewLine
    )

    Write-LogFunctionEntry

    $start = Get-Date
    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $vms = Get-LabVM -ComputerName $ComputerName

    $vms | Add-Member -Name HasShutdown -MemberType NoteProperty -Value $false -Force

    $ProgressIndicatorTimer = Get-Date
    do
    {
        foreach ($vm in $vms)
        {
            $status = Get-LabVMStatus -ComputerName $vm -Verbose:$false

            if ($status -eq 'Stopped')
            {
                $vm.HasShutdown = $true
            }

            Start-Sleep -Seconds 5
        }
        if (((Get-Date) - $ProgressIndicatorTimer).TotalSeconds -ge $ProgressIndicator)
        {
            Write-ProgressIndicator
            $ProgressIndicatorTimer = (Get-Date)
        }
    }
    until (($vms | Where-Object { $_.HasShutdown }).Count -eq $vms.Count -or (Get-Date).AddMinutes(- $TimeoutInMinutes) -gt $start)

    foreach ($vm in ($vms | Where-Object { -not $_.HasShutdown }))
    {
        Write-Error -Message "Timeout while waiting for computer '$($vm.Name)' to shutdown." -TargetObject $vm.Name -ErrorVariable shutdownError
    }

    if ($shutdownError)
    {
        Write-Error "The following machines have not shutdown in the timeout of $TimeoutInMinutes minute(s): $($shutdownError.TargetObject -join ', ')"
    }

    Write-LogFunctionExit
}
#endregion Wait-LabVMShutdown

#region Remove-LabVM
function Remove-LabVM
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [string[]]$Name,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All
    )

    Write-LogFunctionEntry

    $lab = Get-Lab
    if (-not $lab)
    {
        Write-Error 'No definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    if ($Name)
    {
        $machines = $lab.Machines | Where-Object Name -in $Name
    }
    else
    {
        $machines = $lab.Machines
    }

    if (-not $machines)
    {
        $message = 'No machine found to remove'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    foreach ($machine in $machines)
    {
        $doNotUseGetHostEntry = Get-LabConfigurationItem -Name DoNotUseGetHostEntryInNewLabPSSession
        if (-not $doNotUseGetHostEntry)
        {
            $computerName = (Get-HostEntry -Hostname $machine).IpAddress.IpAddressToString
        }

        <#
                removed 161023, might not be required
                if ((Get-LabVMStatus -ComputerName $machine) -eq 'Unknown')
                {
                Start-LabVM -ComputerName $machines -Wait
        }#>

        Get-PSSession | Where-Object {$_.ComputerName -eq $computerName} | Remove-PSSession

        Write-ScreenInfo -Message "Removing Lab VM '$($machine.Name)' (and its associated disks)"

        if ($virtualNetworkAdapter.HostType -eq 'VMWare')
        {
            Write-Error 'Managing networks is not yet supported for VMWare'
            continue
        }

        if ($machine.HostType -eq 'HyperV')
        {
            Remove-LWHypervVM -Name $machine
        }
        elseif ($machine.HostType -eq 'Azure')
        {
            Remove-LWAzureVM -Name $machine
        }
        elseif ($machine.HostType -eq 'VMWare')
        {
            Remove-LWVMWareVM -Name $machine
        }

        if ((Get-HostEntry -Section (Get-Lab).Name.ToLower() -HostName $machine))
        {
            Remove-HostEntry -Section (Get-Lab).Name.ToLower() -HostName $machine
        }

        Write-ScreenInfo -Message "Lab VM '$machine' has been removed"
    }
}
#endregion Remove-LabVM

#region Get-LabVMStatus
function Get-LabVMStatus
{
    [cmdletBinding()]
    
    param (
        [string[]]$ComputerName,

        [switch]$AsHashTable
    )

    Write-LogFunctionEntry

    #required to suporess verbose messages, warnings and errors
    Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState

    if ($ComputerName)
    {
        $vms = Get-LabVM -ComputerName $ComputerName -IncludeLinux | Where-Object { -not $_.SkipDeployment }
    }
    else
    {
        $vms = Get-LabVM -IncludeLinux
    }

    $hypervVMs = $vms | Where-Object HostType -eq 'HyperV'
    if ($hypervVMs) { $hypervStatus = Get-LWHypervVMStatus -ComputerName $hypervVMs.Name }

    $azureVMs = $vms | Where-Object HostType -eq 'Azure'
    if ($azureVMs) { $azureStatus = Get-LWAzureVMStatus -ComputerName $azureVMs.Name }

    $vmwareVMs = $vms | Where-Object HostType -eq 'VMWare'
    if ($vmwareVMs) { $vmwareStatus = Get-LWVMWareVMStatus -ComputerName $vmwareVMs.Name }

    $result = @{ }
    if ($hypervStatus) { $result = $result + $hypervStatus }
    if ($azureStatus) { $result = $result + $azureStatus }
    if ($vmwareStatus) { $result = $result + $vmwareStatus }

    if ($result.Count -eq 1 -and -not $AsHashTable)
    {
        $result.Values[0]
    }
    else
    {
        $result
    }

    Write-LogFunctionExit
}
#endregion Get-LabVMStatus

#region Get-LabVMUptime
function Get-LabVMUptime
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]$ComputerName
    )

    Write-LogFunctionEntry

    $cmdGetUptime = {
        $lastboottime = (Get-WmiObject -Class Win32_OperatingSystem).LastBootUpTime
        (Get-Date) - [System.Management.ManagementDateTimeconverter]::ToDateTime($lastboottime)
    }

    $uptime = Invoke-LabCommand -ComputerName $ComputerName -ActivityName GetUptime -ScriptBlock $cmdGetUptime -UseLocalCredential -PassThru

    if ($uptime)
    {
        Write-LogFunctionExit -ReturnValue $uptime
        $uptime
    }
    else
    {
        Write-LogFunctionExitWithError -Message 'Uptime could not be retrieved'
    }
}
#endregion Get-LabVMUptime

#region Connect-LabVM
function Connect-LabVM
{
    
    param (
        [Parameter(Mandatory)]
        [string[]]$ComputerName,

        [switch]$UseLocalCredential
    )

    $machines = Get-LabVM -ComputerName $ComputerName -IncludeLinux
    $lab = Get-Lab

    foreach ($machine in $machines)
    {
        if ($UseLocalCredential)
        {
            $cred = $machine.GetLocalCredential()
        }
        else
        {
            $cred = $machine.GetCredential($lab)
        }

        if ($machine.OperatingSystemType -eq 'Linux')
        {
            $sshBinary = Get-ChildItem $labsources\Tools\OpenSSH -Filter ssh.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

            if (-not $sshBinary)
            {
                $download = Read-Choice -ChoiceList 'No','Yes' -Caption 'Download Win32-OpenSSH' -Message 'OpenSSH is necessary to connect to Linux VMs. Would you like us to download Win32-OpenSSH for you?' -Default 1

                if ([bool]$download)
                {
                    $downloadUri = Get-LabConfigurationItem -Name OpenSshUri
                    $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) -ChildPath openssh.zip
                    $targetPath = "$labsources\Tools\OpenSSH"
                    Get-LabInternetFile -Uri $downloadUri -Path $downloadPath

                    Microsoft.PowerShell.Archive\Expand-Archive -Path $downloadPath -DestinationPath $targetPath -Force
                    $sshBinary = Get-ChildItem $labsources\Tools\OpenSSH -Filter ssh.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                }
            }

            if ($UseLocalCredential)
            {
                $arguments = '-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l {0} {1}' -f $cred.UserName,$machine
            }
            else
            {
                $arguments = '-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l {0}@{2} {1}' -f $cred.UserName,$machine,$cred.GetNetworkCredential().Domain
            }

            Start-Process -FilePath $sshBinary.FullPath -ArgumentList $arguments
            return
        }

        if ($machine.HostType -eq 'Azure')
        {
            $cn = Get-LWAzureVMConnectionInfo -ComputerName $machine
            $cmd = 'cmdkey.exe /add:"TERMSRV/{0}" /user:"{1}" /pass:"{2}"' -f $cn.DnsName, $cred.UserName, $cred.GetNetworkCredential().Password
            Invoke-Expression $cmd | Out-Null
            mstsc.exe "/v:$($cn.DnsName):$($cn.RdpPort)"

            Start-Sleep -Seconds 5 #otherwise credentials get deleted too quickly

            $cmd = 'cmdkey /delete:TERMSRV/"{0}"' -f $cn.DnsName
            Invoke-Expression $cmd | Out-Null
        }
        else
        {
            $cmd = 'cmdkey.exe /add:"TERMSRV/{0}" /user:"{1}" /pass:"{2}"' -f $machine.Name, $cred.UserName, $cred.GetNetworkCredential().Password
            Invoke-Expression $cmd | Out-Null
            mstsc.exe "/v:$($machine.Name)"

            Start-Sleep -Seconds 1 #otherwise credentials get deleted too quickly

            $cmd = 'cmdkey /delete:TERMSRV/"{0}"' -f $cn.DnsName
            Invoke-Expression $cmd | Out-Null
        }
    }
}
#endregion Connect-LabVM

#region Get-LabVMRdpFile
function Get-LabVMRdpFile
{
    
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string[]]$ComputerName,

        [switch]$UseLocalCredential,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All
    )

    if ($ComputerName)
    {
        $machines = Get-LabVM -ComputerName $ComputerName
    }
    else
    {
        $machines = Get-LabVM -All
    }

    $lab = Get-Lab

    foreach ($machine in $machines)
    {
        Write-PSFMessage "Creating RDP file for machine '$($machine.Name)'"
        $port = 3389
        $name = $machine.Name

        if ($UseLocalCredential)
        {
            $cred = $machine.GetLocalCredential()
        }
        else
        {
            $cred = $machine.GetCredential($lab)
        }

        if ($machine.HostType = 'Azure')
        {
            $cn = Get-LWAzureVMConnectionInfo -ComputerName $machine.Name
            $cmd = 'cmdkey.exe /add:"TERMSRV/{0}" /user:"{1}" /pass:"{2}"' -f $cn.DnsName, $cred.UserName, $cred.GetNetworkCredential().Password
            Invoke-Expression $cmd | Out-Null

            $name = $cn.DnsName
            $port = $cn.RdpPort
        }
        elseif ($machine.HostType -eq 'HyperV')
        {
            $cmd = 'cmdkey.exe /add:"TERMSRV/{0}" /user:"{1}" /pass:"{2}"' -f $machine.Name, $cred.UserName, $cred.GetNetworkCredential().Password
            Invoke-Expression $cmd | Out-Null
        }

        $rdpContent = @"
redirectclipboard:i:1
redirectprinters:i:1
redirectcomports:i:0
redirectsmartcards:i:1
devicestoredirect:s:*
drivestoredirect:s:*
redirectdrives:i:1
session bpp:i:32
prompt for credentials on client:i:0
span monitors:i:1
use multimon:i:0
server port:i:$port
allow font smoothing:i:1
promptcredentialonce:i:0
videoplaybackmode:i:1
audiocapturemode:i:1
gatewayusagemethod:i:0
gatewayprofileusagemethod:i:1
gatewaycredentialssource:i:0
full address:s:$name
use redirection server name:i:1
username:s:$($cred.UserName)
authentication level:i:0
"@
        $path = Join-Path -Path $lab.LabPath -ChildPath ($machine.Name + '.rdp')
        $rdpContent | Out-File -FilePath $path
        Write-PSFMessage "RDP file saved to '$path'"
    }
}
#endregion Get-LabVMRdpFile

#region Join-LabVMDomain
function Join-LabVMDomain
{
    
    [cmdletBinding()]

    param(
        [Parameter(Mandatory, Position = 0)]
        [AutomatedLab.Machine[]]$Machine
    )

    Write-LogFunctionEntry

    #region Join-Computer
    function Join-Computer
    {
        [cmdletBinding()]

        param(
            [Parameter(Mandatory = $true)]
            [string]$DomainName,

            [Parameter(Mandatory = $true)]
            [System.Management.Automation.PSCredential]$Credential,

            [bool]$AlwaysReboot = $false
        )

        try
        {
            if ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name -eq $DomainName)
            {
                return $true
            }
        }
        catch
        {
            # Empty catch. If we are a workgroup member, it is domain join time.
        }

        try
        {
            Add-Computer -DomainName $DomainName -Credential $Credential -ErrorAction Stop -WarningAction SilentlyContinue
            $true
        }
        catch
        {
            if ($AlwaysReboot)
            {
                $false
                Start-Sleep -Seconds 1
                Restart-Computer -Force
            }
            else
            {
                Write-Error -Exception $_.Exception -Message $_.Exception.Message -ErrorAction Stop
            }
        }

        $logonName = "$DomainName\$($Credential.UserName)"
        $password = $Credential.GetNetworkCredential().Password

        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value 1 -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUserName -Value $logonName -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Value $password -Force | Out-Null

        Start-Sleep -Seconds 1

        Restart-Computer -Force
    }
    #endregion

    $lab = Get-Lab
    $jobs = @()
    $startTime = Get-Date

    Write-PSFMessage "Starting joining $($Machine.Count) machines to domains"
    foreach ($m in $Machine)
    {
        $domain = $lab.Domains | Where-Object Name -eq $m.DomainName
        $cred = $domain.GetCredential()

        Write-PSFMessage "Joining machine '$m' to domain '$domain'"
        $jobParameters = @{
            ComputerName = $m
            ActivityName = "DomainJoin_$m"
            ScriptBlock = (Get-Command Join-Computer).ScriptBlock
            UseLocalCredential = $true
            ArgumentList = $domain, $cred
            AsJob = $true
            PassThru = $true
            NoDisplay = $true
        }

        if ($m.HostType -eq 'Azure')
        {
            $jobParameters.ArgumentList += $true
        }
        $jobs += Invoke-LabCommand @jobParameters
    }

    if ($jobs)
    {
        Write-PSFMessage 'Waiting on jobs to finish'
        Wait-LWLabJob -Job $jobs -ProgressIndicator 15 -NoDisplay -NoNewLine

        Write-ProgressIndicatorEnd
        Write-ScreenInfo -Message 'Waiting for machines to restart' -NoNewLine
        Wait-LabVMRestart -ComputerName $Machine -ProgressIndicator 30 -NoNewLine -MonitoringStartTime $startTime
    }

    foreach ($m in $Machine)
    {
        $machineJob = $jobs | Where-Object -Property Name -EQ DomainJoin_$m
        $machineResult = $machineJob | Receive-Job -Keep -ErrorAction SilentlyContinue
        if (($machineJob).State -eq 'Failed' -or -not $machineResult)
        {
            Write-ScreenInfo -Message "$m failed to join the domain. Retrying on next restart" -Type Warning
            $m.HasDomainJoined = $false
        }
        else
        {
            $m.HasDomainJoined = $true
        }
    }
    Export-Lab

    Write-LogFunctionExit
}
#endregion Join-LabVMDomain

#region Mount-LabIsoImage
function Mount-LabIsoImage
{
    
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,

        [Parameter(Mandatory, Position = 1)]
        [string]$IsoPath,

        [switch]$SupressOutput,

        [switch]$PassThru
    )

    Write-LogFunctionEntry

    $machines = Get-LabVM -ComputerName $ComputerName
    if (-not $machines)
    {
        Write-LogFunctionExitWithError -Message 'The specified machines could not be found'
        return
    }
    if ($machines.Count -ne $ComputerName.Count)
    {
        $machinesNotFound = Compare-Object -ReferenceObject $ComputerName -DifferenceObject ($machines.Name)
        Write-ScreenInfo "The specified machine(s) $($machinesNotFound.InputObject -join ', ') could not be found" -Type Warning
    }
    $machines | Where-Object HostType -notin HyperV, Azure | ForEach-Object {
        Write-ScreenInfo "Using ISO images is only supported with Hyper-V VMs or on Azure. Skipping machine '$($_.Name)'" -Type Warning
    }

    $machines = $machines | Where-Object HostType -in HyperV,Azure

    foreach ($machine in $machines)
    {
        if (-not $SupressOutput)
        {
            Write-ScreenInfo -Message "Mounting ISO image '$IsoPath' to computer '$machine'" -Type Info
        }

        if ($machine.HostType -eq 'HyperV')
        {
            Mount-LWIsoImage -ComputerName $machine -IsoPath $IsoPath -PassThru:$PassThru
        }
        else
        {
            Mount-LWAzureIsoImage -ComputerName $machine -IsoPath $IsoPath -PassThru:$PassThru
        }
    }

    Write-LogFunctionExit
}
#endregion Mount-LabIsoImage

#region Dismount-LabIsoImage
function Dismount-LabIsoImage
{
    
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ComputerName,

        [switch]$SupressOutput
    )

    Write-LogFunctionEntry

    $machines = Get-LabVM -ComputerName $ComputerName
    if (-not $machines)
    {
        Write-LogFunctionExitWithError -Message 'The specified machines could not be found'
        return
    }
    if ($machines.Count -ne $ComputerName.Count)
    {
        $machinesNotFound = Compare-Object -ReferenceObject $ComputerName -DifferenceObject ($machines.Name)
        Write-ScreenInfo "The specified machine(s) $($machinesNotFound.InputObject -join ', ') could not be found" -Type Warning
    }
    $machines | Where-Object HostType -notin HyperV, Azure | ForEach-Object {
        Write-ScreenInfo "Using ISO images is only supported with Hyper-V VMs or on Azure. Skipping machine '$($_.Name)'" -Type Warning
    }

    $machines = $machines | Where-Object HostType -eq HyperV
    $azureMachines = $machines | Where-Object HostType -eq Azure

    if ($azureMachines)
    {
        Dismount-LWAzureIsoImage -ComputerName $azureMachines
    }

    foreach ($machine in $machines)
    {
        if (-not $SupressOutput)
        {
            Write-ScreenInfo -Message "Dismounting currently mounted ISO image on computer '$machine'." -Type Info
        }

        Dismount-LWIsoImage -ComputerName $machine
    }

    Write-LogFunctionExit
}
#endregion Dismount-LabIsoImage

#region Get / Set-LabVMUacStatus
function Set-VMUacStatus
{
    
    [Cmdletbinding()]
    param(
        [bool]$EnableLUA,

        [int]$ConsentPromptBehaviorAdmin,

        [int]$ConsentPromptBehaviorUser
    )

    $currentSettings = Get-VMUacStatus -ComputerName $ComputerName
    $uacStatusChanged = $false

    $registryPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $openRegistry = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, 'Default')

    $subkey = $openRegistry.OpenSubKey($registryPath,$true)

    if ($currentSettings.EnableLUA -ne $EnableLUA -and $PSBoundParameters.ContainsKey('EnableLUA'))
    {
        $subkey.SetValue('EnableLUA', [int]$EnableLUA)
        $uacStatusChanged = $true
    }

    if ($currentSettings.PromptBehaviorAdmin -ne $ConsentPromptBehaviorAdmin -and $PSBoundParameters.ContainsKey('ConsentPromptBehaviorAdmin'))
    {
        $subkey.SetValue('ConsentPromptBehaviorAdmin', $ConsentPromptBehaviorAdmin)
        $uacStatusChanged = $true
    }

    if ($currentSettings.PromptBehaviorUser -ne $ConsentPromptBehaviorUser -and $PSBoundParameters.ContainsKey('ConsentPromptBehaviorUser'))
    {
        $subkey.SetValue('ConsentPromptBehaviorUser', $ConsentPromptBehaviorUser)
        $uacStatusChanged = $true
    }

    return (New-Object psobject -Property @{ UacStatusChanged = $uacStatusChanged } )
}

function Get-VMUacStatus
{
    
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $registryPath = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $uacStatus = $false

    $openRegistry = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, 'Default')
    $subkey = $openRegistry.OpenSubKey($registryPath, $false)

    $uacStatus = $subkey.GetValue('EnableLUA')
    $consentPromptBehaviorUser = $subkey.GetValue('ConsentPromptBehaviorUser')
    $consentPromptBehaviorAdmin = $subkey.GetValue('ConsentPromptBehaviorAdmin')

    New-Object -TypeName PSObject -Property @{
        ComputerName = $ComputerName
        EnableLUA = $uacStatus
        PromptBehaviorUser = $consentPromptBehaviorUser
        PromptBehaviorAdmin = $consentPromptBehaviorAdmin
    }
}

function Set-LabVMUacStatus
{
    
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ComputerName,

        [bool]$EnableLUA,

        [int]$ConsentPromptBehaviorAdmin,

        [int]$ConsentPromptBehaviorUser,

        [switch]$PassThru
    )

    Write-LogFunctionEntry

    $machines = Get-LabVM -ComputerName $ComputerName

    if (-not $machines)
    {
        Write-Error 'The given machines could not be found'
        return
    }

    $functions = Get-Command -Name Get-VMUacStatus, Set-VMUacStatus, Sync-Parameter
    $variables = Get-Variable -Name PSBoundParameters
    $result = Invoke-LabCommand -ActivityName 'Set Uac Status' -ComputerName $machines -ScriptBlock {

        Sync-Parameter -Command (Get-Command -Name Set-VMUacStatus)
        Set-VMUacStatus @ALBoundParameters

    } -Function $functions -Variable $variables -PassThru

    if ($result.UacStatusChanged)
    {
        Write-ScreenInfo "The change requires a reboot of '$ComputerName'." -Type Warning
    }

    if ($PassThru)
    {
        Get-LabMachineUacStatus -ComputerName $ComputerName
    }

    Write-LogFunctionExit
}

function Get-LabVMUacStatus
{
    
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ComputerName
    )

    Write-LogFunctionEntry

    $machines = Get-LabVM -ComputerName $ComputerName

    if (-not $machines)
    {
        Write-Error 'The given machines could not be found'
        return
    }

    Invoke-LabCommand -ActivityName 'Get Uac Status' -ComputerName $machines -ScriptBlock {
        Get-VMUacStatus
    } -Function (Get-Command -Name Get-VMUacStatus) -PassThru

    Write-LogFunctionExit
}
#endregion Get / Set-LabVMUacStatus

#region Test-LabMachineInternetConnectivity
function Test-LabMachineInternetConnectivity
{
    
    [OutputType([bool])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [int]$Count = 3,

        [switch]$AsJob
    )

    $cmd = {
        $result = 1..$Count |
        ForEach-Object {
            Test-NetConnection www.microsoft.com -CommonTCPPort HTTP -InformationLevel Detailed -WarningAction SilentlyContinue
            Start-Sleep -Seconds 1
        }

        #if two results are positive, return the first positive result, if all are negative, return the first negative result
        if (($result.TcpTestSucceeded | Where-Object { $_ -eq $true }).Count -ge 2)
        {
            $result | Where-Object TcpTestSucceeded -eq $true | Select-Object -First 1
        }
        elseif (($result.TcpTestSucceeded | Where-Object { $_ -eq $false }).Count -eq 5)
        {
            $result | Where-Object TcpTestSucceeded -eq $false | Select-Object -First 1
        }
    }

    if ($AsJob)
    {
        $job = Invoke-LabCommand -ComputerName $ComputerName -ActivityName "Testing Internet Connectivity of '$ComputerName'" `
        -ScriptBlock $cmd -Variable (Get-Variable -Name Count) -PassThru -NoDisplay -AsJob

        return $job
    }
    else
    {
        $result = Invoke-LabCommand -ComputerName $ComputerName -ActivityName "Testing Internet Connectivity of '$ComputerName'" `
        -ScriptBlock $cmd -Variable (Get-Variable -Name Count) -PassThru -NoDisplay

        return $result.TcpTestSucceeded
    }
}
#endregion Test-LabMachineInternetConnectivity

#region Get-LabVM
function Get-LabVM
{
    
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([AutomatedLab.Machine])]
    param (
        [Parameter(Position = 0, ParameterSetName = 'ByName', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [Parameter(Mandatory, ParameterSetName = 'ByRole')]
        [AutomatedLab.Roles]$Role,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All,

        [switch]$IncludeLinux,

        [switch]$IsRunning,

        [Switch]$SkipConnectionInfo
    )

    begin
    {
        #required to suporess verbose messages, warnings and errors
        Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState

        Write-LogFunctionEntry

        $result = @()
        if (-not $script:data)
        {
            $script:data = Get-Lab
        }
    }

    process
    {
        if ($PSCmdlet.ParameterSetName -eq 'ByName')
        {
            if ($ComputerName)
            {
                foreach ($n in $ComputerName)
                {
                    $machine = $Script:data.Machines | Where-Object Name -in $n
                    if (-not $machine)
                    {
                        continue
                    }

                    $result += $machine
                }
            }
            else
            {
                $result = $Script:data.Machines
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByRole')
        {
            $result = $Script:data.Machines |
            Where-Object { $_.Roles.Name } |
            Where-Object { $_.Roles | Where-Object { $Role.HasFlag([AutomatedLab.Roles]$_.Name) } }

            if (-not $result)
            {
                return
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'All')
        {
            $result = $Script:data.Machines
        }

        # Skip Linux machines by default
        if (-not $IncludeLinux)
        {
            $result = $result | Where-Object -Property OperatingSystemType -eq Windows
        }
    }

    end
    {
        #Add Azure Connection Info
        $azureVMs = $Script:data.Machines | Where-Object { $_.HostType -eq 'Azure' -and -not $_.AzureConnectionInfo.DnsName }
        if ($azureVMs -and -not $SkipConnectionInfo.IsPresent)
        {
            $azureConnectionInfo = Get-LWAzureVMConnectionInfo -ComputerName $azureVMs

            if ($azureConnectionInfo)
            {
                foreach ($azureVM in $azureVMs)
                {
                    $azureVM | Add-Member -Name AzureConnectionInfo -MemberType NoteProperty -Value ($azureConnectionInfo | Where-Object ComputerName -eq $azureVM) -Force
                }
            }
        }

        if ($IsRunning)
        {
            if ($result.Count -eq 1)
            {
                if ((Get-LabVMStatus -ComputerName $result) -eq 'Started')
                {
                    $result
                }
            }
            else
            {
                $startedMachines = (Get-LabVMStatus -ComputerName $result).GetEnumerator() | Where-Object Value -eq 'Started'
                $Script:data.Machines | Where-Object { $_.Name -in $startedMachines.Name }
            }
        }
        else
        {
            $result
        }
    }
}
#endregion Get-LabVM

#region Enable-LabAutoLogon
function Enable-LabAutoLogon
{
    [CmdletBinding()]
    [Alias('Set-LabAutoLogon')]
    param
    (
        [Parameter()]
        [string[]]
        $ComputerName
    )

    Write-PSFMessage -Message "Enabling autologon on $($ComputerName.Count) machines"

    $Machines = Get-LabVm @PSBoundParameters

    foreach ( $Machine in $Machines)
    {
        $InvokeParameters = @{
            Username = $Machine.InstallationUser.UserName
            Password = $Machine.InstallationUser.Password
        }

        if ($Machine.IsDomainJoined -eq $true -and -not ($Machine.Roles.Name -contains 'RootDC' -or $Machine.Roles.Name -contains 'FirstChildDC' -or $Machine.Roles.Name -contains 'DC'))
        {
            $invokeParameters['DomainName'] = $Machine.DomainName
        }
        else
        {
            $invokeParameters['DomainName'] = $Machine.Name
        }

        Invoke-LabCommand -ActivityName "Enabling AutoLogon on $($Machine.Name)" -ComputerName $Machine.Name -ScriptBlock {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -Value 1 -Type String -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount -Value 9999 -Type DWORD -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultDomainName -Value $InvokeParameters.DomainName -Type String -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultUserName -Value $InvokeParameters.UserName -Type String -Force
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -Value $InvokeParameters.Password -Type String -Force
        } -Variable (Get-Variable InvokeParameters) -NoDisplay
    }
}
#endregion

#region Disable-LabAutoLogon
function Disable-LabAutoLogon
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]
        $ComputerName
    )

    Write-PSFMessage -Message "Disabling autologon on $($ComputerName.Count) machines"

    $Machines = Get-LabVm @PSBoundParameters

    Invoke-LabCommand -ActivityName "Disabling AutoLogon on $($ComputerName.Count) machines" -ComputerName $Machines -ScriptBlock {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -Value 0 -Type String -Force
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -Force -ErrorAction SilentlyContinue
    } -NoDisplay
}
#endregion

#region Test-LabAutoLogon
function Test-LabAutoLogon
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]
        $ComputerName
    )

    Write-PSFMessage -Message "Testing autologon on $($ComputerName.Count) machines"

    $Machines = Get-LabVM @PSBoundParameters
    $returnValues = @{}

    foreach ($Machine in $Machines)
    {
        $parameters = @{
            Username = $Machine.InstallationUser.UserName
            Password = $Machine.InstallationUser.Password
        }

        if ($Machine.IsDomainJoined -eq $true -and -not ($Machine.Roles.Name -contains 'RootDC' -or $Machine.Roles.Name -contains 'FirstChildDC' -or $Machine.Roles.Name -contains 'DC'))
        {
            $parameters['DomainName'] = $Machine.DomainName
        }
        else
        {
            $parameters['DomainName'] = $Machine.Name
        }

        $settings = Invoke-LabCommand -ActivityName "Testing AutoLogon on $($Machine.Name)" -ComputerName $Machine.Name -ScriptBlock {
            $values = @{}
            $values['AutoAdminLogon'] = try { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop).AutoAdminLogon } catch { }
            $values['DefaultDomainName'] = try { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop).DefaultDomainName } catch { }
            $values['DefaultUserName'] = try { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop).DefaultUserName } catch { }
            $values['DefaultPassword'] = try { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop).DefaultPassword } catch { }
            $values['LoggedOnUsers'] = (Get-WmiObject -Class Win32_LogonSession -Filter 'LogonType=2').GetRelationships('Win32_LoggedOnUser').Antecedent |
	                        ForEach-Object {
                            # For deprecated OS versions...
                            # Output is convoluted vs the CimInstance variant: \\.\root\cimv2:Win32_Account.Domain="contoso",Name="Install"
                            $null = $_ -match 'Domain="(?<Domain>\w+)",Name="(?<Name>\w+)"'
                            -join ($Matches.Domain, '\', $Matches.Name)
                        } | Select-Object -Unique

            $values
        } -PassThru -NoDisplay

        Write-PSFMessage -Message ('Encountered the following values on {0}:{1}' -f $Machine.Name, ($settings | Out-String))

        if ($settings.AutoAdminLogon -ne 1 -or
            $settings.DefaultDomainName -ne $parameters.DomainName -or
            $settings.DefaultUserName -ne $parameters.Username -or
        $settings.DefaultPassword -ne $parameters.Password)
        {
            $returnValues[$Machine.Name] = $false
            continue
        }

        $interactiveSessionUserName = '{0}\{1}' -f ($parameters.DomainName -split '\.')[0], $parameters.Username

        if ( $settings.LoggedOnUsers -notcontains $interactiveSessionUserName)
        {
            $returnValues[$Machine.Name] = $false
            continue
        }

        $returnValues[$Machine.Name] = $true
    }

    return $returnValues
}
#endregion Test-LabAutoLogon

#region Get-LabVMDotNetFrameworkVersion
function Get-LabVMDotNetFrameworkVersion
{
    
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ComputerName,

        [switch]$NoDisplay
    )

    Write-LogFunctionEntry

    $machines = Get-LabVM -ComputerName $ComputerName

    if (-not $machines)
    {
        Write-Error 'The given machines could not be found'
        return
    }

    Invoke-LabCommand -ActivityName 'Get .net Framework version' -ComputerName $machines -ScriptBlock {
        Get-DotNetFrameworkVersion
    } -Function (Get-Command -Name Get-DotNetFrameworkVersion) -PassThru -NoDisplay:$NoDisplay

    Write-LogFunctionExit
}
#endregion Get-LabVMDotNetFrameworkVersion

#region Checkpoint-LabVM
function Checkpoint-LabVM
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [string[]]$ComputerName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'All')]
        [string]$SnapshotName,

        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'All')]
        [switch]$All
    )

    Write-LogFunctionEntry

    if (-not (Get-LabVM))
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $lab = Get-Lab

    if ($ComputerName)
    {
        $machines = Get-LabVM -IncludeLinux | Where-Object { $_.Name -in $ComputerName }
    }
    else
    {
        $machines = Get-LabVm -IncludeLinux
    }

    if (-not $machines)
    {
        $message = 'No machine found to checkpoint. Either the given name is wrong or there is no machine defined yet'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    foreach ($machine in $machines)
    {
        $ip = (Get-HostEntry -Hostname $machine).IpAddress.IPAddressToString
        $sessions = Get-PSSession | Where-Object { $_.ComputerName -eq $ip }
        if ($sessions)
        {
            Write-PSFMessage "Removing $($sessions.Count) open sessions to the machine"
            $sessions | Remove-PSSession
        }
    }

    switch ($lab.DefaultVirtualizationEngine)
    {
        'HyperV' { Checkpoint-LWHypervVM -ComputerName $machines -SnapshotName $SnapshotName}
        'Azure'  { Checkpoint-LWAzureVM -ComputerName $machines -SnapshotName $SnapshotName}
        'VMWare' { Write-ScreenInfo -Type Error -Message 'Snapshotting VMWare VMs is not yet implemented'}
    }    

    Write-LogFunctionExit
}
#endregion Checkpoint-LabVM

#region Restore-LabVMSnapshot
function Restore-LabVMSnapshot
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [string[]]$ComputerName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'All')]
        [string]$SnapshotName,

        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'All')]
        [switch]$All
    )

    Write-LogFunctionEntry

    if (-not (Get-LabVM))
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $lab = Get-Lab

    if ($ComputerName)
    {
        $machines = Get-LabVM -IncludeLinux | Where-Object { $_.Name -in $ComputerName }
    }
    else
    {
        $machines = Get-LabVM -IncludeLinux
    }

    if (-not $machines)
    {
        $message = 'No machine found to restore the snapshot. Either the given name is wrong or there is no machine defined yet'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    foreach ($machine in $machines)
    {
        $ip = (Get-HostEntry -Hostname $machine).IpAddress.IPAddressToString
        $sessions = Get-PSSession | Where-Object { $_.ComputerName -eq $ip }
        if ($sessions)
        {
            Write-PSFMessage "Removing $($sessions.Count) open sessions to the machine '$machine'"
            $sessions | Remove-PSSession
        }
    }

    switch ($lab.DefaultVirtualizationEngine)
    {
        'HyperV' { Restore-LWHypervVMSnapshot -ComputerName $machines -SnapshotName $SnapshotName}
        'Azure'  { Restore-LWAzureVmSnapshot -ComputerName $machines -SnapshotName $SnapshotName}
        'VMWare' { Write-ScreenInfo -Type Error -Message 'Restoring snapshots of VMWare VMs is not yet implemented'}
    }

    Write-LogFunctionExit
}
#endregion Restore-LabVMSnapshot

#region Remove-LabVMSnapshot
function Remove-LabVMSnapshot
{
    
    [cmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByNameAllSnapShots')]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByNameSnapshotByName')]
        [string[]]$ComputerName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByNameSnapshotByName')]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'AllMachinesSnapshotByName')]
        [string]$SnapshotName,

        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'AllMachinesSnapshotByName')]
        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'AllMachinesAllSnapshots')]
        [switch]$AllMachines,

        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'ByNameAllSnapShots')]
        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'AllMachinesAllSnapshots')]
        [switch]$AllSnapShots
    )

    Write-LogFunctionEntry

    if (-not (Get-LabVM))
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $lab = Get-Lab

    if ($ComputerName)
    {
        $machines = Get-LabVM -IncludeLinux | Where-Object { $_.Name -in $ComputerName }
    }
    else
    {
        $machines = Get-LabVm -IncludeLinux
    }

    if (-not $machines)
    {
        $message = 'No machine found to remove the snapshot. Either the given name is wrong or there is no machine defined yet'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    $parameters = @{
        ComputerName = $machines
    }
    
    if ($SnapshotName)
    {
        $parameters.SnapshotName = $SnapshotName
    }
    elseif ($AllSnapShots)
    {
        $parameters.All = $true
    }

    switch ($lab.DefaultVirtualizationEngine)
    {
        'HyperV' { Remove-LWHypervVMSnapshot @parameters}
        'Azure'  { Remove-LWAzureVmSnapshot @parameters}
        'VMWare' { Write-ScreenInfo -Type Warning -Message 'No VMWare snapshots possible, nothing will be removed'}
    }

    Write-LogFunctionExit
}
#endregion Remove-LabVMSnapshot

#region Get-LabVmSnapshot
function Get-LabVMSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]
        $ComputerName,

        [Parameter()]
        [string]
        $SnapshotName
    )

    Write-LogFunctionEntry

    if (-not (Get-LabVM))
    {
        Write-Error 'No machine definitions imported, so there is nothing to do. Please use Import-Lab first'
        return
    }

    $lab = Get-Lab

    if ($ComputerName)
    {
        $machines = Get-LabVM -IncludeLinux | Where-Object -Property Name -in $ComputerName
    }
    else
    {
        $machines = Get-LabVm -IncludeLinux
    }

    if (-not $machines)
    {
        $message = 'No machine found to remove the snapshot. Either the given name is wrong or there is no machine defined yet'
        Write-LogFunctionExitWithError -Message $message
        return
    }

    $parameters = @{
        VMName = $machines
        ErrorAction = 'SilentlyContinue'
    }
    
    if ($SnapshotName)
    {
        $parameters.Name = $SnapshotName
    }

    switch ($lab.DefaultVirtualizationEngine)
    {
        'HyperV' { Get-LWHypervVMSnapshot @parameters}
        'Azure'  { Get-LWAzureVmSnapshot @parameters}
        'VMWare' { Write-ScreenInfo -Type Warning -Message 'No VMWare snapshots possible, nothing will be listed'}
    }

    Write-LogFunctionExit
}
#endregion
