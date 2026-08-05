// The bot is skipped until a Discord application exists, so the game server can
// be applied on its own -- which also means an apply without the bot does not
// require the build artefact below.
locals {
  bot_enabled = var.discord_public_key == null ? 0 : 1
}

data "archive_file" "bot" {
  count = local.bot_enabled

  type        = "zip"
  source_dir  = "${path.module}/../bot/build"
  output_path = "${path.module}/../bot/build.zip"
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bot_webhook" {
  count = local.bot_enabled

  name               = "${var.project}-bot-webhook"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role" "bot_worker" {
  count = local.bot_enabled

  name               = "${var.project}-bot-worker"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "bot_webhook_logs" {
  count = local.bot_enabled

  role       = aws_iam_role.bot_webhook[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "bot_worker_logs" {
  count = local.bot_enabled

  role       = aws_iam_role.bot_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "bot_webhook" {
  count = local.bot_enabled

  name = "${var.project}-bot-webhook"
  role = aws_iam_role.bot_webhook[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "HandOffToWorker"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.bot_worker[0].arn
    }]
  })
}

resource "aws_iam_role_policy" "bot_worker" {
  count = local.bot_enabled

  name = "${var.project}-bot-worker"
  role = aws_iam_role.bot_worker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ControlTheInstance"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.server.id}"
      },
      {
        Sid      = "ControlPlayerAccess"
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = aws_security_group.server.arn
      },
      {
        // These describe calls reject a resource other than "*".
        Sid    = "ReadState"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeSecurityGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "bot_webhook" {
  count = local.bot_enabled

  function_name    = "${var.project}-bot-webhook"
  role             = aws_iam_role.bot_webhook[0].arn
  filename         = data.archive_file.bot[0].output_path
  source_code_hash = data.archive_file.bot[0].output_base64sha256
  handler          = "palworld_bot.webhook.handle"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      DISCORD_PUBLIC_KEY   = var.discord_public_key
      WORKER_FUNCTION_NAME = aws_lambda_function.bot_worker[0].function_name
    }
  }
}

resource "aws_lambda_function" "bot_worker" {
  count = local.bot_enabled

  function_name    = "${var.project}-bot-worker"
  role             = aws_iam_role.bot_worker[0].arn
  filename         = data.archive_file.bot[0].output_path
  source_code_hash = data.archive_file.bot[0].output_base64sha256
  handler          = "palworld_bot.worker.handle"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 30

  environment {
    variables = {
      INSTANCE_ID       = aws_instance.server.id
      SECURITY_GROUP_ID = aws_security_group.server.id
      GAME_PORT         = var.game_port
    }
  }
}

// Discord signs every request with Ed25519 and the function verifies it, so the
// URL itself is left unauthenticated.
resource "aws_lambda_function_url" "bot_webhook" {
  count = local.bot_enabled

  function_name      = aws_lambda_function.bot_webhook[0].function_name
  authorization_type = "NONE"
}
