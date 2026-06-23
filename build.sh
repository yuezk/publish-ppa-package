#!/usr/bin/env bash

set -e
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update &&
    sudo apt-get install -y gpg debmake debhelper devscripts equivs \
        distro-info-data distro-info software-properties-common

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

echo "::group::Adding PPA..."
# Add extra PPA if it's been set
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "Adding PPA: $ppa"
        sudo add-apt-repository -y ppa:$ppa
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

if [[ -z "$INCLUDE_ORIG" ]]; then
    INCLUDE_ORIG=auto
fi

case "$INCLUDE_ORIG" in
    auto|yes|no) ;;
    *)
        echo "include_orig must be one of: auto, yes, no" >&2
        exit 1
        ;;
esac

repository_name="${REPOSITORY#ppa:}"
if [[ "$repository_name" != */* ]]; then
    echo "repository must be in owner/archive format: $REPOSITORY" >&2
    exit 1
fi
ppa_owner="${repository_name%%/*}"
ppa_archive="${repository_name#*/}"

workspace="${GITHUB_WORKSPACE:-$PWD}"

resolve_one_path() {
    local label=$1
    local pattern=$2
    local matches=()

    if [[ "$pattern" = /* ]]; then
        matches=( $pattern )
    else
        matches=( "$workspace"/$pattern )
    fi

    if [[ ${#matches[@]} -ne 1 || ! -e "${matches[0]}" ]]; then
        echo "Expected exactly one $label, got ${#matches[@]}: $pattern" >&2
        return 1
    fi

    printf '%s\n' "${matches[0]}"
}

source_tarball="$(resolve_one_path "source tarball" "$TARBALL")"

source_archive="$(basename "$source_tarball")"
case "$source_archive" in
    *.tar.gz) source_archive_extension="tar.gz" ;;
    *.tar.xz) source_archive_extension="tar.xz" ;;
    *.tar.bz2) source_archive_extension="tar.bz2" ;;
    *)
        echo "Unsupported source tarball extension: $source_archive" >&2
        exit 1
        ;;
esac

debian_dir=""
if [[ -n $DEBIAN_DIR ]]; then
    debian_dir="$(resolve_one_path "debian directory" "$DEBIAN_DIR")"
    if [[ ! -d "$debian_dir" ]]; then
        echo "debian_dir is not a directory: $DEBIAN_DIR" >&2
        exit 1
    fi
fi

rm -rf /tmp/workspace && mkdir -p /tmp/workspace/source

dput_config=/tmp/workspace/dput.cf
cat > "$dput_config" <<EOF
[ppa]
fqdn = upload.ppa.launchpad.net
method = ftp
incoming = ~$ppa_owner/ubuntu/$ppa_archive/
login = anonymous
allow_unsigned_uploads = 0
passive_ftp = True
EOF

cp "$source_tarball" /tmp/workspace/source/
if [[ -n $debian_dir ]]; then
    cp -r "$debian_dir" /tmp/workspace/debian
fi

series_index=0
for s in $SERIES; do
    series_index=$((series_index + 1))
    ubuntu_version=$(distro-info --series $s -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"

    rm -rf "/tmp/$s" && cp -r /tmp/workspace "/tmp/$s" && cd "/tmp/$s/source"
    tar -xf "$source_archive"
    source_dir=$(find . -maxdepth 1 -mindepth 1 -type d | head -n 1)
    if [[ -z "$source_dir" ]]; then
        echo "Source tarball did not extract to a directory: $source_archive" >&2
        exit 1
    fi
    cd "$source_dir"

    echo "Making non-native package..."
    debmake $DEBMAKE_ARGUMENTS

    if [[ -n $debian_dir ]]; then
        # restore the custom debian directory
        cp -r /tmp/$s/debian/* debian/
    fi

    # Extract the package name from the debian changelog
    package=$(dpkg-parsechangelog --show-field Source)
    pkg_version=$(dpkg-parsechangelog --show-field Version | cut -d- -f1)

    rm -f "../${package}_${pkg_version}.orig.tar".*
    ln -sf "$source_archive" "../${package}_${pkg_version}.orig.${source_archive_extension}"

    # Create the debian changelog
    rm -rf debian/changelog

    # Generate the version using NEW_VERSION_TEMPLATE
    newversion=$(echo "$NEW_VERSION_TEMPLATE" | sed "s/{VERSION}/$pkg_version/g" | sed "s/{REVISION}/$REVISION/g" | sed "s/{SERIES_VERSION}/$ubuntu_version/g" | sed "s/{SERIES}/$s/g")

    echo "New version: $newversion"

    # Use provided changelog if KEEP_CHANGELOG is set
    if [[ -n $KEEP_CHANGELOG ]]; then
        # Ensure the changelog exists in the $DEBIAN_DIR
        if [[ ! -f $debian_dir/changelog ]]; then
            echo "KEEP_CHANGELOG is set, but the changelog file does not exist"
            echo "Please provide a changelog file in the DEBIAN_DIR directory."
            exit 1
        fi

        new_revision=$(echo "$newversion" | cut -d- -f2)
        # Replace the package name, revision, distribution, and urgency in the changelog
        sed -E "s/^(\S+) \(([^-]+)-([^)]+)\) ([^;]+); urgency=(\S+)/$package (\2-$new_revision) $s; urgency=medium/" "$debian_dir/changelog" \
            > debian/changelog

        echo "Changelog after replacement:"
        cat debian/changelog
    else
        dch --create --distribution "$s" \
            --package "$package" \
            --newversion "$newversion" \
            "New upstream release"
    fi

    # Install build dependencies
    sudo mk-build-deps \
        --install \
        --remove \
        --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes" \
        debian/control

    # mk-build-deps will generate .buildinfo and .changes files, remove them, otherwise debuild will fail
    rm -vf ./*.buildinfo ./*.changes

    echo "Building package..."

    source_upload_option=-sd
    case "$INCLUDE_ORIG" in
        yes) source_upload_option=-sa ;;
        no) source_upload_option=-sd ;;
        auto)
            if [[ $series_index -eq 1 ]]; then
                source_upload_option=-sa
            fi
            ;;
    esac

    debuild -S "$source_upload_option" \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback"

    dput -c "$dput_config" ppa ../*.changes

    echo "Uploaded $package to $REPOSITORY"

    echo "::endgroup::"
done
