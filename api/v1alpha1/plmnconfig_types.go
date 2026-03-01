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

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// PLMNConfigSpec defines PLMN identity and slice support for the srsRAN gNB.
// Maps to cell_cfg.plmn, cell_cfg.tac, and the AMF supported_tracking_areas
// slice list in cu_cp.yml.
type PLMNConfigSpec struct {
	// PLMN as a 5-digit string (MCC+MNC concatenated).
	// e.g. "20893" → MCC 208, MNC 93 (private/test PLMN).
	// Must match the free5GC/OAI core PLMN configuration.
	// +kubebuilder:default="20893"
	PLMN string `json:"plmn"`

	// Tracking Area Code. Must match the 5G core (free5GC/OAI) TAC config.
	// +kubebuilder:default=1
	TAC uint32 `json:"tac"`

	// Slices is the list of S-NSSAI entries advertised by this gNB.
	// These populate cu_cp.amf.supported_tracking_areas[].plmn_list[].tai_slice_support_list.
	Slices []SliceInfo `json:"slices"`
}

// SliceInfo represents a single S-NSSAI (Single Network Slice Selection Assistance Information).
type SliceInfo struct {
	// SST is the Slice/Service Type.
	// 1=eMBB, 2=URLLC, 3=mMTC per 3GPP TS 23.501.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=255
	SST uint32 `json:"sst"`

	// SD is the Slice Differentiator (6 hex digits, e.g. "010203").
	// Empty string means wildcard (matches any SD).
	// +optional
	SD string `json:"sd,omitempty"`
}

// PLMNConfigStatus is the observed state of PLMNConfig.
type PLMNConfigStatus struct{}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=plmnconf

// PLMNConfig is the Schema for the PLMN identity and slice configuration CRD.
// It carries PLMN, TAC, and the S-NSSAI slice list for the srsRAN gNB.
type PLMNConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PLMNConfigSpec   `json:"spec,omitempty"`
	Status PLMNConfigStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// PLMNConfigList contains a list of PLMNConfig.
type PLMNConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PLMNConfig `json:"items"`
}

func init() {
	SchemeBuilder.Register(&PLMNConfig{}, &PLMNConfigList{})
}
