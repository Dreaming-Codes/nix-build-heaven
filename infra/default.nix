# OpenTofu config for Nix Build Heaven, written with terranix. Two layers:
#
#   guards   the account-wide budget alert and CloudTrail audit log
#   builder  network tags, security group, launch template, runtime IAM user,
#            image import bucket and vmimport role, and the builder AMI
#
# The AMI and launch template exist only once `snapshot_id` is set, so the
# first apply can run before an image is uploaded. State stays local, outside
# git (scripts/tofu.sh keeps it under /home/box/secrets/nbh-tofu, mode 0700).
{ lib, ... }:
let
  account = "845087560967";
  region = "eu-north-1";
  alertEmail = "lore.rizzotti@gmail.com";
  tags = { "nbh:managed" = "true"; };
  ref = s: "\${${s}}";
  haveImage = ''var.snapshot_id != "" ? 1 : 0'';

  # Section 12 of DESIGN.md, verbatim except the account id and the snapshot
  # statement Phase 4 adds once a real RunInstances call tells us it is needed.
  gatePolicy = {
    Version = "2012-10-17";
    Statement = [
      {
        Sid = "Describe";
        Effect = "Allow";
        Action = [
          "ec2:DescribeInstances"
          "ec2:DescribeInstanceTypes"
          "ec2:DescribeLaunchTemplates"
          "ec2:DescribeLaunchTemplateVersions"
          "ec2:DescribeSpotPriceHistory"
          "ec2:DescribeFleets"
          "ec2:DescribeImages"
          "ec2:DescribeSubnets"
        ];
        Resource = "*";
        Condition.StringEquals."aws:RequestedRegion" = [ "eu-north-1" "eu-central-1" ];
      }
      {
        Sid = "LaunchTaggedInstancesOfAllowedTypes";
        Effect = "Allow";
        Action = [ "ec2:RunInstances" "ec2:CreateFleet" ];
        Resource = "arn:aws:ec2:*:${account}:instance/*";
        Condition = {
          StringEquals = {
            "aws:RequestTag/nbh:managed" = "true";
            "aws:RequestedRegion" = [ "eu-north-1" "eu-central-1" ];
          };
          StringLike."ec2:InstanceType" = [ "c7a.*" "c7i.*" "c6a.*" "c6i.*" "m7a.*" "m7i.*" "c6id.*" "c7gd.*" "c7g.*" "c8g.*" ];
        };
      }
      {
        Sid = "LaunchTaggedVolumesAndFleets";
        Effect = "Allow";
        Action = [ "ec2:RunInstances" "ec2:CreateFleet" ];
        Resource = [
          "arn:aws:ec2:*:${account}:volume/*"
          "arn:aws:ec2:*:${account}:network-interface/*"
          "arn:aws:ec2:*:${account}:fleet/*"
          "arn:aws:ec2:*:${account}:spot-instances-request/*"
        ];
        Condition.StringEquals."aws:RequestTag/nbh:managed" = "true";
      }
      {
        Sid = "LaunchFromOwnTemplateAndImage";
        Effect = "Allow";
        Action = [ "ec2:RunInstances" "ec2:CreateFleet" ];
        Resource = [
          "arn:aws:ec2:*:${account}:launch-template/*"
          "arn:aws:ec2:*::image/*"
          "arn:aws:ec2:*:${account}:subnet/*"
          "arn:aws:ec2:*:${account}:security-group/*"
        ];
        Condition.StringEquals."aws:ResourceTag/nbh:managed" = "true";
      }
      {
        Sid = "TagOnlyAtLaunch";
        Effect = "Allow";
        Action = "ec2:CreateTags";
        Resource = "*";
        Condition.StringEquals."ec2:CreateAction" = [ "RunInstances" "CreateFleet" ];
      }
      {
        Sid = "TerminateOnlyOwn";
        Effect = "Allow";
        Action = "ec2:TerminateInstances";
        Resource = "arn:aws:ec2:*:${account}:instance/*";
        Condition.StringEquals."aws:ResourceTag/nbh:managed" = "true";
      }
    ];
  };
in
{
  terraform.required_providers = {
    aws = { source = "hashicorp/aws"; version = "~> 6.0"; };
    local = { source = "hashicorp/local"; version = "~> 2.5"; };
  };
  provider.aws = {
    inherit region;
    allowed_account_ids = [ account ];
  };

  variable.snapshot_id = {
    type = "string";
    # Uploaded 2026-10-20 by scripts/upload-ami.sh from packages.ami (0mz4016f).
    default = "snap-094d64b10df04f71e";
    description = "EBS snapshot of the builder raw image, from scripts/upload-ami.sh";
  };
  variable.image_name = {
    type = "string";
    default = "nbh-builder-26.11.20261012.6aa7ad7-0mz4016f";
  };
  variable.gate_credentials_file = {
    type = "string";
    default = "/home/box/secrets/nbh-gate.credentials";
  };

  # ---------------------------------------------------------------- guards
  resource.aws_budgets_budget.monthly = {
    name = "nbh-monthly-20usd";
    budget_type = "COST";
    limit_amount = "20";
    limit_unit = "USD";
    time_unit = "MONTHLY";
    notification = map (t: {
      comparison_operator = "GREATER_THAN";
      threshold = t;
      threshold_type = "PERCENTAGE";
      notification_type = "ACTUAL";
      subscriber_email_addresses = [ alertEmail ];
    }) [ 50 80 100 ];
  };

  resource.aws_s3_bucket.trail = {
    bucket = "nbh-cloudtrail-${account}";
    force_destroy = true;
    inherit tags;
  };
  resource.aws_s3_bucket_public_access_block.trail = {
    bucket = ref "aws_s3_bucket.trail.id";
    block_public_acls = true;
    block_public_policy = true;
    ignore_public_acls = true;
    restrict_public_buckets = true;
  };
  resource.aws_s3_bucket_lifecycle_configuration.trail = {
    bucket = ref "aws_s3_bucket.trail.id";
    rule = [{
      id = "expire-90d";
      status = "Enabled";
      filter = { };
      expiration.days = 90;
      noncurrent_version_expiration.noncurrent_days = 1;
    }];
  };
  resource.aws_s3_bucket_policy.trail = {
    bucket = ref "aws_s3_bucket.trail.id";
    policy = builtins.toJSON {
      Version = "2012-10-17";
      Statement = [
        {
          Sid = "AclCheck";
          Effect = "Allow";
          Principal.Service = "cloudtrail.amazonaws.com";
          Action = "s3:GetBucketAcl";
          Resource = "arn:aws:s3:::nbh-cloudtrail-${account}";
          Condition.StringEquals."aws:SourceArn" = "arn:aws:cloudtrail:${region}:${account}:trail/account-audit";
        }
        {
          Sid = "Write";
          Effect = "Allow";
          Principal.Service = "cloudtrail.amazonaws.com";
          Action = "s3:PutObject";
          Resource = "arn:aws:s3:::nbh-cloudtrail-${account}/AWSLogs/${account}/*";
          Condition.StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control";
            "aws:SourceArn" = "arn:aws:cloudtrail:${region}:${account}:trail/account-audit";
          };
        }
      ];
    };
  };
  resource.aws_cloudtrail.audit = {
    name = "account-audit";
    s3_bucket_name = ref "aws_s3_bucket.trail.id";
    is_multi_region_trail = true;
    include_global_service_events = true;
    enable_log_file_validation = true;
    inherit tags;
    depends_on = [ "aws_s3_bucket_policy.trail" ];
  };

  # ---------------------------------------------------------------- network
  data.aws_vpc.default.default = true;
  data.aws_subnets.default.filter = [
    { name = "vpc-id"; values = [ (ref "data.aws_vpc.default.id") ]; }
    { name = "default-for-az"; values = [ "true" ]; }
  ];
  # The gate may only launch into subnets carrying the tag (section 12).
  resource.aws_ec2_tag.subnet_managed = {
    for_each = ref "toset(data.aws_subnets.default.ids)";
    resource_id = ref "each.value";
    key = "nbh:managed";
    value = "true";
  };

  resource.aws_security_group.builder = {
    name = "nbh-builder";
    description = "nix-grpc-daemon behind mTLS";
    vpc_id = ref "data.aws_vpc.default.id";
    inherit tags;
  };
  resource.aws_vpc_security_group_ingress_rule.grpc4 = {
    security_group_id = ref "aws_security_group.builder.id";
    ip_protocol = "tcp";
    from_port = 50051;
    to_port = 50051;
    cidr_ipv4 = "0.0.0.0/0";
    description = "nix-grpc-daemon with mTLS from the gate CA";
  };
  resource.aws_vpc_security_group_egress_rule.all4 = {
    security_group_id = ref "aws_security_group.builder.id";
    ip_protocol = "-1";
    cidr_ipv4 = "0.0.0.0/0";
  };

  # ---------------------------------------------------------------- image
  resource.aws_s3_bucket.images = {
    bucket = "nbh-images-${account}";
    force_destroy = true;
    inherit tags;
  };
  resource.aws_s3_bucket_public_access_block.images = {
    bucket = ref "aws_s3_bucket.images.id";
    block_public_acls = true;
    block_public_policy = true;
    ignore_public_acls = true;
    restrict_public_buckets = true;
  };
  resource.aws_s3_bucket_lifecycle_configuration.images = {
    bucket = ref "aws_s3_bucket.images.id";
    rule = [{
      id = "expire-7d";
      status = "Enabled";
      filter = { };
      expiration.days = 7;
    }];
  };
  resource.aws_iam_role.vmimport = {
    name = "vmimport";
    assume_role_policy = builtins.toJSON {
      Version = "2012-10-17";
      Statement = [{
        Effect = "Allow";
        Principal.Service = "vmie.amazonaws.com";
        Action = "sts:AssumeRole";
        Condition.StringEquals."sts:Externalid" = "vmimport";
      }];
    };
    inherit tags;
  };
  resource.aws_iam_role_policy.vmimport = {
    name = "vmimport";
    role = ref "aws_iam_role.vmimport.id";
    policy = builtins.toJSON {
      Version = "2012-10-17";
      Statement = [
        {
          Effect = "Allow";
          Action = [ "s3:GetBucketLocation" "s3:GetObject" "s3:ListBucket" ];
          Resource = [ "arn:aws:s3:::nbh-images-${account}" "arn:aws:s3:::nbh-images-${account}/*" ];
        }
        {
          Effect = "Allow";
          Action = [ "ec2:ModifySnapshotAttribute" "ec2:CopySnapshot" "ec2:RegisterImage" "ec2:Describe*" ];
          Resource = "*";
        }
      ];
    };
  };

  resource.aws_ami.builder = {
    count = ref haveImage;
    name = ref "var.image_name";
    virtualization_type = "hvm";
    architecture = "x86_64";
    ena_support = true;
    boot_mode = "legacy-bios";
    imds_support = "v2.0";
    root_device_name = "/dev/xvda";
    ebs_block_device = [{
      device_name = "/dev/xvda";
      snapshot_id = ref "var.snapshot_id";
      volume_type = "gp3";
      delete_on_termination = true;
    }];
    tags = tags // { Name = ref "var.image_name"; };
  };

  resource.aws_launch_template.builder = {
    count = ref haveImage;
    name = "nbh-builder";
    image_id = ref "aws_ami.builder[0].id";
    instance_initiated_shutdown_behavior = "terminate";
    update_default_version = true;
    metadata_options = {
      http_endpoint = "enabled";
      http_tokens = "required";
      http_put_response_hop_limit = 1;
    };
    block_device_mappings = [{
      device_name = "/dev/xvda";
      ebs = {
        volume_size = 100;
        volume_type = "gp3";
        iops = 3000;
        throughput = 250;
        delete_on_termination = true;
      };
    }];
    # Default subnets map a public IPv4 on launch, so the gate can pass a
    # plain SubnetId per attempt.
    vpc_security_group_ids = [ (ref "aws_security_group.builder.id") ];
    inherit tags;
  };

  # ---------------------------------------------------------------- runtime user
  resource.aws_iam_service_linked_role.spot = {
    aws_service_name = "spot.amazonaws.com";
  };
  resource.aws_iam_user.gate = {
    name = "nbh-gate";
    inherit tags;
  };
  resource.aws_iam_user_policy.gate = {
    name = "nbh-gate-runtime";
    user = ref "aws_iam_user.gate.name";
    policy = builtins.toJSON gatePolicy;
  };
  resource.aws_iam_access_key.gate.user = ref "aws_iam_user.gate.name";
  resource.local_sensitive_file.gate_credentials = {
    filename = ref "var.gate_credentials_file";
    file_permission = "0600";
    directory_permission = "0700";
    content = ''
      [nbh-gate]
      aws_access_key_id = ${ref "aws_iam_access_key.gate.id"}
      aws_secret_access_key = ${ref "aws_iam_access_key.gate.secret"}
      region = ${region}
    '';
  };

  output.security_group_id.value = ref "aws_security_group.builder.id";
  output.launch_template_id.value = ref ''length(aws_launch_template.builder) > 0 ? aws_launch_template.builder[0].id : ""'';
  output.ami_id.value = ref ''length(aws_ami.builder) > 0 ? aws_ami.builder[0].id : ""'';
  output.gate_user_arn.value = ref "aws_iam_user.gate.arn";
  output.gate_access_key_id.value = ref "aws_iam_access_key.gate.id";
  output.trail_arn.value = ref "aws_cloudtrail.audit.arn";
  output.subnet_ids.value = ref "data.aws_subnets.default.ids";
}
