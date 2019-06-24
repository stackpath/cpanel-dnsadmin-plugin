#!/usr/bin/env bash

# StackPath dnsadmin uninstaller
#
# Remove the plugin's Perl modules from a cPanel installation.

CPANEL_ROOT="/usr/local/cpanel"
REMOTE_MODULE="Cpanel/NameServer/Remote/StackPath.pm"
SETUP_MODULE="Cpanel/NameServer/Setup/Remote/StackPath.pm"
PROJECT_URL="https://github.com/stackpath/cpanel-dnsadmin-plugin"

# Remove a directory with pretty output
remove_directory() {
    echo -n "${1}... "
    if [[ ! -d ${1} ]]; then
        echo "SKIPPED: not present"
    elif RESULT=$(rm -rf ${1} 2>&1); then
        echo "OK"
    else
        echo "FAILED"
        echo ${RESULT}
        echo
        echo "Unable to remove ${1}."
        echo "Please contact your systems administrator and try again."
        echo

        exit 1
    fi
}

# Remove a file with pretty output
remove_file() {
    echo -n "${1}... "
    if [[ ! -f ${1} ]]; then
        echo "SKIPPED: not present"
    elif RESULT=$(rm ${1} 2>&1); then
        echo "OK"
    else
        echo "FAILED"
        echo ${RESULT}
        echo
        echo "Unable to remove ${1}."
        echo "Please contact your systems administrator and try again."
        echo

        exit 1
    fi
}

echo "Welcome to the StackPath dnsadmin plugin uninstaller"
echo "----------"
echo
echo "Removing directories"
remove_directory "${CPANEL_ROOT}/Cpanel/NameServer/Remote/StackPath"

echo
echo "Removing files"
remove_file "${CPANEL_ROOT}/${REMOTE_MODULE}"
remove_file "${CPANEL_ROOT}/${SETUP_MODULE}"

# All done!
echo
echo "----------"
echo "The StackPath dnsadmin plugin has been uninstalled."
echo "Please download the plugin and run install.sh to reinstall it."
echo
echo ${PROJECT_URL}
echo "https://stackpath.com/"
echo
