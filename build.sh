#!/usr/bin/env bash

set -e
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update &&
    sudo apt-get install -y gpg debmake dh-make debhelper devscripts equivs \
        distro-info-data distro-info software-properties-common

echo "::group::Importing GPG private key..."
echo "Importing GPG private key..."

GPG_KEY_ID=$(echo "$GPG_PRIVATE_KEY" | gpg --import-options show-only --import | sed -n '2s/^\s*//p')
echo "$GPG_KEY_ID"
echo "$GPG_PRIVATE_KEY" | gpg --batch --passphrase "$GPG_PASSPHRASE" --import

echo "Checking GPG expirations..."
if [[ $(gpg --list-keys | grep expired) ]]; then
    echo "GPG key has expired. Please update your GPG key." >&2
    exit 1
fi

echo "::endgroup::"

echo "::group::Adding PPA..."
# Add extra PPA if it's been set
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "Adding PPA: $ppa"
        sudo add-apt-repository -y "ppa:$ppa"
    done
fi
sudo apt-get update
echo "::endgroup::"

if [[ -z "$SERIES" ]]; then
    SERIES=$(distro-info --supported)
fi

# Add extra series if it's been set
if [[ -n "$EXTRA_SERIES" ]]; then
    SERIES="$EXTRA_SERIES $SERIES"
fi

if [[ -z "$REVISION" ]]; then
    REVISION=1
fi

if [[ -z "$NEW_VERSION_TEMPLATE" ]]; then
    NEW_VERSION_TEMPLATE="{VERSION}-ppa{REVISION}~ubuntu{SERIES_VERSION}"
fi

rm -rf /tmp/workspace && mkdir -p /tmp/workspace/stage/source
cp $TARBALL /tmp/workspace/stage/source

if [[ -n $DEBIAN_DIR ]]; then
    cp -r $DEBIAN_DIR /tmp/workspace/stage/debian
fi

echo "::group::Extracting source tarball..."

cd /tmp/workspace/stage/source
tarball=$(ls ./*)
tarball_extension="tar.${tarball##*.}"
tarball_root=$(tar -tf "$tarball" | head -n1 | cut -d'/' -f1)

upstream_dir=upstream
if [[ $tarball_root == '.' ]]; then
    echo "Extracting source tarball to the $upstream_dir directory..."
    mkdir "$upstream_dir" && tar -xf "$tarball" -C "$upstream_dir"
else
    echo "Extracting source tarball..."
    tar -xf "$tarball"
    upstream_dir=$tarball_root
fi

# The original tarball is no longer needed
echo "Removing the original tarball..."
rm -f "$tarball" && cd "$upstream_dir"

echo "::endgroup::"

if [[ -d debian ]]; then
    echo "::group::Inferring package name from debian directory..."

    # Infer the package name and version from the debian changelog file
    if [[ -f debian/changelog ]]; then
        if [[ -z $PACKAGE_NAME ]]; then
            echo "Inferring package name and version from debian changelog..."
            PACKAGE_NAME="$(dpkg-parsechangelog --show-field Source)_$(dpkg-parsechangelog --show-field Version | cut -d- -f1)"
        fi

        # The upstream changelog will not be used, so we can remove it
        rm debian/changelog
    fi

    # Backup the upstream debian directory, so that we can restore it later
    echo "Backing up the upstream debian directory..."
    mv debian /tmp/workspace/stage/upstream_debian
    echo "::endgroup::"
fi

echo "::group::Creating new orig tarball using dh_make..."
if [[ -z $PACKAGE_NAME ]]; then
    echo "PACKAGE_NAME is not set, the package name will be inferred from the package's directory..."
    dh_make --createorig --single --yes
else
    echo "PACKAGE_NAME is set to $PACKAGE_NAME, using it to create the new tarball..."
    dh_make --createorig --single --yes --packagename "$PACKAGE_NAME"
fi

# The upstream directory is no longer needed
echo "Removing the $upstream_dir directory..."
cd .. && rm -rf "$upstream_dir"
echo "::endgroup::"

echo "::group::Determining package name and version..."
# Extract the <package-name>_<version> from the created orig tarball
orig_tarball=$(basename ./*.orig.*)

# remove the .orig.* and change the _ to -
package_name_version=${orig_tarball%.orig.*}
package=${package_name_version%_*}
pkg_version=${package_name_version#*_}
full_package_name="$package-$pkg_version"

# Extract the orig tarball to the package's source directory
mkdir "$full_package_name" && tar -xf "$orig_tarball" -C "$full_package_name"
rm -f "$orig_tarball"

echo "Package: $package, Version: $pkg_version"
echo "::endgroup::"

# Create a new tarball with the extracted directory
echo "::group::Creating a new tarball with debmake..."
cd "$full_package_name" && debmake --tar -p "$package" -u "$pkg_version" -r "$REVISION" -z "$tarball_extension" --yes

echo "Keep only the new tarball..."
cd .. && rm -rf "$full_package_name" ./*.orig.* && ls -la

echo "::endgroup::"

for s in $SERIES; do
    ubuntu_version=$(distro-info --series "$s" -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"

    mkdir -p "/tmp/workspace/$s"
    cp -r /tmp/workspace/stage/source "/tmp/workspace/$s/source" && cd "/tmp/workspace/$s/source" && ls -la

    tar -xf ./* && cd ./*/

    echo "Making non-native package..."
    if [[ -n $DEBMAKE_ARGUMENTS ]]; then
        echo "Using debmake arguments: $DEBMAKE_ARGUMENTS"
        debmake --yes -z "$tarball_extension" $DEBMAKE_ARGUMENTS
    else
        debmake --yes -z "$tarball_extension"
    fi

    if [[ -d /tmp/workspace/stage/upstream_debian ]]; then
        echo "Restoring the upstream debian directory..."
        cp -rvf /tmp/workspace/stage/upstream_debian/* debian/
    fi

    if [[ -d /tmp/workspace/stage/debian ]]; then
        echo "Copying the debian directory..."
        cp -rvf /tmp/workspace/stage/debian/* debian/
    fi

    # Create the debian changelog
    rm -rf debian/changelog

    # Generate the version using NEW_VERSION_TEMPLATE
    newversion=$(echo "$NEW_VERSION_TEMPLATE" | sed "s/{VERSION}/$pkg_version/g" | sed "s/{REVISION}/$REVISION/g" | sed "s/{SERIES_VERSION}/$ubuntu_version/g" | sed "s/{SERIES}/$s/g")
    dch --create --distribution "$s" \
        --package "$package" \
        --newversion "$newversion" \
        "New upstream release"

    # Install build dependencies
    sudo mk-build-deps --install --remove --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes' debian/control

    # mk-build-deps will generate .buildinfo and .changes files, remove them, otherwise debuild will fail
    rm -vf ./*.buildinfo ./*.changes

    # Do not upload the orig tarball unless it's the first revision or it's been explicitly set
    debuild_options="-S -sd"
    if [[ $REVISION -eq 1 || -n $ALWAYS_UPLOAD_UPSTREAM_TARBALL ]]; then
        echo "Upstream tarball will be uploaded..."
        debuild_options="-S -sa"
    fi

    debuild $debuild_options \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback"

    dput "ppa:$REPOSITORY" ../*.changes

    echo "Uploaded $package to $REPOSITORY"

    echo "::endgroup::"
done
