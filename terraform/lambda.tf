# The Discord interactions endpoint.
#
# A Function URL rather than API Gateway: Discord needs one HTTPS POST target
# and nothing else, and this is one resource instead of five.

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/.build/discord-lambda.zip"
  excludes    = ["__pycache__", "__pycache__/*", "*.pyc"]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-discord"
  retention_in_days = 14
}

resource "aws_lambda_function" "discord" {
  function_name = "${local.name}-discord"
  role          = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  handler = "lambda_function.lambda_handler"
  runtime = "python3.12"

  # Signature verification is pure Python and takes roughly 30 ms, well inside
  # the three seconds Discord allows. The timeout covers the EC2 and SSM calls.
  timeout = 10

  # More memory buys proportionally more CPU. Signature verification is about
  # 5 ms of real CPU work, so roughly 34 ms at 256 MB and 17 ms at 512 MB --
  # either is fine. The reason to pay for 512 MB is the boto3 import on a cold
  # start, which is the larger half of the three second budget.
  memory_size = 512

  environment {
    variables = {
      DISCORD_PUBLIC_KEY = var.discord_public_key
      INSTANCE_ID        = aws_instance.server.id
      CONNECT_ADDRESS    = local.connect_address
      SERVER_PORT        = tostring(var.server_port)
      STOP_SCRIPT        = "/opt/minecraft/bin/request-stop.sh"
      ALLOWED_ROLE_IDS   = join(",", var.discord_allowed_role_ids)

      # /stop controls. The Lambda refuses the command on these alone; the IAM
      # policy separately withholds ssm:SendCommand when stop is disabled.
      ALLOW_STOP_COMMAND   = tostring(var.allow_stop_command)
      STOP_ROLE_IDS        = join(",", var.discord_stop_role_ids)
      IDLE_TIMEOUT_MINUTES = tostring(var.idle_timeout_minutes)
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]
}

# Public by design: Discord calls this from its own infrastructure with no AWS
# credentials. Every request is authenticated by its Ed25519 signature inside
# the handler, and an unsigned request is answered with 401 before anything
# else happens.
resource "aws_lambda_function_url" "discord" {
  function_name      = aws_lambda_function.discord.function_name
  authorization_type = "NONE"
}
