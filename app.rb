require 'base64'
require 'castle'
require 'sinatra'
require 'sinatra/cookies'

# Configure and initialize the Castle client
Castle.configure do |config|
  config.api_secret = ENV['CASTLE_API_SECRET']
end

def user_data(request)
  {
    id: Base64.urlsafe_encode64(request.params['email']), # generate fake user ID
    email: request.params['email']
  }
end

$castle = Castle::Client.new

get '/' do
  # Logged in already
  if cookies[:user_id]
    return redirect '/overview'
  end

  castle_response = request.params['status']
  if castle_response
    @message = 'Login Failed. Hint: try "password" as password'
  elsif ENV['CASTLE_API_SECRET'].nil? || ENV['CASTLE_PUB_KEY'].nil?
    @message = 'Please set CASTLE_API_SECRET and CASTLE_PUB_KEY in your ENV'
  end

  erb :index
end

get '/overview' do
  @user_id, @user_email = cookies.values_at(:user_id, :user_email)

  redirect '/' if @user_id.nil?

  erb :overview
end

# Simulated login endpoint
post '/login' do
  # simulate failed login when password is not "password"
  failed = request.params['password'] != 'password'

  # Send successful requests to the Risk API
  if failed
    params = castle_params(request).merge(
      event: '$login',
      status: '$failed'
    )

    castle_response = send_to_castle('filter', params)
    redirect "/?status=login_failed"
  else
    user_data = user_data(request)
    params = castle_params(request).merge(
      event: '$login',
      status: '$succeeded',
      user: user_data
    )

    castle_response = send_to_castle('risk', params)

    cookies[:user_id] = user_data[:id]
    cookies[:user_email] = user_data[:email]

    redirect '/overview'
  end
end

# Clear user login data
post '/logout' do
  cookies.delete(:user_id)
  cookies.delete(:user_email)
  redirect '/'
end

# Simulated registration endpoint
post '/signup' do
  user_data = user_data(request)
  params = castle_params(request).merge(
    event: '$registration',
    status: '$succeeded',
    user: user_data
  )

  castle_response = send_to_castle('risk', params)

  cookies[:user_id] = user_data[:id]
  cookies[:user_email] = user_data[:email]

  redirect '/overview'
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
