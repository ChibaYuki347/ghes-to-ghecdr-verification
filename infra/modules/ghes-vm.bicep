// ghes-vm.bicep — GitHub Enterprise Server VM, closed (no public IP, no extensions)
targetScope = 'resourceGroup'

@description('Naming prefix')
param namingPrefix string

@description('Azure region')
param location string

@description('GHES subnet resource id (closed)')
param ghesSubnetId string

@description('Linux admin username for the VM (Azure provisioning user; NOT the GHES admin shell user which is `admin` on port 122)')
param adminUsername string = 'ghadmin'

@description('SSH public key (OpenSSH format)')
@secure()
param adminPublicKey string

@description('VM size — must be memory-optimized with Premium SSD support (s-suffix)')
param vmSize string = 'Standard_E4s_v5'

@description('GHES image version (e.g., 3.18.8)')
param ghesImageVersion string = '3.18.8'

@description('Data disk size in GB (>=150 recommended for trial)')
@minValue(150)
@maxValue(5000)
param dataDiskSizeGb int = 200

@description('Private DNS zone name (e.g., ghestest.internal)')
param privateDnsZoneName string

@description('Hostname (A record) inside the private DNS zone')
param ghesHostname string = 'ghes'

@description('Resource tags')
param tags object = {}

var vmName = 'vm-${namingPrefix}-ghes'

// ---------- NIC (closed: no public IP, no Accelerated Networking) ----------

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namingPrefix}-ghes'
  location: location
  tags: tags
  properties: {
    // GHES image does NOT support Accelerated Networking
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: ghesSubnetId
          }
        }
      }
    ]
  }
}

// ---------- GHES VM ----------
// IMPORTANT design constraints (per GitHub Docs):
//   * No securityProfile (Trusted Launch is rejected by Gen1 image)
//   * No osDisk.diskSizeGB override (image default 400 GiB is used)
//   * No VM extensions (waagent runs in restricted mode)
//   * adminUsername is the Azure provisioning user; the GHES admin shell user is `admin` on port 122

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: ghesHostname
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'GitHub'
        offer: 'GitHub-Enterprise'
        sku: 'GitHub-Enterprise'
        version: ghesImageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: 'disk-${namingPrefix}-ghes-data'
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGb
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------- Private DNS A record ----------

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

resource dnsRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: ghesHostname
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: nic.properties.ipConfigurations[0].properties.privateIPAddress
      }
    ]
  }
}

output ghesVmId string = vm.id
output ghesVmName string = vm.name
output ghesPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output ghesFqdn string = '${ghesHostname}.${privateDnsZoneName}'
