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

// Package controller implements the srsRAN gNB NFDeployment reconciler.
//
// GnbResources generates the Kubernetes resources for the three srsRAN pods:
//
//	CU-CP  – binds N2 (NGAP→AMF), E1 (E1AP↔CU-UP), F1C (F1-AP↔DU)
//	CU-UP  – binds N3 (GTP-U→UPF), E1 (E1AP←CU-CP), F1U (GTP-U↔DU)
//	DU     – binds F1C (F1-AP←CU-CP), F1U (GTP-U←CU-UP), ZMQ RF
package controller

import (
	"encoding/json"
	"fmt"

	"github.com/go-logr/logr"
	workloadv1alpha1 "github.com/nephio-project/api/workload/v1alpha1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"

	srsranov1alpha1 "workload.nephio.org/srsran_operator/api/v1alpha1"
)

const (
	// zmqBasePort is the first ZMQ TX port for srsUE.
	// Each additional UE gets +2 (TX/RX pair).
	zmqBasePort = 2000

	// srsRAN inter-component service ports.
	e1apPort  = 38462
	f1apPort  = 38472
	f1uPort   = 2152
	ngapPort  = 38412
	zmqTxPort = 2000
	zmqRxPort = 2001
)

// GnbResources implements NfResource for the srsRAN gNB (CU-CP + CU-UP + DU).
type GnbResources struct{}

// GetServiceAccount returns the ServiceAccount for the srsRAN gNB pods.
func (g GnbResources) GetServiceAccount() []*corev1.ServiceAccount {
	return []*corev1.ServiceAccount{
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ServiceAccount"},
			ObjectMeta: metav1.ObjectMeta{
				Name: "srsran-gnb-sa",
			},
		},
	}
}

// GetConfigMap generates the three ConfigMaps for CU-CP, CU-UP, and DU.
// IPs are sourced exclusively from NFDeployment.spec.interfaces[] (populated
// by the Nephio nfdeploy-fn / interface-fn pipeline).
func (g GnbResources) GetConfigMap(log logr.Logger, nfDeploy *workloadv1alpha1.NFDeployment, configInfo *ConfigInfo) []*corev1.ConfigMap {
	// ── Read IPAM-injected IPs ──────────────────────────────────────────────
	n2Ip, err := GetFirstInterfaceConfigIPv4(nfDeploy.Spec.Interfaces, "n2")
	if err != nil {
		log.Error(err, "Interface n2 not found in NFDeployment.spec.interfaces")
		return nil
	}
	n3Ip, err := GetFirstInterfaceConfigIPv4(nfDeploy.Spec.Interfaces, "n3")
	if err != nil {
		log.Error(err, "Interface n3 not found in NFDeployment.spec.interfaces")
		return nil
	}
	e1Ip, err := GetFirstInterfaceConfigIPv4(nfDeploy.Spec.Interfaces, "e1")
	if err != nil {
		log.Error(err, "Interface e1 not found in NFDeployment.spec.interfaces")
		return nil
	}
	f1cIp, err := GetFirstInterfaceConfigIPv4(nfDeploy.Spec.Interfaces, "f1c")
	if err != nil {
		log.Error(err, "Interface f1c not found in NFDeployment.spec.interfaces")
		return nil
	}
	f1uIp, err := GetFirstInterfaceConfigIPv4(nfDeploy.Spec.Interfaces, "f1u")
	if err != nil {
		log.Error(err, "Interface f1u not found in NFDeployment.spec.interfaces")
		return nil
	}

	// ── Unmarshal operator-specific CRDs from configInfo ────────────────────
	cellCfg := &srsranov1alpha1.SrsRANCellConfig{}
	if err := json.Unmarshal(configInfo.ConfigSelfInfo["SrsRANCellConfig"].Raw, cellCfg); err != nil {
		log.Error(err, "Cannot unmarshal SrsRANCellConfig")
		return nil
	}
	plmnCfg := &srsranov1alpha1.PLMNConfig{}
	if err := json.Unmarshal(configInfo.ConfigSelfInfo["PLMNConfig"].Raw, plmnCfg); err != nil {
		log.Error(err, "Cannot unmarshal PLMNConfig")
		return nil
	}
	srsranCfg := &srsranov1alpha1.SrsRANConfig{}
	if err := json.Unmarshal(configInfo.ConfigSelfInfo["SrsRANConfig"].Raw, srsranCfg); err != nil {
		log.Error(err, "Cannot unmarshal SrsRANConfig")
		return nil
	}

	// ── Resolve AMF address ──────────────────────────────────────────────────
	// Prefer explicit field; fall back to a statically-known value.
	amfAddr := srsranCfg.Spec.AmfAddr
	if amfAddr == "" {
		// Use a placeholder – the operator admin should set SrsRANConfig.spec.amfAddr.
		amfAddr = "UNSET_AMF_ADDR"
		log.Info("SrsRANConfig.spec.amfAddr not set; using placeholder", "amfAddr", amfAddr)
	}

	// ── CU-CP ConfigMap ──────────────────────────────────────────────────────
	cucpCfg, err := renderCUCPConfig(CUCPConfigValues{
		N2BindAddr:               n2Ip,
		AMFAddr:                  amfAddr,
		E1BindAddr:               e1Ip,
		F1CBindAddr:              f1cIp,
		PLMN:                     plmnCfg.Spec.PLMN,
		TAC:                      plmnCfg.Spec.TAC,
		Slices:                   plmnCfg.Spec.Slices,
		InactivityTimer:          7200,
		RequestPDUSessionTimeout: 20,
	})
	if err != nil {
		log.Error(err, "Failed to render CU-CP config template")
		return nil
	}

	// ── CU-UP ConfigMap ──────────────────────────────────────────────────────
	// CU-UP connects to CU-CP via the Kubernetes Service srsran-cucp-e1-svc.
	cuupCfg, err := renderCUUPConfig(CUUPConfigValues{
		E1CUCPAddr:  cucpE1ServiceName(nfDeploy.Name),
		E1BindAddr:  e1Ip,
		N3BindAddr:  n3Ip,
		F1UBindAddr: f1uIp,
	})
	if err != nil {
		log.Error(err, "Failed to render CU-UP config template")
		return nil
	}

	// ── DU ConfigMap ─────────────────────────────────────────────────────────
	// DU connects to CU-CP via the Kubernetes Service srsran-cucp-f1c-svc.
	// ZMQ RF socket binds to the DU pod's own F1U IP (reachable from UE pod).
	srate := srsranCfg.Spec.SRate
	if srate == "" {
		srate = "23.04"
	}
	duCfg, err := renderDUConfig(DUConfigValues{
		F1CCUCPAddr:         cucpF1CServiceName(nfDeploy.Name),
		F1CBindAddr:         f1cIp,
		F1UBindAddr:         f1uIp,
		ZMQBindAddr:         f1uIp,
		ZMQTxPort:           zmqTxPort,
		ZMQRxPort:           zmqRxPort,
		SRate:               srate,
		TxGain:              txGainOrDefault(srsranCfg.Spec.TxGain),
		RxGain:              rxGainOrDefault(srsranCfg.Spec.RxGain),
		DlArfcn:             cellCfg.Spec.DlArfcn,
		Band:                cellCfg.Spec.Band,
		ChannelBandwidthMHz: cellCfg.Spec.ChannelBandwidthMHz,
		CommonScs:           cellCfg.Spec.CommonScs,
		PLMN:                plmnCfg.Spec.PLMN,
		TAC:                 plmnCfg.Spec.TAC,
		PCI:                 cellCfg.Spec.PCI,
		PDCCH:               cellCfg.Spec.PDCCH,
		PRACH:               cellCfg.Spec.PRACH,
		PDSCHMcsTable:       mcsTableOrDefault(cellCfg.Spec.PDSCHMcsTable),
		PUSCHMcsTable:       mcsTableOrDefault(cellCfg.Spec.PUSCHMcsTable),
	})
	if err != nil {
		log.Error(err, "Failed to render DU config template")
		return nil
	}

	return []*corev1.ConfigMap{
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
			ObjectMeta: metav1.ObjectMeta{
				Name:      nfDeploy.Name + "-cucp-config",
				Namespace: nfDeploy.Namespace,
			},
			Data: map[string]string{"gnb-config.yml": cucpCfg},
		},
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
			ObjectMeta: metav1.ObjectMeta{
				Name:      nfDeploy.Name + "-cuup-config",
				Namespace: nfDeploy.Namespace,
			},
			Data: map[string]string{"gnb-config.yml": cuupCfg},
		},
		{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
			ObjectMeta: metav1.ObjectMeta{
				Name:      nfDeploy.Name + "-du-config",
				Namespace: nfDeploy.Namespace,
			},
			Data: map[string]string{"gnb-config.yml": duCfg},
		},
	}
}

// createNetworkAttachmentDefinitionNetworks builds the Multus annotation value
// for a given set of interface names.
func (g GnbResources) createNetworkAttachmentDefinitionNetworks(templateName string, spec *workloadv1alpha1.NFDeploymentSpec) (string, error) {
	return CreateNetworkAttachmentDefinitionNetworks(templateName, map[string][]workloadv1alpha1.InterfaceConfig{
		"n2":  GetInterfaceConfigs(spec.Interfaces, "n2"),
		"n3":  GetInterfaceConfigs(spec.Interfaces, "n3"),
		"e1":  GetInterfaceConfigs(spec.Interfaces, "e1"),
		"f1c": GetInterfaceConfigs(spec.Interfaces, "f1c"),
		"f1u": GetInterfaceConfigs(spec.Interfaces, "f1u"),
	})
}

// GetDeployment generates the three Deployments: CU-CP, CU-UP, DU
// (and optionally RadioBreaker when UECount > 1).
func (g GnbResources) GetDeployment(log logr.Logger, nfDeploy *workloadv1alpha1.NFDeployment, configInfo *ConfigInfo) []*appsv1.Deployment {
	srsranCfg := &srsranov1alpha1.SrsRANConfig{}
	if err := json.Unmarshal(configInfo.ConfigSelfInfo["SrsRANConfig"].Raw, srsranCfg); err != nil {
		log.Error(err, "Cannot unmarshal SrsRANConfig for Deployment")
		return nil
	}

	nadNetworks, err := g.createNetworkAttachmentDefinitionNetworks(nfDeploy.Name, &nfDeploy.Spec)
	if err != nil {
		log.Error(err, "Cannot build NAD networks annotation")
		return nil
	}

	podAnnotations := map[string]string{
		NetworksAnnotation: nadNetworks,
	}

	cucpImg := srsranCfg.Spec.CUCPImage
	if cucpImg == "" {
		cucpImg = "docker.io/qawl987/srsran-split:latest"
	}
	cuupImg := srsranCfg.Spec.CUUPImage
	if cuupImg == "" {
		cuupImg = "docker.io/qawl987/srsran-split:latest"
	}
	duImg := srsranCfg.Spec.DUImage
	if duImg == "" {
		duImg = "docker.io/qawl987/srsran-split:latest"
	}

	deployments := []*appsv1.Deployment{
		gnbDeployment(nfDeploy, "cucp", cucpImg, nfDeploy.Name+"-cucp-config", podAnnotations),
		gnbDeployment(nfDeploy, "cuup", cuupImg, nfDeploy.Name+"-cuup-config", podAnnotations),
		duDeployment(nfDeploy, duImg, nfDeploy.Name+"-du-config", podAnnotations),
	}

	// Multi-UE topology: add RadioBreaker proxy deployment.
	if srsranCfg.Spec.UECount > 1 {
		rbImg := srsranCfg.Spec.RadioBreakerImage
		if rbImg == "" {
			rbImg = "docker.io/qawl987/srsran-ue:latest"
		}
		deployments = append(deployments, radioBreakerDeployment(nfDeploy, rbImg, srsranCfg.Spec.UECount))
	}

	return deployments
}

// GetService returns the ClusterIP Services for inter-pod communication.
func (g GnbResources) GetService() []*corev1.Service {
	// Services are named relative to the NFDeployment; the controller creates
	// them in the same namespace. For now we return generic-named services so
	// the templates can reference them (cucpE1ServiceName / cucpF1CServiceName).
	return nil // Services are created with NFDeployment name suffix; see GetServiceForDeployment.
}

// GetServiceForNFDeployment returns ClusterIP services scoped to a specific NFDeployment.
// Called from CreateAll after GetDeployment.
func GetServiceForNFDeployment(nfDeploy *workloadv1alpha1.NFDeployment) []*corev1.Service {
	name := nfDeploy.Name
	ns := nfDeploy.Namespace
	return []*corev1.Service{
		clusterIPService(ns, cucpE1ServiceName(name), "e1ap", e1apPort),
		clusterIPService(ns, cucpF1CServiceName(name), "f1ap", f1apPort),
		clusterIPService(ns, name+"-cuup-f1u-svc", "f1u", f1uPort),
		clusterIPService(ns, name+"-du-zmq-svc", "zmq", zmqTxPort),
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

func cucpE1ServiceName(deploymentName string) string  { return deploymentName + "-cucp-e1-svc" }
func cucpF1CServiceName(deploymentName string) string { return deploymentName + "-cucp-f1c-svc" }

func txGainOrDefault(v uint32) uint32 {
	if v == 0 {
		return 75
	}
	return v
}

func rxGainOrDefault(v uint32) uint32 {
	if v == 0 {
		return 75
	}
	return v
}

func mcsTableOrDefault(v string) string {
	if v == "" {
		return "qam64"
	}
	return v
}

func gnbDeployment(nfDeploy *workloadv1alpha1.NFDeployment, component, image, cmName string, podAnnotations map[string]string) *appsv1.Deployment {
	appLabel := fmt.Sprintf("srsran-%s", component)
	entrypoint := fmt.Sprintf("/usr/local/bin/entrypoint-%s.sh", component)
	return &appsv1.Deployment{
		TypeMeta: metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-%s", nfDeploy.Name, component),
			Namespace: nfDeploy.Namespace,
			Labels:    map[string]string{"app.kubernetes.io/name": appLabel},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: ptr.To(int32(1)),
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": appLabel},
			},
			Strategy: appsv1.DeploymentStrategy{Type: appsv1.RecreateDeploymentStrategyType},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      map[string]string{"app.kubernetes.io/name": appLabel},
					Annotations: podAnnotations,
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: "srsran-gnb-sa",
					Containers: []corev1.Container{
						{
							Name:            component,
							Image:           image,
							ImagePullPolicy: corev1.PullIfNotPresent,
							Command:         []string{entrypoint},
							SecurityContext: &corev1.SecurityContext{
								Privileged: ptr.To(true),
							},
							VolumeMounts: []corev1.VolumeMount{
								{
									Name:      "config",
									MountPath: "/etc/config",
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{Name: cmName},
								},
							},
						},
					},
				},
			},
		},
	}
}

func duDeployment(nfDeploy *workloadv1alpha1.NFDeployment, image, cmName string, podAnnotations map[string]string) *appsv1.Deployment {
	appLabel := "srsran-du"
	return &appsv1.Deployment{
		TypeMeta: metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      nfDeploy.Name + "-du",
			Namespace: nfDeploy.Namespace,
			Labels:    map[string]string{"app.kubernetes.io/name": appLabel},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: ptr.To(int32(1)),
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": appLabel},
			},
			Strategy: appsv1.DeploymentStrategy{Type: appsv1.RecreateDeploymentStrategyType},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels:      map[string]string{"app.kubernetes.io/name": appLabel},
					Annotations: podAnnotations,
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: "srsran-gnb-sa",
					Containers: []corev1.Container{
						{
							Name:            "du",
							Image:           image,
							ImagePullPolicy: corev1.PullIfNotPresent,
							Command:         []string{"/usr/local/bin/entrypoint-du.sh"},
							SecurityContext: &corev1.SecurityContext{
								Privileged: ptr.To(true),
							},
							VolumeMounts: []corev1.VolumeMount{
								{
									Name:      "config",
									MountPath: "/etc/config",
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{Name: cmName},
								},
							},
						},
					},
				},
			},
		},
	}
}

func radioBreakerDeployment(nfDeploy *workloadv1alpha1.NFDeployment, image string, ueCount int) *appsv1.Deployment {
	appLabel := "srsran-radio-breaker"
	return &appsv1.Deployment{
		TypeMeta: metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      nfDeploy.Name + "-radio-breaker",
			Namespace: nfDeploy.Namespace,
			Labels:    map[string]string{"app.kubernetes.io/name": appLabel},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: ptr.To(int32(1)),
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": appLabel},
			},
			Strategy: appsv1.DeploymentStrategy{Type: appsv1.RecreateDeploymentStrategyType},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app.kubernetes.io/name": appLabel},
					Annotations: map[string]string{
						"srsran-operator/ue-count": fmt.Sprintf("%d", ueCount),
					},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "radio-breaker",
							Image: image,
							SecurityContext: &corev1.SecurityContext{
								Privileged: ptr.To(true),
							},
						},
					},
				},
			},
		},
	}
}

func clusterIPService(namespace, name, portName string, port int) *corev1.Service {
	return &corev1.Service{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Service"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
		Spec: corev1.ServiceSpec{
			Type: corev1.ServiceTypeClusterIP,
			Ports: []corev1.ServicePort{
				{
					Name:       portName,
					Port:       int32(port),
					TargetPort: intstr.FromInt(port),
					Protocol:   corev1.ProtocolTCP,
				},
			},
		},
	}
}
