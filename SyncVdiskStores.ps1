Function SyncPVSStores {
    <#
        .Synopsis
            Syncronises the Vdisk stores on the E drives of the PVS servers

        Get Target Vdisk store
        Get Destination Vdisk store
        Sync with Bits excluding lock files.

    #>

    Import-Module BitsTransfer
    
    


    $sourceDir = "E:\vDisks"
    $destDir = "\\<servername>\e$\vDisks"
    Set-Location -Path <storeLocation>:\vDisks
    #Getting file lists
    $sourceFiles = Get-ChildItem $sourceDir
    $destFiles = Get-ChildItem $destDir
    #Comparing file lists
    $files = Compare-Object $sourceFiles $destFiles | Where-Object {$_.InputObject -notlike "*.lok"}
    if ($files) {
        #Processing files
        $files | % {
            if ($_.SideIndicator -eq "<=") {
                Write-Host "Copying $($_.InputObject) from <Server1> to <Server2>"
                Start-BitsTransfer -DisplayName $_.InputObject -Source $sourceDir\$($_.InputObject) -Destination $destDir -Asynchronous -TransferType Upload
            }
            if ($_.SideIndicator -eq "=>") {
                Write-Host "Copying $($_.InputObject) from <Server2> to <Server1>"
                Start-BitsTransfer -DisplayName $_.InputObject -Source $destDir\$($_.InputObject) -Destination $sourceDir -Asynchronous
            }
        }

        $bitsJobs = Get-BitsTransfer
        foreach ($bitsJob in $bitsJobs) {
            while ($bitsJob.JobState -eq “Transferring” -or $bitsJob.JobState -eq "Connecting") {
                $pctComplete = [int](($bitsJob.BytesTransferred * 100)/$bitsJob.BytesTotal)            
                write-progress -activity “File Transfer in Progress” -status “% Complete: $pctComplete” -percentcomplete $pctComplete
                sleep 5
            }
            Start-Sleep -Seconds 1
            Complete-BitsTransfer $bitsJob
        }
    } else {
        Write-Host "Vdisk stores are synced" -ForegroundColor Green
        Start-Sleep -Seconds 5
    }
}

SyncPVSStores

