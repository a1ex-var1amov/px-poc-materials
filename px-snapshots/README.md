## Portworx Snapshots Test Kit

This kit provides Kubernetes manifests and a step-by-step test plan to validate Portworx snapshots: Local, Cloud, and 3D Snapshots, plus guidance for SkinnySnaps and RelaxedReclaim behaviors. It leverages CSI snapshots and STORK where appropriate.

References: [Create Snapshots in Portworx](https://docs.portworx.com/portworx-enterprise/operations/create-snapshots)

### Prerequisites
- Kubernetes cluster with cluster-admin access (kubectl ≥ 1.22)
- Portworx Enterprise installed and healthy (PX-Store nodes Ready)
- STORK installed and running
- CSI snapshot CRDs installed in the cluster (VolumeSnapshot, VolumeSnapshotContent, VolumeSnapshotClass)
- A functional Portworx `StorageClass` for volumes
- For Cloud Snapshots:
  - CloudSnap configured: Portworx cloud credentials/secrets and backup location set up
  - Sufficient bandwidth and object storage bucket
- For 3D Snapshots:
  - Application uses a `Deployment`/`StatefulSet` and PVCs provisioned by Portworx
  - STORK Rules for pre/post hooks (optional but recommended)

Note: In airgapped bare metal environments, only Local Snapshots are supported. Cloud Snapshots are not available. See reference above.

### Folder Structure
```
manifests/
  00-namespace.yaml
  01-storageclass.yaml
  app/
    deploy.yaml
    pvc-fast.yaml
    pvc-regular.yaml
  csi/
    volumesnapshotclass-local.yaml
    volumesnapshotclass-cloud.yaml
    volumesnapshot-local.yaml
    volumesnapshot-cloud.yaml
  stork/
    rules.yaml
    volumesnapshot.yaml
    volumesnapshotschedule.yaml
    groupvolumesnapshot.yaml
  mysql/
    secret.yaml
    pvc.yaml
    deploy.yaml
    csi-snapclass.yaml
    csi-snapshot.yaml
    stork-rules.yaml
    stork-volumesnapshot.yaml
    restore.yaml
```

### Quickstart
```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-storageclass.yaml
kubectl apply -f manifests/mysql/secret.yaml
kubectl apply -f manifests/mysql/pvc.yaml
kubectl apply -f manifests/mysql/deploy.yaml
```

Wait for the app Pod to be Running and writing data to the PVC.

### Test Plan

#### 1) Local CSI Snapshot (MySQL)
1. Create a `VolumeSnapshotClass` for local snapshots:
   ```bash
   kubectl apply -f manifests/mysql/csi-snapclass.yaml
   ```
2. Create a `VolumeSnapshot` from the PVC:
   ```bash
   kubectl apply -f manifests/mysql/csi-snapshot.yaml
   ```
3. Verify snapshot status:
   ```bash
   kubectl -n px-snapshots get volumesnapshot
   kubectl -n px-snapshots describe volumesnapshot mysql-snap-local
   ```
4. Restore snapshot to a new PVC by creating a PVC from snapshot:
   ```bash
   kubectl -n px-snapshots apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-from-local-snap
     namespace: px-snapshots
   spec:
     storageClassName: px-sc
     dataSource:
       name: mysql-snap-local
       kind: VolumeSnapshot
       apiGroup: snapshot.storage.k8s.io
     accessModes: [ "ReadWriteOnce" ]
     resources:
       requests:
         storage: 2Gi
   EOF
   ```
5. Restore using the MySQL restore deployment and validate data:
   ```bash
   # Restore from mysql-snap-local and start verifier
   kubectl apply -f manifests/mysql/restore.yaml
   kubectl -n px-snapshots rollout status deploy/mysql-restore
   # Check recent rows and table health from the verifier container
   kubectl -n px-snapshots logs deploy/mysql-restore -c verifier --tail=50
   ```

#### 2) Cloud CSI Snapshot (MySQL)
Precondition: Portworx CloudSnap configured.
1. Apply Cloud `VolumeSnapshotClass`:
   ```bash
   kubectl apply -f manifests/mysql/csi-snapclass-cloud.yaml
   ```
2. Create Cloud `VolumeSnapshot`:
   ```bash
   kubectl apply -f manifests/mysql/csi-snapshot-cloud.yaml
   ```
3. Verify completion and optional off-cluster presence per Portworx monitoring/pxctl.
4. Restore from cloud snapshot similar to Local by creating a PVC from snapshot, then mount in a Pod to verify contents.

#### 3) 3D Snapshot with STORK (MySQL)
STORK can orchestrate application-consistent snapshots across multiple PVCs.
1. Apply optional pre/post exec `Rule`s:
   ```bash
   kubectl apply -f manifests/mysql/stork-rules.yaml
   ```
2. Trigger a `VolumeSnapshot` via STORK for the app PVC(s):
   ```bash
   kubectl apply -f manifests/mysql/stork-volumesnapshot.yaml
   kubectl -n px-snapshots get volumesnapshot -w
   ```
3. Create a `VolumeSnapshotSchedule` for periodic snapshots:
   ```bash
   kubectl apply -f manifests/mysql/stork-volumesnapshotschedule.yaml
   kubectl -n px-snapshots get volumesnapshotschedule
   ```
4. For apps with multiple PVCs, use `GroupVolumeSnapshot`:
   ```bash
   kubectl apply -f manifests/stork/groupvolumesnapshot.yaml
   ```
5. Restore as with CSI: create PVCs from the produced `VolumeSnapshot`s.

#### 4) SkinnySnaps and RelaxedReclaim
- SkinnySnaps: Portworx optimization to reduce full data copy; primarily controlled via Portworx configuration/annotations. Validate by measuring snapshot times and storage usage across repeated snapshots.
- RelaxedReclaim: Allows snapshot objects to be reclaimed more flexibly. Validate by deleting `VolumeSnapshot` and confirming associated resources cleanup behavior per policy.

### Cleanup
```bash
kubectl -n px-snapshots delete pod restore-check-local --ignore-not-found
kubectl delete -f manifests/csi/ --ignore-not-found
kubectl delete -f manifests/stork/ --ignore-not-found
kubectl delete -f manifests/mysql/ --ignore-not-found
kubectl delete -f manifests/01-storageclass.yaml --ignore-not-found
kubectl delete -f manifests/00-namespace.yaml --ignore-not-found
```

### Notes

## MySQL Consistency Test (App-Consistent Snapshots)

This scenario adds a MySQL workload with continuous writes and uses STORK pre/post exec rules to quiesce MySQL during snapshot, improving consistency.

#### Deploy MySQL and start writes
```bash
kubectl apply -f manifests/mysql/secret.yaml
kubectl apply -f manifests/mysql/pvc.yaml
kubectl apply -f manifests/mysql/deploy.yaml
kubectl -n px-snapshots rollout status deploy/mysql
```

The sidecar writer continuously inserts rows into `pxdb.t`.

#### Create a CSI local snapshot (crash-consistent)
```bash
kubectl apply -f manifests/mysql/csi-snapclass.yaml
kubectl apply -f manifests/mysql/csi-snapshot.yaml
kubectl -n px-snapshots get volumesnapshot mysql-snap-local -w
```

This produces a crash-consistent snapshot (no quiesce). You can restore it to validate recovery.

#### Create a STORK snapshot with pre/post rules (app-consistent)
```bash
kubectl apply -f manifests/mysql/stork-rules.yaml
kubectl apply -f manifests/mysql/stork-volumesnapshot.yaml
kubectl -n px-snapshots get volumesnapshot mysql-stork-snap -w
```

The pre-rule issues `FLUSH TABLES WITH READ LOCK`, briefly pausing writes; the post-rule unlocks tables after the snapshot.

#### Restore and verify
1. Restore from the CSI snapshot:
   ```bash
   # Uses mysql-snap-local by default in restore.yaml; change name to mysql-stork-snap to test the app-consistent snapshot
   kubectl apply -f manifests/mysql/restore.yaml
   kubectl -n px-snapshots rollout status deploy/mysql-restore
   ```
2. Verify table integrity and rows:
   ```bash
   kubectl -n px-snapshots logs deploy/mysql-restore -c verifier --tail=50
   # Optionally run manual queries
   kubectl -n px-snapshots exec deploy/mysql-restore -c verifier -- \
     sh -c "mysql -h 127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD -e 'USE pxdb; CHECK TABLE t QUICK;'"
   ```

Expected:
- Crash-consistent snapshot usually recovers cleanly with InnoDB crash recovery, but may contain partially applied last transactions.
- App-consistent snapshot should not require crash recovery and should reflect a clean, locked state at snapshot time.

#### How to tell if the snapshot was app-consistent
- Observe MySQL logs: for app-consistent, you'll see the lock/unlock around snapshot time.
- Compare `CHECK TABLE` results and crash recovery messages in MySQL logs on the restored deployment.
- Optionally compare row counts before and after snapshot by querying live MySQL vs restored MySQL.

#### Cleanup (MySQL scenario)
```bash
kubectl delete -f manifests/mysql/restore.yaml --ignore-not-found
kubectl delete -f manifests/mysql/stork-volumesnapshot.yaml --ignore-not-found
kubectl delete -f manifests/mysql/csi-snapshot.yaml --ignore-not-found
kubectl delete -f manifests/mysql/csi-snapclass.yaml --ignore-not-found
kubectl delete -f manifests/mysql/deploy.yaml --ignore-not-found
kubectl delete -f manifests/mysql/pvc.yaml --ignore-not-found
kubectl delete -f manifests/mysql/secret.yaml --ignore-not-found
```
- The suggested way to manage snapshots on Kubernetes is to use STORK. For information on creating Portworx snapshots using PVC annotations and cloning to PVCs, see the reference docs.
- When cloning a volume, the clone will inherit the `StorageClass` of the clone spec. Match the original `StorageClass` if the clone should reside in the same pod configuration. See reference.


