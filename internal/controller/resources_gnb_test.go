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
	"testing"

	workloadv1alpha1 "github.com/nephio-project/api/workload/v1alpha1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"github.com/go-logr/logr"

	srsranov1alpha1 "workload.nephio.org/srsran_operator/api/v1alpha1"
)

// makeTestNFDeployment creates a test NFDeployment with pre-populated interface IPs.
func makeTestNFDeployment() *workloadv1alpha1.NFDeployment {
	gw := "10.0.0.1"
	return &workloadv1alpha1.NFDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "gnb-test",
			Namespace: "test-ns",
		},
		Spec: workloadv1alpha1.NFDeploymentSpec{
			Provider: "gnb.srsran.io",
			Interfaces: []workloadv1alpha1.InterfaceConfig{
				{Name: "n2", IPv4: &workloadv1alpha1.IPv4{Address: "10.0.2.10/24", Gateway: &gw}},
				{Name: "n3", IPv4: &workloadv1alpha1.IPv4{Address: "10.0.3.10/24", Gateway: &gw}},
				{Name: "e1", IPv4: &workloadv1alpha1.IPv4{Address: "10.0.4.10/24", Gateway: &gw}},
				{Name: "f1c", IPv4: &workloadv1alpha1.IPv4{Address: "10.0.5.10/24", Gateway: &gw}},
				{Name: "f1u", IPv4: &workloadv1alpha1.IPv4{Address: "10.0.6.10/24", Gateway: &gw}},
			},
		},
	}
}

// makeTestConfigInfo builds a ConfigInfo with all three mandatory CRD kinds.
func makeTestConfigInfo(t *testing.T) *ConfigInfo {
	t.Helper()
	cellCfg := struct {
		APIVersion string                              `json:"apiVersion"`
		Kind       string                              `json:"kind"`
		Spec       srsranov1alpha1.SrsRANCellConfigSpec `json:"spec"`
	}{
		APIVersion: "workload.nephio.org/v1alpha1",
		Kind:       "SrsRANCellConfig",
		Spec: srsranov1alpha1.SrsRANCellConfigSpec{
			DlArfcn:             368500,
			Band:                3,
			ChannelBandwidthMHz: 20,
			CommonScs:           15,
			PCI:                 1,
			PDCCH: srsranov1alpha1.SrsRANPDCCHConfig{
				SS0Index: 0, Coreset0Index: 12, SS2Type: "common",
			},
			PRACH:         srsranov1alpha1.SrsRANPRACHConfig{PrachConfigIndex: 1},
			PDSCHMcsTable: "qam64",
			PUSCHMcsTable: "qam64",
		},
	}
	plmnCfg := struct {
		APIVersion string                         `json:"apiVersion"`
		Kind       string                         `json:"kind"`
		Spec       srsranov1alpha1.PLMNConfigSpec  `json:"spec"`
	}{
		APIVersion: "workload.nephio.org/v1alpha1",
		Kind:       "PLMNConfig",
		Spec: srsranov1alpha1.PLMNConfigSpec{
			PLMN: "20893",
			TAC:  1,
			Slices: []srsranov1alpha1.SliceInfo{
				{SST: 1, SD: "010203"},
			},
		},
	}
	srsranCfg := struct {
		APIVersion string                          `json:"apiVersion"`
		Kind       string                          `json:"kind"`
		Spec       srsranov1alpha1.SrsRANConfigSpec `json:"spec"`
	}{
		APIVersion: "workload.nephio.org/v1alpha1",
		Kind:       "SrsRANConfig",
		Spec: srsranov1alpha1.SrsRANConfigSpec{
			CUCPImage: "docker.io/qawl987/srsran-split:latest",
			CUUPImage: "docker.io/qawl987/srsran-split:latest",
			DUImage:   "docker.io/qawl987/srsran-split:latest",
			ZMQMode:   true,
			SRate:     "23.04",
			TxGain:    75,
			RxGain:    75,
			UECount:   1,
			AmfAddr:   "10.0.1.10",
			SliceIntent: srsranov1alpha1.SliceIntent{
				Type:   srsranov1alpha1.SliceTypeMBB,
				FiveQI: 9,
			},
		},
	}

	marshalRaw := func(v any) runtime.RawExtension {
		b, err := json.Marshal(v)
		require.NoError(t, err)
		return runtime.RawExtension{Raw: b}
	}

	ci := NewConfigInfo()
	ci.ConfigSelfInfo["SrsRANCellConfig"] = marshalRaw(cellCfg)
	ci.ConfigSelfInfo["PLMNConfig"] = marshalRaw(plmnCfg)
	ci.ConfigSelfInfo["SrsRANConfig"] = marshalRaw(srsranCfg)
	return ci
}

func testLogger() logr.Logger {
	return logr.Discard()
}

func TestGetConfigMapReturnsThreeEntries(t *testing.T) {
	nfDeploy := makeTestNFDeployment()
	configInfo := makeTestConfigInfo(t)

	logger := testLogger()
	g := GnbResources{}
	cms := g.GetConfigMap(logger, nfDeploy, configInfo)

	require.NotNil(t, cms)
	assert.Len(t, cms, 3, "expected 3 ConfigMaps: cucp, cuup, du")

	names := make(map[string]bool)
	for _, cm := range cms {
		names[cm.Name] = true
	}
	assert.True(t, names["gnb-test-cucp-config"], "expected cucp ConfigMap")
	assert.True(t, names["gnb-test-cuup-config"], "expected cuup ConfigMap")
	assert.True(t, names["gnb-test-du-config"], "expected du ConfigMap")
}

func TestGetConfigMapCUCPContainsN2IP(t *testing.T) {
	nfDeploy := makeTestNFDeployment()
	configInfo := makeTestConfigInfo(t)

	logger := testLogger()
	g := GnbResources{}
	cms := g.GetConfigMap(logger, nfDeploy, configInfo)
	require.NotNil(t, cms)

	var cucpCM *corev1.ConfigMap
	for _, cm := range cms {
		if cm.Name == "gnb-test-cucp-config" {
			cucpCM = cm
			break
		}
	}
	require.NotNil(t, cucpCM)
	cuCPYml := cucpCM.Data["gnb-config.yml"]
	assert.Contains(t, cuCPYml, "10.0.2.10", "CU-CP config must contain N2 IP")
	assert.Contains(t, cuCPYml, "20893", "CU-CP config must contain PLMN")
}

func TestGetConfigMapDUContainsCellConfig(t *testing.T) {
	nfDeploy := makeTestNFDeployment()
	configInfo := makeTestConfigInfo(t)

	logger := testLogger()
	g := GnbResources{}
	cms := g.GetConfigMap(logger, nfDeploy, configInfo)
	require.NotNil(t, cms)

	var duCM *corev1.ConfigMap
	for _, cm := range cms {
		if cm.Name == "gnb-test-du-config" {
			duCM = cm
			break
		}
	}
	require.NotNil(t, duCM)
	duYml := duCM.Data["gnb-config.yml"]
	assert.Contains(t, duYml, "368500", "DU config must contain dl_arfcn")
	assert.Contains(t, duYml, "10.0.5.10", "DU config must contain F1C IP")
}

func TestGetDeploymentReturnsCUCPCUUPDU(t *testing.T) {
	nfDeploy := makeTestNFDeployment()
	configInfo := makeTestConfigInfo(t)

	logger := testLogger()
	g := GnbResources{}
	deps := g.GetDeployment(logger, nfDeploy, configInfo)
	require.NotNil(t, deps)
	assert.Len(t, deps, 3, "expected 3 Deployments for single UE topology")
}

func TestGetServiceForNFDeploymentReturnsServices(t *testing.T) {
	nfDeploy := makeTestNFDeployment()
	svcs := GetServiceForNFDeployment(nfDeploy)
	assert.Len(t, svcs, 4, "expected 4 ClusterIP services")
}

func TestCheckMandatoryKindsAllPresent(t *testing.T) {
	ci := makeTestConfigInfo(t)
	assert.True(t, CheckMandatoryKinds(ci.ConfigSelfInfo))
}

func TestCheckMandatoryKindsMissing(t *testing.T) {
	ci := NewConfigInfo()
	ci.ConfigSelfInfo["SrsRANCellConfig"] = runtime.RawExtension{Raw: []byte(`{}`)}
	// PLMNConfig and SrsRANConfig missing
	assert.False(t, CheckMandatoryKinds(ci.ConfigSelfInfo))
}
