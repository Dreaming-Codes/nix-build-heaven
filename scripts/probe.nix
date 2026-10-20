# The nonce keeps it out of every cache. /bin/sh is the sandbox's busybox ash.
{ nonce }:
derivation {
  name = "nbh-probe-${nonce}";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "read h < /proc/sys/kernel/hostname; echo \"built on $h nonce=${nonce}\" > $out" ];
}
