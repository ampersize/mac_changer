#!/bin/bash

PATH=/bin:/sbin:/usr/bin:/usr/sbin
PATH=$PATH:/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources
KILL=""
RE="[[:xdigit:]]{2}"
MACRE="$RE:$RE:$RE:$RE:$RE:$RE"
DEBUG=0
IF=en0
RUNME=sudo
LOCAL_MAC=""

if [ $EUID -ne 0 ] ;then
    sudo $0 $@
    exit
fi

set -e

usage() {
 BIN=`basename $0`
 printf "Usage: %s [-h] [-?] [-l] [-d] [-r] [-i <interface>] [-m <mac address>]\n" `basename $0`
 printf " -i [interface] defaults to %s\n" ${IF}
 printf " -m [mac address as XX:XX:XX:XX:XX:XX] defaults to a random value withe the vendor bits preserved\n" 
 printf " -d for debug\n"
 printf " -l for random local adminstered mac http://en.wikipedia.org/wiki/MAC_address\n"
 printf " -h|-? help \n"
 exit 0
}

# check arguments
while getopts "dhlm:ni:?" options; do
  case $options in
      i ) IF=$OPTARG;;
      m ) NEWMAC=$OPTARG;;
      d ) DEBUG=1;;
      l ) LOCAL_MAC=1;;
      h|\? ) usage;;
  esac
done 

OLDMAC=$(ifconfig ${IF} | grep ether | awk '{print $2}' )
VENDOR=$(echo $OLDMAC | cut -d : -f1,2,3)
RANDSERIAL=$(openssl rand -hex 1):$(openssl rand -hex 1):$(openssl rand -hex 1)
test "${LOCAL_MAC}" && VENDOR=06:$(openssl rand -hex 1):$(openssl rand -hex 1)
test -z "${NEWMAC}" && NEWMAC=${VENDOR}:${RANDSERIAL}
echo "X${NEWMAC}" | egrep "^X$MACRE$" > /dev/null || ( echo ${NEWMAC} not in valid Format && exit 102 )

GREP_OUT=/dev/null
test ${DEBUG} -ge 1 && GREP_OUT=/dev/stdout

function _try_newether() {
    # setting new mac address may take some time ... keep trying
    local IF=$1    
    local MAC=$2    
    local SLEEP=$3
    local COUNT=$4
    local DEBUG=$5    

    local GREP_OUT=/dev/null
    test ${DEBUG} -ge 1 && GREP_OUT=/dev/stdout

    test ${DEBUG} -ge 1 && echo $(date) seting ${IF} to ether ${MAC}

    ## Recursion limit
    COUNT=$(( $COUNT - 1 ))
    test ${COUNT} -le 1 && echo "_try_newether timed out" && exit 100

    ifconfig ${IF} ether ${MAC}
    ## Test new lladdr has been set or retry
    if (ifconfig ${IF} | grep "^[[:space:]]\+ether[[:space:]]\+${MAC}" > ${GREP_OUT}); then
        echo new lladdr set to ${MAC}
    else
        sleep ${SLEEP}
        _try_newether ${IF} ${MAC} ${SLEEP} ${COUNT} ${DEBUG}
    fi
    true
}

function _try_noaddr() {
    # wait until all aliase have ben removed  ... keep trying
    local IF=$1    
    local SLEEP=$2
    local COUNT=$3
    local DEBUG=$4    

    local GREP_OUT=/dev/null
    test ${DEBUG} -ge 1 && GREP_OUT=/dev/stdout

    test ${DEBUG} -ge 1 && echo $(date) waiting for address removal

    ## Recursion limit
    COUNT=$(( $COUNT - 1 ))
    test ${COUNT} -le 1 && echo "_try_noaddr timed out" && exit 101

    # test
    if (ifconfig ${IF} | grep "^[[:space:]]\+inet" > ${GREP_OUT}); then
        sleep ${SLEEP}
        _try_noaddr ${IF} ${SLEEP} ${COUNT} ${DEBUG}
    fi
    true
}    


if ifconfig -m ${IF} | grep "mediaopt full-duplex" >/dev/null ; then
    ## Ethernet interface
    true
elif airport ${IF}  prefs RequireAdminPowerToggle 2>/dev/null | grep "^RequireAdminPowerToggle=" >/dev/null ; then
    # airport interface needs to be powerd on and not associated
    networksetup -getairportpower ${IF} | grep On > ${GREP_OUT} || ( echo "${IF} is Powered off, not chnaging mac address" && exit 0 )
    ifconfig ${IF} up
    sleep 0.25
    test ${DEBUG} -ge 1 && echo && echo  ifconfig ${IF} up &&  ifconfig ${IF} 

    airport -z ${IF} || true
    test ${DEBUG} -ge 1 && echo && echo  airport -z
    # Wait to disassociate
    _try_noaddr ${IF} 0.3 100 ${DEBUG}
    test ${DEBUG} -ge 1 &&  ifconfig ${IF} 
else
    echo not airport and not ethernet
    exit 1
fi

# interface needs to be up
echo Old lladdr $OLDMAC

# Set the new mac adress
_try_newether ${IF} $NEWMAC 0.7 100 ${DEBUG}

# down/up to reassociate
ifconfig ${IF} down
sleep 0.25
ifconfig ${IF} up
test ${DEBUG} -ge 1 &&  ifconfig ${IF}
