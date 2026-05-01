// proxy-vm.bicep — Ubuntu 22.04 + tinyproxy, attached to ProxySubnet
targetScope = 'resourceGroup'

@description('Naming prefix')
param namingPrefix string

@description('Azure region')
param location string

@description('Proxy subnet resource id')
param proxySubnetId string

@description('Linux admin username')
param adminUsername string

@description('SSH public key (OpenSSH format)')
@secure()
param adminPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('cloud-init user-data (raw text); will be base64-encoded')
param cloudInit string

@description('Private DNS zone name (e.g., ghestest.internal)')
param privateDnsZoneName string

@description('Resource tags')
param tags object = {}

var vmName = 'vm-${namingPrefix}-proxy'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${namingPrefix}-proxy'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: proxySubnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'proxy'
      adminUsername: adminUsername
      customData: base64(cloudInit)
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
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 30
      }
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

// Private DNS A record for the proxy
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

resource dnsRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: 'proxy'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: nic.properties.ipConfigurations[0].properties.privateIPAddress
      }
    ]
  }
}

output proxyVmId string = vm.id
output proxyPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output proxyFqdn string = 'proxy.${privateDnsZoneName}'
