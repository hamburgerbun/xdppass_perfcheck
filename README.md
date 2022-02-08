# xdppass_perfcheck
a script that tests the effects of a trivial XDP_PASS program on veths

## overview
script for ubuntu that basically
1. installs packages required for ebpf stuff
2. initialize some network namespaces
3. set xdp ebpf on veths involved
4. start iperf server and client
5. watch it not do well. 

## why does this exist?
the gist was that it was not clear at the time why XDP was affecting 
communication bandwidth in virtual machines so heavily when it was 
vaunted to be one of the fastest eBPF network low-level hooks to use. 
In the end, the response we got from this was that 
1. XDP generic (as opposed to XDP hardware) is not great
2. XDP foregoes speedups like TCP segmentation and concatenation so
   bandwidth falls apart if XDP is just thrown in the mix for no 
   reason. There's a reason its first real application was for dropping
   potential DDoSers and not handling the bulk of communications. 
