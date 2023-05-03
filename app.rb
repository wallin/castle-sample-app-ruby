require 'base64'
require 'castle'
require 'sinatra'
require 'sinatra/cookies'
require 'faye/websocket'
require 'time'
require 'digest'

Faye::WebSocket.load_adapter('puma')

$connections = {}

configure do
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET', 'default_secret')
end

def send_to_client(client_id, endpoint, params, resp)
  return unless $connections[client_id]

  message = {
    event: params[:event],
    endpoint: endpoint,
    status: params[:status] || params[:name],
    timestamp: Time.now.utc.iso8601.to_s,
    response: resp.to_h
  }
  $connections[client_id].send(JSON.generate(message))
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


  if (session['api_key'] || ENV['CASTLE_API_SECRET']).nil? || (session['pub_key'] || ENV['CASTLE_PUB_KEY']).nil?
    @message = 'Please set CASTLE_API_SECRET and CASTLE_PUB_KEY in your ENV'
  end

  erb :home
end


get '/overview' do
  @user_id, @user_email = cookies.values_at(:user_id, :user_email)

  redirect '/' if @user_id.nil?

  erb :overview
end

get '/login' do
  castle_response = request.params['status']
  if castle_response
    @message = 'Login Failed. Hint: try "password" as password'
  end

  erb :login
end

# Simulated login endpoint
post '/login' do
  # simulate failed login when password is not "password"
  failed = request.params['password'] != 'password'
  user_data = user_data(request)

  # Send successful requests to the Risk API
  if failed
    params = castle_params(request).merge(
      event: '$login',
      status: '$failed',
      user: user_data,
      authentication_method: {
        type: '$password'
      }
    )

    castle_response = send_to_castle('filter', params, cookies[:client_id])
    redirect "/login?status=login_failed"
  else
    params = castle_params(request).merge(
      event: '$login',
      status: '$succeeded',
      user: user_data,
      authentication_method: {
        type: '$password'
      }
    )

    castle_response = send_to_castle('risk', params, cookies[:client_id])

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

get '/signup' do
  erb :signup
end

# Simulated registration endpoint
post '/signup' do
  user_data = user_data(request)
  params = castle_params(request).merge(
    event: '$registration',
    status: '$succeeded',
    user: user_data
  )

  castle_response = send_to_castle('risk', params, cookies[:client_id])

  cookies[:user_id] = user_data[:id]
  cookies[:user_email] = user_data[:email]

  redirect '/overview'
end

############################## Admin related

get '/admin' do
  erb :admin
end

get '/ws' do
  if Faye::WebSocket.websocket?(request.env)
    ws = Faye::WebSocket.new(request.env)

    ws.on :open do
      client_id = SecureRandom.uuid
      $connections[client_id] = ws
      ws.send(JSON.generate(handshake: true, client_id: client_id))
    end

    ws.on :close do
      $connections.delete_if { |_, s| s == ws }
    end

    ws.rack_response
  else
    status 400
  end
end

post "/configure" do
  api_key = params["api-key"]
  pub_key = params["pub-key"]

  session[:api_key] = api_key
  session[:pub_key] = pub_key

  status 200
  redirect "/admin"
end

delete '/configure' do
  session[:api_key] = nil
  session[:pub_key] = nil

  status 200
  redirect '/admin'
end

post '/messages' do
  params = castle_params(request).merge(
    event: '$custom',
    name: 'message_sent',
    user: { id: cookies[:user_id], email: cookies[:user_email] },
    properties: {
      message_hash: Digest::MD5.hexdigest(request.params['message'])
    }
  )

  castle_response = send_to_castle('risk', params, cookies[:client_id])

  status 200
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

def send_to_castle(endpoint, params, client_id = nil)
  # Configure and initialize the Castle client
  Castle.configure do |config|
    config.api_secret = session[:api_key] || ENV['CASTLE_API_SECRET']
  end

  resp = $castle.public_send(endpoint, params)
  send_to_client(client_id, "POST /v1/#{endpoint}", params, resp)
# rescue => e
#  $connections.each { |conn| conn.send(e.message) }
end
