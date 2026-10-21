{
  lib,
  python3,
  runCommand,
  makeWrapper,
}:
let
  py = python3.withPackages (ps: [ ps.boto3 ps.zstandard ps.cryptography ]);
in
runCommand "nbh-cache"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "nbh-cache";
  }
  ''
    install -Dm755 ${../cache/nbh-cache.py} $out/libexec/nbh-cache.py
    makeWrapper ${py}/bin/python3 $out/bin/nbh-cache --add-flags $out/libexec/nbh-cache.py
    ${py}/bin/python3 -m unittest discover -s ${../cache} -p 'test_*.py' 2>&1
  ''
