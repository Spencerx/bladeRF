#!/usr/bin/env bash
#
# Build a bladeRF fpga image
################################################################################

# Ensure we're in the right directory and submodules are initialized
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Initialize and update submodules if needed
echo "Checking and initializing submodules..."
cd "$PROJECT_ROOT"
if [ -f .gitmodules ]; then
    # Initialize submodules if not already initialized
    git submodule init

    # Update submodules to ensure they're checked out
    git submodule update

    echo "Submodules initialized and updated."
fi
cd "$SCRIPT_DIR"

cleanup() {
    # Prevent recursive cleanup calls
    trap '' INT TERM HUP

    echo "Cleaning up and terminating builds..."
    if [ -n "${build_pids[*]}" ]; then
        for pid in "${build_pids[@]}"; do
            pkill -P $pid 2>/dev/null || true
        done
    fi

    exit 1
}

# Set up trap to catch Ctrl+C and other termination signals
trap cleanup INT TERM HUP

function print_boards() {
    echo "Supported boards:"
    for i in ../fpga/platforms/*/build/platform.conf ; do
        source $i
        echo "    [*] $BOARD_NAME";
        echo "        Supported revisions:"
        for rev in ${PLATFORM_REVISIONS[@]} ; do
            echo "            ${rev}"
        done
        echo "        Supported sizes (kLE):"
        for size in ${PLATFORM_FPGA_SIZES[@]} ; do
            echo "            ${size}"
        done
        echo ""
    done
}

function usage()
{
    echo ""
    echo "bladeRF FPGA build script"
    echo ""
    echo "Usage: `basename $0` -b <board_name> -r <rev> -s <size>"
    echo ""
    echo "Options:"
    echo "    -c                    Clear working directory"
    echo "    -b <board_name>       Target board name"
    echo "    -r <rev>              Quartus project revision"
    echo "    -s <size>             FPGA size"
    echo "    -a <stp>              SignalTap STP file"
    echo "    -H                    Build all hosted configurations"
    echo "    -f                    Force SignalTap STP insertion by temporarily enabling"
    echo "                          the TalkBack feature of Quartus (required for Web Edition)."
    echo "                          The previous setting will be restored afterward."
    echo "    -n <Tiny|Fast>        Select Nios II Gen 2 core implementation."
    echo "       Tiny (default)       Nios II/e; Compatible with Quartus Web Edition"
    echo "       Fast                 Nios II/f; Requires Quartus Standard or Pro Edition"
    echo "    -l <gen|synth|full>   Quartus build steps to complete. Valid options:"
    echo "       gen                  Only generate the project files"
    echo "       synth                Synthesize the design"
    echo "       full (default)       Fit the design and create programming files"
    echo "    -S <seed>             Fitter seed setting (default: 1)"
    echo "    -D                    Output directory name won't contain the date"
    echo "    -h                    Show this text"
    echo ""

    print_boards

}

pushd () {
    command pushd "$@" >/dev/null
}

popd () {
    command popd "$@" >/dev/null
}

# Current Quartus version
declare -A QUARTUS_VER # associative array
QUARTUS_VER[major]=0
QUARTUS_VER[minor]=0

# Parameters:
#   $1 Expected major Quartus version
#   $2 Expected minor Quartus version
# Returns:
#   0 on compatible version
#   1 on incompatible version or unable to detemine version
check_quartus_version()
{
    local readonly exp_major_ver="$1"
    local readonly exp_minor_ver="$2"
    local readonly exp_ver="${exp_major_ver}.${exp_minor_ver}"

    local readonly VERSION_FILE="${QUARTUS_ROOTDIR}/version.txt"

    if [ ! -f "${VERSION_FILE}" ]; then
        echo "Could not find Quartus version file." >&2
        return 1
    fi

    local readonly VERSION=$( \
        grep -m 1 Version "${QUARTUS_ROOTDIR}/version.txt" | \
        sed -e 's/Version=//' \
    )

    echo "Detected Quartus II ${VERSION}"

    QUARTUS_VER[major]=$( \
        echo "${VERSION}" | \
        sed -e 's/\([[:digit:]]\+\).*/\1/g' \
    )

    QUARTUS_VER[minor]=$( \
        echo "${VERSION}"   | \
        sed -e 's/^16\.//g' | \
        sed -e 's/\([[:digit:]]\+\).*/\1/g' \
    )

    if [ -z "${QUARTUS_VER[major]}" ] ||
           [ -z "${QUARTUS_VER[minor]}" ]; then
        echo "Failed to retrieve Quartus version number." >&2
        return 1
    fi

    if [ $(expr ${QUARTUS_VER[major]}\.${QUARTUS_VER[minor]} \< ${exp_ver}) -eq 1 ]; then
        echo "The bladeRF FPGA design requires Quartus II version ${exp_ver}" >&2
        echo "The installed version is: $VERSION" >&2
        return 1
    fi

    return 0
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

# Set default options
nios_rev="Tiny"
flow="full"
seed="1"
omit_date=false

while getopts ":cb:r:s:a:fn:l:S:DhH" opt; do
    case $opt in
        c)
            clear_work_dir=1
            ;;

        b)
            board=$OPTARG
            ;;

        r)
            rev=$OPTARG
            ;;

        s)
            size=$OPTARG
            ;;

        a)
            echo "STP: $OPTARG"
            stp=$(readlink -f $OPTARG)
            ;;

        H)
            build_hosted=1
            ;;

        f)
            echo "Forcing STP insertion"
            force="-force"
            ;;

        n)
            nios_rev=$OPTARG
            ;;

        l)
            flow=$OPTARG
            ;;

        S)
            seed=$OPTARG
            ;;

        D)
            omit_date=true
            ;;

        h)
            usage
            exit 0
            ;;

        \?)
            echo -e "\nUnrecognized option: -$OPTARG\n" >&2
            exit 1
            ;;

        :)
            echo -e "\nArgument required for argument -${OPTARG}.\n" >&2
            exit 1
            ;;
    esac
done

if [ "$build_hosted" == "1" ]; then
    mkdir -p build_logs
    build_pids=()

    echo "Starting parallel builds for all hosted configurations..."
    for config in "bladeRF 40" "bladeRF 115" "bladeRF-micro A4" "bladeRF-micro A5" "bladeRF-micro A9"; do
        read -r board size <<< "$config"
        log_file="build_logs/$board-hosted-$size.log"
        $0 -b "$board" -r hosted -s "$size" > "$log_file" 2>&1 &
        build_pids+=($!)
        echo " → $board $size (PID: ${build_pids[-1]})"
    done

    echo "Waiting for ${#build_pids[@]} builds to complete..."

    # Monitor build processes
    failed=0
    for pid in "${build_pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo "One or more builds failed. Check build_logs directory for details."
        cleanup
        exit 1
    fi

    echo "All hosted builds completed successfully!"
    exit 0
fi

if [ "$board" == "" ]; then
    echo -e "\nError: board (-b) is required\n" >&2
    print_boards
    exit 1
fi

if [ "$size" == "" ]; then
    echo -e "\nError: FPGA size (-s) is required\n" >&2
    print_boards
    exit 1
fi

if [ "$rev" == "" ]; then
    echo -e "\nError: Quartus project revision (-r) is required\n" >&2
    print_boards
    exit 1
fi

for plat in ../fpga/platforms/*/build/platform.conf ; do
    source $plat
    if [ $board == "$BOARD_NAME" ]; then
        platform=$(basename $(dirname $(dirname $plat)))
        break
    fi
done

if [ "$platform" == "" ]; then
    echo -e "\nError: Invalid board (\"$board\")\n" >&2
    exit 1
fi

for plat_size in ${PLATFORM_FPGA_SIZES[@]} ; do
    if [ "$size" == "$plat_size" ]; then
        size_valid="yes"
        break
    fi
done

if [ "$size_valid" == "" ]; then
    echo -e "\nError: Invalid FPGA size (\"$size\")\n" >&2
    print_boards
    exit 1
fi

for plat_rev in ${PLATFORM_REVISIONS[@]} ; do
    if [ "$rev" == "$plat_rev" ]; then
        rev_valid="yes"
        break
    fi
done

if [ "$rev_valid" == "" ]; then
    echo -e "\nError: Invalid Quartus project revision (\"$rev\")\n" >&2
    print_boards
    exit 1
fi

if [ "$stp" != "" ] && [ ! -f "$stp" ]; then
    echo -e "\nCould not find STP file: $stp\n" >&2
    exit 1
fi

nios_rev=$(echo "$nios_rev" | tr "[:upper:]" "[:lower:]")
if [ "$nios_rev" != "tiny" ] && [ "$nios_rev" != "fast" ]; then
    echo -e "\nInvalid Nios II revision: $nios_rev\n" >&2
    exit 1
fi

if [[ ${flow} != "gen" ]] &&
       [[ ${flow} != "synth" ]] &&
       [[ ${flow} != "full" ]]; then
    echo -e "\nERROR: Invalid flow option: ${flow}.\n" >&2
    exit 1
fi

DEVICE_FAMILY=$(get_device_family $size)
DEVICE=$(get_device $size)

# Check for quartus_sh
quartus_check="`which quartus_sh`"
if [ $? -ne 0 ] || [ ! -f "$quartus_check" ]; then
    echo -e "\nError: quartus_sh (Quartus 'bin' directory) does not appear to be in your PATH\n" >&2
    exit 1
fi

# Check for Qsys
qsys_check="`which qsys-generate`"
if [ $? -ne 0 ] || [ ! -f "$qsys_check" ]; then
    echo -e "\nError: Qsys (SOPC builder 'bin' directory) does not appear to be in your PATH.\n" >&2
    exit 1
fi

# Check for Nios II SDK
nios2_check="`which nios2-bsp-create-settings`"
if [ $? -ne 0 ] || [ ! -f "$nios2_check" ]; then
    echo -e "\nError: Nios II SDK (nios2eds 'bin' directory) does not appear to be in your PATH.\n" >&2
    exit 1
fi

# Complain early about an unsupported version. Otherwise, the user
# may get some unintuitive error messages.
check_quartus_version ${PLATFORM_QUARTUS_VER[major]} ${PLATFORM_QUARTUS_VER[minor]}
if [ $? -ne 0 ]; then
    exit 1
fi

if [ $(expr ${QUARTUS_VER[major]} \>= 19 ) -eq 1 ]; then
   export PERL5LIB=$(echo ${QUARTUS_ROOTDIR}/linux64/perl/lib/*.*/)
fi

nios_system=../fpga/ip/altera/nios_system

# 9a484b436: Windows-specific workaround for Quartus bug
if [ "x$(uname)" != "xLinux" ]; then
    QUARTUS_BINDIR=$QUARTUS_ROOTDIR/bin
    export QUARTUS_BINDIR
    echo "## Non-Linux OS Detected (Windows?)"
    echo "## Forcing QUARTUS_BINDIR to ${QUARTUS_BINDIR}"
fi

# Error out at the first sign of trouble
set -e

work_dir="work/${platform}-${size}-${rev}"

if [ "$clear_work_dir" == "1" ]; then
    echo -e "\nClearing ${work_dir} directory\n" >&2
    rm -rf "${work_dir}"
fi

mkdir -p ${work_dir}
pushd ${work_dir}

# These paths are relative to $work_dir
common_dir=../../../fpga/platforms/common/bladerf
build_dir=../../../fpga/platforms/${platform}/build

cp -au ${build_dir}/ip.ipx .

if [ -f ${build_dir}/suppressed_messages.srf ]; then
    cp -au ${build_dir}/suppressed_messages.srf ./${rev}.srf
fi

echo ""
echo "##########################################################################"
echo "    Generating Nios II Qsys for ${board} ..."
echo "##########################################################################"
echo ""

if [ -f nios_system.qsys ]; then
    echo "Skipping building platform Qsys"
else
    echo "Building platform Qsys"
    cmd="set nios_impl ${nios_rev}"
    cmd="${cmd}; set device_family {${DEVICE_FAMILY}}"
    cmd="${cmd}; set device ${DEVICE}"
    cmd="${cmd}; set nios_impl ${nios_rev}"
    cmd="${cmd}; set ram_size $(get_qsys_ram $size)"
    cmd="${cmd}; set platform_revision ${rev}"
    qsys-script \
        --script=${build_dir}/nios_system.tcl \
        --cmd="${cmd}"
fi

if [ -f ${build_dir}/platform.sh ]; then
    source ${build_dir}/platform.sh
fi

if [ -f nios_system.sopcinfo ]; then
    echo "Skipping qsys-generate, nios_system.sopcinfo already exists"
else
    qsys-generate --synthesis=Verilog nios_system.qsys
fi

echo ""
echo "##########################################################################"
echo "    Building BSP and ${board} application..."
echo "##########################################################################"
echo ""

mkdir -p bladeRF_nios_bsp
if [ -f settings.bsp ]; then
    echo "Skipping creating Nios BSP, settings.bsp already exists"
else
    nios2-bsp-create-settings \
        --settings settings.bsp \
        --type hal \
        --bsp-dir bladeRF_nios_bsp \
        --cpu-name nios2 \
        --script $(readlink -f $QUARTUS_ROOTDIR/..)/nios2eds/sdk2/bin/bsp-set-defaults.tcl \
        --sopc nios_system.sopcinfo \
        --set hal.max_file_descriptors 4 \
        --set hal.enable_instruction_related_exceptions_api false \
        --set hal.make.bsp_cflags_optimization "-Os" \
        --set hal.enable_exit 0 \
        --set hal.enable_small_c_library 1 \
        --set hal.enable_clean_exit 0 \
        --set hal.enable_c_plus_plus 0 \
        --set hal.enable_reduced_device_drivers 1 \
        --set hal.enable_lightweight_device_driver_api 1
fi

pushd bladeRF_nios_bsp

# Fix warnings about a memory width mismatch between the Nios and the memory initialization file
sed -i.bak 's/\($(ELF2HEX).*--width=$(mem_hex_width)\)/\1 --record=$(shell expr ${mem_hex_width} \/ 8)/g' mem_init.mk

make
popd

pushd ${build_dir}/../software/bladeRF_nios/

# Encountered issues on Ubuntu 13.04 with the SDK's scripts not resolving
# paths properly. In the end, some items wind up being defined as .jar's that
# should be in our PATH at this point, so we set these up here...

#ELF2HEX=elf2hex.jar ELF2DAT=.jar make mem_init_generate
make WORKDIR=${work_dir} \
     mem_init_clean \
     mem_init_generate

popd

if [ "$rev" == "foxhunt" ]; then
    pushd ${build_dir}/../software/foxhunt/

    make WORKDIR=${work_dir} \
         mem_init_clean \
         mem_init_generate

    popd
fi

echo ""
echo "##########################################################################"
echo "    Building ${board} FPGA Image: $rev, $size kLE"
echo "##########################################################################"
echo ""

# Generate Quartus project
quartus_sh --64bit \
           -t        "${build_dir}/bladerf.tcl" \
           -projname "${PROJECT_NAME}" \
           -part     "${DEVICE}" \
           -platdir  "${build_dir}/.."

# Run Quartus flow
quartus_sh --64bit \
           -t        "../../build.tcl" \
           -projname "${PROJECT_NAME}" \
           -rev      "${rev}" \
           -flow     "${flow}" \
           -stp      "${stp}" \
           -force    "${force}" \
           -seed     "${seed}"

popd

if [[ ${flow} == "full" ]]; then
    BUILD_TIME_DONE="$(cat ${work_dir}/output_files/$rev.done)"
    BUILD_TIME_DONE=$(date -d"$BUILD_TIME_DONE" '+%F_%H.%M.%S')

    BUILD_NAME="$rev"x"$size"
    if [ "$omit_date" = false ]; then
        BUILD_OUTPUT_DIR="$BUILD_NAME"-"$BUILD_TIME_DONE"
    else
        BUILD_OUTPUT_DIR="$BUILD_NAME"
    fi
    RBF=$BUILD_NAME.rbf

    mkdir -p "$BUILD_OUTPUT_DIR"
    cp "${work_dir}/output_files/$rev.rbf" "$BUILD_OUTPUT_DIR/$RBF"

    for file in ${work_dir}/output_files/*rpt ${work_dir}/output_files/*summary; do
        new_file=$(basename $file | sed -e s/$rev/"$BUILD_NAME"/)
        cp $file "$BUILD_OUTPUT_DIR/$new_file"
    done

    pushd $BUILD_OUTPUT_DIR
    md5sum $RBF > $RBF.md5sum
    sha256sum $RBF > $RBF.sha256sum
    MD5SUM=$(cat $RBF.md5sum | awk '{ print $1 }')
    SHA256SUM=$(cat $RBF.sha256sum  | awk '{ print $1 }')

    GIT_HASH=$(git rev-parse --short HEAD)
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    GIT_DIRTY=$(git diff --quiet && echo "clean" || echo "dirty")

    cat << EOF > git_info.txt
Git Information:
Commit Hash: $GIT_HASH
Branch: $GIT_BRANCH
Working Directory: $GIT_DIRTY
EOF

    popd

    echo ""
    echo "##########################################################################"
    echo " Done! Image, reports, and checksums copied to:"
    echo "   $BUILD_OUTPUT_DIR"
    echo ""
    echo " $RBF checksums:"
    echo "  MD5:    $MD5SUM"
    echo "  SHA256: $SHA256SUM"
    echo ""
    echo " Git Information:"
    echo "  Commit: $GIT_HASH ($GIT_DIRTY)"
    echo "  Branch: $GIT_BRANCH"
    echo ""
    cat "$BUILD_OUTPUT_DIR/$BUILD_NAME.fit.summary" | sed -e 's/^\(.\)/ \1/g'
    echo "##########################################################################"
fi

echo ""
printf "%s %02d:%02d:%02d\n" "Total Build Time:" "$(($SECONDS / 3600))" "$((($SECONDS / 60) % 60))" "$(($SECONDS % 60))"
echo ""

# Delete empty SOPC directories in the user's home directory
#find ~ -maxdepth 1 -type d -empty -iname "sopc_altera_pll*" -delete
