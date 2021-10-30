# Publish PPA Package

GitHub action to publish the Ubuntu PPA (Personal Package Archives) packages.

## Inputs

### `repository`

**Required** The PPA respository, e.g. `ppa:yuezk/globalprotect-openconnect`.

### `gpg_private_key`

**Required** GPG private key exported as an ASCII armored version or its base64 encoding, exported with the following command.

```sh
gpg --output private.pgp --armor --export-secret-key <KEY_ID or EMAIL>
```


### `gpg_passphrase`

**Optional** Passphrase of the GPG private key.

### `pkgdir`

**Required** The package directory which contains the `debian` folder.

### `series`

**Optional** The series to which the package will be published, separated by space. e.g., `"bionic focal"`.

Default to the series that are suppported at the moment, i.e., the output of `distro-info --supported`.

### `is_native`

**Optional** Indicates whether it is a native debian package or not.

Default to `''`. Then it will auto dectect the value from the `debian/source/format` file.

## Example usage

```sh
name: Publish PPA
uses: yuezk/publish-ppa-package@main
with:
    repository: 'ppa:yuezk/globalprotect-openconnect'
    gpg_private_key: ${{ secrets.PPA_GPG_PRIVATE_KEY }}
    gpg_passphrase: ${{ secrets.PPA_GPG_PASSPHRASE }}
    pkgdir: '${{ github.workspace }}/artifacts/deb-build/globalprotect-openconnect*/'
```

The example above will publish the package to the series: `binoic`, `focal`, `hirsute`, `impish`, and `jammy`. See: [ppa:yuezk/globalprotect-openconnect](https://launchpad.net/~yuezk/+archive/ubuntu/globalprotect-openconnect)

## Real-world applications

- [GlobalProtect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect): A GlobalProtect VPN client (GUI) for Linux based on OpenConnect and built with Qt5, supports SAML auth mode.

## LICENSE

[MIT](./LICENSE)
