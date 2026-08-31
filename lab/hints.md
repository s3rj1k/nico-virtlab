# Lab Hints

NICo is the `infra-controller/` submodule, pinned at the revision this lab was built
against (`git -C infra-controller log -1`). Everything under `lab/` is this repo's.

Three VMs: builder, mgmt, worker. Clone on builder and run everything from there;
mgmt and worker are reached over SSH with the forwarded agent.

## Bring-up

Steps 1-7 from the repo root on builder, the rest from inside `infra-controller/`.
Needs passwordless sudo.

1. Provision from `lab/heat/lab-stack.yaml`.
2. `git clone --recurse-submodules git@github.com:s3rj1k/nico-virtlab.git`
3. `make -C infra-controller bootstrap`
4. `sg docker -c 'docker login oci.s3rj1k.fyi'`
5. `ansible-playbook lab/ansible/build.yml -K`
6. `ansible-playbook -i lab/ansible/inventory.yml lab/ansible/mgmt.yaml`
7. `ansible-playbook -i lab/ansible/inventory.yml lab/ansible/worker.yaml`
8. `cd infra-controller`
9. `../lab/scripts/env.sh`, then `direnv reload`
10. `helm-prereqs/setup.sh --skip-dpf`
11. `../lab/scripts/register.sh`, then `../lab/scripts/provision-instance.sh`

- No `--recurse-submodules`? `git submodule update --init` before step 3.
- Step 5 resets the submodule to the pin, applies `lab/patches` and commits them as
  `WIP: lab patches (build)` on a detached HEAD — the stamped `VERSION`. The next run resets
  it, so the pin never moves. `-e nico_sync_submodule=false` builds the tree as it stands.
- Step 6 writes the admin kubeconfig to `~/.kube/config` on builder.
- Inventory IPs default to the heat params; override with `MGMT_IP` / `WORKER_IP`, not `-e`.
- Step 9 wires `lab/scripts/lab.env` into `infra-controller/.local_envrc`, read by `.envrc`
  and `setup.sh`. Only a shell there has the vars.

## Moving the NICo pin

```bash
git -C infra-controller fetch origin
git -C infra-controller checkout --detach <sha>
lab/patches/apply.sh -n
git add infra-controller
```

## admin-cli

```bash
lab/scripts/admin-cli.sh machine show
lab/scripts/admin-cli.sh machine show -f json
lab/scripts/admin-cli.sh vpc show
lab/scripts/admin-cli.sh network-segment show
```

## Machine validation

`Completed(Success)` means nothing failed, not that tests ran. Check results:

```bash
lab/scripts/admin-cli.sh machine-validation runs show
lab/scripts/admin-cli.sh machine-validation results show --validation-id <id>
```
