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
```

### Quickstart
```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-storageclass.yaml
kubectl apply -f manifests/app/
```

Wait for the app Pod to be Running and writing data to the PVC.

### Test Plan

#### 1) Local CSI Snapshot
1. Create a `VolumeSnapshotClass` for local snapshots:
   ```bash
   kubectl apply -f manifests/csi/volumesnapshotclass-local.yaml
   ```
2. Create a `VolumeSnapshot` from the PVC:
   ```bash
   kubectl apply -f manifests/csi/volumesnapshot-local.yaml
   ```
3. Verify snapshot status:
   ```bash
   kubectl -n px-snapshots get volumesnapshot
   kubectl -n px-snapshots describe volumesnapshot data-snap-local
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
       name: data-snap-local
       kind: VolumeSnapshot
       apiGroup: snapshot.storage.k8s.io
     accessModes: [ "ReadWriteOnce" ]
     resources:
       requests:
         storage: 2Gi
   EOF
   ```
5. Mount restored PVC in a test Pod and validate data:
   ```bash
   kubectl -n px-snapshots apply -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: restore-check-local
     namespace: px-snapshots
   spec:
     containers:
     - name: busybox
       image: busybox:1.36
       command: ["sh","-c","ls -l /data && cat /data/testfile.txt || true && sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-from-local-snap
   EOF
   kubectl -n px-snapshots exec -it restore-check-local -- cat /data/testfile.txt || true
   ```

#### 2) Cloud CSI Snapshot
Precondition: Portworx CloudSnap configured.
1. Apply Cloud `VolumeSnapshotClass`:
   ```bash
   kubectl apply -f manifests/csi/volumesnapshotclass-cloud.yaml
   ```
2. Create Cloud `VolumeSnapshot`:
   ```bash
   kubectl apply -f manifests/csi/volumesnapshot-cloud.yaml
   ```
3. Verify completion and optional off-cluster presence per Portworx monitoring/pxctl.
4. Restore from cloud snapshot similar to Local by creating a PVC from snapshot, then mount in a Pod to verify contents.

#### 3) 3D Snapshot with STORK
STORK can orchestrate application-consistent snapshots across multiple PVCs.
1. Apply optional pre/post exec `Rule`s:
   ```bash
   kubectl apply -f manifests/stork/rules.yaml
   ```
2. Trigger a `VolumeSnapshot` via STORK for the app PVC(s):
   ```bash
   kubectl apply -f manifests/stork/volumesnapshot.yaml
   kubectl -n px-snapshots get volumesnapshot -w
   ```
3. Create a `VolumeSnapshotSchedule` for periodic snapshots:
   ```bash
   kubectl apply -f manifests/stork/volumesnapshotschedule.yaml
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
kubectl delete -f manifests/app/ --ignore-not-found
kubectl delete -f manifests/01-storageclass.yaml --ignore-not-found
kubectl delete -f manifests/00-namespace.yaml --ignore-not-found
```

### Notes
- The suggested way to manage snapshots on Kubernetes is to use STORK. For information on creating Portworx snapshots using PVC annotations and cloning to PVCs, see the reference docs.
- When cloning a volume, the clone will inherit the `StorageClass` of the clone spec. Match the original `StorageClass` if the clone should reside in the same pod configuration. See reference.


