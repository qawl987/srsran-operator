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
	"encoding/json"
	"fmt"

	"k8s.io/apimachinery/pkg/runtime"
)

// ConfigInfo holds the parsed config data read from the NFDeployment's
// parametersRefs chain (NFDeployment → NFConfig → configRefs[]).
//
// ConfigSelfInfo maps kind name (e.g. "SrsRANCellConfig") → raw JSON extension
// so the controller can unmarshal each CRD by kind name.
type ConfigInfo struct {
	// ConfigSelfInfo holds inline configRefs from NFConfig.spec.configRefs,
	// keyed by the "kind" field extracted from each raw JSON object.
	ConfigSelfInfo map[string]runtime.RawExtension
}

// NewConfigInfo allocates and returns an empty ConfigInfo.
func NewConfigInfo() *ConfigInfo {
	return &ConfigInfo{
		ConfigSelfInfo: make(map[string]runtime.RawExtension),
	}
}

// GetMandatoryNfKinds returns the list of kind names that MUST be present in
// NFConfig.spec.configRefs before the controller will proceed with reconciliation.
func GetMandatoryNfKinds() []string {
	return []string{"SrsRANCellConfig", "PLMNConfig", "SrsRANConfig"}
}

// CheckMandatoryKinds returns true if every kind returned by GetMandatoryNfKinds()
// is present in configSelfInfo.
func CheckMandatoryKinds(configSelfInfo map[string]runtime.RawExtension) bool {
	for _, kind := range GetMandatoryNfKinds() {
		if _, ok := configSelfInfo[kind]; !ok {
			return false
		}
	}
	return true
}

// extractKindFromRaw parses a runtime.RawExtension and returns the "kind" field.
func extractKindFromRaw(raw runtime.RawExtension) (string, error) {
	var obj map[string]any
	if err := json.Unmarshal(raw.Raw, &obj); err != nil {
		return "", fmt.Errorf("cannot unmarshal configRef JSON: %w", err)
	}
	kind, ok := obj["kind"].(string)
	if !ok || kind == "" {
		return "", fmt.Errorf("configRef JSON missing or empty \"kind\" field")
	}
	return kind, nil
}
