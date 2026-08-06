data "aws_caller_identity" "current" {}

// bot/build comes from bot/scripts/build.sh, run before apply. Building it from
// Terraform does not work: archive_file is evaluated during plan, so it would zip
// a directory a null_resource has not created yet.
data "archive_file" "bot" {
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
  name               = "${var.project}-bot-webhook"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role" "bot_worker" {
  name               = "${var.project}-bot-worker"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "bot_webhook_logs" {
  role       = aws_iam_role.bot_webhook.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "bot_worker_logs" {
  role       = aws_iam_role.bot_worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "bot_webhook" {
  name = "${var.project}-bot-webhook"
  role = aws_iam_role.bot_webhook.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "HandOffToWorker"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.bot_worker.arn
    }]
  })
}

resource "aws_iam_role_policy" "bot_worker" {
  name = "${var.project}-bot-worker"
  role = aws_iam_role.bot_worker.id

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
      {
        // Every Claude Platform on AWS route maps to one action in this
        // namespace; POST /v1/messages is CreateInference and nothing else is
        // needed to answer a question.
        Sid      = "AnswerQuestions"
        Effect   = "Allow"
        Action   = ["aws-external-anthropic:CreateInference"]
        Resource = "arn:aws:aws-external-anthropic:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/${var.anthropic_workspace_id}"
      },
      {
        // Undocumented prerequisite for the above: the SDK mints a web identity
        // token about the calling principal before signing the inference call,
        // and without this the call 403s on sts:GetWebIdentityToken even though
        // CreateInference alone is granted. Found from a production 403, not
        // from the published IAM action list.
        Sid      = "MintTheWebIdentityToken"
        Effect   = "Allow"
        Action   = ["sts:GetWebIdentityToken"]
        Resource = "arn:aws:sts::${data.aws_caller_identity.current.account_id}:self"
      },
      {
        Sid      = "ReadTheSystemPrompt"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.ask_system_prompt.arn
      },
      {
        Sid    = "AskTheServer"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.server.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        // This call rejects a resource other than "*".
        Sid      = "ReadTheAnswer"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Sid      = "ReadCommandOutput"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.command_output.arn, "${aws_s3_bucket.command_output.arn}/*"]
      },
    ]
  })
}

// Two functions from one zip, differing only in handler. Returning the deferred
// ACK ends the invocation, so the function Discord calls cannot also send the
// follow-up.
resource "aws_lambda_function" "bot_webhook" {
  function_name    = "${var.project}-bot-webhook"
  role             = aws_iam_role.bot_webhook.arn
  filename         = data.archive_file.bot.output_path
  source_code_hash = data.archive_file.bot.output_base64sha256
  handler          = "palworld_bot.webhook.handle"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      DISCORD_PUBLIC_KEY   = var.discord_public_key
      WORKER_FUNCTION_NAME = aws_lambda_function.bot_worker.function_name
    }
  }
}

resource "aws_lambda_function" "bot_worker" {
  function_name    = "${var.project}-bot-worker"
  role             = aws_iam_role.bot_worker.arn
  filename         = data.archive_file.bot.output_path
  source_code_hash = data.archive_file.bot.output_base64sha256
  handler          = "palworld_bot.worker.handle"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 512
  timeout          = 300

  environment {
    variables = {
      INSTANCE_ID                = aws_instance.server.id
      SECURITY_GROUP_ID          = aws_security_group.server.id
      GAME_PORT                  = var.game_port
      QUERY_PORT                 = var.query_port
      REST_API_PORT              = var.rest_api_port
      COMMAND_OUTPUT_BUCKET      = aws_s3_bucket.command_output.id
      SERVER_SECRETS_PARAMETER   = aws_ssm_parameter.server_secrets.name
      SYSTEM_PROMPT_PARAMETER    = aws_ssm_parameter.ask_system_prompt.name
      CLAUDE_MODEL               = var.claude_model
      ANTHROPIC_AWS_WORKSPACE_ID = var.anthropic_workspace_id
    }
  }
}

// A retry can never be correct here: the worker already ran the model, posted
// chunks and possibly broadcast with announce, so a retried invocation repeats
// all of that rather than recovering anything. Lambda's async default of two
// retries would otherwise fire on ordinary followup flakiness (a 429, a
// timeout) partway through a run.
resource "aws_lambda_function_event_invoke_config" "bot_worker" {
  function_name          = aws_lambda_function.bot_worker.function_name
  maximum_retry_attempts = 0
}

// Discord signs every request with Ed25519 and the function verifies it, so the
// URL itself is left unauthenticated.
resource "aws_lambda_function_url" "bot_webhook" {
  function_name      = aws_lambda_function.bot_webhook.function_name
  authorization_type = "NONE"
}

// The prompt lives in the repository and is pushed with `make prompt-deploy`,
// so Terraform seeds the value once and then leaves it alone. Managing the
// value here would mean an apply for every wording change, and would revert
// any prompt pushed since the last apply.
resource "aws_ssm_parameter" "ask_system_prompt" {
  name  = "/${var.project}/${var.server_version}/ask_system_prompt"
  type  = "String"
  tier  = "Advanced"
  value = file("${path.module}/../bot/prompts/ask.md")

  lifecycle {
    ignore_changes = [value]
  }
}
