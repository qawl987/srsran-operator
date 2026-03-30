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

	srsranov1alpha1 "workload.nephio.org/srsran_operator/api/v1alpha1"
)

// ConfigInfo holds the parsed config CRs read from NFConfig.spec.configRefs (ObjectReferences).
type ConfigInfo struct {
	CellConfig  *srsranov1alpha1.SrsRANCellConfig
	PLMNConfig  *srsranov1alpha1.PLMNConfig
	SrsRANConfig *srsranov1alpha1.SrsRANConfig
}

// NewConfigInfo allocates and returns an empty ConfigInfo.
func NewConfigInfo() *ConfigInfo {
	return &ConfigInfo{}
}

// IsComplete returns true if all mandatory configs are present.
func (c *ConfigInfo) IsComplete() bool {
	return c.CellConfig != nil && c.PLMNConfig != nil && c.SrsRANConfig != nil
}

// GetMandatoryNfKinds returns the list of kind names that MUST be present in
// NFConfig.spec.configRefs before the controller will proceed with reconciliation.
func GetMandatoryNfKinds() []string {
	return []string{"SrsRANCellConfig", "PLMNConfig", "SrsRANConfig"}
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

// extractNameFromRaw parses a runtime.RawExtension and returns the "metadata.name" field.
func extractNameFromRaw(raw runtime.RawExtension) (string, error) {
	var obj map[string]any
	if err := json.Unmarshal(raw.Raw, &obj); err != nil {
		return "", fmt.Errorf("cannot unmarshal configRef JSON: %w", err)
	}
	metadata, ok := obj["metadata"].(map[string]any)
	if !ok {
		return "", fmt.Errorf("configRef JSON missing \"metadata\" field")
	}
	name, ok := metadata["name"].(string)
	if !ok || name == "" {
		return "", fmt.Errorf("configRef JSON missing or empty \"metadata.name\" field")
	}
	return name, nil
}
