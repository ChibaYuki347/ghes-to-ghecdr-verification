// network.bicep — VNet, 3 subnets, 2 NSGs, NAT Gateway, Private DNS Zone
targetScope = 'resourceGroup'

@description('Naming prefix for all resources')
param namingPrefix string

@description('Azure region')
param location string

@description('VNet CIDR')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('GHES subnet CIDR (closed; no internet)')
param ghesSubnetPrefix string = '10.0.1.0/24'

@description('Proxy subnet CIDR (NAT GW for outbound)')
param proxySubnetPrefix string = '10.0.2.0/24'

@description('AzureBastionSubnet CIDR (must be /26 or larger)')
param bastionSubnetPrefix string = '10.0.255.0/26'

@description('Private DNS zone name for the test environment')
param privateDnsZoneName string = '${namingPrefix}.internal'

@description('Resource tags')
param tags object = {}

// ---------- NSGs ----------

resource nsgGhes 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namingPrefix}-ghes'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: ghesSubnetPrefix
          destinationPortRanges: [
            '22'
            '80'
            '122'
            '443'
            '8080'
            '8443'
          ]
          description: 'Bastion -> GHES admin/web/git ports'
        }
      }
      {
        name: 'Allow-Vnet-Internal'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: ghesSubnetPrefix
          destinationPortRange: '*'
          description: 'Intra-VNet (future HA / git clients in same VNet)'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Out-Proxy'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ghesSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: proxySubnetPrefix
          destinationPortRange: '8888'
          description: 'GHES -> tinyproxy:8888'
        }
      }
      {
        name: 'Allow-Out-Vnet'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: ghesSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
          description: 'Intra-VNet (Bastion replies, future HA). Note: Azure platform DNS (168.63.129.16) and WireServer are not subject to NSGs.'
        }
      }
      {
        name: 'Deny-Out-Internet'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: ghesSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
          description: 'Force all egress through proxy'
        }
      }
    ]
  }
}

resource nsgProxy 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${namingPrefix}-proxy'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Ghes-Proxy-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ghesSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: proxySubnetPrefix
          destinationPortRange: '8888'
          description: 'GHES -> tinyproxy'
        }
      }
      {
        name: 'Allow-Bastion-SSH'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: proxySubnetPrefix
          destinationPortRange: '22'
          description: 'Bastion SSH to proxy VM (debugging)'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------- NAT Gateway ----------

resource pipNat 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namingPrefix}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [ '1' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 10
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'ngw-${namingPrefix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: [ '1' ]
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: pipNat.id
      }
    ]
  }
}

// ---------- VNet ----------

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namingPrefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'GhesSubnet'
        properties: {
          addressPrefix: ghesSubnetPrefix
          networkSecurityGroup: {
            id: nsgGhes.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'ProxySubnet'
        properties: {
          addressPrefix: proxySubnetPrefix
          networkSecurityGroup: {
            id: nsgProxy.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

// ---------- Private DNS ----------

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-${namingPrefix}-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ---------- Outputs ----------

output vnetId string = vnet.id
output vnetName string = vnet.name
output ghesSubnetId string = '${vnet.id}/subnets/GhesSubnet'
output proxySubnetId string = '${vnet.id}/subnets/ProxySubnet'
output bastionSubnetId string = '${vnet.id}/subnets/AzureBastionSubnet'
output privateDnsZoneName string = privateDnsZone.name
output privateDnsZoneId string = privateDnsZone.id
output natGatewayPublicIp string = pipNat.properties.ipAddress
