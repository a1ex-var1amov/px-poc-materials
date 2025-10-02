## Prerequisites (CloudSnap with CSI GA)

1. Create an S3-compatible bucket (example: NooBaa ObjectBucketClaim)

```
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: cloud-snaps-px
  namespace: openshift-storage
spec:
  additionalConfig:
    bucketclass: noobaa-default-bucket-class
  generateBucketName: cloud-snaps-px-
  storageClassName: openshift-storage.noobaa.io
```

2. Retrieve the generated access keys secret (example shows OBC secret):

```
oc get secret cloud-snaps-px -n openshift-storage -o yaml
```

3. Create Portworx CloudSnap credentials using your bucket endpoint and keys:

```
pxctl credentials create --provider s3 \
  --s3-access-key <ACCESS_KEY_ID> \
  --s3-secret-key <SECRET_ACCESS_KEY> \
  --s3-region <REGION> \
  --s3-endpoint <S3_ENDPOINT> \
  --s3-storage-class STANDARD \
  --bucket <BUCKET_NAME> \
  <CRED_NAME>
```

4. Apply a cloud-capable VolumeSnapshotClass (CSI GA):

```
kubectl apply -f ../manifests/csi/volumesnapshotclass-cloud.yaml
```

## Create a cloud snapshot (manual)

1. Create the VolumeSnapshot:

```
oc apply -f mysql-volume-snapshot-cloud.yaml
```

2. Watch for readiness:

```
oc -n px-snapshots get volumesnapshot mysql-snapshot-cloud -w
```

3. Verify via Portworx layer (optional):

```
pxctl cloudsnap list
```

4. Locate the CloudSnap object in your object store using the ID reported by Portworx.

Notes:
- Older, annotation-based `volumesnapshot.external-storage.k8s.io` objects are replaced by CSI GA `snapshot.storage.k8s.io/v1` API and a `VolumeSnapshotClass` with `csi.openstorage.org/snapshot-type: cloud`.

