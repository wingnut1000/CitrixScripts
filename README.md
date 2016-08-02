# CitrixScripts
Repository for Citrix related scripts.

###RebootWorkerGroups.ps1
Contains the functions necessary to automate the reboot of worker groups in a XenApp 6.5 farm.  This script will reboot worker groups without interrupting end users.  The script disables logins on servers within a worker group and waits for users to bleed off.  Once there are no active ICA sessions, each server is rebooted.

####For more information:
```powershell
. .\RebootWorkerGroups.ps1
Get-Help RebootWorkerGroups -full
```


