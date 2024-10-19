#!/bin/bash
#
# This script downlaods and builds the Android openSSL libraries
#

set -e

# Custom build options
CUSTOMCONFIG="enable-ssl-trace"

# Formatting
default="\033[39m"
wihte="\033[97m"
green="\033[32m"
red="\033[91m"
yellow="\033[33m"

bold="\033[0m${green}\033[1m"
subbold="\033[0m${green}"
archbold="\033[0m${yellow}\033[1m"
normal="${white}\033[0m"
dim="\033[0m${white}\033[2m"
alert="\033[0m${red}\033[1m"
alertdim="\033[0m${red}\033[2m"

# Set trap to help debug build errors
trap 'echo -e "${alert}** ERROR with Build - Check /tmp/openssl*.log${alertdim}"; tail -3 /tmp/openssl*.log' INT TERM EXIT

# Set defaults
VERSION="3.0.15"				# OpenSSL version default
ANDROID_API_VERSION="28"		# Android API

CORES=$(sysctl -n hw.ncpu)
OPENSSL_VERSION="openssl-${VERSION}"

LIBOPENSSL="${PWD}/../openssl"

usage ()
{
	echo
	echo -e "${bold}Usage:${normal}"
	echo
	echo -e "  ${subbold}$0${normal} [-v ${dim}<version>${normal}] [-s ${dim}<version>${normal}] [-t ${dim}<version>${normal}] [-i ${dim}<version>${normal}] [-a ${dim}<version>${normal}] [-u ${dim}<version>${normal}]  [-e] [-m] [-3] [-x] [-h]"
	echo
	echo "         -v   version of OpenSSL (default $VERSION)"
	echo "         -s   iOS min target version (default $IOS_MIN_SDK_VERSION)"
	echo "         -t   tvOS min target version (default $TVOS_MIN_SDK_VERSION)"
	echo "         -i   macOS 86_64 min target version (default $MACOS_X86_64_VERSION)"
	echo "         -a   macOS arm64 min target version (default $MACOS_ARM64_VERSION)"
	echo "         -e   compile with engine support"
	echo "         -m   compile Mac Catalyst library"
	echo "         -u   Mac Catalyst iOS min target version (default $CATALYST_IOS)"
	echo "         -3   compile with SSLv3 support"
	echo "         -x   disable color output"
	echo "         -h   show usage"
	echo
	trap - INT TERM EXIT
	exit 127
}

engine=0

while getopts "v:s:t:i:a:u:emx3h\?" o; do
	case "${o}" in
		v)
			OPENSSL_VERSION="openssl-${OPTARG}"
			;;
		s)
			IOS_MIN_SDK_VERSION="${OPTARG}"
			;;
		t)
			TVOS_MIN_SDK_VERSION="${OPTARG}"
			;;
		i)
			MACOS_X86_64_VERSION="${OPTARG}"
			;;
		a)
			MACOS_ARM64_VERSION="${OPTARG}"
			;;
		e)
			engine=1
			;;
		m)
			catalyst="1"
			;;
		u)
			catalyst="1"
			CATALYST_IOS="${OPTARG}"
			;;
		x)
			bold=""
			subbold=""
			normal=""
			dim=""
			alert=""
			alertdim=""
			archbold=""
			;;
		3)
			CUSTOMCONFIG="enable-ssl3 enable-ssl3-method enable-ssl-trace"
			;;
		*)
			usage
			;;
	esac
done
shift $((OPTIND-1))

buildAndroid()
{
	ARCH=$1
	TARGET=$ARCH
	ANDROID_API=$ANDROID_API_VERSION

	# export CROSS_COMPILE=aarch64-linux-android-
	# export CC=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang
	# export CXX=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang++

    if [ $ARCH == "android-arm" ]
	then
	    HOST=armv7a-linux-androideabi
    elif [ $ARCH == "android-arm64" ]
	then
	    HOST=aarch64-linux-android
    elif [ $ARCH == "android-x86" ]
	then
	    HOST=i686-linux-android
    elif [ $ARCH == "android-x86_64" ]
	then
	    HOST=x86_64-linux-android
    fi

	export ANDROID_NDK_ROOT=$NDK_HOME
	export CROSS_COMPILE=${HOST}-
	export AR=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar
	export CC=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/${HOST}${ANDROID_API}-clang
	export CXX=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/${HOST}${ANDROID_API}-clang++
	export LD=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/lld
	export RANLIB=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ranlib

	echo -e "${subbold}Building ${OPENSSL_VERSION} for ${archbold}${ARCH}${dim} (Android)"

	pushd . > /dev/null
	cd "${OPENSSL_VERSION}"
	if [[ "$OPENSSL_VERSION" = "openssl-1.0"* ]]; then
		./Configure no-asm ${ARCH} -D__ANDROID_API__=${ANDROID_API} -fPIC -no-shared  --openssldir="${LIBOPENSSL}/Android/${ARCH}" $CUSTOMCONFIG &> "/tmp/${OPENSSL_VERSION}-${ARCH}.log"
	else
		./Configure no-asm ${ARCH} -D__ANDROID_API__=${ANDROID_API} -fPIC -no-shared  --prefix="${LIBOPENSSL}/Android/${ARCH}" --openssldir="${LIBOPENSSL}/Android/${ARCH}" $CUSTOMCONFIG &> "/tmp/${OPENSSL_VERSION}-${ARCH}.log"
	fi
	make -j${CORES} >> "/tmp/${OPENSSL_VERSION}-${ARCH}.log" 2>&1
	make install_sw >> "/tmp/${OPENSSL_VERSION}-${ARCH}.log" 2>&1
	make clean >> "/tmp/${OPENSSL_VERSION}-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export ANDROID_NDK_ROOT=""
	export CROSS_COMPILE=""
	export AR=""
	export CC=""
	export CXX=""
	export LD=""
	export RANLIB=""
}

echo -e "${bold}Cleaning up${dim}"
rm -rf Android

rm -rf "/tmp/openssl"
rm -rf "/tmp/${OPENSSL_VERSION}-*"
rm -rf "/tmp/${OPENSSL_VERSION}-*.log"

rm -rf "${OPENSSL_VERSION}"

if [ ! -e ${OPENSSL_VERSION}.tar.gz ]; then
	echo -e "${dim}Downloading ${OPENSSL_VERSION}.tar.gz"
	curl -LOs https://www.openssl.org/source/${OPENSSL_VERSION}.tar.gz
else
	echo -e "${dim}Using ${OPENSSL_VERSION}.tar.gz"
fi

if [[ "$OPENSSL_VERSION" = "openssl-1.1.1"* || "$OPENSSL_VERSION" = "openssl-3"* ]]; then
	echo -e "${dim}** Building OpenSSL ${OPENSSL_VERSION} **"
else
	if [[ "$OPENSSL_VERSION" = "openssl-1.0."* ]]; then
		echo -e "${dim}** Building OpenSSL ${OPENSSL_VERSION} ** "
		echo -e "${alert}** WARNING: End of Life Version - Upgrade to 1.1.1 **${dim}"
	else
		echo -e "${alert}** WARNING: This build script has not been tested with $OPENSSL_VERSION **${dim}"
	fi
fi

echo -e "${dim}Unpacking openssl"
tar xfz "${OPENSSL_VERSION}.tar.gz"

mkdir -p Android

echo -e "${bold}Building Android libraries${dim}"

buildAndroid "android-arm"
buildAndroid "android-arm64"
buildAndroid "android-x86"
buildAndroid "android-x86_64"

#echo -e "${bold}Cleaning up${dim}"
rm -rf /tmp/${OPENSSL_VERSION}-*
rm -rf ${OPENSSL_VERSION}

#reset trap
trap - INT TERM EXIT

#echo -e "${normal}Done"
