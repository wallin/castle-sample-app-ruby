require 'base64'
require 'castle'
require 'sinatra'

# Configure and initialize the Castle client
Castle.configure do |config|
  config.api_secret = ENV['CASTLE_API_SECRET']
end

$castle = Castle::Client.new

get '/' do
  castle_response = request.params['response']
  if castle_response
    @castle_response = JSON.parse(Base64.urlsafe_decode64(castle_response))
  end

  erb :index
end

# Simulated login endpoint
post '/login' do
  params = castle_params(request).merge(
    event: '$login',
    status: '$succeeded',
    user: {
      id: request.params['email'],
      email: request.params['email']
    }
  )

  castle_response = send_to_castle('risk', params)

  redirect "/?response=#{Base64.urlsafe_encode64(JSON.dump(castle_response))}"
end

# Simulated registration endpoint
post '/signup' do
  params = castle_params(request).merge(
    event: '$registration'
  )

  castle_response = send_to_castle('filter', params)

  redirect "/?response=#{Base64.urlsafe_encode64(JSON.dump(castle_response))}"
end

private

# Helper methods for sending requests to Castle
def castle_params(request)
  headers = Castle::Headers::Filter.new(request).call

  {
    request_token: request.params['castle_request_token'],
    context: {
      ip: Castle::IPs::Extract.new(headers).call,
      headers: headers
    }
  }
end

def send_to_castle(endpoint, params)
  $castle.public_send(endpoint, params)
rescue Castle::InvalidParametersError => e
  e.message
end
