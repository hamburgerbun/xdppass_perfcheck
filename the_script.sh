#!/bin/bash
set -x 
CWD=`pwd`

# the trivial program we are testing with
read -r -d '' PROGRAM_OUTPUT <<- EOF
#include <linux/bpf.h>
#include "bpf_helpers.h"
SEC("xdp_pass")
// trivial program to pass traffic. xdp for some reason needs a prog on the other side of the veth tunnels to do what we want. 
int xdp_pass_func(struct xdp_md *ctx) {
    return XDP_PASS;
}
char _license[] SEC("license") = "GPL";
EOF


# this was tested on an ubuntu 19.10 box. 

NETNS1=nsone
NETNS2=nstwo
NS1IP=169.254.1.1
NS2IP=169.254.1.2
NS1NET=${NS1IP}/30
NS2NET=${NS2IP}/30
IPERF3_PORT=8000
BRNAME=cbr0
NS1_INSIDE_VETH=ns1veth1
NS1_ROOT_VETH=ns1veth2
NS2_INSIDE_VETH=ns2veth1
NS2_ROOT_VETH=ns2veth2
XDP_C_FILE=/tmp/xdp_kern.c
XDP_O_FILE=/tmp/xdp_kern.o
XDP_LL_FILE=/tmp/xdp_kern.ll
XDP_SECT="xdp_pass"
LIBBPF=/tmp/libbpf

teardown () {
    ip link del $NS1_ROOT_VETH
    ip link del $NS2_ROOT_VETH
    ip link del $BRNAME
    ip netns delete $NETNS1
    ip netns delete $NETNS2
    for x in `ps -ef | grep iperf3 | grep $IPERF3_PORT | grep -v grep | awk $'{print $2}'`; do 
        kill $x
    done
}

if [ $1 = "teardown" ]; then
    echo "only executing teardown"
    teardown
    exit
fi

set -e 
apt update
apt install -y vim iperf3 make gcc pkg-config clang llvm libelf-dev libelf1 git

if [ ! -d $LIBBPF ]; then
    git clone https://github.com/libbpf/libbpf.git $LIBBPF
fi
cd $LIBBPF/src
make

echo "$PROGRAM_OUTPUT" >$XDP_C_FILE
clang -S -target bpf -D __BPF_TRACING__ -I. -I${LIBBPF}/src -I/usr/include/x86_64-linux-gnu -I${LIBBPF}/include/uapi \
	-Wall -Wno-unused-value -Wno-pointer-sign -Wno-compare-distinct-pointer-types -Werror -O3 -emit-llvm -c -o $XDP_LL_FILE $XDP_C_FILE
llc -O3 -march=bpf -filetype=obj -o $XDP_O_FILE $XDP_LL_FILE

# set two network namespaces
ip netns add $NETNS1
ip netns add $NETNS2

# add the bridge to connect them
ip link add name $BRNAME type bridge
ip link set $BRNAME up

# do veth pair for ns one
ip link add name $NS1_INSIDE_VETH type veth peer name $NS1_ROOT_VETH 
ip link set $NS1_INSIDE_VETH netns $NETNS1
ip link set $NS1_ROOT_VETH up
ip link set $NS1_ROOT_VETH master $BRNAME
ip netns exec $NETNS1 bash -c "ip link set $NS1_INSIDE_VETH up"
ip netns exec $NETNS1 bash -c "ip addr add $NS1NET dev $NS1_INSIDE_VETH"

# do veth pair for ns two
ip link add name $NS2_INSIDE_VETH type veth peer name $NS2_ROOT_VETH 
ip link set $NS2_INSIDE_VETH netns $NETNS2
ip link set $NS2_ROOT_VETH up
ip link set $NS2_ROOT_VETH master $BRNAME
ip netns exec $NETNS2 bash -c "ip link set $NS2_INSIDE_VETH up"
ip netns exec $NETNS2 bash -c "ip addr add $NS2NET dev $NS2_INSIDE_VETH"

# start the server
ip netns exec $NETNS2 iperf3 -s -p $IPERF3_PORT &
sleep 1

# test with no xdp
echo "testing with no xdp"
ip netns exec $NETNS1 iperf3 -c $NS2IP -p $IPERF3_PORT

ip link set $NS1_ROOT_VETH xdp object $XDP_O_FILE section $XDP_SECT
ip link set $NS2_ROOT_VETH xdp object $XDP_O_FILE section $XDP_SECT
echo "testing with xdp in veths, root ns side"
ip netns exec $NETNS1 iperf3 -c $NS2IP -p $IPERF3_PORT

ip netns exec $NETNS1 bash -c "ip link set $NS1_INSIDE_VETH xdp object $XDP_O_FILE section $XDP_SECT"
ip netns exec $NETNS2 bash -c "ip link set $NS2_INSIDE_VETH xdp object $XDP_O_FILE section $XDP_SECT"
echo "testing with xdp in veths, both root ns and netns side"
ip netns exec $NETNS1 iperf3 -c $NS2IP -p $IPERF3_PORT

echo "tearing down"
teardown 
exit
