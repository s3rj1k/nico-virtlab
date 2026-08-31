# lab/patches

Ad-hoc lab tweaks applied by `apply.sh`, dispatched by extension. They target the
`infra-controller/` submodule working tree, not this repo, so every path inside them
is relative to the NICo root and `apply.sh` cds there before touching anything.
Override `NICO_ROOT` to patch a checkout kept elsewhere. `build.yml` runs it for you
against the pinned commit, so the calls below are for inspecting and reverting by hand.

- `*.patch` is a `git apply` diff. For Rust source, shell, Go-templated Helm, YAML blobs.
- `*.ytt.yaml` is a ytt overlay on the `#! target: <path>` it names. For structured YAML.

```bash
apply.sh        # apply all, sorted by NNNN- prefix
apply.sh -n     # dry-run
apply.sh -R     # revert
apply.sh -f     # patches only: retry with --fuzz
apply.sh <file> # just one
```

Overlays regenerate their target from HEAD each run (idempotent). A file can use both:
ytt first, then a patch cut against its output.
