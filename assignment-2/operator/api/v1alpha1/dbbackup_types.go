// Package v1alpha1 defines the DbBackup custom resource's Go types.
//
// Normally `kubebuilder create api` / `operator-sdk create api` scaffold
// this file plus a zz_generated.deepcopy.go via controller-gen. Neither
// tool, nor a Go toolchain, is preinstallable without root in this
// environment, so these ~90 lines (two small structs, no nested
// slices/pointers beyond metav1.ObjectMeta which client-go already knows
// how to deep-copy) are written by hand instead. The schema mirrors
// ../../config/crd/dbbackups.yaml exactly.
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// GroupVersion is the API group/version DbBackup lives in.
var (
	GroupVersion  = schema.GroupVersion{Group: "dso202.io", Version: "v1alpha1"}
	SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)
	AddToScheme   = SchemeBuilder.AddToScheme
)

func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(GroupVersion, &DbBackup{}, &DbBackupList{})
	metav1.AddToGroupVersion(scheme, GroupVersion)
	return nil
}

// DbBackupSpec is the desired state: which database Service to dump, and
// which image (must carry pg_dump) the backup Job runs.
type DbBackupSpec struct {
	TargetService string `json:"targetService,omitempty"`
	Image         string `json:"image,omitempty"`
}

// DbBackupPhase is the reconciler's own small state machine, reported back
// onto .status.phase.
type DbBackupPhase string

const (
	PhasePending   DbBackupPhase = "Pending"
	PhaseRunning   DbBackupPhase = "Running"
	PhaseSucceeded DbBackupPhase = "Succeeded"
	PhaseFailed    DbBackupPhase = "Failed"
)

// DbBackupStatus is observed state, written only by the controller
// (never by a user) via the status subresource.
type DbBackupStatus struct {
	Phase              DbBackupPhase `json:"phase,omitempty"`
	JobName            string        `json:"jobName,omitempty"`
	StartTime          string        `json:"startTime,omitempty"`
	CompletionTime     string        `json:"completionTime,omitempty"`
	Message            string        `json:"message,omitempty"`
	ObservedGeneration int64         `json:"observedGeneration,omitempty"`
}

// DbBackup is the Custom Resource itself: one instance = one requested
// backup run.
type DbBackup struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DbBackupSpec   `json:"spec,omitempty"`
	Status DbBackupStatus `json:"status,omitempty"`
}

// DbBackupList is the standard List wrapper client-go/controller-runtime
// require for any type registered with a scheme.
type DbBackupList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []DbBackup `json:"items"`
}

// ---- hand-written deep-copy methods (see package comment) ----

func (in *DbBackupSpec) DeepCopy() *DbBackupSpec {
	if in == nil {
		return nil
	}
	out := *in
	return &out
}

func (in *DbBackupStatus) DeepCopy() *DbBackupStatus {
	if in == nil {
		return nil
	}
	out := *in
	return &out
}

func (in *DbBackup) DeepCopyInto(out *DbBackup) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = *in.Spec.DeepCopy()
	out.Status = *in.Status.DeepCopy()
}

func (in *DbBackup) DeepCopy() *DbBackup {
	if in == nil {
		return nil
	}
	out := new(DbBackup)
	in.DeepCopyInto(out)
	return out
}

func (in *DbBackup) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *DbBackupList) DeepCopyInto(out *DbBackupList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		l := make([]DbBackup, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&l[i])
		}
		out.Items = l
	}
}

func (in *DbBackupList) DeepCopy() *DbBackupList {
	if in == nil {
		return nil
	}
	out := new(DbBackupList)
	in.DeepCopyInto(out)
	return out
}

func (in *DbBackupList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}
