import json
import boto3
import logging
from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError

PUBLIC_KEY = 'REDACTED'

lambda_client = boto3.client('lambda')
region = 'us-west-2'
ec2 = boto3.client('ec2', region_name=region)



def lambda_handler(event, context):

  try:
    body = json.loads(event['body'])
        
    signature = event['headers']['x-signature-ed25519']
    timestamp = event['headers']['x-signature-timestamp']

    # validate the interaction

    verify_key = VerifyKey(bytes.fromhex(PUBLIC_KEY))

    message = timestamp + event['body']
    
    try:
      verify_key.verify(message.encode(), signature=bytes.fromhex(signature))
    except BadSignatureError:
      return {
        'statusCode': 401,
        'body': json.dumps('invalid request signature')
      }
    
    # handle the interaction

    t = body['type']

    if t == 1:
      return {
        'statusCode': 200,
        'body': json.dumps({
          'type': 1
        })
      }
    elif t == 2:
      return command_handler(body)
    else:
      return {
        'statusCode': 400,
        'body': json.dumps('unhandled request type')
      }
  except:
    raise

def command_handler(body):
  command = body['data']['name']

  if command == 'test':
    return {
      'statusCode': 200,
      'headers' : {'Content-Type': 'application/json'},
      'body': json.dumps({
        'type': 4,
        'data': {
          'content': 'Hello, World.',
        }
      })
    }
  elif command == 'server':
    logger = logging.getLogger()
    # Initialize the EC2 client
    response = ec2.describe_instances( InstanceIds=[
                'i-REDACTED'
            ])
    logger.info(response)
    print(response)
    if response:
      instance_state = response['Reservations'][0]['Instances'][0]['State']['Name']
      print(instance_state)
      if instance_state == 'running':
        return {
          'statusCode': 200,
          'headers' : {'Content-Type': 'application/json'},
          'body': json.dumps({
          'type': 4,
          'data': {
            'content': 'Server already running.',
          }
          })
        }
      elif instance_state == 'stopped':
        instance_starter()
        return {
          'statusCode': 200,
          'headers' : {'Content-Type': 'application/json'},
          'body': json.dumps({
            'type': 4,
            'data': {
              'content': 'Starting server....',
            }
          })
        }
      else:
        return{
        'statusCode': 200,
        'headers' : {'Content-Type': 'application/json'},
        'body': json.dumps({
          'type': 4,
          'data': {
            'content': 'Server already starting/stopping.',
          }
        })
        }

    instance_starter()
    return {
      'statusCode': 200,
      'headers' : {'Content-Type': 'application/json'},
      'body': json.dumps({
        'type': 4,
        'data': {
          'content': 'Server not found.',
        }
      })
    }
  #else:
   # return {
    #  'statusCode': 400,
     # 'body': json.dumps('unhandled command')
    #}
  else:
    return {
    'statusCode': 200,
      'headers' : {'Content-Type': 'application/json'},
      'body': json.dumps({
        'type': 4,
        'data': {
          'content': command,
        }
      })
  }

def instance_starter():
  payload = {
        'message': 'Hello from the invoking Lambda!',
  }
  response = lambda_client.invoke(
        FunctionName='arn:aws:lambda:us-west-2:000000000000:function:start-server',
        InvocationType='Event',
        Payload=json.dumps(payload)
  )

  