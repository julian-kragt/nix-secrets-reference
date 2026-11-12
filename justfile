set shell := ["bash", "-euo", "pipefail", "-c"]

# Where the keys live on a host (see DESIGN.md). Override either with SOPS_AGE_KEY_FILE.
host_age_key := env_var_or_default("SOPS_AGE_KEY_FILE", "/var/lib/sops-nix/key.txt")
user_age_key := env_var_or_default("SOPS_AGE_KEY_FILE", env_var("HOME") + "/.config/sops/age/keys.txt")

default:
    @just --list

develop:
    nix develop

# ── editing ───────────────────────────────────────────────────────────────────
# Every file is encrypted to keys that live on its host only, so editing runs there.

# The host's own secrets; run on the host as root (decrypts with the host key).
edit-host host:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    h="${h#hosts/}"
    h="${h##*/}"
    h="${h%.yaml}"
    [[ -n "$h" ]] || { echo "edit-host: need a hostname" >&2; exit 1; }
    export SOPS_AGE_KEY_FILE='{{host_age_key}}'
    exec sops "hosts/$h.yaml"

# A user's secrets on one host; run on that host as the user (decrypts with the user's key there).
edit-host-user host user:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    u='{{user}}'
    [[ -n "$h" && -n "$u" ]] || { echo "edit-host-user: need a hostname and a username" >&2; exit 1; }
    export SOPS_AGE_KEY_FILE='{{user_age_key}}'
    exec sops "host-users/$h-$u.yaml"

# Open any sops file with SOPS_AGE_KEY_FILE as the key (default: the user key).
edit file:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE='{{user_age_key}}'
    exec sops "{{file}}"

# Re-encrypt one host's files to the recipients .sops.yaml now gives them; run on the host as root.
rekey host:
    #!/usr/bin/env bash
    set -euo pipefail
    h='{{host}}'
    export SOPS_AGE_KEY_FILE='{{host_age_key}}'
    shopt -s nullglob
    for f in "hosts/$h.yaml" host-users/"$h"-*.yaml; do
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
