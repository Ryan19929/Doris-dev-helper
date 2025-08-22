#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# get parameters from command line
# convert tags
# build fe, be, ms
# find cpu arch
# download binary tar package.
# extract archive
#

usage() {
    echo "$0 <options>
    -v                    specify version to build.
    -o <output_dir>       use local output dir (e.g. /root/doris/output) to copy fe/be into resource and build images. If -v omitted, default to '3-local'.
    --rebuild-base        force rebuild base image even if doris-base:latest exists.
    --clean               remove images for the specified version (use with -v, or with --clean-version)
    --clean-version <v>   version to clean when using --clean (e.g. 3-local or 3.0.4-dev)
    --clean-all           remove all doris.fe/be/ms/broker images (all versions)
    --clean-base          remove base images doris-base:latest and apache/doris:base-latest
    -h, --help            show this help and exit
    Eg:
    $0 -v x.x.x           build the \"x.x.x\" version and the binary will download from https://doris.apache.org/zh-CN/download/ to download binary.
    $0 -o /root/doris/output   build images from local doris/output(fe, be) without downloading (images' tag is 3-local)."
}

version=
output_dir=
rebuild_base=false
clean=false
clean_all=false
clean_base=false
clean_version=

OPTS="$(getopt -n "$0" -o 'v:o:h' -l 'rebuild-base,clean,clean-all,clean-base,clean-version:,help' -- "$@")"
eval set -- "${OPTS}"
while true; do
    case "$1" in
        -v|--version)
        version="$2"
        shift 2
        ;;
        -o)
        output_dir="$2"
        shift 2
        ;;
        -h|--help)
        usage
        exit 0
        ;;
        --rebuild-base)
        rebuild_base=true
        shift 1
        ;;
        --clean)
        clean=true
        shift 1
        ;;
        --clean-all)
        clean_all=true
        shift 1
        ;;
        --clean-base)
        clean_base=true
        shift 1
        ;;
        --clean-version)
        clean_version="$2"
        shift 2
        ;;
        --)
        shift
        break
        ;;
        *)
        usage
        shift
        exit 1
        ;;
esac
done

version=$(echo $version | sed 's/\s//g')
clean_version=$(echo $clean_version | sed 's/\s//g')

# Allow omitting -v when using local output mode; default to a value that triggers JDK17 in Dockerfile
if [[ "x$version" == "x" && -n "$output_dir" ]]; then
    version="3-local"
fi

# Handle clean-only paths early
if [[ "$clean_all" == true || "$clean" == true || "$clean_base" == true ]]; then
    # Clean base images
    if [[ "$clean_base" == true ]]; then
        echo "clean base image: doris-base:latest (if exists)"
        docker image inspect doris-base:latest >/dev/null 2>&1 && docker rmi -f doris-base:latest || true
        echo "clean base image: apache/doris:base-latest (if exists)"
        docker image inspect apache/doris:base-latest >/dev/null 2>&1 && docker rmi -f apache/doris:base-latest || true
    fi

    # Clean all doris component images
    if [[ "$clean_all" == true ]]; then
        echo "clean all doris component images (fe/be/ms/broker)"
        docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^doris\.(fe|be|ms|broker):' | xargs -r docker rmi -f || true
    fi

    # Clean by version
    if [[ "$clean" == true ]]; then
        cv="$clean_version"
        if [[ "x$cv" == "x" ]]; then
            cv="$version"
        fi
        if [[ "x$cv" == "x" ]]; then
            echo "ERROR: --clean requires -v <version> or --clean-version <version>"
            exit 1
        fi
        echo "clean doris component images for version: $cv"
        for r in doris.fe doris.be doris.ms doris.broker; do
            if docker image inspect "$r:$cv" >/dev/null 2>&1; then
                docker rmi -f "$r:$cv" || true
            fi
        done
    fi

    exit 0
fi

if [[ "x$version" == "x" ]]; then
    usage
    exit 1
fi

ARCH=$(uname -m)

url_arch=
sub_path=
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    url_arch="arm64"
    sub_path="arm64"
else
    url_arch="x64"
    sub_path="amd64"
fi

if [[ "$url_arch" == "x64" ]]; then
    avx=$(cat /proc/cpuinfo | grep avx2 | wc -l)
    if [[ $avx -le 0 ]]; then
        url_arch=$url_arch"-noavx2"
    fi
fi

if docker image inspect doris-base:latest >/dev/null 2>&1 && [[ "${rebuild_base}" != true ]]; then
    echo "skip building base image: found local doris-base:latest"
else
    echo "docker build base image, tag both doris-base:latest and apache/doris:base-latest"
    cd base-image/ && docker build -t doris-base:latest -t apache/doris:base-latest -f Dockerfile_base .
    cd -
fi

if [[ -n "$output_dir" ]]; then
    echo "build images from local output: $output_dir"
    if [[ ! -d "$output_dir/fe" || ! -d "$output_dir/be" ]]; then
        echo "ERROR: $output_dir must contain 'fe' and 'be' directories."
        exit 1
    fi

    # Prepare resource directories using bin-${sub_path} to match Dockerfile expectations
    dest_fe_dir="fe/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}"
    dest_be_dir="be/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}"

    echo "prepare resource directories: ${dest_fe_dir} and ${dest_be_dir}"
    mkdir -p "$dest_fe_dir" "$dest_be_dir"
    rm -rf "$dest_fe_dir/fe" "$dest_be_dir/be"

    echo "copy local fe and be into resource directory"
    cp -a "$output_dir/fe" "$dest_fe_dir/"
    cp -a "$output_dir/be" "$dest_be_dir/"

    echo "docker build fe image, tag=doris.fe:${version}"
    cd fe/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.fe:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
    cd -

    echo "docker build be image, tag=doris.be:${version}"
    cd be/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.be:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
    cd -

    exit 0
fi

URL="https://apache-doris-releases.oss-accelerate.aliyuncs.com/apache-doris-${version}-bin-${url_arch}.tar.gz"

echo "wget the archive binary in current directory!"
wget $URL

echo "extract archive"

tar zxf "apache-doris-${version}-bin-${url_arch}.tar.gz"

echo "distribute binary to corresponding path."
mkdir -p fe/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}
mkdir -p be/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}
mkdir -p ms/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}
mkdir -p broker/resource/${sub_path}/apache-doris-${version}-bin-${sub_path}

mv -f apache-doris-${version}-bin-${url_arch}/fe fe/resource/$sub_path/apache-doris-${version}-bin-${sub_path}/
mv -f apache-doris-${version}-bin-${url_arch}/be be/resource/$sub_path/apache-doris-${version}-bin-${sub_path}/
mv -f apache-doris-${version}-bin-${url_arch}/ms ms/resource/$sub_path/apache-doris-${version}-bin-${sub_path}/
mv -f apache-doris-${version}-bin-${url_arch}/extensions broker/resource/$sub_path/apache-doris-${version}-bin-${sub_path}/

echo "docker build fe image,tag=doris.fe:${version}"
cd fe/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.fe:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
cd -

echo "docker build be image,tag=doris.be:${version}"
cd be/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.be:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
cd -

echo "docker build ms image,tag=doris.ms:${version}"
cd ms/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.ms:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
cd -

echo "docker build broker image,tag=doris.broker:${version}"
cd broker/ && docker build --build-arg TARGETARCH=${sub_path} -t doris.broker:${version} -f Dockerfile --build-arg DORIS_VERSION=${version} .
