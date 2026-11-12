# nix-secrets-reference

The structure of a private `nix-secrets` repository, without any secrets. It holds
[sops](https://github.com/getsops/sops) files, encrypted with [age](https://github.com/FiloSottile/age), for a NixOS
flake that reads them with [sops-nix](https://github.com/Mic92/sops-nix).

This is a public copy of the layout, the templates, the tooling and the documentation. The real repository is
private and holds encrypted files under `hosts/` and `host-users/`; here those directories are empty and `.sops.yaml`
lists no recipients.

It belongs with:

- [nixos-config](https://github.com/JulianKragt/nixos-config): the NixOS configuration that reads these files.
- [nixos-installer](https://github.com/julian-kragt/nixos-installer): installs a host, creates its keys and writes its
  files here.
- [nixos-bootstrap](https://github.com/julian-kragt/nixos-bootstrap): the first-install system the installer starts
  from.

How it is put together, and why, is in [DESIGN.md](DESIGN.md).

## Layout

```
.sops.yaml                      which recipients decrypt which file
hosts/<host>.yaml               a host's own secrets            → the host's key
host-users/<host>-<user>.yaml   a user's secrets on one host    → the host's key + the user's key on that host
templates/host.yaml             schema of a host file
templates/user.yaml             schema of a user file
flake.nix                       dev shell: age, sops, mkpasswd, just
justfile                        editing, rekeying and key recipes
```

## Using it for your own secrets

1. Copy this repository (not a fork: fork visibility follows this one) and make the copy **private**.
2. Edit `templates/` to hold the keys your configuration reads. A leaf named `hashedPassword` is asked for as a
   password and stored as a crypt hash; a leaf that is empty or `CHANGEME` is filled in by hand; anything else is kept.
3. Point your configuration's flake input at it, for example:
   ```nix
   inputs.nix-secrets = {
     url = "git+ssh://git@github.com/<you>/nix-secrets.git?ref=main&shallow=1";
     flake = false;
   };
   ```
   and read `"${inputs.nix-secrets}/hosts/${hostName}.yaml"` and
   `"${inputs.nix-secrets}/host-users/${hostName}-${user}.yaml"` from sops-nix (see DESIGN.md for the full setup).
4. Install hosts with nixos-installer: it creates each host's and user's age key on the target, writes their
   recipients and rules into `.sops.yaml`, lets you fill in the templates, and commits and pushes the encrypted files.

Without the installer, do the same by hand:

```sh
nix develop                                   # age, sops, mkpasswd, just
# on the host, as root:
age-keygen -o /var/lib/sops-nix/key.txt       # the host key; prints its recipient
# on the host, as each user:
age-keygen -o ~/.config/sops/age/keys.txt     # that user's key on this host
```

Then add both recipients and one rule per file to `.sops.yaml` (the shape is in the file's comment), and create the
files with `sops hosts/<host>.yaml` and `sops host-users/<host>-<user>.yaml`. sops encrypts to public keys, so this
works from any machine. A password hash comes from `just hash-password`.

## Editing later

Every file is encrypted only to keys that live on its own host, so it is decrypted there:

```sh
just edit-host <host>              # on the host, as root
just edit-host-user <host> <user>  # on the host, as that user
just rekey <host>                  # on the host, as root, after changing .sops.yaml
```

Commit and push, then update the configuration's lock of the `nix-secrets` input (`nix flake update nix-secrets`)
and rebuild.

## Keep your copy private

The encrypted files are safe on their own, but the real repository is still kept private: `.sops.yaml` lists every
host and user and when their keys changed, and the files show which secrets exist and when they were edited.
Never commit an age private key (`AGE-SECRET-KEY-…`) or a decrypted file (`*.dec`, `*.dec.yaml` are ignored).
