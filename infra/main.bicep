targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'japaneast'

@description('Naming prefix for all resources.')
param namePrefix string = 'ghestest'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-ghestest-jpe'

@description('GHES image version.')
param ghesImageVersion string = '3.18.8'

@description('GHES VM size.')
param ghesVmSize string = 'Standard_E4s_v5'

@description('Proxy VM size.')
param proxyVmSize string = 'Standard_B2s'

@description('GHES data disk size in GB.')
param dataDiskSizeGB int = 200

@description('Linux admin username for both VMs.')
param adminUsername string = 'ghadmin'

@description('SSH public key in OpenSSH format. Required; must not be empty.')
@secure()
@minLength(80)
param sshPublicKey string

@description('Resource tags.')
param tags object = {
  workload: 'ghes-test'
  costCenter: 'test'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: '${namePrefix}-network'
  scope: rg
  params: {
    namingPrefix: namePrefix
    location: location
    tags: tags
  }
}

module bastion 'modules/bastion.bicep' = {
  name: '${namePrefix}-bastion'
  scope: rg
  params: {
    namingPrefix: namePrefix
    location: location
    bastionSubnetId: network.outputs.bastionSubnetId
    tags: tags
  }
}

module proxyVm 'modules/proxy-vm.bicep' = {
  name: '${namePrefix}-proxy-vm'
  scope: rg
  params: {
    namingPrefix: namePrefix
    location: location
    proxySubnetId: network.outputs.proxySubnetId
    adminUsername: adminUsername
    adminPublicKey: sshPublicKey
    vmSize: proxyVmSize
    cloudInit: loadTextContent('cloud-init/proxy-init.yaml')
    privateDnsZoneName: network.outputs.privateDnsZoneName
    tags: tags
  }
}

module ghesVm 'modules/ghes-vm.bicep' = {
  name: '${namePrefix}-ghes-vm'
  scope: rg
  dependsOn: [
    proxyVm
  ]
  params: {
    namingPrefix: namePrefix
    location: location
    ghesSubnetId: network.outputs.ghesSubnetId
    adminUsername: adminUsername
    adminPublicKey: sshPublicKey
    vmSize: ghesVmSize
    ghesImageVersion: ghesImageVersion
    dataDiskSizeGb: dataDiskSizeGB
    privateDnsZoneName: network.outputs.privateDnsZoneName
    tags: tags
  }
}

output resourceGroupName string = rg.name
output bastionName string = bastion.outputs.bastionName
output ghesVmName string = ghesVm.outputs.ghesVmName
output ghesVmId string = ghesVm.outputs.ghesVmId
output ghesPrivateIp string = ghesVm.outputs.ghesPrivateIp
output ghesFqdn string = ghesVm.outputs.ghesFqdn
output proxyFqdn string = proxyVm.outputs.proxyFqdn
output tunnelCommand string = 'az network bastion tunnel --name ${bastion.outputs.bastionName} --resource-group ${rg.name} --target-resource-id ${ghesVm.outputs.ghesVmId} --resource-port 8443 --port 8443'
