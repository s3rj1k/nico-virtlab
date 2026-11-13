# lab/patches

Lab tweaks applied by `apply.sh`, dispatched by extension and grouped by directory.
They target the `infra-controller/` submodule working tree, not this repo, so every path
inside them is relative to the NICo root and `apply.sh` cds there before touching
anything. Override `NICO_ROOT` to patch a checkout kept elsewhere.

- `*.patch` is a `git apply` diff. For Rust source, shell, Go-templated Helm, YAML blobs.
- `*.ytt.yaml` is a ytt overlay on the `#! target: <path>` it names. For structured YAML.

## Groups

| Group     | Applied by                       | May touch                     |
|-----------|----------------------------------|-------------------------------|
| `base/`   | `build.yml` (images) and deploy  | anything                      |
| `sushy/`  | deploy only (`scripts/setup.sh`) | `helm/`, `helm-prereqs/` only |
| `dpf/`    | deploy only (`scripts/setup.sh`) | `helm/`, `helm-prereqs/` only |

`base` is what the images are compiled from, shared by every deployment. A deployment adds
exactly one flavour on top: `sushy` (emulated zero-DPU hosts on a flat VPC) or `dpf` (real
hosts with DPUs, provisioned through DPF). Flavours are deploy-time config only and never
change an image. `apply.sh` refuses a flavour file that reaches outside `helm/` and
`helm-prereqs/`, and refuses two flavours at once.

`NICO_LAB_FLAVOR` (default `sushy`, recorded in `lab.env` by `env.sh`) picks the flavour, so
`apply.sh` applies `base,$NICO_LAB_FLAVOR`. `-g` or `NICO_LAB_GROUPS` override it, and
`build.yml` always pins `base`.

```bash
apply.sh             # base plus $NICO_LAB_FLAVOR
apply.sh -g dpf      # base, then dpf
apply.sh -n          # dry-run
apply.sh -R          # revert
apply.sh -f          # patches only: retry with --fuzz (dry-runs first, never half-applies)
apply.sh <file>      # just one, e.g. 0016-machine-controller-honor-disable-lockdown.patch
check-compiled.sh    # which patches change image sources; must equal base/COMPILED
```

`base/COMPILED` lists, with sha256, the base patches that change compiled sources (today
0014-0016). Touching any of them, or adding a new one, means rebuilding the images;
`check-compiled.sh` fails until the manifest is updated on purpose.

Site values for overlays go in the gitignored `values.local.yaml` (see
`values.local.example.yaml`), `NICO_LAB_VALUES` points elsewhere. Defaults are declared in
`values.yaml`. Overlays editing the embedded TOML site config share `lib/toml.star`.

## Overlays

Overlays read data values declared in `values.yaml`. `image_registry` comes from
`NICO_IMAGE_REGISTRY` when set, so overlays name the same registry the build pushes to.

The first overlay on a target in a run renders from `HEAD`, so every run starts clean
and stays idempotent. Later overlays on the same target build on the working file, so a
flavour overlay keeps what `base` did to it. A patch cut against an overlay's output goes
after it. Always run the whole chain (that is what `apply.sh` does by default).
