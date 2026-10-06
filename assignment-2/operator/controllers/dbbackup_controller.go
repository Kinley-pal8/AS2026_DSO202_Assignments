// Package controllers holds the Operator pattern's core piece (2.4.1): a
// Reconciler that watches DbBackup custom resources and drives real cluster
// state (a pg_dump Job) towards what each one asks for, reporting progress
// back onto .status. This is what `operator-sdk create api --controller`
// would scaffold; hand-written here for the same reason the API types are
// (see api/v1alpha1/dbbackup_types.go's package comment).
package controllers

import (
	"context"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	dsov1alpha1 "dso202.io/dbbackup-operator/api/v1alpha1"
)

// task-tracker-config / task-tracker-secret already exist in the namespace
// (Assignment 2's own manifests) -- the Operator reads the SAME ConfigMap
// and Secret the app itself uses rather than duplicating credentials.
const (
	configMapName    = "task-tracker-config"
	secretName       = "task-tracker-secret"
	defaultDumpImage = "sarojsanyasi/dso202-db:1.0"
	defaultService   = "db"
)

// DbBackupReconciler is the controller (2.4.2.2 "writing controllers for
// custom resources"). Embedding client.Client promotes Get/Create/Status()
// etc directly onto the receiver.
type DbBackupReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=dso202.io,resources=dbbackups,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=dso202.io,resources=dbbackups/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;delete
// (kept in sync by hand with ../rbac/rbac.yaml's dbbackup-operator Role.)

// Reconcile is the whole control loop: given one DbBackup's name, make the
// world match it. Called once at creation, then again whenever the DbBackup
// or a Job it owns changes (see SetupWithManager's .Owns(&batchv1.Job{})).
func (r *DbBackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var backup dsov1alpha1.DbBackup
	if err := r.Get(ctx, req.NamespacedName, &backup); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil // deleted; nothing to reconcile
		}
		return ctrl.Result{}, err
	}

	// Terminal states are final for this design: one DbBackup = one backup
	// attempt. Create a new DbBackup object to run another.
	if backup.Status.Phase == dsov1alpha1.PhaseSucceeded || backup.Status.Phase == dsov1alpha1.PhaseFailed {
		return ctrl.Result{}, nil
	}

	if backup.Status.JobName == "" {
		return ctrl.Result{}, r.startBackupJob(ctx, &backup)
	}
	return r.pollBackupJob(ctx, &backup)
}

// startBackupJob is reached exactly once per DbBackup: build and create the
// pg_dump Job, then record its name and Phase=Running on .status so the
// next Reconcile (triggered by the Job's own status changing) knows to poll
// instead of creating a second Job.
func (r *DbBackupReconciler) startBackupJob(ctx context.Context, backup *dsov1alpha1.DbBackup) error {
	logger := log.FromContext(ctx)

	job := r.buildJob(backup)
	if err := controllerutil.SetControllerReference(backup, job, r.Scheme); err != nil {
		return err
	}
	if err := r.Create(ctx, job); err != nil {
		return err
	}
	logger.Info("created pg_dump Job", "job", job.Name, "dbbackup", backup.Name)

	backup.Status.Phase = dsov1alpha1.PhaseRunning
	backup.Status.JobName = job.Name
	backup.Status.StartTime = time.Now().UTC().Format(time.RFC3339)
	backup.Status.Message = "pg_dump Job created"
	backup.Status.ObservedGeneration = backup.Generation
	return r.Status().Update(ctx, backup)
}

// pollBackupJob is reached on every Reconcile after the Job exists: read
// its status and, once it has a terminal outcome, copy that onto the
// DbBackup's own status.
func (r *DbBackupReconciler) pollBackupJob(ctx context.Context, backup *dsov1alpha1.DbBackup) (ctrl.Result, error) {
	var job batchv1.Job
	err := r.Get(ctx, types.NamespacedName{Namespace: backup.Namespace, Name: backup.Status.JobName}, &job)
	if apierrors.IsNotFound(err) {
		backup.Status.Phase = dsov1alpha1.PhaseFailed
		backup.Status.Message = "backup Job disappeared before completing"
		return ctrl.Result{}, r.Status().Update(ctx, backup)
	}
	if err != nil {
		return ctrl.Result{}, err
	}

	switch {
	case job.Status.Succeeded > 0:
		backup.Status.Phase = dsov1alpha1.PhaseSucceeded
		backup.Status.Message = "pg_dump completed; see: kubectl logs job/" + job.Name
		backup.Status.CompletionTime = time.Now().UTC().Format(time.RFC3339)
		return ctrl.Result{}, r.Status().Update(ctx, backup)
	case job.Status.Failed > 0:
		backup.Status.Phase = dsov1alpha1.PhaseFailed
		backup.Status.Message = "pg_dump Job failed; see: kubectl logs job/" + job.Name
		backup.Status.CompletionTime = time.Now().UTC().Format(time.RFC3339)
		return ctrl.Result{}, r.Status().Update(ctx, backup)
	default:
		// Still running -- Owns(&batchv1.Job{}) means the Job's next status
		// change re-triggers Reconcile anyway; the requeue is just a backstop.
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
}

// buildJob renders a one-shot Job that runs `pg_dump` against
// spec.targetService, authenticating with the SAME Secret/ConfigMap keys
// the backend Deployment already uses.
func (r *DbBackupReconciler) buildJob(backup *dsov1alpha1.DbBackup) *batchv1.Job {
	image := backup.Spec.Image
	if image == "" {
		image = defaultDumpImage
	}
	target := backup.Spec.TargetService
	if target == "" {
		target = defaultService
	}

	backoff := int32(1)
	dumpCmd := fmt.Sprintf(
		`set -e; pg_dump -h %s -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /tmp/backup.sql; echo "BACKUP_OK: $(wc -l < /tmp/backup.sql) lines dumped from %s"`,
		target, target,
	)

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: fmt.Sprintf("dbbackup-%s-", backup.Name),
			Namespace:    backup.Namespace,
			Labels: map[string]string{
				"app":       "task-tracker",
				"component": "dbbackup-operator",
				"dbbackup":  backup.Name,
			},
		},
		Spec: batchv1.JobSpec{
			BackoffLimit: &backoff,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "task-tracker", "component": "dbbackup-operator"},
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{
						{
							Name:    "pg-dump",
							Image:   image,
							Command: []string{"sh", "-c", dumpCmd},
							Env: []corev1.EnvVar{
								{Name: "PGPASSWORD", ValueFrom: secretRef("POSTGRES_PASSWORD")},
								{Name: "POSTGRES_USER", ValueFrom: secretRef("POSTGRES_USER")},
								{Name: "POSTGRES_DB", ValueFrom: configMapRef("POSTGRES_DB")},
							},
						},
					},
				},
			},
		},
	}
}

func secretRef(key string) *corev1.EnvVarSource {
	return &corev1.EnvVarSource{
		SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: secretName},
			Key:                  key,
		},
	}
}

func configMapRef(key string) *corev1.EnvVarSource {
	return &corev1.EnvVarSource{
		ConfigMapKeyRef: &corev1.ConfigMapKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: configMapName},
			Key:                  key,
		},
	}
}

// SetupWithManager registers the controller: DbBackup is the primary
// watched resource, and Owns(&batchv1.Job{}) makes a status change on a Job
// this controller created (via SetControllerReference above) enqueue its
// owning DbBackup for another Reconcile -- event-driven, not just polling.
func (r *DbBackupReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&dsov1alpha1.DbBackup{}).
		Owns(&batchv1.Job{}).
		Complete(r)
}
