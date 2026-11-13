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
4. `sg docker -c 'docker login oci.s3rj1k.fyi'`, or your own registry, see below
5. `ansible-playbook lab/ansible/build.yml -K`
6. `ansible-playbook -i lab/ansible/inventory.yml lab/ansible/mgmt.yaml`
7. `ansible-playbook -i lab/ansible/inventory.yml lab/ansible/worker.yaml`
8. `cd infra-controller`
9. `../lab/scripts/env.sh`, then `direnv reload`
10. `../lab/scripts/setup.sh` (NICo Core only, no REST or RMS, DPF only for the dpf flavour)
11. `../lab/scripts/register.sh`, then `../lab/scripts/provision-instance.sh`

- No `--recurse-submodules`? `git submodule update --init` before step 3.
- Step 5 resets the submodule to the pin, applies `lab/patches/base` and commits them as
  `WIP: lab patches (build)` on a detached HEAD — the stamped `VERSION`. The next run resets
  it, so the pin never moves. `-e nico_sync_submodule=false` builds the tree as it stands.
- Step 6 writes the admin kubeconfig to `~/.kube/config` on builder.
- Images go to `oci.s3rj1k.fyi/nv`. To use another registry, export `REGISTRY` (host)
  and `IMAGE_NAMESPACE` (path under it) before step 4 and keep them set for steps 5 and 9.
  `build.yml`, `env.sh` and the `apply.sh` overlays all follow them. Keep them in the
  gitignored `lab/registry.env` (with `REGISTRY_USER` / `REGISTRY_TOKEN` for the login)
  and `source` it first. `env.sh` loads it too and wires it into `.local_envrc`. With
  `REGISTRY_PULL_SECRET` set (`registry.env` maps it from `REGISTRY_TOKEN`), `setup.sh`
  creates the pull secrets and 0011 points core workloads at `imagepullsecret`.
- Inventory IPs default to the heat params; override with `MGMT_IP` / `WORKER_IP`, not `-e`.
- Step 9 wires `lab/scripts/lab.env` into `infra-controller/.local_envrc`, read by `.envrc`
  and `setup.sh`. Only a shell there has the vars.
- Step 10 re-applies `base` plus the `NICO_LAB_FLAVOR` group (lab.env, default `sushy`) to
  the tree, then runs `helm-prereqs/setup.sh --skip-rest --skip-rms`, plus `--skip-dpf`
  unless the flavour is `dpf`. Flavours are deploy-time config only and share the same
  images, see `lab/patches/README.md`. Step 11 is the sushy flavour.
- The emulated BMC (sushy) listens on 443 like a real one, so NICo needs no `bmc_proxy`
  and emulated and real BMCs can share the site. `REDFISH_PORT` overrides it on the worker.

## DPF flavour (real hosts with DPUs)

Same images as the sushy flavour, plus the DPU-side services, built once by hand from the
same tree after step 5 (it reuses the cross container that build left behind).

```bash
source ../lab/registry.env
REG="$REGISTRY/$IMAGE_NAMESPACE"; VER="$(git describe --tags --always | sed 's/^v//')"
echo "$REGISTRY_TOKEN" | helm registry login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin
# The dpu-agent image copies the MFT deb from the build context, as CI does.
curl -fsSL https://www.mellanox.com/downloads/MFT/mft-4.35.0-159-aarch64-deb.tgz | tar -xz
# Some Dockerfiles do not pin arm64, so default every build to it on this amd64 host.
# Only what the four charts deploy, docker-build-all also wants a Dockerfile upstream lacks.
for t in docker-build-otelcol docker-build-dpu-agent docker-build-dhcp-server docker-build-fmds; do
  (cd bluefield && sg docker -c "CARGO_HOME=$HOME/.cargo DOCKER_DEFAULT_PLATFORM=linux/arm64 \
    CARBIDE_IMAGE_REGISTRY=$REG VERSION=$VER cargo make $t")
done
sg docker -c "DOCKER_DEFAULT_PLATFORM=linux/arm64 docker build -t $REG/transceiver-exporter:$VER \
  -f bluefield/containers/transceiver-exporter/Dockerfile ."
for i in forge-dpu-agent forge-dhcp-server carbide-fmds otelcol-contrib transceiver-exporter; do
  sg docker -c "docker tag $REG/$i:$VER $REG/$i:virtlab && docker push $REG/$i:$VER && docker push $REG/$i:virtlab"
done
# helm-package-all still names the old carbide-* chart dirs.
for c in bluefield/charts/nico-*/; do helm package "$c" -d target/charts; done
for c in target/charts/nico-*.tgz; do helm push "$c" "oci://$REG/charts"; done
```

Then describe the remote site, wire it up, deploy and register. Addresses derived from
the heat stack have defaults, every CHANGEME and the remote prefixes are per deployment,
and the playbooks and `apply.sh` refuse to run without them.

```bash
cp ../lab/dpf.env.example ../lab/dpf.env                                    # VIPs, remote GW, DPU ports
cp ../lab/patches/values.local.example.yaml ../lab/patches/values.local.yaml  # remote networks, same prefixes
source ../lab/dpf.env
ansible-playbook -i ../lab/ansible/inventory.yml ../lab/ansible/dpf-net.yaml  # remote-gw.yaml, WireGuard hub, routes
ansible-playbook -i ../lab/ansible/inventory.yml ../lab/ansible/sonic.yaml    # sonic-vs ToR on the worker
NICO_LAB_FLAVOR=dpf ../lab/scripts/env.sh && direnv reload
../lab/scripts/setup.sh
DPU_HOST_BMC_MAC=.. DPU_HOST_SERIAL=.. DPU_HOST_BMC_PASSWORD=.. ../lab/scripts/register-dpu.sh
DPU_HOSTS_FILE=expected-machines.json ../lab/scripts/register-dpu.sh  # or NICo JSON, all entries
```

| Piece | Address | Source |
|---|---|---|
| WireGuard hub | worker `10.42.71.103:51820`, tunnel `10.42.72.1` | heat `worker_ip`, lab choice |
| WireGuard peer | remote GW, tunnel `10.42.72.2`, dials `DPF_WG_ENDPOINT` | per deployment |
| Remote prefixes | `DPF_REMOTE_PREFIXES`, routed mgmt to `192.168.42.103` to wg0 | per deployment |
| DHCP relay | GW `REMOTE_GW_LAN_ADDR` to Kea `192.168.42.201` | per deployment, base 0011 |
| DPU ports | GW NIC to VXLAN `4200+N` over wg0 to worker `brdpuN` | per deployment |
| sonic-vs | `Ethernet(4N)` on `brdpuN`, AS 65100, mgmt `192.168.123.10` | lab choice |

The bridged DPU ports carry MTU 1370 (wg0 1420 minus VXLAN). BGP adapts through the
TCP MSS, but larger frames from the DPU side are dropped on the way. The sonic-vs login
is the image default (`admin`/`YourPaSsWoRd`), reachable from the worker only.

### Remote site box

One Debian or Ubuntu box per remote site, set up by
`remote-gw.yaml` (also run by `dpf-net.yaml`). It needs, before the playbook runs:

- SSH with passwordless sudo for `REMOTE_GW_USER` from the builder.
- UDP to the worker floating IP on 51820 (`DPF_WG_ENDPOINT`). The box dials out, so it
  can sit behind NAT.
- An interface on the LAN of the DPU OOB ports (`REMOTE_GW_LAN_IF`), with no other DHCP
  server on it. It may be a NIC or a bridge.
- One interface per DPU port, in DPU order (`DPF_DPU_PORTS`). A bridge is used as is, a
  plain NIC gets its own `brdpuN`.
- Host and DPU BMCs reachable from mgmt on 443, either routed (static BMC IPs, as an
  `underlay` network in `values.local.yaml`) or over the OOB LAN with DHCP.
- Internet for the DPUs (nvcr.io, BFB downloads), from the site or through
  `REMOTE_GW_NAT_IF`.

What the playbook leaves there, all under systemd:

| Unit | Does |
|---|---|
| `wg-quick@wg0` | tunnel `10.42.72.2`, routes the lab provisioning net `192.168.42.0/24` |
| `lab-dpf-gw` | `REMOTE_GW_LAN_ADDR` on the OOB LAN, NAT, VXLAN `4200+N` per DPU port |
| `lab-dhcp-relay` | dnsmasq relay from the OOB LAN to Kea `192.168.42.201` |

`lab-dpf-gw` reruns every 30s, so interfaces that appear later (a hotplugged NIC, a bridge
created after boot) are picked up without rerunning the playbook.

DPF hands DPU BMCs the BFB registry at `NICO_DPF_K8S_API_VIP` and NodePort 30085
(`NICO_DPF_BFB_REGISTRY_NODEPORT`), so the BMCs must reach mgmt there over the tunnel.
Hosts can also come from an inventory file in NICo's `expected_machines` JSON format:

```bash
DPU_HOSTS_FILE=expected-machines.json ../lab/scripts/register-dpu.sh
```

Check it from the box with `sudo wg show` (recent handshake) and
`timeout 3 bash -c '</dev/tcp/192.168.42.211/443'` (NICo API over the tunnel). The
service VIPs do not answer ping.

## Moving the NICo pin

```bash
git -C infra-controller fetch origin
git -C infra-controller checkout --detach <sha>
lab/patches/apply.sh -n -g sushy
lab/patches/apply.sh -n -g dpf
lab/patches/check-compiled.sh
git add infra-controller
```

## admin-cli

```bash
lab/scripts/admin-cli.sh machine show
lab/scripts/admin-cli.sh -f json machine show
lab/scripts/admin-cli.sh vpc show
lab/scripts/admin-cli.sh network-segment show
```

## Machine validation

`Completed(Success)` means nothing failed, not that tests ran. Check results:

```bash
lab/scripts/admin-cli.sh machine-validation runs show
lab/scripts/admin-cli.sh machine-validation results show --validation-id <id>
```
