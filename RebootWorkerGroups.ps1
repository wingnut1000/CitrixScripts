Function RebootWorkerGroups {
<#
      .SYNOPSIS
        Reboots Xenapp servers within worker groups on a XenApp 6.5 farm.
    
    .DESCRIPTION
        Creates background jobs for each worker group in XenApp farm and runs them concurrently.
        For each worker group, script evaluates how many servers are alive and able to take users.
        Script will place servers in maintenance mode with the option "Prevent logons and reconnections until server reboot."
        Script will then check the servers every 15 minutes (by default) and re-evaluate their status.
        Once all users have vacated the server, it is rebooted and placed back into circulation.
        It is recommended that all servers in each worker group have logons set to either "Allow logons and reconnections" or "Prevent logons and reconnections until server reboot." before running this script.
        Reference the "RebootWorkerGroup" function for more details on actions preformed on each worker group.
    
    .PARAMETER wgNames
        A list of worker group names to reboot
        By default all worker groups are targeted.
    
    .PARAMETER excludeWorkerGroups
        A list of worker group names to exclude.
        You may not use this in conjunction with the wgNames parameter.
    
    .PARAMETER schTask
        Switch will disable the user confirmation prompt to enable script to be run as scheduled task without interruption
    
    .PARAMETER availableServers
        Specifies the number of servers to remain available in each worker group.
        By default if not specified, half the worker group will remain available.
    
    .PARAMETER loopDelay
        Specifies the number of seconds between delaying each loop
        Defaults to 900 seconds (15 minutes)
    
    .PARAMETER logFile
        Specifies directory of log file
        Defaults to directory where script is initialized in "Log.txt"
    
    .PARAMETER rebootComment
        Specifies optional reboot comment to supply when rebooting servers
    
    .EXAMPLE
        CitrixServerMaintenance -schTask
    
    .EXAMPLE
        CitrixServerMaintenance -excludeWorkerGroups "Production Worker Group"
    
    .EXAMPLE
        CitrixServerMaintenance -wgNames "Non Production Worker Group" -loopDelay 1800 -logFile "\\FolderShare\LogDirectory\CitrixRebootLogs.txt" -rebootComment "Rebooting server for scheduled maintenance"
    
    .LINKS
        https://github.com/caseygill03/CitrixScripts

    .NOTES
        Ensure this is run from a Zone Data Collector within the XenApp farm you wish to manage.
        This must be run with an account with the appropriate permissions to preform maintenance on the worker groups.
        Also, I am not responsible for breaking anything.  Test in a lab before implementing.
#>

    param (
        [Parameter(Mandatory=$false,ValueFromPipeline=$True)][array]$wgNames,
        [Parameter(Mandatory=$false)][array]$excludeWorkerGroups,
        [Parameter(Mandatory=$false)][switch]$schTask,
        [Parameter(Mandatory=$false)][int]$availableServers,
        [Parameter(Mandatory=$false)][int]$loopDelay=900,
        [Parameter(Mandatory=$false)][string]$logFile = ".\Log.txt",
        [Parameter(Mandatory=$false)][string]$rebootComment
    )

    BEGIN {
        $functions = {
            #These functions are passes to each job in charge of rebooting a worker group

            Function RebootServer($serverName, [string]$rebootComment) {
            <#
                .DESCRIPTION
                    Reboots designated server with optional reboot comment
                    Logs and writes to console

                .PARAMETER serverName
                    Name or IP address of target server

                .PARAMETER rebootComment
                    Optional reboot comment to supply when rebooting server
            #>
		        Log "Rebooting $serverName" -verbose
                if (!$rebootComment){
                    shutdown /r /f /t 0 /m \\$serverName
                } else {
		            shutdown /r /f /t 0 /m \\$serverName /c $rebootComment
                }
            }

            Function ServerIsEmpty($serverName,[switch]$verbose) {
            <#
                .DESCRIPTION
                    Tests if a specified server is empty of active ICA sessions

                .PARAMETER serverName
                    Name or IP address of target server
                
                .PARAMETERS verbose
                    Logs and writes results to console
            #>
		        $sessions = Get-XASession -servername $serverName | Where-Object {$_.Protocol -eq "ICA" -and $_.State -eq "Active"}
		        if ($sessions.Count -gt 0) {
			        if ($verbos){Log "Server $serverName has active ICA sessions" -verbose}
			        return $false
		        } else {
                    if ($verbose){Log "Server $serverName has no active ICA sessions" -verbose}
			        return $true
		        }
            }

            Function ServerInMaintenance($serverName,[switch]$verbose) {
            <#
                .DESCRIPTION
                    Tests if server has logins disabled
                
                .PARAMETER serverName
                    Name or IP address of target server

                .PARAMETER verbose
                    Logs and writes results to console                    
            #>
                if (Get-XAServer -Name $serverName | Select -ExpandProperty LogOnsEnabled) {
			        if ($verbose){Log "$servername is not in maintenance mode" -verbose}
                    return $true
		        } else {
			        if ($verbose){Log "$servername is in maintenance mode" -verbose}
			        return $false
		        }
            }    

            Function ServerIsReadyToReboot($serverName) {
            <#
                .DESCRIPTION
                    Test the following conditions to determine if designated server is ready to be rebooted
                        1. The server has logins disabled
                        2. The server has no active ICA sessions
                        3. The server is pingable
                    Logs and writes results to console
                
                .PARAMETER serverName
                    Name or IP address of server to target
            #>
                if ((ServerInMaintenance $serverName -verbose) -and (ServerIsEmpty $serverName -verbose) -and (ServerIsAlive $serverName -verbose)) {
                    return $true
                } else {
                    return $false
                }
            }

            Function ServerIsAlive($serverName,[switch]$verbose) {
            <#
                .DESCRIPTION
                    Preforms a simple ping test to specified server
                
                .PARAMETER serverName
                    Name or IP address of target server

                .PARAMETER verbose
                    Will log and write to console results
            #>
                if (Test-Connection -BufferSize 16 -Count 1 -ComputerName $serverName -Quiet) {
                    if($verbose){Log "Server $serverName is pingable" -verbose}
                    return $true
                } else {
                    if($verbose){Log "Server $serverName is not pingable" -verbose}
                    return $false
                }
            }

            Function CheckWorkerGroupThreshold {
            <#
                .DESCRIPTION
                    Check if the worker group has enoughs servers avaliable and if they are pingable.

                .PARAMTER workerGroupName
                    Name of workergroup to check

                .Parameter availableServers
                    Allows user to set the number of servers to remain avaliable.
                    If not specified, half of the farm will remain avaliable.
            #>        
                param (
                    [Parameter(Mandatory=$true)][string]$workerGroupName,
                    [Parameter(Mandatory=$false)][int]$availableServers
                )      
        
                $serverObjects = Get-XAServer -WorkerGroupName $workerGroupName
        
                Switch ($availableServers) {
                    {$availableServers} {
                        if (($serverObjects | Where-Object {$_.LogOnsEnabled -eq $true} | Select ServerName -ExpandProperty ServerName | % {Test-Connection -BufferSize 16 -Count 1 -ComputerName  $_ -Quiet}).Count -gt $availableServers) {
                            return $true
                        } else {
                            return $false
                        }
                    }
                    default {                
                        if ($serverObjects.Count / 2 -lt ($serverObjects | Where-Object {$_.LogOnsEnabled -eq $true} | Select ServerName -ExpandProperty ServerName | % {Test-Connection -BufferSize 16 -Count 1 -ComputerName  $_ -Quiet}).Count) {
                            return $true
                        } else {
                            return $false
                        }
                    }
                }
            }

            Function Log([string]$message,[switch]$verbose,$color) {
            <#
                .SYNOPSIS
                    Logs to a text file in scripts running directory
    
                .PARAMETER message
                    Contents of log message
    
                .PARAMETER verbose
                    Writes message to console

                .PARAMETER color
                    Optional foreground color of message when writing to console
            #>
                if ($verbose) {
                    if ($color) {
                        Write-Host $message -ForegroundColor $color
                    } else {
                        Write-Host $message
                    }
                }    
                (Get-Date -Format [MM/dd/yyyy]H:mm:ss) + " - " + $message | Add-Content $logFile
            }

            Function RebootWorkerGroup  {
                <#
	                .SYNOPSIS
		                Reboots designated worker group

	                .DESCRIPTION
                        This is the main function that handles rebooting a worker group.
                        The following conditions must be met in order for a server to be rebooted.
                            1. The server must not have logins enabled
                            2. The server must have no active ICA sessions
                            3. The server must be pingable
                            
                        If the conditions are not met the script will call the CheckWorkerGroupThreshold function to determine if there
                        are enough availalbe server in the worker group to disable logins for the designated server.
                        Once all conditions are met the server is rebooted and placed back into circulation.
                            
                    .PARAMETER workerGroupName
                        Name of target worker group to reboot

                    .PARAMETER loopDelay
                        Specifies the number of seconds between delaying each loop

                    .PARAMETER availableServers
                        Specifies the number of servers to remain available in each worker group.  If not specified, half the worker group will remain available.
    
                    .PARAMETER logFile
                        Specifies directory of log file, default will log to directory where script is initialized in "Log.txt"
                #>

                param (
                    [Paramater(Mandatory=$true)][string]$workerGroupName,
                    [Paramater(Mandatory=$true)][int]$loopDelay,
                    [Parameter(Mandatory=$true)][int]$availableServers,
                    [Paramater(Mandatory=$true)][string]$logFile,
                    [Paramater(Mandatory=$false)][string]$rebootComment
                )

                Log "Beginning reboot on $workerGroupName" -verbose

                Write-Host "Importing Citrix Snappin..."
                ASNP Citrix.*

                #Get list of servers to reboot
                $needToReboot = Get-XAWorkerGroup -Name $workerGroupName | Select ServerNames -ExpandProperty ServerNames
                if (!$needToReboot) {
                    Log "An error occured when attempting to communicate with the worker group, aborting..." -verbose -color red
                    return
                }
                $hasRebooted = @()
                $skippedServers = @()

                #Check if servers are pingable, skip those that are not
                foreach ($serverName in $needToReboot) {
                    if (ServerIsAlive $serverName){}else{
                        Log "$serverName is not pingable, skipping" -verbose -color Red
                        $needToReboot = $needToReboot | Where-Object {$_ -ne $serverName}
                        $skippedServers += $serverName
                    }
                }

                #Main work loop
                $i = 0
                do {
                    #loop delay
                    if ($i -gt 0) {
                        #Loop has run more then once, delay script
                        Log "Waiting $loopDelay seconds for resources to become available..." -verbose
		                Log "Next cycle begins at $((Get-Date).AddSeconds($loopDelay).Tostring('[MM/dd/yyyy]H:mm:ss'))" -verbose
                        Start-Sleep -Seconds $loopDelay
                    } else {$i ++}

                    foreach ($serverName in $needToReboot) {            
                        if (ServerIsReadyToReboot $serverName) {
                            Log "Server $serverName is ready to reboot" -verbose
                            RebootServer $serverName $rebootComment
                            $needToReboot = $needToReboot | Where-Object {$_ -ne $serverName}
                            $hasRebooted += $serverName
                        } else {
                            #check maintenance threshold
                            if (CheckWorkerGroupThreshold $workerGroupName -availableServers $availableServers) {
                                Log "Enough servers are avaliable in $workerGroupName to disable logins on server $serverName" -verbose
                                if (ServerInMaintenance $serverName) {
                                    #take no action, move to next server
                                    Log "$serverName taking no action..." -verbose
                                    continue
                                } else {
                                    Log "Enabling maintenance mode on $serverName" -verbose
                                    Set-XAServerLogOnMode -LogOnMode ProhibitNewLogOnsUntilRestart -ServerName $serverName
                                }
                            } else {
                                Log "Not enough servers are avaliable in $workerGroupName to disable logins on server $serverName" -verbose
                            }
                        }
                    }
                } while ($needToReboot)

                #All servers have been rebooted outputing results
                Write-Host ""
                Log "Worker Group $workerGroupName reboot has completed" -verbose -color Green
                Log "Servers that rebooted: $hasRebooted" -verbose
                Write-Host ""
                if ($skippedServers) {
                    Log "Servers that were skipped: $skippedServers" -verbose -Color Yellow
                    Write-Host ""
                }
                return
            }
    
            Function PromptUser{
            <#
                .DESCRIPTION
                    Prompts the user with a window warning that running this script will reboot the farm
                    Requires user to click "Yes" to continue
                    Do call this function if script is running as a sheduled task!!!
            #>
                $title = "Server maintenance"
                $message = "Warning, this script will perform maintenance on the Production Xenapp Farm.  Servers will be place into maintenance mode and once users have vacated them they will be rebooted.  Half of each worker group will remain available, please monitor each worker group load closely." 
                $a = new-object -comobject wscript.shell 
                $intAnswer = $a.popup($message,0,$title,4) 
                if ($intAnswer -eq 6) { 
                    #answer is yes
                    return
                } else { 
                    #answer is no
                    exit
                }
            }
        }
        
        #Prompt user is not running as scheduled task
        if (!$schTask) {PromptUser}

        #Determine worker group names to target if none were provided
        if (!$wgNames) {        
            if ($excludeWorkerGroups) {
                #Retrieve list of all avaliable worker groups with exclusions
                $wgNames =  Get-XAWorkerGroup | Select -ExpandProperty WorkerGroupName | %{ if ($excludeWorkerGroups -notcontains $_) {$_}}
            } else {
                #Retrieve list of all avaliable worker groups
                $wgNames = Get-XAWorkerGroup | Select -ExpandProperty WorkerGroupName
            }
        }

    }

    PROCESS{        
        
        #Start jobs for each worker group
        foreach ($wgName in $wgNames) {
            Start-Job -Name $wgName -InitializationScript $functions -ScriptBlock {RebootWorkerGroup -wgName $args[0] -loopDelay $args[1] -availableServers $args[2] -logFile $args[3] -rebootComment $args[4]} -ArgumentList $wgName,$loopDelay,$availableServers,$logFile,$rebootComment | Out-Null
        }

        #Loop until all jobs are complete
        Do {
                Receive-Job *
                Start-Sleep -Seconds 5
           }
        while (Get-Job * | Where-Object {$_.State -eq "Running"})
    }

    END {}
}
