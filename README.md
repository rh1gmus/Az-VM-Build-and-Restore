# Az-VM-Build-and-Restore

A PowerShell script for parking Azure VMs as snapshots and bringing them back later, using only the VM name in most cases.

- **Clean** snapshots a VM's OS disk, records everything needed to rebuild it as tags on the snapshot, then deletes the VM, its NICs, public IPs and OS disk.
- **Build** finds that snapshot and recreates the OS disk, NIC (optionally with a static private IP and/or public IP) and VM.

Useful for VMs that only need to exist occasionally (test boxes, seasonal workloads, lab machines) where you want to stop paying for compute and premium disks without losing the machine.

The script never creates, modifies or deletes VNets, subnets, NSGs or resource groups.

## Requirements

- PowerShell 7+ (Azure Cloud Shell works out of the box)
- Az PowerShell modules: `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources`
- An authenticated session (`Connect-AzAccount`) with rights to create and delete VMs, disks, snapshots, NICs and public IPs in the target resource group, and to join NICs to the target subnet

## How it works

### Clean

1. Locates the VM by name (searches the current subscription unless `-ResourceGroup` is given).
2. Deallocates the VM.
3. Snapshots the OS disk as `<VMName>-<yyyyMMdd-HHmmss>`. Disk SKUs that aren't valid for snapshots (StandardSSD, PremiumV2, Ultra) are mapped to the nearest snapshot SKU unless `-SnapshotSku` is given.
4. Tags the snapshot with the metadata Build needs (see [Snapshot tags](#snapshot-tags)).
5. Deletes the VM, all attached NICs, their public IPs, and the OS disk.

> ⚠️ Clean is destructive. Only the OS disk is preserved. **Data disks are not snapshotted** and are left attached-less in the resource group; handle them separately.

### Build

1. Uses `-SnapshotId` if given, otherwise the newest snapshot tagged `sourceVM = <VMName>`.
2. Resolves settings from parameters first, then snapshot tags, then defaults.
3. Validates the static private IP (if any) is free in the VNet before creating anything.
4. Refuses to continue if a VM, NIC, public IP or OS disk with the target names already exists.
5. Creates the OS disk (`<VMName>-osdisk`), optional public IP (`<VMName>-pip`, Standard SKU, static), NIC (`<VMName>-nic`) and VM.

## Usage

```powershell
# Park a VM: snapshot it and delete its compute/network/disk resources
./vm.ps1 -Action Clean -VMName deb12-1

# Bring it back using only the name (reads the snapshot's tags)
./vm.ps1 -Action Build -VMName deb12-1

# Bring it back without a public IP, on a fixed private address
./vm.ps1 -Action Build -VMName deb12-1 -NoPublicIP -PrivateIpAddress 10.10.1.20
```

### Building from a snapshot not made by Clean

Snapshots created manually or by other tools have no tags, so supply what the script can't discover. `-OsType` is required if the snapshot doesn't carry an OS type.

```powershell
$build = @{
    Action           = 'Build'
    VMName           = 'app-01-restore'
    ResourceGroup    = 'rg-apps'
    Location         = 'eastus'
    SnapshotId       = '/subscriptions/<sub>/resourceGroups/rg-apps/providers/Microsoft.Compute/snapshots/app-01-snap'
    SubnetId         = '/subscriptions/<sub>/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-east/subnets/apps'
    OsType           = 'Windows'
    VmSize           = 'Standard_D4s_v3'
    DiskSku          = 'Premium_LRS'
    PrivateIpAddress = '10.40.10.250'
}
./vm.ps1 @build -NoPublicIP
```

## Parameters

| Parameter | Applies to | Description |
|---|---|---|
| `-Action` | Both | **Required.** `Build` or `Clean`. |
| `-VMName` | Both | **Required.** VM name. For Build, also used to find the snapshot and to name the new disk, NIC and public IP. |
| `-SubscriptionId` | Both | Subscription to work in. Defaults to the VM's (Clean) or snapshot's (Build) subscription, otherwise the current Az context. |
| `-ResourceGroup` | Both | Clean: where the VM lives (discovered if omitted). Build: where new resources go (defaults to the snapshot's RG). |
| `-Location` | Both | Defaults to the VM's (Clean) or snapshot's (Build) region. |
| `-SnapshotId` | Build | Full resource ID of the snapshot to use. Otherwise the newest snapshot tagged `sourceVM = <VMName>`. |
| `-SubnetId` | Build | Full resource ID of the subnet for the NIC. Otherwise the `subnetId` tag. Build fails if neither is available. |
| `-OsType` | Build | `Windows` or `Linux`. Otherwise the snapshot's OS type, then the `osType` tag. Build fails rather than guess. |
| `-VmSize` | Build | Otherwise the `vmSize` tag, then `Standard_B2ms`. |
| `-DiskSku` | Build | OS disk SKU (e.g. `Premium_LRS`, `StandardSSD_LRS`). Otherwise the `diskSku` tag, then `Premium_LRS`. |
| `-PrivateIpAddress` | Build | Static private IPv4 for the NIC. Otherwise reuses the `privateIp` tag **only if** the original allocation was Static; else Azure assigns one dynamically. |
| `-NoPublicIP` | Build | Don't create a public IP. By default one is created. |
| `-SnapshotSku` | Clean | Force the snapshot SKU: `Standard_LRS`, `Premium_LRS`, `Standard_ZRS` or `Premium_ZRS`. |

## Snapshot tags

Written by Clean and read by Build:

| Tag | Source |
|---|---|
| `sourceVM` | VM name (how Build finds the snapshot) |
| `subnetId` | Subnet of the first NIC |
| `privateIp` / `privateIpMethod` | Private IP of the first NIC and whether it was `Static` or `Dynamic` |
| `osType` | OS disk OS type |
| `diskSku` | Original OS disk SKU (Build recreates the disk with this, even if the snapshot used a cheaper SKU) |
| `vmSize` | VM size |
| `location`, `sourceResourceGroup` | Where the VM lived |
| `createdUtc` | When the snapshot was taken |

You can edit these tags in the portal to change what the next Build does, e.g. move the VM to another subnet or resize it.

## Notes and limitations

- **Single NIC on rebuild.** Clean deletes all NICs, but Build recreates only one, using the first NIC's subnet and IP.
- **OS disk only.** Data disks, extensions, availability sets/zones, managed identities, tags on the VM and NSGs attached directly to the NIC are not recreated.
- **Static IPs.** Azure reserves a static private IP at the platform level; leave the guest OS on DHCP. Because Clean releases the IP, something else on the subnet can claim it in the meantime. Build checks availability first and suggests free addresses if it's taken.
- **Finding snapshots by name** searches the current Az context's subscription. If the snapshot lives elsewhere, run `Set-AzContext` first or pass `-SnapshotId`.
- **Failed builds are not rolled back.** If Build fails partway, delete the resources it created (`<VMName>-osdisk`, `<VMName>-nic`, `<VMName>-pip`) before rerunning, or the guard rails will stop it.
- **`-WhatIf` is not implemented**, despite the script declaring `SupportsShouldProcess`. Don't rely on it for a dry run.

## License

Add a license of your choice (e.g. MIT) before sharing the repo publicly.
