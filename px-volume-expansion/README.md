
1. Create the Storage Class with the `allowVolumeExpansion: true` parameter:

```
oc create -f manifests/sc-auto-extend.yaml
```

2. Deploy Postgres - create a `namespace`, `pvc`, `deployment` and `service` for testing:

```
oc create -f manifests/namespace.yaml
oc create -f manifests/pvc.yaml
oc create -f manifests/deployment.yaml
```

3. Create an `AutopilotRule` rule which defines how the Autopilot must handle scaling:

```
oc create -f manifests/autopilotrule.yaml
```

4. Check PX Autopilot events:

```
oc get events --field-selector involvedObject.kind=AutopilotRule,involvedObject.name=volume-resize --all-namespaces --sort-by .lastTimestamp
```

The expected output:

```
NAMESPACE   LAST SEEN   TYPE     REASON       OBJECT                        MESSAGE
default     2m48s       Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from  => Initializing
default     2m37s       Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from Initializing => Normal
```

5. Check the `data` volume size of the Postgres instance:

```
POSTGRES_POD=$(oc get pods -n px-volume-expansion -l app=postgres -o jsonpath='{.items[0].metadata.name}')
oc exec -it -n px-volume-expansion $POSTGRES_POD -- df -h /var/lib/postgresql/data
```

The expected output:

```
Filesystem                      Size  Used Avail Use% Mounted on
/dev/pxd/pxd778591918787647079  4.9G   44M  4.8G   1% /var/lib/postgresql/data
```

6. Try to generate a load and observe the Autopilot's behaviour:

The suggested method on https://px-docs-poc.netlify.app/autopilot_volume-resize doesn't work.
It doesn't work as the `AutopilotRule` we create expecting to see the volume being filled to more than 50% for 5 minutes.
So the next commands won't be helpful, as the `pgbench` will cleanup the test records.

```
oc exec -it -n px-volume-expansion $POSTGRES_POD -- createdb pxdemo2
oc exec -it -n px-volume-expansion $POSTGRES_POD -- pgbench -i -s 50 pxdemo2
```

Instead you can just create a few (or just single) large file with `dd`:

```
 oc exec -it -n px-volume-expansion $POSTGRES_POD -- dd if=/dev/zero of=/var/lib/postgresql/data/1000MB_dd_file bs=1M count=1000
 oc exec -it -n px-volume-expansion $POSTGRES_POD -- dd if=/dev/zero of=/var/lib/postgresql/data/1000MB_dd_file-2 bs=1M count=1000
 oc exec -it -n px-volume-expansion $POSTGRES_POD -- dd if=/dev/zero of=/var/lib/postgresql/data/1000MB_dd_file-3 bs=1M count=1000
```

In a separate console run - you must wait for 5 minutes to see the `Autopilot` takes an action:

```
watch 'oc get events --field-selector involvedObject.kind=AutopilotRule,involvedObject.name=volume-resize --all-namespaces --sort-by .lastTimestamp'
```

The expected output:

```
NAMESPACE   LAST SEEN   TYPE     REASON       OBJECT                        MESSAGE
default     62m         Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from  => Initializing
default     62m         Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from Initializing => Normal
default     52m         Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from Normal => Triggered
default     51m         Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from Triggered => ActiveActionsPending
default     50m         Normal   Transition   autopilotrule/volume-resize   rule: volume-resize:pvc-0274b599-cce8-4505-9cd6-14889f6ed45a transition from ActiveActionsPending => Normal
```



## Addittional notes

While running test we observed the Autopilot attempts to assess PVCs which doesn't belong to the PX StorageClasses:

```
time="03-10-2025 15:38:49" level=error msg="Failed to get dependents while scraping all objects: rpc error: code = NotFound desc = Volume id pvc-4497746d-1520-49bc-b0fd-c751ab1906c2 not found" file="engine.go:332" component=engine-v1 rule=:pvc-4497746d-1520-49bc-b0fd-c751ab1906c2=
```

The kubectl/oc out:

```
oc get pvc -A | grep pvc-4497746d-1520-49bc-b0fd-c751ab1906c2
px-bench                   px-bench-results                            Bound    pvc-4497746d-1520-49bc-b0fd-c751ab1906c2   20Gi       RWX            ocs-storagecluster-cephfs     <unset>                 15d
```

The behaviour shared with the Portworx team.