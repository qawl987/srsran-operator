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

// SliceType defines the RAN slice profile.
// +kubebuilder:validation:Enum=eMBB;URLLC
type SliceType string

const (
	// SliceTypeMBB is the enhanced Mobile Broadband slice type.
	SliceTypeMBB SliceType = "eMBB"
	// SliceTypeURLLC is the Ultra-Reliable Low-Latency Communications slice type.
	SliceTypeURLLC SliceType = "URLLC"
)

// SliceIntent captures the high-level 5G QoS slice intent for the RAN.
// Supported 5QI values:
//
//	eMBB  : 9 (default best-effort), 7 (real-time video), 10 (low-latency video)
//	URLLC : 82 (mission-critical data), 84 (V2X messages), 85 (mission-critical MPS)
type SliceIntent struct {
	// Type is the slice category: eMBB or URLLC.
	// +kubebuilder:validation:Enum=eMBB;URLLC
	// +kubebuilder:default=eMBB
	Type SliceType `json:"type"`

	// FiveQI is the 5G QoS Identifier.
	// eMBB valid values: 7, 9, 10. URLLC valid values: 82, 84, 85.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=255
	// +kubebuilder:default=9
	FiveQI int `json:"fiveQI"`

	// MaxLatencyMs is the target per-packet end-to-end latency budget (e.g. "10ms").
	// +optional
	MaxLatencyMs string `json:"maxLatencyMs,omitempty"`
}

// SrsRANConfigSpec defines the deployment configuration for srsRAN:
// container images, ZMQ RF simulation parameters, UE count and slice intent.
type SrsRANConfigSpec struct {
	// CUCPImage is the container image for the srsRAN CU-CP process.
	// +kubebuilder:default="docker.io/softwareradiosystems/srsran-project:latest"
	CUCPImage string `json:"cucpImage"`

	// CUUPImage is the container image for the srsRAN CU-UP process.
	// +kubebuilder:default="docker.io/softwareradiosystems/srsran-project:latest"
	CUUPImage string `json:"cuupImage"`

	// DUImage is the container image for the srsRAN DU process.
	// +kubebuilder:default="docker.io/softwareradiosystems/srsran-project:latest"
	DUImage string `json:"duImage"`

	// UEImage is the container image for the srsUE simulator.
	// Only used when ZMQMode is true.
	// +optional
	// +kubebuilder:default="docker.io/softwareradiosystems/srsue:latest"
	UEImage string `json:"ueImage,omitempty"`

	// RadioBreakerImage is the ZMQ proxy image used for multi-UE topology.
	// Only used when ZMQMode is true and UECount > 1.
	// +optional
	// +kubebuilder:default="docker.io/softwareradiosystems/radio-breaker:latest"
	RadioBreakerImage string `json:"radioBreakerImage,omitempty"`

	// ZMQMode enables ZMQ RF simulation (ru_sdr with device_driver=zmq).
	// Set to false when connecting to real hardware.
	// +kubebuilder:default=true
	ZMQMode bool `json:"zmqMode"`

	// SRate is the RF sample rate in MHz. Only used when ZMQMode is true.
	// Matches ru_sdr.srate in srsRAN config (e.g. "23.04" for 20 MHz BW).
	// +optional
	// +kubebuilder:default="23.04"
	SRate string `json:"srate,omitempty"`

	// TxGain is the RF transmit gain. Only used when ZMQMode is true.
	// Matches ru_sdr.tx_gain in srsRAN config.
	// +optional
	// +kubebuilder:default=75
	TxGain uint32 `json:"txGain,omitempty"`

	// RxGain is the RF receive gain. Only used when ZMQMode is true.
	// Matches ru_sdr.rx_gain in srsRAN config.
	// +optional
	// +kubebuilder:default=75
	RxGain uint32 `json:"rxGain,omitempty"`

	// UECount is the number of simulated UEs to deploy.
	// When 1: single topology – DU ZMQ connects directly to srsUE.
	// When >1: multi topology – RadioBreaker ZMQ proxy is deployed.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:default=1
	UECount int `json:"ueCount"`

	// AmfAddr is the AMF NGAP address (IP or DNS) for the CU-CP.
	// When empty the controller attempts to resolve it from a Dependency configRef.
	// +optional
	AmfAddr string `json:"amfAddr,omitempty"`

	// SliceIntent defines the 5G QoS slice intent for the RAN.
	// +optional
	SliceIntent SliceIntent `json:"sliceIntent,omitempty"`
}

// SrsRANConfigStatus is the observed state of SrsRANConfig.
type SrsRANConfigStatus struct{}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=srsconf

// SrsRANConfig is the Schema for the srsRAN deployment configuration CRD.
// It carries container images, ZMQ RF simulation parameters, UE count and
// slice intent for the srsRAN CU-CP / CU-UP / DU deployment.
type SrsRANConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SrsRANConfigSpec   `json:"spec,omitempty"`
	Status SrsRANConfigStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// SrsRANConfigList contains a list of SrsRANConfig.
type SrsRANConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []SrsRANConfig `json:"items"`
}

func init() {
	SchemeBuilder.Register(&SrsRANConfig{}, &SrsRANConfigList{})
}
