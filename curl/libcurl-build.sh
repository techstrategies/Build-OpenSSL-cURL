#!/bin/bash

# This script downlaods and builds the Mac, iOS and tvOS libcurl libraries with Bitcode enabled

# Credits:
#
# Felix Schwarz, IOSPIRIT GmbH, @@felix_schwarz.
#   https://gist.github.com/c61c0f7d9ab60f53ebb0.git
# Bochun Bai
#   https://github.com/sinofool/build-libcurl-ios
# Jason Cox, @jasonacox
#   https://github.com/jasonacox/Build-OpenSSL-cURL
# Preston Jennings
#   https://github.com/prestonj/Build-OpenSSL-cURL

set -e

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

# Set trap to help debug any build errors
trap 'echo -e "${alert}** ERROR with Build - Check /tmp/curl*.log${alertdim}"; tail -30 /tmp/curl*.log' INT TERM EXIT

# Set defaults
CURL_VERSION="curl-8.10.1"
ANDROID_API_VERSION="28"		# Android API

nohttp2="0"
nolibssh2="2"
catalyst="0"
FORCE_SSLV3="no"
CONF_FLAGS="--without-libidn2 --disable-shared --enable-static -with-random=/dev/urandom --without-libpsl --enable-http --enable-ftp --enable-smtp --disable-file --disable-ldap --disable-ldaps --disable-rtsp --enable-proxy --disable-dict --enable-telnet --enable-tftp --enable-pop3 --enable-imap --enable-smb --disable-gopher --disable-manual --without-zlib"

# Set minimum OS versions for target
MACOS_X86_64_VERSION=""			# Empty = use host version
MACOS_ARM64_VERSION=""			# Min supported is MacOS 11.0 Big Sur
CATALYST_IOS="15.0"				# Min supported is iOS 15.0 for Mac Catalyst
IOS_MIN_SDK_VERSION="8.0"
IOS_SDK_VERSION=""
TVOS_MIN_SDK_VERSION="9.0"
TVOS_SDK_VERSION=""

CORES=$(sysctl -n hw.ncpu)

if [ -z "${MACOS_X86_64_VERSION}" ]; then
	MACOS_X86_64_VERSION=$(sw_vers -productVersion)
fi
if [ -z "${MACOS_ARM64_VERSION}" ]; then
	MACOS_ARM64_VERSION=$(sw_vers -productVersion)
fi

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

# Usage Instructions
usage ()
{
	echo
	echo -e "${bold}Usage:${normal}"
	echo
	echo -e "  ${subbold}$0${normal} [-v ${dim}<curl version>${normal}] [-s ${dim}<version>${normal}] [-t ${dim}<version>${normal}] [-i ${dim}<version>${normal}] [-a ${dim}<version>${normal}] [-u ${dim}<version>${normal}] [-b] [-m] [-x] [-n] [-h]"
    echo
	echo "         -v   version of curl (default $CURL_VERSION)"
	echo "         -s   iOS min target version (default $IOS_MIN_SDK_VERSION)"
	echo "         -t   tvOS min target version (default $TVOS_MIN_SDK_VERSION)"
	echo "         -i   macOS 86_64 min target version (default $MACOS_X86_64_VERSION)"
	echo "         -a   macOS arm64 min target version (default $MACOS_ARM64_VERSION)"
	echo "         -b   compile without bitcode"
	echo "         -n   compile with nghttp2"
	echo "         -p   compile with libssh2"
	echo "         -u   Mac Catalyst iOS min target version (default $CATALYST_IOS)"
	echo "         -m   compile Mac Catalyst library [beta]"
	echo "         -x   disable color output"
	echo "         -3   enable SSLv3 support"
	echo "         -h   show usage"
	echo
	trap - INT TERM EXIT
	exit 127
}

while getopts "v:s:t:i:a:u:npfmb3xh\?" o; do
    case "${o}" in
        v)
			CURL_VERSION="curl-${OPTARG}"
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
		n)
			nohttp2="1"
			;;
		p)
			nolibssh2="1"
			;;
		m)
			catalyst="1"
			;;
		u)
			catalyst="1"
			CATALYST_IOS="${OPTARG}"
			;;
		b)
			NOBITCODE="yes"
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
			FORCE_SSLV3="yes"
			;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

OPENSSL="${PWD}/../openssl"
CURL="${PWD}/../curl"
DEVELOPER=`xcode-select -print-path`

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}
if version_lte $MACOS_ARM64_VERSION 11.0; then
        MACOS_ARM64_VERSION="11.0"      # Min support for Apple Silicon is 11.0
fi

# HTTP2 support
if [ $nohttp2 == "1" ]; then
	# nghttp2 will be in ../nghttp2/{Platform}/{arch}
	NGHTTP2="${PWD}/../nghttp2"
fi

# SFTP/SSH support
if [ $nolibssh2 == "1" ]; then
	# libssh2 will be in ../libssh2/{Platform}/{arch}
	LIBSSH2="${PWD}/../libssh2"
fi

if [ $nohttp2 == "1" ]; then
	echo -e "${dim}Building with HTTP2 Support (nghttp2)"
else
	echo -e "${dim}Building without HTTP2 Support (nghttp2)"
	NGHTTP2CFG=""
	NGHTTP2LIB=""
fi

if [ $nolibssh2 == "1" ]; then
	echo -e "${dim}Building with SSH/SFTP Support (libssh2)"
else
	echo -e "${dim}Building without SSH/SFTP Support (libssh2)"
	LIBSSH2CFG=""
	LIBSSH2LIB=""
fi

# Check to see if pkg-config is already installed
PATH=$PATH:/tmp/pkg_config/bin
if ! (type "pkg-config" > /dev/null 2>&1 ) ; then
	echo -e "${alertdim}** WARNING: pkg-config not installed... attempting to install.${dim}"

	# Check to see if Brew is installed
	if (type "brew" > /dev/null 2>&1 ) ; then
		echo -e "  ${dim}brew installed - using to install pkg-config"
		brew install pkg-config
	else
		# Build pkg-config from Source
		curl -LOs https://pkg-config.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
		echo -e "  ${dim}Building pkg-config"
		tar xfz pkg-config-0.29.2.tar.gz
		pushd pkg-config-0.29.2 > /dev/null
		./configure --prefix=/tmp/pkg_config --with-internal-glib >> "/tmp/${NGHTTP2_VERSION}.log" 2>&1
		make -j${CORES} >> "/tmp/${NGHTTP2_VERSION}.log" 2>&1
		make install >> "/tmp/${NGHTTP2_VERSION}.log" 2>&1
		popd > /dev/null
	fi

	# Check to see if installation worked
	if (type "pkg-config" > /dev/null 2>&1 ) ; then
		echo -e "  ${dim}SUCCESS: pkg-config now installed"
	else
		echo -e "${alert}** FATAL ERROR: pkg-config failed to install - exiting.${normal}"
		exit 1
	fi
fi 

buildMac()
{
	ARCH=$1
	HOST="x86_64-apple-darwin"

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/Mac/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/Mac/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/Mac/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/Mac/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	TARGET="darwin-i386-cc"
	BUILD_MACHINE=`uname -m`
	export CC="clang"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH} -L${OPENSSL}/Mac/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -L${OPENSSL}/Mac/lib ${NGHTTP2LIB} ${LIBSSH2LIB} "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - native build
			export CC="${DEVELOPER}/usr/bin/gcc"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -L${OPENSSL}/Mac/lib ${NGHTTP2LIB} ${LIBSSH2LIB} "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		fi
	fi

	echo -e "${subbold}Building ${CURL_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER})"

	pushd . > /dev/null
	cd "${CURL_VERSION}"
	./configure -prefix="/tmp/${CURL_VERSION}-${ARCH}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/Mac ${NGHTTP2CFG} ${LIBSSH2CFG} --host=${HOST} &> "/tmp/${CURL_VERSION}-${ARCH}.log"
	make -j${CORES} >> "/tmp/${CURL_VERSION}-${ARCH}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-${ARCH}.log" 2>&1
	# Save curl binary for Mac Version
	cp "/tmp/${CURL_VERSION}-${ARCH}/bin/curl" "/tmp/curl-${ARCH}"
	cp "/tmp/${CURL_VERSION}-${ARCH}/bin/curl" "/tmp/curl"
	make clean >> "/tmp/${CURL_VERSION}-${ARCH}.log" 2>&1
	popd > /dev/null

	# test binary
	if [ $ARCH == ${BUILD_MACHINE} ]; then
		echo -e "Testing binary for ${BUILD_MACHINE}:"
		/tmp/curl -V
	fi

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildCatalyst()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="MacOSX"
	TARGET="${ARCH}-apple-ios${CATALYST_IOS}-macabi"
	BUILD_MACHINE=`uname -m`

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/Catalyst/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/Catalyst/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/Catalyst/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/Catalyst/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -target $TARGET ${CC_BITCODE_FLAG}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/catalyst/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"

	echo -e "${subbold}Building ${CURL_VERSION} for ${archbold}${ARCH}${dim} ${BITCODE} (Mac Catalyst iOS ${CATALYST_IOS})"

	if [[ "${ARCH}" == "arm64" ]]; then
		./configure -prefix="/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/catalyst ${NGHTTP2CFG} ${LIBSSH2CFG} --host="arm-apple-darwin" &> "/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/catalyst ${NGHTTP2CFG} ${LIBSSH2CFG} --host="${ARCH}-apple-darwin" &> "/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log"
	fi
	
	make -j${CORES} >> "/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log" 2>&1
	make clean >> "/tmp/${CURL_VERSION}-catalyst-${ARCH}-${BITCODE}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export $PLATFORM=""
	export CROSS_TOP=""
	export CROSS_SDK=""
	export CC=""
	export CFLAGS=""
	export LDFLAGS=""
}


buildIOS()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="iPhoneOS"
	PLATFORMDIR="iOS"

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/${PLATFORMDIR}/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/${PLATFORMDIR}/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${IOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG}"

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} ${BITCODE} (iOS ${IOS_MIN_SDK_VERSION})"

	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"

	if [[ "${ARCH}" == *"arm64"* || "${ARCH}" == "arm64e" ]]; then
		./configure -prefix="/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP2CFG} ${LIBSSH2CFG} --host="arm-apple-darwin" &> "/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP2CFG} ${LIBSSH2CFG} --host="${ARCH}-apple-darwin" &> "/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j${CORES} >> "/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make clean >> "/tmp/${CURL_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export $PLATFORM=""
	export CROSS_TOP=""
	export CROSS_SDK=""
	export CC=""
	export CFLAGS=""
	export LDFLAGS=""
}

buildIOSsim()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="iPhoneSimulator"
	PLATFORMDIR="iOS-simulator"

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/${PLATFORMDIR}/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/${PLATFORMDIR}/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	TARGET="darwin-i386-cc"
	RUNTARGET=""
	MIPHONEOS="${IOS_MIN_SDK_VERSION}"
	if [[ $ARCH != "i386" ]]; then
		TARGET="darwin64-${ARCH}-cc"
		RUNTARGET="-target ${ARCH}-apple-ios${IOS_MIN_SDK_VERSION}-simulator"
	fi

	# set up exports for build 
	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CXX="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${MIPHONEOS} ${CC_BITCODE_FLAG} ${RUNTARGET} "
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"
	export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk "

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} ${BITCODE} (iOS ${IOS_MIN_SDK_VERSION})"

	if [[ "${ARCH}" == *"arm64"* || "${ARCH}" == "arm64e" ]]; then
		./configure -prefix="/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP2CFG} ${LIBSSH2CFG} --host="arm-apple-darwin" &> "/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	else
		./configure -prefix="/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}" $CONF_FLAGS --with-secure-transport --without-ca-bundle --with-ssl=${OPENSSL}/${PLATFORMDIR} ${NGHTTP2CFG} ${LIBSSH2CFG} --host="${ARCH}-apple-darwin" &> "/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log"
	fi

	make -j${CORES} >> "/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log" 2>&1
	make clean >> "/tmp/${CURL_VERSION}-iOS-simulator-${ARCH}-${BITCODE}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export $PLATFORM=""
	export CROSS_TOP=""
	export CROSS_SDK=""
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildTVOS()
{
	ARCH=$1
	BITCODE=$2

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="AppleTVSimulator"
	else
		PLATFORM="AppleTVOS"
	fi

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/tvOS/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/tvOS/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/tvOS/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/tvOS/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${TVOS_SDK_VERSION}.sdk"
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -L${OPENSSL}/tvOS/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"
#	export PKG_CONFIG_PATH

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS ${TVOS_MIN_SDK_VERSION})"

	./configure -prefix="/tmp/${CURL_VERSION}-tvOS-${ARCH}" --host="arm-apple-darwin" $CONF_FLAGS --with-secure-transport --without-ca-bundle --disable-shared -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/tvOS" ${NGHTTP2CFG} ${LIBSSH2CFG} &> "/tmp/${CURL_VERSION}-tvOS-${ARCH}.log"

	# Patch to not use fork() since it's not available on tvOS
        LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./lib/curl_config.h"
        LANG=C sed -i -- 's/HAVE_FORK"]=" 1"/HAVE_FORK\"]=" 0"/' "config.status"

	make -j${CORES} >> "/tmp/${CURL_VERSION}-tvOS-${ARCH}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-tvOS-${ARCH}.log" 2>&1
	make clean >> "/tmp/${CURL_VERSION}-tvOS-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export $PLATFORM=""
	export CROSS_TOP=""
	export CROSS_SDK=""
	export CC=""
	export CFLAGS=""
	export LDFLAGS=""
}


buildTVOSsim()
{
	ARCH=$1
	BITCODE=$2

	if [[ "${BITCODE}" == "nobitcode" ]]; then
		CC_BITCODE_FLAG=""
	else
		CC_BITCODE_FLAG="-fembed-bitcode"
	fi

	pushd . > /dev/null
	cd "${CURL_VERSION}"

	PLATFORM="AppleTVSimulator"
	PLATFORMDIR="tvOS-simulator"

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/${PLATFORMDIR}/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/${PLATFORMDIR}/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/${PLATFORMDIR}/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	TARGET="darwin64-${ARCH}-cc"
	RUNTARGET="-target ${ARCH}-apple-tvos${TVOS_MIN_SDK_VERSION}-simulator"

	export $PLATFORM
	export SYSROOT=$(xcrun --sdk appletvsimulator --show-sdk-path)
	export CC="${DEVELOPER}/usr/bin/gcc"
	export CXX="${DEVELOPER}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${SYSROOT} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG} ${RUNTARGET}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${SYSROOT} -L${OPENSSL}/${PLATFORMDIR}/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"
	export CPPFLAGS=" -I.. -isysroot ${SYSROOT} "

	echo -e "${subbold}Building ${CURL_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS SIM ${TVOS_MIN_SDK_VERSION})"

	if [[ "${ARCH}" == "arm64" ]]; then
		./configure --prefix="/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}" --host="arm-apple-darwin" $CONF_FLAGS --with-secure-transport --without-ca-bundle --disable-shared -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/${PLATFORMDIR}" ${NGHTTP2CFG} ${LIBSSH2CFG} &> "/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	else
		./configure --prefix="/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}" --host="${ARCH}-apple-darwin" $CONF_FLAGS --with-secure-transport --without-ca-bundle --disable-shared  -with-random=/dev/urandom --disable-ntlm-wb --with-ssl="${OPENSSL}/${PLATFORMDIR}" ${NGHTTP2CFG} ${LIBSSH2CFG} &> "/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}.log"
	fi

	# Patch to not use fork() since it's not available on tvOS
        LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./lib/curl_config.h"
        LANG=C sed -i -- 's/HAVE_FORK"]=" 1"/HAVE_FORK\"]=" 0"/' "config.status"

	make -j${CORES} >> "/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}.log" 2>&1
	make install >> "/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}.log" 2>&1
	make clean >> "/tmp/${CURL_VERSION}-tvOS-simulator-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export $PLATFORM=""
	export SYSROOT=""
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildAndroid()
{
	ARCH=$1
	TARGET=$ARCH
	ANDROID_API=$ANDROID_API_VERSION

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
	export CFLAGS="-fPIC"
	export CXXFLAGS="-fPIC"

	if [ $nohttp2 == "1" ]; then
		NGHTTP2CFG="--with-nghttp2=${NGHTTP2}/Android/${ARCH}"
		NGHTTP2LIB="-L${NGHTTP2}/Android/${ARCH}/lib"
	else 
		NGHTTP2CFG="--without-nghttp2"
		NGHTTP2LIB=""
	fi

	if [ $nolibssh2 == "1" ]; then
		LIBSSH2CFG="--with-libssh2=${LIBSSH2}/Android/${ARCH}"
		LIBSSH2LIB="-L${LIBSSH2}/Android/${ARCH}/lib"
	else 
		LIBSSH2CFG="--without-libssh2"
		LIBSSH2LIB=""
	fi

	SYSROOT="$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
    export CPPFLAGS="-I$SYSROOT/usr/include --sysroot=$SYSROOT"
	export LDFLAGS="-L${OPENSSL}/Android/${ARCH}/lib ${NGHTTP2LIB} ${LIBSSH2LIB}"

	echo -e "${subbold}Building ${CURL_VERSION} for ${archbold}${ARCH}${dim} (Android)"

	pushd . > /dev/null
	cd "${CURL_VERSION}"
	./configure --prefix="${CURL}/Android/${ARCH}" $CONF_FLAGS --with-ssl=${OPENSSL}/Android/${ARCH} ${NGHTTP2CFG} ${LIBSSH2CFG} --host=${HOST} --target=$HOST &> "/tmp/${CURL_VERSION}-${ARCH}.log"
	make -j${CORES} >> "/tmp/${NGHTTP2_VERSION}-${ARCH}.log" 2>&1
	make install >> "/tmp/${NGHTTP2_VERSION}-${ARCH}.log" 2>&1
	make clean >> "/tmp/${NGHTTP2_VERSION}-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export ANDROID_NDK_ROOT=""
	export CROSS_COMPILE=""
	export AR=""
	export CC=""
	export CXX=""
	export LD=""
	export RANLIB=""
	export CFLAGS=""
	export CXXFLAGS=""
	export CPPFLAGS=""
	export LDFLAGS=""
}

echo -e "${bold}Cleaning up${dim}"
rm -rf include/curl/* lib/*
rm -rf Android

mkdir -p lib
mkdir -p include/curl/
mkdir -p Android

rm -fr "/tmp/curl"
rm -rf "/tmp/${CURL_VERSION}-*"
rm -rf "/tmp/${CURL_VERSION}-*.log"

rm -rf "${CURL_VERSION}"

if [ ! -e ${CURL_VERSION}.tar.gz ]; then
	echo -e "${dim}Downloading ${CURL_VERSION}.tar.gz"
	curl -LOs https://curl.haxx.se/download/${CURL_VERSION}.tar.gz
else
	echo -e "${dim}Using ${CURL_VERSION}.tar.gz"
fi

echo -e "${dim}Unpacking curl"
tar xfz "${CURL_VERSION}.tar.gz"

if [ ${FORCE_SSLV3} == 'yes' ]; then
	if version_lte ${CURL_VERSION} "curl-7.76.1"; then
		echo -e "${dim}SSLv3 Requested: No patch needed for ${CURL_VERSION}."
	else
		echo -e "${dim}SSLv3 Requested: This requires a patch for 7.77.0 and above - mileage may vary."
		# for library
		sed -i '' '/version == CURL_SSLVERSION_SSLv3/d' "${CURL_VERSION}/lib/setopt.c"
		patch --ignore-whitespace -N "${CURL_VERSION}/lib/vtls/openssl.c" sslv3.patch || true
		# for command line
		sed -i '' -e 's/warnf(global, \"Ignores instruction to use SSLv3\");/config->ssl_version = CURL_SSLVERSION_SSLv3;/g' "${CURL_VERSION}/src/tool_getparam.c"
		sed -i '' -e 's/warnf(global, \"Ignores instruction to use SSLv3\\n\");/config->ssl_version = CURL_SSLVERSION_SSLv3;/g' "${CURL_VERSION}/src/tool_getparam.c"
	fi
fi

echo -e "${bold}Building Mac libraries${dim}"
buildMac "x86_64"
buildMac "arm64"

echo -e "  ${dim}Copying headers"
cp /tmp/${CURL_VERSION}-x86_64/include/curl/* include/curl/

lipo \
	"/tmp/${CURL_VERSION}-x86_64/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_Mac.a

if [ $catalyst == "1" ]; then
echo -e "${bold}Building Catalyst libraries${dim}"
buildCatalyst "x86_64" "bitcode"
buildCatalyst "arm64" "bitcode"

lipo \
	"/tmp/${CURL_VERSION}-catalyst-x86_64-bitcode/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-catalyst-arm64-bitcode/lib/libcurl.a" \
	-create -output lib/libcurl_Catalyst.a
fi

if ! [[ "${NOBITCODE}" == "yes" ]]; then
    BITCODE="bitcode"
else
    BITCODE="nobitcode"
fi

echo -e "${bold}Building iOS libraries (${BITCODE})${dim}"
buildIOS "armv7" "${BITCODE}"
buildIOS "armv7s" "${BITCODE}"
buildIOS "arm64" "${BITCODE}"
buildIOS "arm64e" "${BITCODE}"

lipo \
	"/tmp/${CURL_VERSION}-iOS-armv7-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-armv7s-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-arm64-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-arm64e-${BITCODE}/lib/libcurl.a" \
	-create -output lib/libcurl_iOS.a

buildIOSsim "i386" "${BITCODE}"
buildIOSsim "x86_64" "${BITCODE}"
buildIOSsim "arm64" "${BITCODE}"

lipo \
	"/tmp/${CURL_VERSION}-iOS-simulator-i386-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-simulator-x86_64-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-simulator-arm64-${BITCODE}/lib/libcurl.a" \
	-create -output lib/libcurl_iOS-simulator.a

lipo \
	"/tmp/${CURL_VERSION}-iOS-armv7-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-armv7s-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-arm64-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-arm64e-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-simulator-i386-${BITCODE}/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-iOS-simulator-x86_64-${BITCODE}/lib/libcurl.a" \
	-create -output lib/libcurl_iOS-fat.a


# if [[ "${NOBITCODE}" == "yes" ]]; then
# 	echo -e "${bold}Building iOS libraries (nobitcode)${dim}"
# 	buildIOS "armv7" "nobitcode"
# 	buildIOS "armv7s" "nobitcode"
# 	buildIOS "arm64" "nobitcode"
# 	buildIOS "arm64e" "nobitcode"
# 	buildIOSsim "x86_64" "nobitcode"
# 	buildIOSsim "i386" "nobitcode"

# 	lipo \
# 		"/tmp/${CURL_VERSION}-iOS-armv7-nobitcode/lib/libcurl.a" \
# 		"/tmp/${CURL_VERSION}-iOS-armv7s-nobitcode/lib/libcurl.a" \
# 		"/tmp/${CURL_VERSION}-iOS-simulator-i386-nobitcode/lib/libcurl.a" \
# 		"/tmp/${CURL_VERSION}-iOS-arm64-nobitcode/lib/libcurl.a" \
# 		"/tmp/${CURL_VERSION}-iOS-arm64e-nobitcode/lib/libcurl.a" \
# 		"/tmp/${CURL_VERSION}-iOS-simulator-x86_64-nobitcode/lib/libcurl.a" \
# 		-create -output lib/libcurl_iOS_nobitcode.a
# fi

echo -e "${bold}Building Android libraries${dim}"
buildAndroid "android-arm"
buildAndroid "android-arm64"
buildAndroid "android-x86"
buildAndroid "android-x86_64"

echo -e "${bold}Building tvOS libraries${dim}"
buildTVOS "arm64" "${BITCODE}"

lipo \
	"/tmp/${CURL_VERSION}-tvOS-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS.a

buildTVOSsim "x86_64" "${BITCODE}"
buildTVOSsim "arm64" "${BITCODE}"

lipo \
	"/tmp/${CURL_VERSION}-tvOS-arm64/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-tvOS-simulator-x86_64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS-fat.a

lipo \
	"/tmp/${CURL_VERSION}-tvOS-simulator-x86_64/lib/libcurl.a" \
	"/tmp/${CURL_VERSION}-tvOS-simulator-arm64/lib/libcurl.a" \
	-create -output lib/libcurl_tvOS-simulator.a

echo -e "${bold}Cleaning up${dim}"
rm -rf /tmp/${CURL_VERSION}-*
rm -rf ${CURL_VERSION}

echo -e "${dim}Checking libraries"
xcrun -sdk iphoneos lipo -info lib/*.a

#reset trap
trap - INT TERM EXIT

echo -e "${normal}Done"
