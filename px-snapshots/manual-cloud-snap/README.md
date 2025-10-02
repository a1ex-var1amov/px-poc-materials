## Prerequisites

1. Create a S3 bucket; in this case we will create it via Noobaa GW

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

2. Get a secret for Noobaa S3 bucket:

```
❯ oc get secret fcloud-snaps-px -o yaml
apiVersion: v1
data:
  AWS_ACCESS_KEY_ID: WVU4ZWhhY1VCUVZJMmx3bW1uVlU=
  AWS_SECRET_ACCESS_KEY: bCtTelZUbWNKTk5qbkVBK0pTMW9QUEJqMkFkSzNCNUFJSGkvajltUg==
kind: Secret
metadata:
  creationTimestamp: "2025-10-02T16:22:50Z"
  finalizers:
  - objectbucket.io/finalizer
  labels:
    app: noobaa
    bucket-provisioner: openshift-storage.noobaa.io-obc
    noobaa-domain: openshift-storage.noobaa.io
  name: cloud-snaps-px
  namespace: openshift-storage
  ownerReferences:
  - apiVersion: objectbucket.io/v1alpha1
    blockOwnerDeletion: true
    controller: true
    kind: ObjectBucketClaim
    name: cloud-snaps-px
    uid: 4c8a86d2-4213-4755-ab2b-19cbe707f6b4
  resourceVersion: "95979970"
  uid: 07593695-9c9b-4194-bae6-53580589718b
type: Opaque
```

3. Configure Portworx according to the guide:

```
pxctl credentials create --provider s3  --s3-secret-key l+SzVTmcJNNjnEA+JS1oPPBj2AdK3B5AIHi/j9mR --s3-access-key YU8ehacUBQVI2lwmmnVU --s3-endpoint s3-openshift-storage.apps.hwinf-k8s-os-lab.nvparkosdev.nvidia.com --s3-storage-class STANDARD --bucket cloud-snaps-px-716c14d8-ff6d-4de7-a5d4-ecd54d9b44d4 noobaa-s3 --s3-region local --s3-disable-ssl
```

4. create snapshot

`oc create -f mysql-volume-snapshot-cloud.yaml`

5. Check the Snapshot

`oc get volumesnapshot.volumesnapshot.external-storage.k8s.io/mysql-snapshot-cloud`

```
❯ oc get volumesnapshot.volumesnapshot.external-storage.k8s.io/mysql-snapshot-cloud  
NAME                   AGE
mysql-snapshot-cloud   39s
```

6. Check the fact snapshot is made:

```
❯ oc get volumesnapshotdatas
NAME                                                       AGE
k8s-volume-snapshot-9ad04f53-6d9a-43c2-95c7-8c29bdcc0774   104s
```

7. Describe the `volumesnapshotdatas`

```
❯ oc describe volumesnapshotdatas
Name:         k8s-volume-snapshot-9ad04f53-6d9a-43c2-95c7-8c29bdcc0774
Namespace:
Labels:       <none>
Annotations:  <none>
API Version:  volumesnapshot.external-storage.k8s.io/v1
Kind:         VolumeSnapshotData
Metadata:
  Creation Timestamp:  2025-10-02T18:55:26Z
  Generation:          1
  Resource Version:    96084043
  UID:                 106eea28-4302-45f0-b059-023b96981d5a
Spec:
  Persistent Volume Ref:
    Kind:  PersistentVolume
    Name:  pvc-45a1bd7d-93f7-45aa-9bfb-339c7c3bd792
  Portworx Volume:
    Snapshot Id:         cloud-snaps-px-716c14d8-ff6d-4de7-a5d4-ecd54d9b44d4/487778063228724423-789582301178466521
    Snapshot Task ID:    4683e490-13cb-43ce-88fc-6d8a2cb30aaf
    Snapshot Type:       cloud
    Volume Provisioner:  pxd.portworx.com
  Volume Snapshot Ref:
    Kind:  VolumeSnapshot
    Name:  px-snapshots/mysql-snapshot-cloud-4683e490-13cb-43ce-88fc-6d8a2cb30aaf
Status:
  Conditions:
    Last Transition Time:  2025-10-02T18:55:26Z
    Message:               Snapshot created successfully and it is ready
    Reason:
    Status:                True
    Type:                  Ready
  Creation Timestamp:      <nil>
Events:                    <none>
```

8. With Noobaa GW you can also validate the snapshot is made via OCP console:

Storage > Object Storage > Click on your bucket 

NOTE: The ID of the Snapshot and "Folder name" is available in the `volumesnapshotdatas` definition
See the ID in `spec.portworxVolume.snapshotId` - `<bucket name>/<ID>`, for example:
`cloud-snaps-px-716c14d8-ff6d-4de7-a5d4-ecd54d9b44d4/487778063228724423-789582301178466521`

