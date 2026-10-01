# SOPS + age Secrets

How app and platform secrets are encrypted in git and applied to the cluster.
See [ADR-017](adrs/017-vault-paused-sops-default.md) for why SOPS is the default (Vault paused).

## How it works

1. Encrypted files (`*.enc.yaml`) live in git under `<chart>/sops/` — **never** inside `templates/`.
2. ArgoCD does **not** decrypt SOPS. Encrypted secrets are applied out-of-band:
   `bootstrap/init-sops.sh` pulls the age key from RustFS (`s3://secrets-homelab/sops/keys.txt`),
   runs `sops decrypt | kubectl apply` for every `<chart>/sops/*.enc.yaml`, then shreds the key file.
3. Entry points: `just secrets-apply` (local) and `.github/workflows/deploy.yaml` (CI, installs `sops v3.10.2` first).

> **Order: GitOps first, SOPS second.** `init-sops.sh` applies Secrets into
> existing namespaces but never creates them — on a bare cluster run
> `./bootstrap/init-gitops.sh prod` (and let ArgoCD sync) before applying
> secrets, or the apply fails with "namespace not found".

## Prerequisites

- `sops` and `age` binaries installed.
- The age private key available locally (never committed). CI restores it from RustFS automatically.
- `.sops.yaml` at the repo root with a `creation_rules` entry whose `path_regex` matches
  `platform/*/sops/*.enc.yaml` (and `apps/*/sops/*.enc.yaml` if you add app charts).

## Creating a new encrypted secret

1. Make sure your age key is available and `SOPS_AGE_KEY_FILE` points at it
   (CI uses `/tmp/age-keys.txt`; locally it comes from your `.env`):
   ```bash
   echo $SOPS_AGE_KEY_FILE
   ```
   No key yet? Generate one and register its recipient in `.sops.yaml`:
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   # copy the "public key: age1..." line into .sops.yaml under creation_rules
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   ```
2. Write the plaintext manifest as pure YAML at `<chart>/sops/<name>.enc.yaml`
   (e.g. `platform/monitoring/sops/loki-s3.enc.yaml`). It must be a plain `Secret` —
   see "No Helm templating" below.
3. Encrypt in place **from the repo root, with the repo-relative path** —
   `sops` matches `path_regex` against the path you pass, so an absolute path
   or another cwd fails with `no matching creation rules`.
   `--encrypted-regex '^(data|stringData)$'` encrypts only secret values,
   leaving `apiVersion`/`kind`/`metadata` readable (see below):
   ```bash
   sops --encrypt --in-place --encrypted-regex '^(data|stringData)$' platform/monitoring/sops/loki-s3.enc.yaml
   ```
4. Verify it is really encrypted before `git add`: the file must contain
   `ENC[AES256_GCM` markers and no plaintext values:
   ```bash
   grep -c 'ENC\[AES256_GCM' platform/monitoring/sops/loki-s3.enc.yaml
   ```
5. Sanity-check the decrypted render without applying:
   ```bash
   sops decrypt platform/monitoring/sops/loki-s3.enc.yaml | kubectl apply --dry-run=client -f -
   ```
6. Apply for real: `just secrets-apply` (loads `.env`, restores the key,
   decrypts + applies, shreds the key).

To edit an existing encrypted file, open it through sops itself
(decrypts to a temp file, re-encrypts on save):

```bash
sops platform/monitoring/sops/loki-s3.enc.yaml
```

## Lessons learned (read before creating one)

### 1. No Helm templating inside `.enc.yaml`

`sops` parses the file as strict YAML before encrypting. A Helm line like
`{{- if .Values.vault.enabled }}` is not valid YAML and breaks encryption.
Keep `.enc.yaml` files 100% pure YAML with no `{{ }}`. If you need conditional
behavior, put the gate in a separate wrapper template under `templates/` —
never in the encrypted file itself.

### 2. Quote JSON values with a block scalar

A Secret whose value is inline JSON (e.g. an S3 config blob) breaks YAML parsing
once encrypted. Use a literal block scalar:

```yaml
stringData:
  config.json: |-
    {"accessKey":"...","secretKey":"..."}
```

### 3. `path_regex` must match the real directory

If `.sops.yaml` still points at an old location (e.g. `templates/secrets/`) while
files live in `<chart>/sops/`, `sops encrypt` fails with `no matching creation
rules`. After moving directories, update `.sops.yaml` first, encrypt second.

### 4. Never commit plaintext, verify every time

After encrypting, grep the file for your plaintext values before `git add`.
The `ENC[AES256_GCM` markers are the proof. `init-sops.sh` also refuses to run
if any `*.enc.yaml` is found inside `templates/`.

## Rotating the age key

1. Generate a new recipient (`age-keygen`), add it to `.sops.yaml`.
2. Re-encrypt every file: `sops updatekeys -y <file>` for each `*.enc.yaml`.
3. Upload the new `keys.txt` to `s3://secrets-homelab/sops/keys.txt` and document the rotation.
4. Shred the old key material.
