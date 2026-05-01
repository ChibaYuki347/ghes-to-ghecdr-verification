// bastion.bicep — Azure Bastion Standard SKU with native client tunneling
targetScope = 'resourceGroup'

@description('Naming prefix')
param namingPrefix string

@description('Azure region')
param location string

@description('AzureBastionSubnet resource id')
param bastionSubnetId string

@description('Resource tags')
param tags object = {}

resource pipBastion 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namingPrefix}-bas'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-${namingPrefix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: false
    enableShareableLink: false
    enableFileCopy: false
    disableCopyPaste: false
    scaleUnits: 2
    ipConfigurations: [
      {
        name: 'ipconfig-bastion'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: pipBastion.id
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
output bastionPublicIp string = pipBastion.properties.ipAddress
