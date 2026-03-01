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
	"sort"
	"strings"

	workloadv1alpha1 "github.com/nephio-project/api/workload/v1alpha1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// NetworksAnnotation is the Multus annotation key for attaching secondary networks.
const NetworksAnnotation = "k8s.v1.cni.cncf.io/networks"

// NetworkAttachmentDefinitionGVK is the GVK for Multus NAD resources.
var NetworkAttachmentDefinitionGVK = schema.GroupVersionKind{
	Group:   "k8s.cni.cncf.io",
	Kind:    "NetworkAttachmentDefinition",
	Version: "v1",
}

// CreateNetworkAttachmentDefinitionNetworks builds the JSON value for the
// k8s.v1.cni.cncf.io/networks pod annotation from a map of interface name →
// []InterfaceConfig entries (as populated by the Nephio interface-fn).
//
// Interface names are sorted to ensure a deterministic output string.
func CreateNetworkAttachmentDefinitionNetworks(templateName string, interfaceConfigs map[string][]workloadv1alpha1.InterfaceConfig) (string, error) {
	// Sort interface names for deterministic output.
	names := make([]string, 0, len(interfaceConfigs))
	for n := range interfaceConfigs {
		names = append(names, n)
	}
	sort.Strings(names)

	var entries []string
	for _, name := range names {
		for _, ic := range interfaceConfigs[name] {
			if ic.IPv4 == nil || ic.IPv4.Gateway == nil {
				return "", fmt.Errorf("missing InterfaceConfig.IPv4.Gateway for interface %q", name)
			}
			entries = append(entries, fmt.Sprintf(` {
  "name": %q,
  "interface": %q,
  "ips": [%q],
  "gateways": [%q]
 }`,
				CreateNetworkAttachmentDefinitionName(templateName, name),
				ic.Name,
				ic.IPv4.Address,
				*ic.IPv4.Gateway))
		}
	}

	return "[\n" + strings.Join(entries, ",\n") + "\n]", nil
}

// CreateNetworkAttachmentDefinitionName returns the NAD name for a given
// deployment name and interface suffix (e.g. "srsran-gnb-n2").
func CreateNetworkAttachmentDefinitionName(templateName string, suffix string) string {
	return templateName + "-" + suffix
}
