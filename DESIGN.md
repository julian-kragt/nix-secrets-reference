# Design

This repository is one of three parts that never import each other's code. They agree on a layout: file paths,
`.sops.yaml` anchors and template keys.

| Part | Role |
| --- | --- |
| **nix-secrets** (this layout) | Holds encrypted files and the rules saying who can decrypt them. No Nix code besides a dev shell. |
| [nixos-config](https://github.com/JulianKragt/nixos-config) | **Reads** the files: a non-flake input `nix-secrets`, decrypted by sops-nix at activation. |
| [nixos-installer](https://github.com/julian-kragt/nixos-installer) | **Writes** the files: creates keys on the target, edits `.sops.yaml`, encrypts, commits, pushes and locks. |

[nixos-bootstrap](https://github.com/julian-kragt/nixos-bootstrap), the first-install system the installer starts
from, has no key or secrets code on purpose.

## Goals

1. **A compromised host exposes only its own secrets.** No key decrypts files of more than one host.
2. **Private keys never leave the machine they were made on.** Nothing is copied to a target, derived from another
   key or shared between roles (macOS hosts are the one exception, see below).
3. **Nothing is decrypted on the operator's machine.** Encryption needs only public keys, so the machine running the
   installer never holds a key that could read a secret.
4. **The layout is fixed and checkable.** File names, anchors and rules follow from the host and user names alone, so
   the installer can write them and verify a pushed commit without decrypting anything.

## Layout

```
.sops.yaml
hosts/<host>.yaml               secrets of the host itself
host-users/<host>-<user>.yaml   secrets of one user on one host
templates/host.yaml             schema of every hosts/*.yaml
templates/user.yaml             schema of every host-users/*.yaml
```

There is no `secrets/` or `sops/` subdirectory: the encrypted files sit next to `.sops.yaml`, so its `path_regex`es
are plain repository-relative paths.

A user's secrets are kept **per host**, not per user. The same person on two hosts has two files, each encrypted to a
different pair of keys, so one host's compromise doesn't reveal what the user has on another.

### Names

The installer only accepts names that keep every file, rule and anchor apart:

| Name | Pattern | Why |
| --- | --- | --- |
| host | `^[A-Za-z0-9][A-Za-z0-9-]*$` | No `_`, so `user_<user>_<host>` splits one way; nothing a glob or YAML anchor reads as syntax. |
| user | `^[a-z_][a-z0-9_]*$` | No `-`, so `<host>-<user>.yaml` splits one way, even when one host's name starts like another's. |

## Keys

One age key per role. Each is a standalone age key made with `age-keygen` on the machine that uses it. None is derived
from an SSH key: a leaked SSH key shouldn't also expose secrets, and the reverse.

| Key | Where it lives | Made by | Decrypts |
| --- | --- | --- | --- |
| Host | `/var/lib/sops-nix/key.txt` on the host (root only) | the installer, on the target (stage 1.2) | `hosts/<host>.yaml` and every `host-users/<host>-*.yaml` |
| User on a host | `~/.config/sops/age/keys.txt` in the user's home on that host | the installer, as that user on the target (stage 1.3) | `host-users/<host>-<user>.yaml` only |

There is **no operator key**: no recipient on every file and no key on a laptop that decrypts everything. A host's
secrets are read and edited on that host. The cost is that no single machine can rekey or audit everything; the gain is
that no single machine can leak everything.

The installer never replaces an existing key file. If a key already exists it reads the recipient from it
(`age-keygen -y`); if the recipient in `.sops.yaml` differs, it asks before replacing the anchor.

## `.sops.yaml`

```yaml
keys:
  - &host_example age1...
  - &user_alice_example age1...
creation_rules:
  - path_regex: ^hosts/example\.yaml$
    key_groups:
      - age:
          - *host_example
  - path_regex: ^host-users/example-alice\.yaml$
    key_groups:
      - age:
          - *host_example
          - *user_alice_example
```

- **Anchors.** `&host_<host>` for a host's key, `&user_<user>_<host>` for a user's key on a host. Rules refer to them by
  alias, so a recipient is written once and replacing it updates every rule.
- **One rule per file**, anchored at both ends (`^…$`, dots escaped). No globs: a rule like `^host-users/example-.*`
  would also match a host named `example-2`.
- **First match wins** in sops, so a rule may not match any file but its own. The installer checks this before it
  changes anything and refuses to go on while another rule would shadow one.
- A host file goes to the host only. A user file goes to the host (sops-nix decrypts it at activation, before anyone
  logs in) and to the user's own key on that host (so the user can read and edit it).
- When a user leaves a host, the installer removes their rule, their anchor (unless another rule still uses it) and
  their file.
- A recipient written literally into a rule, rather than by alias, is kept: that is how to add an extra recipient
  by hand.

## Templates

`templates/host.yaml` and `templates/user.yaml` are the schemas of the two kinds of file. Every file of that kind must
have exactly the template's keys, nested the same way. Each leaf is one of:

| Leaf | Kind | Filled in by |
| --- | --- | --- |
| named `hashedPassword` | password | a password prompt; stored as a crypt hash, never in plain text |
| empty, `CHANGEME` or `change_me` | secret | the operator, in an editor |
| anything else | literal | the template; kept unless edited |

This repository's templates are minimal: a user file holds `hashedPassword`, and a host file holds a single unused
`placeholder`, because sops-nix needs the host's `defaultSopsFile` to exist even when the host has no secrets yet.
Adding a key to a template means every existing file of that kind needs it too: the installer has a file that no
longer matches its template written again the next time it runs for that host.

## How the configuration reads it

`nix-secrets` is a flake input with `flake = false`, pinned in the configuration's `flake.lock`. A host builds exactly
the commit the lock names, so a secrets change takes effect only when the lock is updated and committed.

NixOS (`hosts/common/core/sops.nix`):

```nix
sops = {
  defaultSopsFile = "${inputs.nix-secrets}/hosts/${config.hostSpec.hostName}.yaml";
  validateSopsFiles = false;
  age = {
    keyFile = "/var/lib/sops-nix/key.txt"; # the host key, created by the installer
    sshKeyPaths = [ ];                     # never the SSH host key
    generateKey = false;                   # a new key would decrypt nothing
  };
};
```

Login passwords (`hosts/common/accounts/secrets.nix`), one per user on the host:

```nix
sops.secrets."passwords/${user}" = {
  sopsFile = "${inputs.nix-secrets}/host-users/${hostName}-${user}.yaml";
  key = "hashedPassword";
  neededForUsers = true; # decrypted before users are created
};
users.users.${user}.hashedPasswordFile = config.sops.secrets."passwords/${user}".path;
```

With `users.mutableUsers = false`, the password in this repository is the only one: `passwd` on the host doesn't
last past a rebuild. An account can opt out (`accounts.users.<user>.secrets = false`) and then has no password.

Home Manager (`home/common/core/sops.nix`), for secrets a user's own programs need:

```nix
sops = {
  defaultSopsFile = "${inputs.nix-secrets}/host-users/${hostName}-${config.home.username}.yaml";
  age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  validateSopsFiles = false;
};
```

macOS hosts are the one exception to the key model: the installer doesn't install them, and the configuration lets
sops-nix on macOS use the SSH host key (`sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`). Their `&host_<host>`
recipient is that key's age form (`nix run nixpkgs#ssh-to-age -- -i /etc/ssh/ssh_host_ed25519_key.pub`). The layout
and rules are the same.

## How the installer writes it

After the base install and creating the keys on the target (stages 1.2 and 1.3), the installer's secrets phase runs
against a local clone of the private repository:

| Stage | What it does |
| --- | --- |
| 2.1 Secrets repository | Requires the clone to be clean, except for `.sops.yaml` and this host's own files, and level with its remote. |
| 2.2 Recipients | Sets the host's and its users' anchors and rules in `.sops.yaml`; removes users no longer on the host; refuses while a rule would shadow another file. |
| 2.3 Template authoring | For each file that doesn't already hold the template's keys: opens the template in an editor for secret leaves, prompts for each password and hashes it, then encrypts with `sops` to the recipients from 2.2. The target checks the result with its key; nothing is decrypted on the operator's machine. |
| 2.4 Commit and push | Checks every file is encrypted (so plaintext is never committed), commits the host's files as one commit and pushes it. |
| 2.5 Pushed secrets | Reads that commit from git, not from the clone: it must be on the remote and hold exactly this host's files, each encrypted to the recipients of its own rule. |
| 3.1 Flake input | Locks the configuration's `nix-secrets` input at that commit and pushes the lock file. |
| 3.2 Rebuild | The target rebuilds from the pushed configuration and decrypts with its own key. |

Each host's install is one commit that touches only `.sops.yaml` and that host's files, so installs of different hosts
don't conflict beyond `.sops.yaml`.

## Changing things by hand

- **Edit a secret:** on the host, `just edit-host <host>` as root or `just edit-host-user <host> <user>` as the user.
  Commit, push, `nix flake update nix-secrets` in the configuration, rebuild.
- **Add a host or user:** run the installer, or create the key on the host, add its anchor and rule to `.sops.yaml`
  and create the file with `sops` (which encrypts using public keys only).
- **Replace a key:** make the new key on the host, change the anchor's recipient, then `just rekey <host>` on the host
  while the old key is still in place, then swap the key file.
- **Remove a user from a host:** delete their rule, their anchor and `host-users/<host>-<user>.yaml`. Old commits still
  hold the file, encrypted to the old keys; if that matters, change the secrets themselves, not only the keys.

## Why the real repository is private

Encrypted values are safe to publish, but the rest isn't:

- `.sops.yaml` lists every host and user, and the history shows when each was added and when keys changed.
- File names and the unencrypted key names in each file show which secrets exist; `sops.lastmodified` shows when.
- A private repository means a future break of one recipient's key or of the encryption doesn't expose the full
  history to everyone.

This reference repository has the layout, templates and tooling, with fresh history, no recipients and no encrypted
files.
