# Publish PPA Package

GitHub action to publish the Ubuntu PPA (Personal Package Archives) packages.

## Inputs

### `repository`
**Required** The PPA repository, e.g. `yuezk/globalprotect-openconnect`.

### `gpg_private_key`
**Required** GPG private key exported as an ASCII armored version or its base64 encoding, exported with the following command.

```sh
gpg --output private.pgp --armor --export-secret-key <KEY_ID or EMAIL>
```

### `gpg_passphrase`
**Optional** Passphrase of the GPG private key.

### `deb_email`
**Required** The email address of the maintainer.

### `deb_fullname`
**Required** The full name of the maintainer.

### `tarball`
**Required** The tarball of the package to be published.

### `package_name`
**Optional** The name of the package. Format: `<name>` or `<name>_<version>`. e.g., "globalprotect-openconnect" or "globalprotect-openconnect_1.0.0"

### `revision`
**Optional** The revision of the package, default to `1`.

### `new_version_template`
**Optional** The template of the new version, default to `{VERSION}-ppa{REVISION}~ubuntu{SERIES_VERSION}`.

### `debian_dir`
**Optional** The debian directory, will be merged with the tarball.

### `series`
**Optional** The series to which the package will be published, separated by space. e.g., `"bionic focal"`.

Default to the series that are supported at the moment, i.e., the output of `distro-info --supported`.

### `extra_series`
**Optional** The extra series to which the package will be published, separated by space. e.g., `"bionic focal"`.

### `extra_ppa`
**Optional** The extra PPA this package depends on, separated by space. e.g., `"liushuyu-011/rust-bpo-1.75"`.

### `debmake_arguments`
**Optional** The arguments for debmake

### `always_upload_upstream_tarball`
**Optional** Always upload the upstream tarball, default to empty.

By default, the upstream tarball will be uploaded only when the revision is 1.

## Example usage

```yaml
name: Publish PPA
uses: yuezk/publish-ppa-package@v2
with:
    repository: "yuezk/globalprotect-openconnect"
    gpg_private_key: ${{ secrets.PPA_GPG_PRIVATE_KEY }}
    gpg_passphrase: ${{ secrets.PPA_GPG_PASSPHRASE }}
    tarball: publish-ppa/globalprotect-openconnect-*/.build/tarball/*.tar.gz
    debian_dir: publish-ppa/globalprotect-openconnect-*/.build/debian
    deb_email: "<email>"
    deb_fullname: "<full name>"
    extra_ppa: "liushuyu-011/rust-bpo-1.75"
```

## Real-world applications

- [GlobalProtect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect): A GlobalProtect VPN client for Linux, written in Rust, based on OpenConnect and Tauri, supports SSO with MFA, Yubikey, etc.

## LICENSE

[MIT](./LICENSE)
