#!/usr/bin/env bash

# StackPath dnsadmin installer
#
# Make sure cPanel is installed then copy the plugin's Perl modules into place
# in the cPanel installation.

CPANEL_ROOT="/usr/local/cpanel"
LOCAL_ROOT=$(pwd)
REMOTE_MODULE="Cpanel/NameServer/Remote/StackPath.pm"
SETUP_MODULE="Cpanel/NameServer/Setup/Remote/StackPath.pm"
API_MODULE="Cpanel/NameServer/Remote/StackPath/API.pm"
PROJECT_URL="https://github.com/stackpath/cpanel-dnsadmin-plugin"

# Create a directory with pretty output
make_directory() {
    echo -n "${1}... "
    if RESULT=$(mkdir -p ${1} 2>&1); then
        echo "OK"
    else
        echo "FAILED"
        echo ${RESULT}
        echo
        echo "Unable to create ${1}."
        echo "Please contact your systems administrator and try again."
        echo

        exit 1
    fi
}

# Copy a file with pretty output
copy_file() {
    echo -n "${2}... "
    if RESULT=$(cp ${1} ${2} 2>&1); then
        echo "OK"
    else
        echo "FAILED"
        echo ${RESULT}
        echo
        echo "Unable to copy ${2}."
        echo "Please contact your systems administrator and try again."
        echo

        exit 1
    fi
}

echo "Welcome to the StackPath dnsadmin plugin installer"
echo "----------"
echo

# Assume that cPanel is installed if /usr/local/cpanel exists
echo -n "Looking for cPanel... "
if [[ -d ${CPANEL_ROOT} ]]; then
    echo "OK"
else
    echo "FAILED"
    echo
    echo "Unable to locate a cPanel installation at ${CPANEL_ROOT}."
    echo "Please verify cPanel is installed and try again."
    echo

    exit 1
fi

echo -n "Validating write access... "
if [[ -w ${CPANEL_ROOT} ]]; then
    echo "OK"
else
    echo "FAILED"
    echo
    echo "The cPanel installation at ${CPANEL_ROOT} is not writable."
    echo "Please run this script as root and try again."
    echo

    exit 1
fi

# Make sure files exist before copying them into place
echo -n "Validating local files... "
if [[ -f "${LOCAL_ROOT}/lib/${REMOTE_MODULE}" ]] && [[ -f "${LOCAL_ROOT}/lib/${SETUP_MODULE}" ]] && [[ -f "${LOCAL_ROOT}/lib/${API_MODULE}" ]]; then
    echo "OK"
else
    echo "FAILED"
    echo
    echo "Local files are missing."
    echo "Please re-download the plugin from"
    echo "${PROJECT_URL} and try again."
    echo

    exit 1
fi

# Make necessary directories
echo
echo "Making directories"
make_directory "${CPANEL_ROOT}/Cpanel/NameServer/Remote/StackPath"

# Copy files into place
echo
echo "Copying files"
copy_file "${LOCAL_ROOT}/lib/${REMOTE_MODULE}" "${CPANEL_ROOT}/${REMOTE_MODULE}"
copy_file "${LOCAL_ROOT}/lib/${SETUP_MODULE}" "${CPANEL_ROOT}/${SETUP_MODULE}"
copy_file "${LOCAL_ROOT}/lib/${API_MODULE}" "${CPANEL_ROOT}/${API_MODULE}"

# All done!
echo
echo "----------"
echo "The StackPath dnsadmin plugin has been installed."
echo "Log into WHM and visit the DNS Clustering page to configure it. Enjoy!"
echo
echo ${PROJECT_URL}
echo "https://stackpath.com/"
echo
