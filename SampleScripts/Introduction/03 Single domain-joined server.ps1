#It does not get easier. These three lines install a lab with just one single Windows 10 machine.
#AL takes care about network settings like creating a virtual switch and fining a suitable IP range.

New-LabDefinition -Name 'Lab1' -DefaultVirtualizationEngine HyperV

Add-LabMachineDefinition -Name DC1 -Memory 1GB -OperatingSystem 'Windows Server 2012 R2 SERVERDATACENTER' -Roles RootDC -DomainName contoso.com
Add-LabMachineDefinition -Name Client1 -Memory 1GB -OperatingSystem 'Windows 10 Pro' -DomainName contoso.com

Install-Lab

Show-LabInstallationTime