{ lib, ... }:
let
  c = import ../nix/cache.nix;
  tags = { "nbh:managed" = "true"; "nbh:purpose" = "binary-cache"; };
  ref = s: "\${${s}}";
  arn = "arn:aws:s3:::${c.bucket}";
  readStatements = [
    { Sid = "List"; Effect = "Allow"; Action = "s3:ListBucket"; Resource = arn; }
    { Sid = "Read"; Effect = "Allow"; Action = "s3:GetObject"; Resource = "${arn}/*"; }
  ];
  # The keys nbh-cache push writes. A wildcard spans "/", so roots/x.narinfo
  # would match and needs the explicit deny.
  cacheObjects = [ "${arn}/*.narinfo" "${arn}/nar/*" ];
  noRoots = {
    Sid = "NoRootsOrCacheInfo";
    Effect = "Deny";
    Action = "s3:PutObject";
    Resource = [ "${arn}/roots/*" "${arn}/nix-cache-info" ];
  };
  builderStatements = [
    { Sid = "List"; Effect = "Allow"; Action = "s3:ListBucket"; Resource = arn; }
    { Sid = "SkipExisting"; Effect = "Allow"; Action = "s3:GetObject"; Resource = cacheObjects; }
    { Sid = "Upload"; Effect = "Allow"; Action = [ "s3:PutObject" "s3:AbortMultipartUpload" ]; Resource = cacheObjects; }
    noRoots
  ];
  identities = {
    # One key shared by every host. Any host can rewrite any root.
    client = readStatements ++ [
      { Sid = "Roots"; Effect = "Allow"; Action = "s3:PutObject"; Resource = "${arn}/roots/*"; }
    ];
    # Signs on the box. Only rewrites narinfos; nars come from the builder role.
    signer = [
      { Sid = "List"; Effect = "Allow"; Action = "s3:ListBucket"; Resource = arn; }
      { Sid = "Read"; Effect = "Allow"; Action = "s3:GetObject"; Resource = cacheObjects; }
      { Sid = "Sign"; Effect = "Allow"; Action = "s3:PutObject"; Resource = "${arn}/*.narinfo"; }
      noRoots
    ];
    gc = readStatements ++ [
      {
        Sid = "Sweep";
        Effect = "Allow";
        Action = "s3:DeleteObject";
        Resource = [ "${arn}/*.narinfo" "${arn}/*.ls" "${arn}/nar/*" "${arn}/roots/*" ];
      }
    ];
  };
  user = id: "nbh-cache-${id}";
in
{
  variable.secrets_dir = {
    type = "string";
    default = "/home/box/secrets";
  };

  resource.aws_s3_bucket.cache = {
    bucket = c.bucket;
    tags = tags;
  };
  resource.aws_s3_bucket_public_access_block.cache = {
    bucket = ref "aws_s3_bucket.cache.id";
    block_public_acls = true;
    block_public_policy = true;
    ignore_public_acls = true;
    restrict_public_buckets = true;
  };
  resource.aws_s3_bucket_ownership_controls.cache = {
    bucket = ref "aws_s3_bucket.cache.id";
    rule.object_ownership = "BucketOwnerEnforced";
  };
  resource.aws_s3_bucket_server_side_encryption_configuration.cache = {
    bucket = ref "aws_s3_bucket.cache.id";
    rule = [{ apply_server_side_encryption_by_default.sse_algorithm = "AES256"; }];
  };
  resource.aws_s3_bucket_policy.cache = {
    bucket = ref "aws_s3_bucket.cache.id";
    policy = builtins.toJSON {
      Version = "2012-10-17";
      Statement = [{
        Sid = "TlsOnly";
        Effect = "Deny";
        Principal = "*";
        Action = "s3:*";
        Resource = [ arn "${arn}/*" ];
        Condition.Bool."aws:SecureTransport" = "false";
      }];
    };
    depends_on = [ "aws_s3_bucket_public_access_block.cache" ];
  };
  resource.aws_s3_object.cache_info = {
    bucket = ref "aws_s3_bucket.cache.id";
    key = "nix-cache-info";
    content = "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: ${toString c.priority}\n";
    content_type = "text/x-nix-cache-info";
    tags = tags;
  };

  resource.aws_iam_user = lib.mapAttrs (id: _: { name = user id; tags = tags; }) identities;
  resource.aws_iam_user_policy = lib.mapAttrs (id: statements: {
    name = "${user id}-s3";
    user = ref "aws_iam_user.${id}.name";
    policy = builtins.toJSON { Version = "2012-10-17"; Statement = statements; };
  }) identities;
  resource.aws_iam_access_key = lib.mapAttrs (id: _: { user = ref "aws_iam_user.${id}.name"; }) identities;
  resource.local_sensitive_file = lib.mapAttrs' (id: _: lib.nameValuePair "cache_${id}" {
    filename = "${ref "var.secrets_dir"}/${user id}.credentials";
    file_permission = "0600";
    directory_permission = "0700";
    content = ''
      [${user id}]
      aws_access_key_id = ${ref "aws_iam_access_key.${id}.id"}
      aws_secret_access_key = ${ref "aws_iam_access_key.${id}.secret"}
      region = ${c.region}
    '';
  }) identities;

  resource.aws_iam_role.builder = {
    name = "nbh-builder";
    assume_role_policy = builtins.toJSON {
      Version = "2012-10-17";
      Statement = [{
        Effect = "Allow";
        Principal.Service = "ec2.amazonaws.com";
        Action = "sts:AssumeRole";
        Condition.StringEquals."aws:SourceAccount" = c.account;
      }];
    };
    tags = tags;
  };
  resource.aws_iam_role_policy.builder = {
    name = "nbh-builder-cache-push";
    role = ref "aws_iam_role.builder.id";
    policy = builtins.toJSON { Version = "2012-10-17"; Statement = builderStatements; };
  };
  resource.aws_iam_instance_profile.builder = {
    name = "nbh-builder";
    role = ref "aws_iam_role.builder.name";
    tags = tags;
  };

  output.cache_bucket_arn.value = ref "aws_s3_bucket.cache.arn";
  output.cache_user_arns.value = lib.mapAttrs (id: _: ref "aws_iam_user.${id}.arn") identities;
  output.builder_role_arn.value = ref "aws_iam_role.builder.arn";
  output.builder_instance_profile_arn.value = ref "aws_iam_instance_profile.builder.arn";
}
