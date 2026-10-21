{ nonce }:
{
  proof = derivation {
    name = "nbh-proof-role-${nonce}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo ${nonce} > $out" ];
  };
  # Fixed-output, so it shares the builder's network. Prints only the IMDS status line.
  imds = derivation {
    name = "nbh-imds-probe-${nonce}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" ''
      if exec 3<>/dev/tcp/169.254.169.254/80; then
        printf 'PUT /latest/api/token HTTP/1.0\r\nX-aws-ec2-metadata-token-ttl-seconds: 60\r\n\r\n' >&3
        read -r line <&3; echo "imds from a build: ''${line%$'\r'}" >&2
      else
        echo "imds from build user: unreachable" >&2
      fi
      echo done > $out
    '' ];
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "d117fa006ba9208500b2930ce69cbde436c647afa917cb7396a9bc9111a46dd2";
  };
}
