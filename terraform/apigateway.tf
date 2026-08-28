# --------------------------------------------------------------------------
# HTTP API in front of the Lambda
#
# Only created when endpoint_type = "api_gateway". The default is a Lambda
# function URL, which is simpler and free -- but some accounts refuse to serve
# a public function URL at all, answering every request with 403
# AccessDeniedException however correct the resource policy is. This is the way
# in for those accounts.
#
# An HTTP API (not a REST API) because it is a fifth of the price, and because
# its 2.0 payload format hands the Lambda the same lowercase headers, body and
# isBase64Encoded fields a function URL does -- so the handler is identical
# either way and neither path is a special case in the code.
# --------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "discord" {
  count = local.use_api_gateway ? 1 : 0

  name          = "${local.name}-discord"
  description   = "Discord interactions endpoint for ${local.name}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "discord" {
  count = local.use_api_gateway ? 1 : 0

  api_id           = aws_apigatewayv2_api.discord[0].id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.discord.invoke_arn

  # 2.0 is what makes this drop-in compatible with the function URL event.
  payload_format_version = "2.0"

  # Discord gives up after 3 seconds, so a longer wait here would only ever
  # bill for an answer nobody is still listening for.
  timeout_milliseconds = 10000
}

# Discord only ever POSTs to the root. Routing exactly that, rather than
# $default, means anything scanning the URL gets a 404 from API Gateway without
# reaching the Lambda.
resource "aws_apigatewayv2_route" "discord" {
  count = local.use_api_gateway ? 1 : 0

  api_id    = aws_apigatewayv2_api.discord[0].id
  route_key = "POST /"
  target    = "integrations/${aws_apigatewayv2_integration.discord[0].id}"
}

resource "aws_apigatewayv2_stage" "discord" {
  count = local.use_api_gateway ? 1 : 0

  api_id      = aws_apigatewayv2_api.discord[0].id
  name        = "$default"
  auto_deploy = true
}

# Scoped to this API: the function is invokable by API Gateway, and only by
# this one.
resource "aws_lambda_permission" "api_gateway" {
  count = local.use_api_gateway ? 1 : 0

  statement_id  = "AllowInvokeFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.discord[0].execution_arn}/*/*"
}
