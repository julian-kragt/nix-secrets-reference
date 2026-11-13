set shell := ["bash", "-euo", "pipefail", "-c"]

# Where the keys live on a host (see DESIGN.md). Override either with SOPS_AGE_KEY_FILE.
host_age_key := env_var_or_default("SOPS_AGE_KEY_FILE", "/var/lib/sops-nix/key.txt")
user_age_key := env_var_or_default("SOPS_AGE_KEY_FILE", env_var("HOME") + "/.config/sops/age/keys.txt")

default:
    @just --list

develop:
    nix develop

# ── editing ───────────────────────────────────────────────────────────────────
# Every file is encrypted to keys that live on its hosts only, so editing runs there.
# Paths come from the flake's secretsEntry, checked by its installerSecretsData output.

# Print a field of the checked layout ("null" when it doesn't apply to userMode).
layout field:
    @nix eval --quiet --json '.#installerSecretsData.{{field}}' | tr -d '"'

# The host's own secrets; run on the host as root (decrypts with the host key).
edit-host host:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    [[ -n "$h" ]] || { echo "edit-host: need a hostname" >&2; exit 1; }
    export SOPS_AGE_KEY_FILE='{{host_age_key}}'
    exec sops "$(just layout hostPath)/$h.yaml"

# A user's secrets on one host; run on that host as the user (decrypts with the user's key there).
edit-host-user host user:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    u='{{user}}'
    [[ -n "$h" && -n "$u" ]] || { echo "edit-host-user: need a hostname and a username" >&2; exit 1; }
    dir=$(just layout hostUserPath)
    [[ "$dir" != null ]] || { echo "edit-host-user: userMode has no per-host user files" >&2; exit 1; }
    export SOPS_AGE_KEY_FILE='{{user_age_key}}'
    exec sops "$dir/$h-$u.yaml"

# A user's secrets on every host they are on; run as the user on any of those hosts.
edit-shared-user user:
    #!/usr/bin/env bash
    set -euo pipefail
    u='{{user}}'
    [[ -n "$u" ]] || { echo "edit-shared-user: need a username" >&2; exit 1; }
    dir=$(just layout sharedUserPath)
    [[ "$dir" != null ]] || { echo "edit-shared-user: userMode has no shared user files" >&2; exit 1; }
    export SOPS_AGE_KEY_FILE='{{user_age_key}}'
    exec sops "$dir/$u.yaml"

# Open any sops file with SOPS_AGE_KEY_FILE as the key (default: the user key).
edit file:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE='{{user_age_key}}'
    exec sops "{{file}}"

# Re-encrypt every file this host can read (its own, its users', shared ones it is on) to .sops.yaml's recipients; run on the host as root.
rekey host:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    export SOPS_AGE_KEY_FILE='{{host_age_key}}'
    me=$(age-keygen -y "$SOPS_AGE_KEY_FILE")
    host_dir=$(just layout hostPath)
    host_user_dir=$(just layout hostUserPath)
    shared_dir=$(just layout sharedUserPath)
    shopt -s nullglob
    files=("$host_dir/$h.yaml")
    [[ "$host_user_dir" == null ]] || files+=("$host_user_dir/$h"-*.yaml)
    if [[ "$shared_dir" != null ]]; then
      for f in "$shared_dir"/*.yaml; do
        if grep -qF "$me" "$f"; then files+=("$f"); fi
      done
    fi
    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      if ! grep -qE '^[[:space:]]*sops:' "$f"; then
        echo ">>> skip $f (not sops-encrypted yet)"
        continue
      fi
      echo ">>> sops updatekeys -y $f"
      sops updatekeys -y "$f"
    done

# ── keys ──────────────────────────────────────────────────────────────────────

# Print the age recipient (public key) of an age key file, for .sops.yaml.
recipient key-file:
    age-keygen -y '{{key-file}}'

# Hash a login password for hashedPassword (sha-512 crypt).
hash-password:
    mkpasswd -m sha-512
