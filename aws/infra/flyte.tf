# The Flyte layer on top of the base in main.tf: object storage, managed Postgres and workload identity. The
# Kubernetes objects and the flyte-binary release that use them are in ../helm/flyte.tf.

locals {
  # Suffixed name for globally unique or account-wide names (bucket, IAM roles, database).
  unique_name = "${var.name}-${random_id.suffix.hex}"

  # Kubernetes service accounts that reach AWS APIs: the chart's backend and the task pods' account. The helm root
  # creates them under exactly these names (service_accounts output), so the IRSA trust below cannot drift from them.
  service_accounts = {
    backend = { namespace = "flyte", name = "flyte-backend" }
    task    = { namespace = "flyte", name = "flyte-task" }
  }

  database_username = "flyte"
  database_name     = "flyte"
}

# Object storage: one bucket for run metadata, inputs, outputs and code bundles.
resource "aws_s3_bucket" "this" {
  bucket = local.unique_name
}

# Refuse plain-HTTP access to the bucket.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # The public access block and the policy are both bucket-level writes that S3 rejects when they race.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Managed Postgres in the private subnets, reachable only from the cluster nodes (pods use the node security group).
resource "aws_db_subnet_group" "this" {
  name       = local.unique_name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  description = "Flyte database: Postgres from the EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    # A security group in use cannot be deleted; create the replacement first when the name prefix changes.
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from the EKS nodes"
}

# The password lives in this root's state, in the helm root's state (it reads it from here) and in the Helm release;
# use encrypted remote backends (README).
resource "random_password" "database" {
  length  = 32
  special = false
}

resource "aws_db_instance" "this" {
  identifier = local.unique_name

  engine         = "postgres"
  engine_version = "17"
  instance_class = var.database.instance_class
  multi_az       = var.database.multi_az

  allocated_storage = var.database.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = local.database_name
  username = local.database_username
  password = random_password.database.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = var.database.deletion_protection
  skip_final_snapshot        = var.database.skip_final_snapshot
  # Only used (and required) when a final snapshot is taken.
  final_snapshot_identifier = var.database.skip_final_snapshot ? null : "${local.unique_name}-final"
}

# One IRSA role per Kubernetes service account, each trusting exactly that account.
data "aws_iam_policy_document" "trust" {
  # One document per service account so the subject condition names exactly that account.
  for_each = local.service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.name}"]
    }
  }
}

resource "aws_iam_role" "workload" {
  # Same shape for the backend and the task account, so one resource with two instances.
  for_each = local.service_accounts

  name               = "${local.unique_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
}

data "aws_iam_policy_document" "storage" {
  # The backend manages objects (including deleting them); task pods read and write but never delete.
  for_each = local.service_accounts

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "Objects"
    actions   = each.key == "backend" ? ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"] : ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
}

resource "aws_iam_role_policy" "storage" {
  # One policy per role, from the matching document above.
  for_each = local.service_accounts

  name   = "storage"
  role   = aws_iam_role.workload[each.key].id
  policy = data.aws_iam_policy_document.storage[each.key].json
}
