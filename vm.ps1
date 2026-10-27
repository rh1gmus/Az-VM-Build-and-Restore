<#PSScriptInfo
.VERSION 2.0.0
.GUID 7b3bc5e9-3b41-4b9e-a3a5-1e79d7f7f0af
.AUTHOR Rob + Geoffrey
.DESCRIPTION
    Rebuild a VM from a snapshot (Build) or preserve a VM to snapshot then delete its VM/NIC/PIP/OS disk (Clean),
    using Az.* cmdlets and metadata-driven discovery so "VM name only" is enough in most cases.
#>

<#
.SYNOPSIS
Build a VM from a snapshot or Clean a VM into a snapshot (then delete VM, NICs, PIPs, OS disk).

.DESCRIPTION
- CLEAN:
    1) Locates the VM by name (optionally by resource group/subscription).
    2) Captures a timestamped snapshot of the OS disk.
    3) Writes tags onto the snapshot so future BUILD can rehydrate from *VM name alone*:
         - sourceVM, subnetId, osType, diskSku, vmSize, location, sourceResourceGroup, createdUtc
    4) Deletes the VM object, all attached NICs, any associated Public IPs, and the OS disk.
       (Leaves VNets/subnets/NSGs/RGs untouched.)

- BUILD:
    1) Finds a snapshot by tag sourceVM = <VMName> (or by -SnapshotId).
    2) Recreates managed OS disk from snapshot (same SKU if tagged).
    3) Creates a NIC on the recorded subnet (or -SubnetId override).
    4) Optionally creates a Public IP (default) unless -NoPublicIP.
    5) Creates the VM using the recorded OS type and size (or overrides).

The script refuses to modify VNets, subnets, NSGs or resource groups.

.PARAMETER Action
"Build" or "Clean"

.PARAMETER VMName
The virtual machine name (unique per resource group).

.PARAMETER SubscriptionId
Optional. If omitted, tries to infer from VM (Clean) or from snapshot (Build).
Falls back to current Az context.

.PARAMETER ResourceGroup
Optional. If omitted, Clean discovers from the VM; Build uses the snapshot RG by default.

.PARAMETER Location
Optional. If omitted, Clean uses VM.Location; Build uses snapshot.Location.

.PARAMETER SnapshotId
Optional. BUILD only. If provided, use this snapshot; otherwise discover latest snapshot
with tag sourceVM = VMName.

.PARAMETER SubnetId
Optional. BUILD only. If omitted, uses the 'subnetId' tag on the snapshot. If neither is available, throws.

.PARAMETER VmSize
Optional. BUILD only. Overrides size recorded on snapshot tag 'vmSize'.

.PARAMETER DiskSku
Optional. BUILD only. Overrides disk SKU recorded on snapshot tag 'diskSku'. (e.g. Premium_LRS, StandardSSD_LRS)

.PARAMETER NoPublicIP
Optional. BUILD only. If set, no Public IP will be created/attached.

.PARAMETER OsType
Optional. BUILD only. If omitted, uses the snapshot's OsType property or 'osType' tag. Must be 'Windows' or 'Linux'.

.EXAMPLE
# Preserve a VM to snapshot and delete its VM/NIC/PIP/OS disk:
./vm.ps1 -Action Clean -VMName deb12-1

.EXAMPLE
# Rebuild a VM using only its name (uses snapshot tags from Clean):
./vm.ps1 -Action Build -VMName deb12-1

.EXAMPLE
# Build from a specific snapshot and override size, no public IP:
./vm.ps1 -Action Build -VMName deb12-1 -SnapshotId "/subscriptions/xxx/.../snapshots/deb12-1-20251003-153012" -VmSize Standard_B2ms -NoPublicIP -OsType Linux

.NOTES
Requires Az PowerShell (Cloud Shell is fine).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Build','Clean')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,

    # BUILD-only helpers
    [ValidateSet('Windows','Linux')]
    [string]$OsType,
    [string]$SnapshotId,
    [string]$SubnetId,
    [string]$VmSize,
    [string]$DiskSku,
    [string]$PrivateIpAddress,
    [switch]$NoPublicIP,

    # CLEAN-only helper
    [ValidateSet('Standard_LRS','Premium_LRS','Standard_ZRS','Premium_ZRS')]
    [string]$SnapshotSku
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function WriteLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level='INFO')
    $ts = (Get-Date).ToString('u')
    Write-Host "[$ts][$Level] $Message"
}

function UseSubscription {
    param([string]$SubId)
    if ($SubId) {
        WriteLog "Setting Az context: $SubId"
        Set-AzContext -SubscriptionId $SubId | Out-Null
    }
}

function GetLatestSnapshotForVM {
    param(
        [string]$VmName
    )
    # Look for snapshots tagged with sourceVM = $VMName; choose the newest by TimeCreated.
    $snaps = Get-AzSnapshot -ErrorAction SilentlyContinue | Where-Object {
        $_.Tags.ContainsKey('sourceVM') -and $_.Tags['sourceVM'] -eq $VmName
    }
    if (-not $snaps) { return $null }
    $snaps | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1
}

function GetVMExact {
    param(
        [string]$VmName,
        [string]$Rg
    )
    if ($Rg) {
        # Exact match when RG is known
        return Get-AzVM -Name $VmName -ResourceGroupName $Rg -Status -ErrorAction Stop
    } else {
        # Wrap in array so .Count is always valid even for 0/1 results
        $all = @( Get-AzVM -Status | Where-Object { $_.Name -eq $VmName } )

        switch ($all.Count) {
            0       { return $null }
            1       { return $all[0] }
            default { throw "Multiple VMs named '$VmName' found in the subscription. Please specify -ResourceGroup." }
        }
    }
}

function NewOsDiskFromSnapshot {
    param(
        [Microsoft.Azure.Commands.Compute.Automation.Models.PSSnapshot]$Snapshot,
        [string]$DiskName,
        [string]$DiskSku,
        [string]$Location,
        [string]$ResourceGroup,
        [string]$OsType
    )
    $skuToUse = if ($DiskSku) { $DiskSku }
                elseif ($Snapshot.Tags -and $Snapshot.Tags['diskSku']) { $Snapshot.Tags['diskSku'] }
                else { 'Premium_LRS' }

    $conf = New-AzDiskConfig -Location $Location -SkuName $skuToUse -CreateOption Copy -SourceResourceId $Snapshot.Id -OsType $OsType
    New-AzDisk -ResourceGroupName $ResourceGroup -DiskName $DiskName -Disk $conf
}

function ResolveSnapshotSku {
    param(
        [string]$DiskSkuName,
        [string]$Override
    )
    # Disks and Snapshots have different valid SKU sets. Snapshots generally only
    # support Standard_LRS, Premium_LRS, Standard_ZRS, Premium_ZRS (availability
    # varies by region). Map the disk's SKU down to a snapshot-safe equivalent
    # unless the caller explicitly overrides it with -SnapshotSku.
    if ($Override) { return $Override }

    switch -Regex ($DiskSkuName) {
        '^Premium_ZRS$'                                  { return 'Premium_ZRS' }
        '^(Premium_LRS|PremiumV2_LRS|UltraSSD_LRS)$'      { return 'Premium_LRS' }
        '^(StandardSSD_ZRS)$'                             { return 'Standard_ZRS' }
        default                                           { return 'Standard_LRS' }
    }
}

function NewOptionalPublicIP {
    param(
        [string]$PipName,
        [string]$ResourceGroup,
        [string]$Location
    )
    New-AzPublicIpAddress -Name $PipName -ResourceGroupName $ResourceGroup -Location $Location -AllocationMethod Static -Sku Standard
}

function NewPrimaryNic {
    param(
        [string]$NicName, [string]$ResourceGroup, [string]$Location,
        [string]$SubnetId, [string]$PipId, [string]$PrivateIp
    )
    $p = @{
        Name              = $NicName
        ResourceGroupName = $ResourceGroup
        Location          = $Location
        SubnetId          = $SubnetId
    }
    if ($PipId)     { $p.PublicIpAddressId = $PipId }
    if ($PrivateIp) { $p.PrivateIpAddress  = $PrivateIp }   # implies Static allocation
    New-AzNetworkInterface @p
}

function BuildFromSnapshot {
    # 1) Find snapshot (by ID or by tag sourceVM)
    # 2) Resolve subscription/RG/location from snapshot by default
    # 3) Recreate OS disk, NIC (+/- PIP), VM
    if ($SnapshotId) {
        $snapshot = Get-AzResource -ResourceId $SnapshotId -ExpandProperties -ErrorAction Stop | ForEach-Object {
            Get-AzSnapshot -ResourceGroupName $_.ResourceGroupName -SnapshotName $_.Name
        }
    } else {
        $snapshot = GetLatestSnapshotForVM -VmName $VMName
        if (-not $snapshot) {
            throw "No snapshot found with tag 'sourceVM=$VMName'. Supply -SnapshotId or run Clean first."
        }
    }

    # Use subscription if provided; else try to switch to the snapshot's subscription
    if (-not $SubscriptionId) {
        # Extract sub from snapshot.Id: /subscriptions/<sub>/...
        if ($snapshot.Id -match '/subscriptions/([^/]+)/') {
            $SubscriptionId = $Matches[1]
        }
    }
    UseSubscription -SubId $SubscriptionId

    $rgToUse  = if ($ResourceGroup) { $ResourceGroup } else { $snapshot.ResourceGroupName }
    $locToUse = if ($Location)      { $Location }      else { $snapshot.Location }

    # Subnet selection
    $subnetToUse = $SubnetId
    if (-not $subnetToUse) {
        if ($snapshot.Tags.ContainsKey('subnetId') -and $snapshot.Tags['subnetId']) {
            $subnetToUse = $snapshot.Tags['subnetId']
        } else {
            throw "Subnet not specified. Provide -SubnetId or ensure the snapshot has tag 'subnetId'."
        }
    }

    $osTypeToUse = if ($OsType) { $OsType }
                   elseif ($snapshot.OsType) { "$($snapshot.OsType)" }
                   elseif ($snapshot.Tags -and $snapshot.Tags['osType']) { $snapshot.Tags['osType'] }
                   else { throw "Cannot determine OS type for snapshot '$($snapshot.Name)'. Pass -OsType Windows|Linux." }
    WriteLog "OS type: $osTypeToUse"
    
    # Static private IP: explicit override wins; else reuse tag if the original was Static
    $ipToUse = $PrivateIpAddress
    if (-not $ipToUse -and $snapshot.Tags.ContainsKey('privateIp') -and
        $snapshot.Tags['privateIpMethod'] -eq 'Static') {
        $ipToUse = $snapshot.Tags['privateIp']
    }

    if ($ipToUse) {
        # subnetId: /subscriptions/<s>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<sn>
        if ($subnetToUse -notmatch '/resourceGroups/([^/]+)/providers/Microsoft\.Network/virtualNetworks/([^/]+)/subnets/') {
            throw "Cannot parse VNet from subnet ID '$subnetToUse'."
        }
        $vnetRg, $vnetName = $Matches[1], $Matches[2]
        $avail = Test-AzPrivateIPAddressAvailability -ResourceGroupName $vnetRg -VirtualNetworkName $vnetName -IPAddress $ipToUse
        if (-not $avail.Available) {
            throw "Private IP $ipToUse is not available in VNet '$vnetName'. Suggestions: $($avail.AvailableIPAddresses -join ', ')"
        }
        WriteLog "Will assign static private IP $ipToUse"
    }

    # Names
    $diskName = "$VMName-osdisk"
    $nicName  = "$VMName-nic"
    $pipName  = "$VMName-pip"

    # Guard rails: do not overwrite existing instance
    if (Get-AzVM -ResourceGroupName $rgToUse -Name $VMName -ErrorAction SilentlyContinue) {
        throw "VM '$VMName' already exists in RG '$rgToUse'. Aborting BUILD."
    }
    if (Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgToUse -ErrorAction SilentlyContinue) {
        throw "NIC '$nicName' already exists in RG '$rgToUse'. Aborting BUILD."
    }
    if ((-not $NoPublicIP) -and (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $rgToUse -ErrorAction SilentlyContinue)) {
        throw "Public IP '$pipName' already exists in RG '$rgToUse'. Aborting BUILD."
    }
    if (Get-AzDisk -Name $diskName -ResourceGroupName $rgToUse -ErrorAction SilentlyContinue) {
        throw "OS Disk '$diskName' already exists in RG '$rgToUse'. Aborting BUILD."
    }

    WriteLog "Creating OS disk from snapshot '$($snapshot.Name)' in $rgToUse/$locToUse"
    $disk = NewOsDiskFromSnapshot -Snapshot $snapshot -DiskName $diskName -DiskSku $DiskSku -Location $locToUse -ResourceGroup $rgToUse -OsType $osTypeToUse

    $pip = $null
    if (-not $NoPublicIP) {
        WriteLog "Creating Public IP '$pipName'"
        $pip = NewOptionalPublicIP -PipName $pipName -ResourceGroup $rgToUse -Location $locToUse
    }

    WriteLog "Creating NIC '$nicName' on subnet '$subnetToUse'"
    $pipId = if ($pip) { $pip.Id } else { $null }
    $nic = NewPrimaryNic -NicName $nicName -ResourceGroup $rgToUse -Location $locToUse -SubnetId $subnetToUse -PipId $pipId -PrivateIp $ipToUse

    $osType = if ($snapshot.OsType) { $snapshot.OsType } elseif ($snapshot.Tags['osType']) { $snapshot.Tags['osType'] } else { 'Linux' }
    $vmSizeToUse = if ($VmSize) {
        $VmSize
    } elseif ($snapshot.Tags -and $snapshot.Tags['vmSize']) {
        $snapshot.Tags['vmSize']
    } else {
        'Standard_B2ms'
    }

    WriteLog "Creating VM '$VMName' (Size=$vmSizeToUse, OS=$osTypeToUse)"
    $vmCfg = New-AzVMConfig -VMName $VMName -VMSize $vmSizeToUse
    if ($osTypeToUse -eq 'Windows') {
        $vmCfg = Set-AzVMOSDisk -VM $vmCfg -ManagedDiskId $disk.Id -CreateOption Attach -Windows
    } else {
        $vmCfg = Set-AzVMOSDisk -VM $vmCfg -ManagedDiskId $disk.Id -CreateOption Attach -Linux
    }
    $vmCfg = Add-AzVMNetworkInterface -VM $vmCfg -Id $nic.Id
    $vmCfg = Set-AzVMBootDiagnostic -VM $vmCfg -Enable

    New-AzVM -ResourceGroupName $rgToUse -Location $locToUse -VM $vmCfg | Out-Null
    WriteLog "BUILD complete for '$VMName'"
}

function CleanAndSnapshot {
    # 1) Identify VM and resolve context
    $vm = GetVMExact -VmName $VMName -Rg $ResourceGroup
    if (-not $vm) { throw "VM '$VMName' not found." }

    # Adopt subscription and location from VM if not specified
    if (-not $SubscriptionId) {
        if ($vm.Id -match '/subscriptions/([^/]+)/') { $SubscriptionId = $Matches[1] }
    }
    UseSubscription -SubId $SubscriptionId

    $rgToUse  = if ($ResourceGroup) { $ResourceGroup } else { $vm.ResourceGroupName }
    $locToUse = if ($Location)      { $Location }      else { $vm.Location }

    WriteLog "Deallocating VM '$VMName'"
    Stop-AzVM -Name $VMName -ResourceGroupName $rgToUse -Force -NoWait:$false | Out-Null

    # Collect hardware: NICs, PIPs, OS disk, subnet
    $vmFull = Get-AzVM -Name $VMName -ResourceGroupName $rgToUse
    $osDiskId = $vmFull.StorageProfile.OsDisk.ManagedDisk.Id

    $nicIds = @()
    $pipIds = @()
    $privateIpUsed   = $null
    $privateIpMethod = $null
    $subnetIdUsed = $null

    foreach ($nicRef in $vmFull.NetworkProfile.NetworkInterfaces) {
        $nicObj = Get-AzNetworkInterface -ResourceGroupName $rgToUse -Name (Split-Path $nicRef.Id -Leaf)
        $nicIds += $nicObj.Id
        if (-not $subnetIdUsed) { 
            $subnetIdUsed    = $nicObj.IpConfigurations[0].Subnet.Id
            $privateIpUsed   = $nicObj.IpConfigurations[0].PrivateIpAddress
            $privateIpMethod = $nicObj.IpConfigurations[0].PrivateIpAllocationMethod
        }
        foreach ($ipconf in $nicObj.IpConfigurations) {
            if ($ipconf.PublicIpAddress -and $ipconf.PublicIpAddress.Id) { $pipIds += $ipconf.PublicIpAddress.Id }
        }
    }

    $diskObj = Get-AzDisk -ResourceGroupName $rgToUse -DiskName (Split-Path $osDiskId -Leaf)

    # Build snapshot name and tag payload
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $snapName = "$VMName-$stamp"
    $tags = @{
        sourceVM            = $VMName
        subnetId            = $subnetIdUsed
        osType              = ($vmFull.StorageProfile.OsDisk.OsType.ToString())
        diskSku             = $diskObj.Sku.Name
        vmSize              = $vmFull.HardwareProfile.VmSize
        location            = $locToUse
        sourceResourceGroup = $rgToUse
        privateIp           = $privateIpUsed
        privateIpMethod     = $privateIpMethod        
        createdUtc          = (Get-Date).ToUniversalTime().ToString('u')
    }

    WriteLog "Creating snapshot '$snapName' from OS disk"
    $snapshotSkuToUse = ResolveSnapshotSku -DiskSkuName $diskObj.Sku.Name -Override $SnapshotSku
    if ($snapshotSkuToUse -ne $diskObj.Sku.Name) {
        WriteLog "Disk SKU '$($diskObj.Sku.Name)' is not a valid Snapshot SKU; using '$snapshotSkuToUse' for the snapshot resource"
    }
    $snapConfig = New-AzSnapshotConfig -SourceResourceId $osDiskId -Location $locToUse -CreateOption Copy -SkuName $snapshotSkuToUse

    # Create the snapshot (no -Tag here for compatibility)
    $snapshot = New-AzSnapshot -Snapshot $snapConfig -SnapshotName $snapName -ResourceGroupName $rgToUse

    # Apply tags in a second step (works across Az versions)
    Update-AzTag -ResourceId $snapshot.Id -Tag $tags -Operation Merge | Out-Null

    # Re-read to ensure Tags are visible for subsequent logic
    $snapshot = Get-AzSnapshot -ResourceGroupName $rgToUse -SnapshotName $snapName

    # Remove VM first, then NICs, then PIPs, then OS disk (keep all VNets/subnets/NSGs/RGs)
    WriteLog "Deleting VM '$VMName'"
    Remove-AzVM -Name $VMName -ResourceGroupName $rgToUse -Force

    foreach ($nicId in $nicIds) {
        $nicName = (Split-Path $nicId -Leaf)
        WriteLog "Deleting NIC '$nicName'"
        Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $rgToUse -Force
    }

    foreach ($pipId in $pipIds | Select-Object -Unique) {
        $pipName = (Split-Path $pipId -Leaf)
        WriteLog "Deleting Public IP '$pipName'"
        Remove-AzPublicIpAddress -Name $pipName -ResourceGroupName $rgToUse -Force
    }

    WriteLog "Deleting OS Disk '$(Split-Path $osDiskId -Leaf)'"
    Remove-AzDisk -ResourceGroupName $rgToUse -DiskName (Split-Path $osDiskId -Leaf) -Force

    WriteLog "CLEAN complete. Snapshot '$($snapshot.Name)' is preserved in RG '$rgToUse'."
    $snapshot
}

# ----- Main switch -----
try {
    if ($Action -eq 'Clean') {
        CleanAndSnapshot | Out-Null
    } elseif ($Action -eq 'Build') {
        BuildFromSnapshot
    }
}
catch {
    WriteLog $_.Exception.Message 'ERROR'
    throw
}