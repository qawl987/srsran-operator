/*
Copyright 2024 The Nephio Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"fmt"
	"net"

	workloadv1alpha1 "github.com/nephio-project/api/workload/v1alpha1"
)

// GetInterfaceConfigs returns all InterfaceConfig entries matching the given name.
func GetInterfaceConfigs(interfaceConfigs []workloadv1alpha1.InterfaceConfig, interfaceName string) []workloadv1alpha1.InterfaceConfig {
	var selected []workloadv1alpha1.InterfaceConfig
	for _, ic := range interfaceConfigs {
		if ic.Name == interfaceName {
			selected = append(selected, ic)
		}
	}
	return selected
}

// GetFirstInterfaceConfig returns the first InterfaceConfig with the given name.
// Returns an error if no match is found.
func GetFirstInterfaceConfig(interfaceConfigs []workloadv1alpha1.InterfaceConfig, interfaceName string) (*workloadv1alpha1.InterfaceConfig, error) {
	for _, ic := range interfaceConfigs {
		if ic.Name == interfaceName {
			return &ic, nil
		}
	}
	return nil, fmt.Errorf("interface %q not found in NFDeployment.spec.interfaces", interfaceName)
}

// GetFirstInterfaceConfigIPv4 returns the host part of the IPv4 CIDR address
// for the first InterfaceConfig matching interfaceName.
// The CIDR (e.g. "10.0.0.2/24") is parsed and only the host IP ("10.0.0.2")
// is returned so it can be directly embedded in srsRAN config files.
func GetFirstInterfaceConfigIPv4(interfaceConfigs []workloadv1alpha1.InterfaceConfig, interfaceName string) (string, error) {
	ic, err := GetFirstInterfaceConfig(interfaceConfigs, interfaceName)
	if err != nil {
		return "", err
	}
	if ic.IPv4 == nil {
		return "", fmt.Errorf("interface %q has no IPv4 config", interfaceName)
	}
	ip, _, err := net.ParseCIDR(ic.IPv4.Address)
	if err != nil {
		return "", fmt.Errorf("interface %q: cannot parse IPv4 address %q: %w", interfaceName, ic.IPv4.Address, err)
	}
	return ip.String(), nil
}
