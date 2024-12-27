#!/usr/bin/env bash

set -e
export DEBIAN_FRONTEND=noninteractive

echo "::group::Installing dependencies..."
sudo apt-get update &&
    sudo apt-get install -y gpg debmake debhelper devscripts equivs \
        distro-info-data distro-info software-properties-common

echo "::endgroup::"

echo "::group::Importing GPG private key..."
echo "Importing GPG private key..."

GPG_KEY_ID=$(echo "$GPG_PRIVATE_KEY" | gpg --import-options show-only --import | sed -n '2s/^\s*//p')
echo $GPG_KEY_ID
echo "$GPG_PRIVATE_KEY" | gpg --batch --passphrase "$GPG_PASSPHRASE" --import

echo "Checking GPG expirations..."
if [[ $(gpg --list-keys | grep expired) ]]; then
    echo "GPG key has expired. Please update your GPG key." >&2
    exit 1
fi

echo "::endgroup::"

# Add extra PPA if it's been set
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "::group::Adding PPA: $ppa"
        sudo add-apt-repository -y ppa:$ppa
        echo "::endgroup::"
    done
fi

echo "::group::Determining series..."
if [[ -z "$SERIES" ]]; then
    echo "SERIES is not set. Using default series."
    SERIES=$(distro-info --supported)
fi

# Add extra series if it's been set
if [[ -n "$EXTRA_SERIES" ]]; then
    echo "Adding extra series: $EXTRA_SERIES"
    SERIES="$EXTRA_SERIES $SERIES"
fi

# Exclude the series if it's been set
if [[ -n "$EXCLUDED_SERIES" ]]; then
    echo "Excluding series: $EXCLUDED_SERIES"
    SERIES=$(echo $SERIES | tr ' ' '\n' | grep -vE "$(echo $EXCLUDED_SERIES | tr ' ' '|')" | tr '\n' ' ')
fi

echo "Final series: $SERIES"
echo "::endgroup::"

echo "::group::Setting up workspace..."
mkdir -p /tmp/workspace/source
echo "Copying source files..."
cp -v $TARBALL /tmp/workspace/source
if [[ -n $DEBIAN_DIR ]]; then
    echo "Copying debian directory..."
    cp -vr $DEBIAN_DIR /tmp/workspace/debian
fi

echo "::endgroup::"

for s in $SERIES; do
    ubuntu_version=$(distro-info --series $s -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"

    echo "Copying workspace to /tmp/$s..."
    cp -vr /tmp/workspace /tmp/$s && cd /tmp/$s/source

    echo "Extracting source tarball..."
    tar -xf ./* && cd ./*/

    echo "Making non-native package..."
    debmake $DEBMAKE_ARGUMENTS

    if [[ -n $DEBIAN_DIR ]]; then
        echo "Copying debian directory..."
        cp -rvf /tmp/$s/debian/* debian/
    fi

    # Extract the package name from the debian changelog
    package=$(dpkg-parsechangelog --show-field Source)
    pkg_version=$(dpkg-parsechangelog --show-field Version | cut -d- -f1)
    changes="New upstream release"

    echo "Generating debian changelog..."

    # Create the debian changelog
    rm -vf debian/changelog
    dch --create --distribution $s --package $package --newversion $pkg_version-ppa$REVISION~ubuntu$ubuntu_version "$changes"

    echo "Installing build dependencies..."
    # Install build dependencies
    sudo mk-build-deps --install --remove debian/control

    # mk-build-deps will generate .buildinfo and .changes files, remove them, otherwise debuild will fail
    rm -vf *.buildinfo *.changes

    echo "Building package..."
    debuild -S -sa \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback"

    dput ppa:$REPOSITORY ../*.changes

    echo "Uploaded $package to $REPOSITORY"

    echo "::endgroup::"
done
