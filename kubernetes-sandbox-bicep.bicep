@description('Azure region for all resources')
param location string = resourceGroup().location

param vm1Name string = 'pk-vm1'
param vm2Name string = 'pk-vm2'
param adminUsername string = 'azureuser'
@secure()
param sshPublicKey string

@description('Priority for the Cloud Shell SSH rule. It must be unique in the NSG.')
param sshRulePriority int = 200

@description('CIDR allowed to SSH directly to the VMs. Empty disables the optional admin-IP rule.')
param sshSourceAddressPrefix string = ''
param cloudShellPublicIp string = ''
param vmSize string = 'Standard_B2ms'
param vnetName string = 'vnet-kubernetes'
param subnetName string = 'kubernetes-subnet'

@description('Kubernetes pod network CIDR. This is not an Azure subnet.')
param podCidr string = '192.168.0.0/16'

@description('Kubernetes service CIDR. This must not overlap the VNet or pod CIDR.')
param serviceCidr string = '10.96.0.0/12'

var vnetAddressPrefix = '172.16.0.0/16'
var workloadSubnetPrefix = '172.16.0.0/24'

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: '${vnetName}-nsg'
  location: location
  properties: {
    securityRules: empty(sshSourceAddressPrefix) ? [] : [
      {
        name: 'AllowSshFromAdminIp'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sshSourceAddressPrefix
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource allowCloudShellSsh 'Microsoft.Network/networkSecurityGroups/securityRules@2025-01-01' = {
  parent: nsg
  name: 'AllowSshFromCloudShell'
  properties: {
    access: 'Allow'
    direction: 'Inbound'
    protocol: 'Tcp'
    sourcePortRange: '*'
    sourceAddressPrefix: cloudShellPublicIp
    destinationPortRange: '22'
    destinationAddressPrefix: '*'
    priority: sshRulePriority
    description: 'Allow SSH from the current Azure Cloud Shell public egress IP'
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefixes: [
            workloadSubnetPrefix
          ]
          networkSecurityGroup: {
            id: nsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource vm1PublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: '${vm1Name}-pip'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource vm2PublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
  name: '${vm2Name}-pip'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource nic1 'Microsoft.Network/networkInterfaces@2025-01-01' = {
  name: '${vm1Name}-nic'
  location: location
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: vm1PublicIp.id
          }
          subnet: {
            id: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
              vnet.name,
              subnetName
            )
          }
        }
      }
    ]
  }
}

resource nic2 'Microsoft.Network/networkInterfaces@2025-01-01' = {
  name: '${vm2Name}-nic'
  location: location
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: vm2PublicIp.id
          }
          subnet: {
            id: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
              vnet.name,
              subnetName
            )
          }
        }
      }
    ]
  }
}

resource vm1 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vm1Name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
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
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
        diskSizeGB: 30
      }
    }
    osProfile: {
      computerName: vm1Name
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic1.id
          properties: {
            deleteOption: 'Delete'
          }
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

resource vm2 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vm2Name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
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
          storageAccountType: 'StandardSSD_LRS'
        }
        deleteOption: 'Delete'
        diskSizeGB: 30
      }
    }
    osProfile: {
      computerName: vm2Name
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic2.id
          properties: {
            deleteOption: 'Delete'
          }
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

output vm1Name string = vm1.name
output vm2Name string = vm2.name
output controlPlanePrivateIp string = nic1.properties.ipConfigurations[0].properties.privateIPAddress
output workerPrivateIp string = nic2.properties.ipConfigurations[0].properties.privateIPAddress
output podCidr string = podCidr
output serviceCidr string = serviceCidr
output vm1PublicIpAddress string = vm1PublicIp.properties.ipAddress
output vm2PublicIpAddress string = vm2PublicIp.properties.ipAddress
output vnetId string = vnet.id
