// Command dbbackup-operator is the Operator's entrypoint: wires the
// DbBackup scheme and the DbBackupReconciler into a controller-runtime
// Manager and runs it. This is what `operator-sdk create api` /
// `kubebuilder create api` normally scaffold into cmd/main.go; hand-written
// here (see api/v1alpha1/dbbackup_types.go's package comment for why).
package main

import (
	"os"
	"strings"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	dsov1alpha1 "dso202.io/dbbackup-operator/api/v1alpha1"
	"dso202.io/dbbackup-operator/controllers"
)

var scheme = runtime.NewScheme()

// namespaceFile is where every in-cluster Pod's projected ServiceAccount
// mounts its own namespace -- reading it here is what lets this binary
// scope its own cache without a Downward API env var or a flag.
const namespaceFile = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

func init() {
	_ = clientgoscheme.AddToScheme(scheme) // core/v1, batch/v1, apps/v1, ...
	_ = dsov1alpha1.AddToScheme(scheme)    // our own DbBackup CRD type
}

// watchNamespace reports the namespace this manager's cache -- and
// therefore every List/Watch it issues -- must be confined to.
//
// rbac/rbac.yaml's dbbackup-operator Role is deliberately a Role, not a
// ClusterRole (least privilege: this Operator has no business watching
// Jobs or DbBackups outside its own namespace). controller-runtime's
// Manager cache defaults to watching ALL namespaces, though, which would
// make it try a cluster-scoped LIST/WATCH on batch/v1 Jobs the very first
// time SetupWithManager's Owns(&batchv1.Job{}) starts an informer for that
// type -- and the API server correctly rejects it as Forbidden.
func watchNamespace() string {
	if b, err := os.ReadFile(namespaceFile); err == nil {
		if ns := strings.TrimSpace(string(b)); ns != "" {
			return ns
		}
	}
	return "dso202-assignment-02" // fallback: running outside the cluster (e.g. `go run` against a local kubeconfig)
}

func main() {
	ctrl.SetLogger(zap.New())

	ns := watchNamespace()
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		Cache: cache.Options{
			// Confines every List/Watch (DbBackup AND the Jobs it Owns) to
			// this one namespace, matching the namespaced Role exactly --
			// without this, the cache tries a cluster-scoped watch on Jobs
			// and the API server correctly returns Forbidden.
			DefaultNamespaces: map[string]cache.Config{ns: {}},
		},
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err := (&controllers.DbBackupReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "unable to create controller", "controller", "DbBackup")
		os.Exit(1)
	}

	ctrl.Log.Info("starting dbbackup-operator")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "problem running manager")
		os.Exit(1)
	}
}
