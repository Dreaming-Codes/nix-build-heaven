{
  account = "845087560967";
  region = "eu-north-1";
  bucket = "nbh-cache-845087560967";
  publicKey = "nbh-cache-845087560967-1:ncBMB14sruhdtGhlkrHt3tLw8xGBwq33QiQUM/760Rc=";
  hosts = [ "DreamingDesk" "DreamingBlade" ];
  graceDays = 14;
  priority = 50;
  upstream = [
    "https://install.determinate.systems"
    "https://cache.nixos.org"
  ];
  upstreamKeys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    "cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio="
  ];
}
