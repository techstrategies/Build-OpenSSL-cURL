#!/bin/bash
# This script downloads and builds the Mac, iOS and tvOS libevent libraries 
#
# libevent - https://libevent.org
#

# > libevent is an event notification library
# 
# NOTE: pkg-config is required

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

# set trap to help debug build errors
trap 'echo -e "${alert}** ERROR with Build - Check /tmp/libevent*.log${alertdim}"; tail -5 /tmp/libevent*.log' INT TERM EXIT

# --- Edit this to update default version ---
LIBEVENT_VERNUM="2.1.12-stable"
ANDROID_API_VERSION="28"		# Android API

# Set defaults
catalyst="0"

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

CORES=$(sysctl -n hw.ncpu)

usage ()
{
	echo
	echo -e "${bold}Usage:${normal}"
	echo
    echo -e "  ${subbold}$0${normal} [-v ${dim}<libevent version>${normal}] [-s ${dim}<iOS SDK version>${normal}] [-t ${dim}<tvOS SDK version>${normal}] [-m] [-x] [-h]"
    echo
	echo "         -v   version of libevent (default $LIBEVENT_VERNUM)"
	echo "         -s   iOS min target version (default $IOS_MIN_SDK_VERSION)"
	echo "         -t   tvOS min target version (default $TVOS_MIN_SDK_VERSION)"
	echo "         -i   macOS 86_64 min target version (default $MACOS_X86_64_VERSION)"
	echo "         -a   macOS arm64 min target version (default $MACOS_ARM64_VERSION)"
	echo "         -m   compile Mac Catalyst library"
	echo "         -u   Mac Catalyst iOS min target version (default $CATALYST_IOS)"
	echo "         -x   disable color output"
	echo "         -h   show usage"	
	echo
	trap - INT TERM EXIT
	exit 127
}

while getopts "v:s:t:i:a:u:mxh\?" o; do
    case "${o}" in
        v)
            LIBEVENT_VERNUM="${OPTARG}"
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
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

LIBEVENT_VERSION="libevent-${LIBEVENT_VERNUM}"
DEVELOPER=`xcode-select -print-path`

LIBEVENT="${PWD}/../libevent"

# Semantic Version Comparison
version_lte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}
if version_lte $MACOS_ARM64_VERSION 11.0; then
        MACOS_ARM64_VERSION="11.0"      # Min support for Apple Silicon is 11.0
fi

# Check to see if pkg-config is already installed
if (type "pkg-config" > /dev/null 2>&1 ) ; then
	echo -e "  ${dim}pkg-config already installed"
else
	echo -e "${alertdim}** WARNING: pkg-config not installed... attempting to install.${dim}"

	# Check to see if Brew is installed
	if (type "brew" > /dev/null 2>&1 ) ; then
		echo -e "  ${dim}brew installed - using to install pkg-config"
		brew install pkg-config
	else
		# Build pkg-config from Source
		echo -e "  ${dim}Downloading pkg-config-0.29.2.tar.gz"
		curl -LOs https://pkg-config.freedesktop.org/releases/pkg-config-0.29.2.tar.gz
		echo -e "  ${dim}Building pkg-config"
		tar xfz pkg-config-0.29.2.tar.gz
		pushd pkg-config-0.29.2 > /dev/null
		./configure --prefix=/tmp/pkg_config --with-internal-glib >> "/tmp/${LIBEVENT_VERSION}.log" 2>&1
		make -j${CORES} >> "/tmp/${LIBEVENT_VERSION}.log" 2>&1
		make install >> "/tmp/${LIBEVENT_VERSION}.log" 2>&1
		PATH=$PATH:/tmp/pkg_config/bin
		popd > /dev/null
	fi

	# Check to see if installation worked
	if (type "pkg-config" > /dev/null 2>&1 ) ; then
		echo -e "  ${dim}SUCCESS: pkg-config installed"
	else
		echo -e "${alert}** FATAL ERROR: pkg-config failed to install - exiting.${normal}"
		exit 1
	fi
fi 

buildMac()
{
	ARCH=$1

	TARGET="darwin-i386-cc"
	BUILD_MACHINE=`uname -m`
	export CC="${BUILD_TOOLS}/usr/bin/gcc -fembed-bitcode"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
	export LDFLAGS="-arch ${ARCH}"

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode"
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected 
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode"
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode"
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
		fi
	fi

	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER})"

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"
	if [[ $ARCH != ${BUILD_MACHINE} ]]; then
		# cross compile required
		if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
			./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/Mac/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log"
		else
			./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/Mac/${ARCH}" --host="${ARCH}-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log"
		fi
	else
		./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/Mac/${ARCH}" &> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log"
	fi
	make -j${CORES} >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
	make install >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
	popd > /dev/null

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

	TARGET="darwin64-${ARCH}-cc"
	BUILD_MACHINE=`uname -m`

	export CC="${BUILD_TOOLS}/usr/bin/gcc"
    export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
    export LDFLAGS="-arch ${ARCH}"

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
		MACOS_VER="${MACOS_X86_64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - cross compile
			TARGET="darwin64-x86_64-cc"
			MACOS_VER="${MACOS_X86_64_VERSION}"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		else
			# Apple x86_64 Build Machine Detected - native build
			export CFLAGS=" -mmacosx-version-min=${MACOS_X86_64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
		fi
	fi
	if [[ $ARCH == "arm64" ]]; then
		TARGET="darwin64-arm64-cc"
		MACOS_VER="${MACOS_ARM64_VERSION}"
		if [ ${BUILD_MACHINE} == 'arm64' ]; then
   			# Apple ARM Silicon Build Machine Detected - native build
			TARGET="darwin64-arm64-cc"
			export CFLAGS=" -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -pipe -Os -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
		else
			# Apple x86_64 Build Machine Detected - cross compile
			TARGET="darwin64-arm64-cc"
			export CC="clang"
			export CXX="clang"
			export CFLAGS=" -Os -mmacosx-version-min=${MACOS_ARM64_VERSION} -arch ${ARCH} -gdwarf-2 -fembed-bitcode -target ${ARCH}-apple-ios${CATALYST_IOS}-macabi "
			export LDFLAGS=" -arch ${ARCH} -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
			export CPPFLAGS=" -I.. -isysroot ${DEVELOPER}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk "
		fi
	fi

	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${archbold}${ARCH}${dim} (MacOS ${MACOS_VER} Catalyst iOS ${CATALYST_IOS})"

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"

	# Cross compile required for Catalyst
	if [[ "${ARCH}" == "arm64" ]]; then
		./configure --disable-shared --enable-static ---disable-openssl --prefix="${LIBEVENT}/Catalyst/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-catalyst-${ARCH}.log"
	else
		./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/Catalyst/${ARCH}" --host="${ARCH}-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-catalyst-${ARCH}.log"
	fi
	
	make -j${CORES} >> "/tmp/${LIBEVENT_VERSION}-catalyst-${ARCH}.log" 2>&1
	make install >> "/tmp/${LIBEVENT_VERSION}-catalyst-${ARCH}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-catalyst-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildIOS()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"
  
	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="iPhoneSimulator"
	else
		PLATFORM="iPhoneOS"
	fi

        if [[ "${BITCODE}" == "nobitcode" ]]; then
                CC_BITCODE_FLAG=""
        else
                CC_BITCODE_FLAG="-fembed-bitcode"
        fi
  
	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${IOS_MIN_SDK_VERSION} ${CC_BITCODE_FLAG}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK}"
   
	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} (iOS ${IOS_MIN_SDK_VERSION})"
	if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
		./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/iOS/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
		./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/iOS/${ARCH}" --host="${ARCH}-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j8 >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make install >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildIOSsim()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"
  
  	PLATFORM="iPhoneSimulator"
	export $PLATFORM

	TARGET="darwin-i386-cc"
	RUNTARGET=""
	MIPHONEOS="${IOS_MIN_SDK_VERSION}"
	if [[ $ARCH != "i386" ]]; then
		TARGET="darwin64-${ARCH}-cc"
		RUNTARGET="-target ${ARCH}-apple-ios${IOS_MIN_SDK_VERSION}-simulator"
			# e.g. -target arm64-apple-ios11.0-simulator
	fi

	if [[ "${BITCODE}" == "nobitcode" ]]; then
			CC_BITCODE_FLAG=""
	else
			CC_BITCODE_FLAG="-fembed-bitcode"
	fi
  
	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -miphoneos-version-min=${MIPHONEOS} ${CC_BITCODE_FLAG} ${RUNTARGET}  "
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK}"
   
	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${archbold}${ARCH}${dim} (iOS ${IOS_MIN_SDK_VERSION})"
	if [[ "${ARCH}" == "arm64" || "${ARCH}" == "arm64e"  ]]; then
	./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/iOS-simulator/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	else
	./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/iOS-simulator/${ARCH}" --host="${ARCH}-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log"
	fi

	make -j8 >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make install >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-iOS-${ARCH}-${BITCODE}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildTVOS()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"
  
	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="AppleTVSimulator"
	else
		PLATFORM="AppleTVOS"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${TVOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} -mtvos-version-min=${TVOS_MIN_SDK_VERSION}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK}"
	export LC_CTYPE=C
  
	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS ${TVOS_MIN_SDK_VERSION})"

	# Patch source to remove all uses of fork() since it's not available on tvOS
	LANG=C sed -i -- 's/opt_nofork = 0/opt_nofork = 1/' "./test/tinytest.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/tinytest.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/regress_main.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/regress_thread.c"

	./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/tvOS/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log"

	make -j8 >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	make install  >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
	export CC=""
	export CXX=""
	export CFLAGS=""
	export LDFLAGS=""
	export CPPFLAGS=""
}

buildTVOSsim()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"

	PLATFORM="AppleTVSimulator"

	TARGET="darwin64-${ARCH}-cc"
	RUNTARGET="-target ${ARCH}-apple-tvos${TVOS_MIN_SDK_VERSION}-simulator"

	export $PLATFORM
	export SYSROOT=$(xcrun --sdk appletvsimulator --show-sdk-path)
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc"
	export CFLAGS="-arch ${ARCH} -pipe -Os -gdwarf-2 -isysroot ${SYSROOT} -mtvos-version-min=${TVOS_MIN_SDK_VERSION} ${RUNTARGET}"
	export LDFLAGS="-arch ${ARCH} -isysroot ${SYSROOT}"
	export LC_CTYPE=C

	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${archbold}${ARCH}${dim} (tvOS Simulator ${TVOS_MIN_SDK_VERSION})"

	# Patch source to remove all uses of fork() since it's not available on tvOS
	LANG=C sed -i -- 's/opt_nofork = 0/opt_nofork = 1/' "./test/tinytest.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/tinytest.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/regress_main.c"
	LANG=C sed -i -- 's/fork()/0/' "./test/regress_thread.c"

	if [[ "${ARCH}" == "arm64" ]]; then
	./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/tvOS-simulator/${ARCH}" --host="arm-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-tvOS-simulator${ARCH}.log"
	else
	./configure --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/tvOS-simulator/${ARCH}" --host="${ARCH}-apple-darwin" &> "/tmp/${LIBEVENT_VERSION}-tvOS-simulator${ARCH}.log"
	fi

	make -j8 >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	make install  >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-tvOS-${ARCH}.log" 2>&1
	popd > /dev/null

	# Clean up exports
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

	echo -e "${subbold}Building ${LIBEVENT_VERSION} for ${archbold}${ARCH}${dim} (Android)"

	pushd . > /dev/null
	cd "${LIBEVENT_VERSION}"
	./configure --host=$HOST --target=$TARGET --disable-shared --enable-static --disable-openssl --prefix="${LIBEVENT}/Android/${ARCH}" &> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log"
	make -j${CORES} >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
	make install >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
	make clean >> "/tmp/${LIBEVENT_VERSION}-${ARCH}.log" 2>&1
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
rm -rf include/event2/* lib/*
rm -fr Android
rm -fr Mac
rm -fr iOS
rm -fr tvOS
rm -fr Catalyst

mkdir -p lib
mkdir -p include/event2
mkdir -p Android
mkdir -p Mac
mkdir -p iOS
mkdir -p tvOS
mkdir -p Catalyst

rm -rf "/tmp/${LIBEVENT_VERSION}-*"
rm -rf "/tmp/${LIBEVENT_VERSION}-*.log"

rm -rf "${LIBEVENT_VERSION}"

if [ ! -e ${LIBEVENT_VERSION}.tar.gz ]; then
	echo -e "${dim}Downloading ${LIBEVENT_VERSION}.tar.gz"
	curl -LOs https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERNUM}/${LIBEVENT_VERSION}.tar.gz
else
	echo -e "${dim}Using ${LIBEVENT_VERSION}.tar.gz"
fi

echo -e "${dim}Unpacking libevent"
tar xfz "${LIBEVENT_VERSION}.tar.gz"

echo -e "${bold}Building Mac libraries${dim}"
buildMac "x86_64"
buildMac "arm64"

echo -e "  ${dim}Copying headers"
cp ${LIBEVENT}/Mac/x86_64/include/event2/* include/event2/

lipo \
        "${LIBEVENT}/Mac/x86_64/lib/libevent.a" \
		"${LIBEVENT}/Mac/arm64/lib/libevent.a" \
        -create -output "${LIBEVENT}/lib/libevent_Mac.a"

if [ $catalyst == "1" ]; then
echo -e "${bold}Building Catalyst libraries${dim}"
buildCatalyst "x86_64"
buildCatalyst "arm64"

lipo \
        "${LIBEVENT}/Catalyst/x86_64/lib/libevent.a" \
		"${LIBEVENT}/Catalyst/arm64/lib/libevent.a" \
        -create -output "${LIBEVENT}/lib/libevent_Catalyst.a"
fi

echo -e "${bold}Building iOS libraries${dim}"
buildIOS "armv7" "nobitcode"
buildIOS "armv7s" "nobitcode"
buildIOS "arm64" "nobitcode"
buildIOS "arm64e" "nobitcode"

echo -e "${bold}Building iOS simulator libraries (bitcode)${dim}"
buildIOSsim "x86_64" "bitcode"
buildIOSsim "arm64" "bitcode"
buildIOSsim "i386" "bitcode"

lipo \
	"${LIBEVENT}/iOS/armv7/lib/libevent.a" \
	"${LIBEVENT}/iOS/armv7s/lib/libevent.a" \
	"${LIBEVENT}/iOS-simulator/i386/lib/libevent.a" \
	"${LIBEVENT}/iOS/arm64/lib/libevent.a" \
	"${LIBEVENT}/iOS/arm64e/lib/libevent.a" \
	"${LIBEVENT}/iOS-simulator/x86_64/lib/libevent.a" \
	-create -output "${LIBEVENT}/lib/libevent_iOS-fat.a"

lipo \
	"${LIBEVENT}/iOS/armv7/lib/libevent.a" \
	"${LIBEVENT}/iOS/armv7s/lib/libevent.a" \
	"${LIBEVENT}/iOS/arm64/lib/libevent.a" \
	"${LIBEVENT}/iOS/arm64e/lib/libevent.a" \
	-create -output "${LIBEVENT}/lib/libevent_iOS.a"

lipo \
	"${LIBEVENT}/iOS-simulator/i386/lib/libevent.a" \
	"${LIBEVENT}/iOS-simulator/x86_64/lib/libevent.a" \
	"${LIBEVENT}/iOS-simulator/arm64/lib/libevent.a" \
	-create -output "${LIBEVENT}/lib/libevent_iOS-simulator.a"

echo -e "${bold}Building Android libraries${dim}"
buildAndroid "android-arm"
buildAndroid "android-arm64"
buildAndroid "android-x86"
buildAndroid "android-x86_64"

echo -e "${bold}Building tvOS libraries${dim}"
buildTVOS "arm64"

lipo \
        "${LIBEVENT}/tvOS/arm64/lib/libevent.a" \
        -create -output "${LIBEVENT}/lib/libevent_tvOS.a"

buildTVOSsim "x86_64"
buildTVOSsim "arm64"

lipo \
        "${LIBEVENT}/tvOS/arm64/lib/libevent.a" \
        "${LIBEVENT}/tvOS-simulator/x86_64/lib/libevent.a" \
        -create -output "${LIBEVENT}/lib/libevent_tvOS-fat.a"

lipo \
	"${LIBEVENT}/tvOS-simulator/x86_64/lib/libevent.a" \
	"${LIBEVENT}/tvOS-simulator/arm64/lib/libevent.a" \
	-create -output "${LIBEVENT}/lib/libevent_tvOS-simulator.a"

echo -e "${bold}Cleaning up${dim}"
rm -rf /tmp/${LIBEVENT_VERSION}-*
rm -rf ${LIBEVENT_VERSION}

#reset trap
trap - INT TERM EXIT

echo -e "${normal}Done"

