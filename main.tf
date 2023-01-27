# Terraform configuration
locals {
  port                 = var.port == "" ? var.engine == "aurora-postgresql" ? "5432" : "3306" : var.port
  db_subnet_group_name = var.db_subnet_group_name == "" ? join("", aws_db_subnet_group.this.*.name) : var.db_subnet_group_name
  backtrack_window     = (var.engine == "aurora-mysql" || var.engine == "aurora") && var.engine_mode != "serverless" ? var.backtrack_window : 0

  rds_enhanced_monitoring_arn  = var.create_monitoring_role ? join("", aws_iam_role.rds_enhanced_monitoring.*.arn) : var.monitoring_role_arn
  rds_enhanced_monitoring_name = join("", aws_iam_role.rds_enhanced_monitoring.*.name)

  parameter_description = coalesce(var.parameter_description, "Database parameter group for ${var.identifier}")
  parameter_cluster_description = coalesce(var.parameter_cluster_description, "Database parameter cluster group for ${var.global_cluster_identifier}")
}

data "aws_secretsmanager_secret" "this" {
  name = var.aws_secretsmanager_rds_secret_arn
}

data "aws_secretsmanager_secret_version" "this" {
  secret_id = data.aws_secretsmanager_secret.this.id
}

resource "aws_db_subnet_group" "this" {
  count = var.create_cluster && var.db_subnet_group_name == "" ? 1 : 0

  name_prefix = "${var.identifier}-"
  description = "For Aurora cluster ${var.identifier}"
  subnet_ids  = var.subnet_ids

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )
}

resource "aws_rds_cluster" "this" {
  count = var.create_cluster ? 1 : 0

  global_cluster_identifier           = var.global_cluster_identifier
  cluster_identifier                  = var.identifier
  replication_source_identifier       = var.replication_source_identifier
  source_region                       = var.source_region
  engine                              = var.engine
  engine_mode                         = var.engine_mode
  engine_version                      = var.engine_version
  enable_http_endpoint                = var.enable_http_endpoint
  kms_key_id                          = var.kms_key_id
  database_name                       = var.database_name
  master_username                     = jsondecode(data.aws_secretsmanager_secret_version.this.secret_string)["username"]
  master_password                     = jsondecode(data.aws_secretsmanager_secret_version.this.secret_string)["password"]
  final_snapshot_identifier           = "${var.final_snapshot_identifier_prefix}-${var.identifier}-${element(concat(random_id.snapshot_identifier.*.hex, [""]), 0)}"
  skip_final_snapshot                 = var.skip_final_snapshot
  deletion_protection                 = var.deletion_protection
  backup_retention_period             = var.backup_retention_period
  preferred_backup_window             = var.preferred_backup_window
  preferred_maintenance_window        = var.preferred_maintenance_window
  port                                = local.port
  db_subnet_group_name                = local.db_subnet_group_name
  vpc_security_group_ids              = var.vpc_security_group_ids
  snapshot_identifier                 = var.snapshot_identifier
  storage_encrypted                   = var.storage_encrypted
  apply_immediately                   = var.apply_immediately
  db_cluster_parameter_group_name     = element(concat(aws_rds_cluster_parameter_group.this.*.id, [""]), 0)
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  backtrack_window                    = local.backtrack_window
  copy_tags_to_snapshot               = var.copy_tags_to_snapshot
  iam_roles                           = var.iam_roles

  enabled_cloudwatch_logs_exports     = var.enabled_cloudwatch_logs_exports

  dynamic "scaling_configuration" {
    for_each = length(keys(var.scaling_configuration)) == 0 ? [] : [var.scaling_configuration]

    content {
      auto_pause               = lookup(scaling_configuration.value, "auto_pause", null)
      max_capacity             = lookup(scaling_configuration.value, "max_capacity", null)
      min_capacity             = lookup(scaling_configuration.value, "min_capacity", null)
      seconds_until_auto_pause = lookup(scaling_configuration.value, "seconds_until_auto_pause", null)
      timeout_action           = lookup(scaling_configuration.value, "timeout_action", null)
    }
  }

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )
}


resource "aws_rds_cluster_instance" "this" {
  count = var.create_cluster ? (var.replica_scale_enabled ? var.replica_scale_min : var.replica_count) : 0

  identifier                      = length(var.instances_parameters) > count.index ? lookup(var.instances_parameters[count.index], "instance_name", "${var.identifier}-${count.index + 1}") : "${var.identifier}-${count.index + 1}"
  cluster_identifier              = element(concat(aws_rds_cluster.this.*.id, [""]), 0)
  engine                          = var.engine
  engine_version                  = var.engine_version
  instance_class                  = length(var.instances_parameters) > count.index ? lookup(var.instances_parameters[count.index], "instance_type", var.instance_type) : count.index > 0 ? coalesce(var.instance_type_replica, var.instance_type) : var.instance_type
  publicly_accessible             = false
  db_subnet_group_name            = local.db_subnet_group_name
  # db_parameter_group_name         = var.db_parameter_group_name
  db_parameter_group_name         = element(concat(aws_db_parameter_group.this.*.id, [""]), 0)
  preferred_maintenance_window    = var.preferred_maintenance_window
  apply_immediately               = var.apply_immediately
  monitoring_role_arn             = local.rds_enhanced_monitoring_arn
  monitoring_interval             = var.monitoring_interval
  auto_minor_version_upgrade      = var.auto_minor_version_upgrade
  promotion_tier                  = length(var.instances_parameters) > count.index ? lookup(var.instances_parameters[count.index], "instance_promotion_tier", count.index + 1) : count.index + 1
  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_kms_key_id
  ca_cert_identifier              = var.ca_cert_identifier

  # Updating engine version forces replacement of instances, and they shouldn't be replaced
  # because cluster will update them if engine version is changed
  lifecycle {
    ignore_changes = [
      engine_version
    ]
  }

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )
}

resource "random_id" "snapshot_identifier" {
  count = var.create_cluster ? 1 : 0

  keepers = {
    id = var.identifier
  }

  byte_length = 4
}

resource "aws_db_parameter_group" "this" {
  count = var.create_cluster && var.use_parameter_group_name_prefix ? 1 : 0

  name_prefix = "${var.identifier}-"
  description = local.parameter_description
  family      = var.parameter_family

  dynamic "parameter" {
    for_each = var.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = lookup(parameter.value, "apply_method", null)
    }
  }

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster_parameter_group" "this" {
  count = var.create_cluster && var.use_parameter_group_name_prefix ? 1 : 0

  name_prefix = "${var.identifier}-"
  description = local.parameter_cluster_description
  family = var.parameter_cluster_family

  dynamic "parameter" {
    for_each = var.cluster_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = lookup(parameter.value, "apply_method", null)
    }
  }

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "monitoring_rds_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.create_cluster && var.create_monitoring_role && var.monitoring_interval > 0 ? 1 : 0

  name               = "rds-enhanced-monitoring-${var.identifier}"
  assume_role_policy = data.aws_iam_policy_document.monitoring_rds_assume_role.json

  permissions_boundary = var.permissions_boundary

  tags = merge(
    var.tags,
    {
      "Name" = format("%s", var.identifier)
    },
  )
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count = var.create_cluster && var.create_monitoring_role && var.monitoring_interval > 0 ? 1 : 0

  role       = local.rds_enhanced_monitoring_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_appautoscaling_target" "read_replica_count" {
  count = var.create_cluster && var.replica_scale_enabled ? 1 : 0

  max_capacity       = var.replica_scale_max
  min_capacity       = var.replica_scale_min
  resource_id        = "cluster:${element(concat(aws_rds_cluster.this.*.cluster_identifier, [""]), 0)}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"
}

resource "aws_appautoscaling_policy" "autoscaling_read_replica_count" {
  count = var.create_cluster && var.replica_scale_enabled ? 1 : 0

  name               = "target-metric"
  policy_type        = "TargetTrackingScaling"
  resource_id        = "cluster:${element(concat(aws_rds_cluster.this.*.cluster_identifier, [""]), 0)}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = var.predefined_metric_type
    }

    scale_in_cooldown  = var.replica_scale_in_cooldown
    scale_out_cooldown = var.replica_scale_out_cooldown
    target_value       = var.predefined_metric_type == "RDSReaderAverageCPUUtilization" ? var.replica_scale_cpu : var.replica_scale_connections
  }

  depends_on = [aws_appautoscaling_target.read_replica_count]
}