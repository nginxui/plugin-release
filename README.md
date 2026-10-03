# plugin-release

A GitHub Action that signs the packages of an Nginx UI plugin and publishes
them on the GitHub Release of the tag. The plugin's own build makes the
packages; this action makes them what Nginx UI and the
[plugin catalog](https://github.com/nginxui/plugins) expect:

1. The signer certificate, `plugin.signer` and `plugin.signer.minisig`, goes
   to the root of every package.
2. `plugin.sums` lists the sha256 of every other file and the signing key
   signs it into `plugin.sums.minisig`.
3. Each package is packed again with `plugin.json` as its first entry, and
   `<archive>.sha256` is written next to it.
4. Every package is checked: its digest, `plugin.sums` against the files, the
   signature against the certified key, and the certificate against the
   primary key when it is given. Signing with the primary key by mistake
   fails here. Without a certificate, the signature is checked against the
   given key instead.
5. With `publish: true`, the packages and their `.sha256` files go on the
   GitHub Release of the tag, as a prerelease for a version such as
   `1.1.0-beta.1`.

See [Signing and Trust](https://nginxui.com/plugin/signing) for the keys and
[Packaging](https://nginxui.com/plugin/packaging) for the package layout.

## Setup

Create the keys once with `nginx-ui plugin key init --id <your plugin id>`:

| File | Where it goes |
| --- | --- |
| `primary.key` | Offline, with a backup. Never into the repository or CI. |
| `primary.pub` | `author_public_key` of the catalog entry, and the `PLUGIN_TRUSTED_KEY` variable below. |
| `signing.key` | The `PLUGIN_SIGNING_KEY` secret of a `release` environment. |
| `plugin.signer`, `plugin.signer.minisig` | Committed to the repository root. |

Give the `release` environment a required reviewer, so a pushed tag alone
cannot sign.

## Usage

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  release:
    runs-on: ubuntu-latest
    environment: release
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
        with:
          # git-cliff reads the commits since the previous tag.
          fetch-depth: 0

      # Builds the unsigned packages into dist/, for example
      # dist/io.github.example.mydns-1.2.0-linux-amd64.tar.gz.
      - run: ./build.sh

      - uses: nginxui/plugin-release@v1
        with:
          signing-key: ${{ secrets.PLUGIN_SIGNING_KEY }}
          signing-key-password: ${{ secrets.PLUGIN_SIGNING_KEY_PASSWORD }}
          trusted-key: ${{ vars.PLUGIN_TRUSTED_KEY }}
          publish: true
```

A package is `<id>-<version>.tar.gz` or `<id>-<version>-<goos>-<goarch>.tar.gz`
with `plugin.json` at its root, and its id and version must start the file
name. On a tag the version must be the tag without its `v`.

Plugins signed by the official plugin key or a partner key sign directly:
pass `certificate: ''` and that key's public half as `trusted-key`.

To keep the signing key away from a token that can write, sign in one job and
publish in another: leave `publish` off, upload the `packages` output with
their `.sha256` files as an artifact, and create the release in a job without
the `release` environment.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `working-directory` | `.` | The checkout of the plugin repository. `cliff.toml` and the history are read there, and `packages` and `certificate` are relative to it. |
| `packages` | `dist` | Directory of the unsigned packages, signed in place. |
| `signing-key` | | The minisign secret key, as its file holds it. Required. |
| `signing-key-password` | | Its password, empty for a key made without one. |
| `certificate` | `.` | Directory of `plugin.signer` and `plugin.signer.minisig`. Empty signs without a certificate. |
| `trusted-key` | | The public key the catalog and Nginx UI trust for the plugin: your primary key, which issued the certificate, or a key that signs directly, such as the official plugin key. When given, the certificate must verify against it, or without a certificate the packages must. |
| `publish` | `false` | Publish on the GitHub Release of the tag. |
| `notes` | | `git-cliff` (needs `cliff.toml`), `generate`, or a Markdown file. Empty picks `git-cliff` when `cliff.toml` exists, else `generate`. |
| `token` | `github.token` | The token that publishes the release, which needs `contents: write`. |

## Outputs

| Output | Value |
| --- | --- |
| `packages` | The signed archives, one per line, relative to `working-directory`. |
| `signer` | The id of the signing key the certificate names, empty without a certificate. |

The action runs on Linux and macOS runners and needs Node.js, which every
GitHub hosted runner has.

## License

MIT
