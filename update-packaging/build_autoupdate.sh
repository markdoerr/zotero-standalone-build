#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
. $ROOT_DIR/config.sh
UPDATE_STAGE_DIR="$SCRIPT_DIR/staging"

function usage {
	cat >&2 <<DONE
Usage: $0 -f [-i FROM_VERSION] [-c CHANNEL] [-p PLATFORMS] [-l] VERSION
Options
 -f                  Perform full build
 -i FROM             Perform incremental build
 -c CHANNEL          Release channel ('release', 'beta')
 -p PLATFORMS        Platforms to build (m=Mac, w=Windows, l=Linux)
 -l                  Use local TO directory instead of downloading TO files from S3
DONE
	exit 1
}

# From https://gist.github.com/cdown/1163649#gistcomment-1639097
urlencode() {
    local LANG=C
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

BUILD_FULL=0
BUILD_INCREMENTAL=0
FROM=""
BUILD_MAC=0
BUILD_WIN32=0
BUILD_LINUX=0
S3_SUBDIR=""
USE_LOCAL_TO=0
while getopts "i:c:p:fl" opt; do
	case $opt in
		i)
			FROM="$OPTARG"
			BUILD_INCREMENTAL=1
			;;
		c)
			# Use a subdirectory if not the 'release' channel
			if [ "$OPTARG" != 'release' ]; then
				S3_SUBDIR="/$OPTARG"
			fi
			;;
		p)
			for i in `seq 0 1 $((${#OPTARG}-1))`
			do
				case ${OPTARG:i:1} in
					m) BUILD_MAC=1;;
					w) BUILD_WIN32=1;;
					l) BUILD_LINUX=1;;
					*)
						echo "$0: Invalid platform option ${OPTARG:i:1}"
						usage
						;;
				esac
			done
			;;
		f)
			BUILD_FULL=1
			;;
		l)
			USE_LOCAL_TO=1
			;;
		*)
			usage
			;;
	esac
	shift $((OPTIND-1)); OPTIND=1
done

shift $(($OPTIND - 1))
TO=${1:-}

if [ -z "$TO" ]; then
	usage
fi

if [ -z "$FROM" ] && [ $BUILD_FULL -eq 0 ]; then
	usage
fi

# Require at least one platform
if [[ $BUILD_MAC == 0 ]] && [[ $BUILD_WIN32 == 0 ]] && [[ $BUILD_LINUX == 0 ]]; then
	usage
fi

rm -rf "$UPDATE_STAGE_DIR"
mkdir "$UPDATE_STAGE_DIR"

INCREMENTALS_FOUND=0
for version in "$FROM" "$TO"; do
	if [[ $version == "$TO" ]] && [[ $INCREMENTALS_FOUND == 0 ]] && [[ $BUILD_FULL == 0 ]]; then
		exit
	fi
	
	if [ -z "$version" ]; then
		continue
	fi
	
	echo "Getting Zotero version $version"
	
	versiondir="$UPDATE_STAGE_DIR/$version"
	
	#
	# Use main build script's staging directory for TO files rather than downloading the given version.
	#
	# The caller must ensure that the files in ../staging match the platforms and version given.
	if [[ $version == $TO && $USE_LOCAL_TO == "1" ]]; then
		if [ ! -d "$STAGE_DIR" ]; then
			echo "Can't find local TO dir $STAGE_DIR"
			exit 1
		fi
		
		echo "Using files from $STAGE_DIR"
		ln -s "$STAGE_DIR" "$versiondir"
		continue
	fi
	
	#
	# Otherwise, download version from S3
	#
	mkdir -p "$versiondir"
	cd "$versiondir"
	
	MAC_ARCHIVE="Zotero-${version}.dmg"
	WIN_ARCHIVE="Zotero-${version}_win32.zip"
	LINUX_X86_ARCHIVE="Zotero-${version}_linux-i686.tar.bz2"
	LINUX_X86_64_ARCHIVE="Zotero-${version}_linux-x86_64.tar.bz2"
	
	for archive in "$MAC_ARCHIVE" "$WIN_ARCHIVE" "$LINUX_X86_ARCHIVE" "$LINUX_X86_64_ARCHIVE"; do
		if [[ $archive = "$MAC_ARCHIVE" ]] && [[ $BUILD_MAC != 1 ]]; then
			continue
		fi
		if [[ $archive = "$WIN_ARCHIVE" ]] && [[ $BUILD_WIN32 != 1 ]]; then
			continue
		fi
		if [[ $archive = "$LINUX_X86_ARCHIVE" ]] && [[ $BUILD_LINUX != 1 ]]; then
			continue
		fi
		if [[ $archive = "$LINUX_X86_64_ARCHIVE" ]] && [[ $BUILD_LINUX != 1 ]]; then
			continue
		fi
		
		rm -f $archive
		# URL-encode '+' in beta version numbers
		ENCODED_VERSION=`urlencode $version`
		ENCODED_ARCHIVE=`urlencode $archive`
		URL="https://$S3_BUCKET.s3.amazonaws.com/$S3_PATH${S3_SUBDIR}/$ENCODED_VERSION/$ENCODED_ARCHIVE"
		echo "Fetching $URL"
		set +e
		wget -nv $URL
		set -e
	done
	
	# Unpack Zotero.app
	if [ $BUILD_MAC == 1 ]; then
		if [ -f "$MAC_ARCHIVE" ]; then
			set +e
			hdiutil detach -quiet /Volumes/Zotero 2>/dev/null
			set -e
			hdiutil attach -quiet "$MAC_ARCHIVE"
			cp -R /Volumes/Zotero/Zotero.app "$versiondir"
			rm "$MAC_ARCHIVE"
			hdiutil detach -quiet /Volumes/Zotero
			INCREMENTALS_FOUND=1
		else
			echo "$MAC_ARCHIVE not found"
		fi
	fi
	
	# Unpack Win32 zip
	if [ $BUILD_WIN32 == 1 ]; then
		if [ -f "$WIN_ARCHIVE" ]; then
			unzip -q "$WIN_ARCHIVE"
			rm "$WIN_ARCHIVE"
			INCREMENTALS_FOUND=1
		else
			echo "$WIN_ARCHIVE not found"
		fi
	fi
	
	# Unpack Linux tarballs
	if [ $BUILD_LINUX == 1 ]; then
		if [[ -f "$LINUX_X86_ARCHIVE" ]] && [[ -f "$LINUX_X86_64_ARCHIVE" ]]; then
			for build in "$LINUX_X86_ARCHIVE" "$LINUX_X86_64_ARCHIVE"; do
				tar -xjf "$build"
				rm "$build"
			done
			INCREMENTALS_FOUND=1
		else
			echo "$LINUX_X86_ARCHIVE/$LINUX_X86_64_ARCHIVE not found"
		fi
	fi
	
	echo
done

CHANGES_MADE=0
for build in "mac" "win32" "linux-i686" "linux-x86_64"; do
	if [[ $build == "mac" ]]; then
		if [[ $BUILD_MAC == 0 ]]; then
			continue
		fi
		dir="Zotero.app"
	else
		if [[ $build == "win32" ]] && [[ $BUILD_WIN32 == 0 ]]; then
			continue
		fi
		if [[ $build == "linux-i686" ]] || [[ $build == "linux-x86_64" ]] && [[ $BUILD_LINUX == 0 ]]; then
			continue
		fi
		dir="Zotero_$build"
		touch "$UPDATE_STAGE_DIR/$TO/$dir/precomplete"
		cp "$SCRIPT_DIR/removed-files_$build" "$UPDATE_STAGE_DIR/$TO/$dir/removed-files"
	fi
	if [[ $BUILD_INCREMENTAL == 1 ]] && [[ -d "$UPDATE_STAGE_DIR/$FROM/$dir" ]]; then
		echo
		echo "Building incremental update from $FROM to $TO"
		"$SCRIPT_DIR/make_incremental_update.sh" "$DIST_DIR/Zotero-${TO}-${FROM}_$build.mar" "$UPDATE_STAGE_DIR/$FROM/$dir" "$UPDATE_STAGE_DIR/$TO/$dir"
		CHANGES_MADE=1
	fi
	if [[ $BUILD_FULL == 1 ]]; then
		echo
		echo "Building full update for $TO"
		"$SCRIPT_DIR/make_full_update.sh" "$DIST_DIR/Zotero-${TO}-full_$build.mar" "$UPDATE_STAGE_DIR/$TO/$dir"
		CHANGES_MADE=1
	fi
done

rm -rf "$UPDATE_STAGE_DIR"

# Update file manifests
if [ $CHANGES_MADE -eq 1 ]; then
	cd "$DIST_DIR"
	for platform in "mac" "win" "linux"; do
		file=files-$platform
		rm -f $file
		for fn in `find . -name "*$platform*.mar" -exec basename {} \;`; do
			size=`wc -c "$fn" | tr -s ' ' | cut -d ' ' -f2`
			hash=`shasum -a 512 "$fn" | cut -d ' ' -f1`
			echo $fn $hash $size >> $file
		done
	done
fi
