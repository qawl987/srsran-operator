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

// SrsRANCellConfigSpec defines the radio cell parameters for srsRAN.
// Parameters match cell_cfg section of srsRAN gnb_zmq.yml / du_zmq.yml.
type SrsRANCellConfigSpec struct {
	// Downlink ARFCN (center frequency). e.g. 368500 for Band 3 at 1800 MHz.
	// +kubebuilder:default=368500
	DlArfcn uint32 `json:"dlArfcn"`

	// NR operating band number. e.g. 3 = FDD 1800 MHz.
	// +kubebuilder:default=3
	Band uint32 `json:"band"`

	// Channel bandwidth in MHz.
	// +kubebuilder:validation:Enum=5;10;15;20;25;30;40;50;60;80;90;100
	// +kubebuilder:default=20
	ChannelBandwidthMHz uint32 `json:"channelBandwidthMHz"`

	// Subcarrier spacing in kHz (common_scs). 15 kHz SCS for FR1.
	// +kubebuilder:validation:Enum=15;30
	// +kubebuilder:default=15
	CommonScs uint32 `json:"commonScs"`

	// Physical Cell ID.
	// +kubebuilder:default=1
	PCI uint32 `json:"pci"`

	// PDCCH configuration.
	// +optional
	PDCCH SrsRANPDCCHConfig `json:"pdcch,omitempty"`

	// PRACH configuration.
	// +optional
	PRACH SrsRANPRACHConfig `json:"prach,omitempty"`

	// MCS table for PDSCH. "qam64" or "qam256".
	// +kubebuilder:validation:Enum=qam64;qam256
	// +kubebuilder:default=qam64
	PDSCHMcsTable string `json:"pdschMcsTable,omitempty"`

	// MCS table for PUSCH. "qam64" or "qam256".
	// +kubebuilder:validation:Enum=qam64;qam256
	// +kubebuilder:default=qam64
	PUSCHMcsTable string `json:"puschMcsTable,omitempty"`
}

// SrsRANPDCCHConfig holds PDCCH (Physical Downlink Control Channel) parameters.
type SrsRANPDCCHConfig struct {
	// Search space zero index (SS0). Matches pdcch.common.ss0_index in srsRAN config.
	// +kubebuilder:default=0
	SS0Index uint32 `json:"ss0Index,omitempty"`

	// CORESET zero index. Matches pdcch.common.coreset0_index.
	// +kubebuilder:default=12
	Coreset0Index uint32 `json:"coreset0Index,omitempty"`

	// Search space 2 type. Matches pdcch.dedicated.ss2_type.
	// +kubebuilder:validation:Enum=common;ue_specific
	// +kubebuilder:default=common
	SS2Type string `json:"ss2Type,omitempty"`

	// Use DCI format 0_1/1_1 (true) vs 0_0/1_0 (false).
	// Matches pdcch.dedicated.dci_format_0_1_and_1_1.
	// +kubebuilder:default=false
	DCIFormat01and11 bool `json:"dciFormat01and11,omitempty"`
}

// SrsRANPRACHConfig holds PRACH (Physical Random Access Channel) parameters.
type SrsRANPRACHConfig struct {
	// PRACH configuration index per TS 38.211 Table 6.3.3.2-x.
	// Matches prach.prach_config_index in srsRAN config.
	// +kubebuilder:default=1
	PrachConfigIndex uint32 `json:"prachConfigIndex,omitempty"`
}

// SrsRANCellConfigStatus is the observed state of SrsRANCellConfig.
type SrsRANCellConfigStatus struct{}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=srscell

// SrsRANCellConfig is the Schema for the radio cell configuration CRD.
// It carries the srsRAN cell_cfg parameters (band, frequency, PDCCH, PRACH, MCS).
type SrsRANCellConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SrsRANCellConfigSpec   `json:"spec,omitempty"`
	Status SrsRANCellConfigStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// SrsRANCellConfigList contains a list of SrsRANCellConfig.
type SrsRANCellConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []SrsRANCellConfig `json:"items"`
}

func init() {
	SchemeBuilder.Register(&SrsRANCellConfig{}, &SrsRANCellConfigList{})
}
