require "sinatra"
require 'json'
require "oauth"
require "oauth/consumer"
require 'haml'
require 'gmail_xoauth'

enable :sessions

before do
  session[:oauth] ||= {}  
  
  consumer_key = ENV["CONSUMER_KEY"] || ENV["consumer_key"]
  consumer_secret = ENV["CONSUMER_SECRET"] || ENV["consumer_secret"]
  
  @consumer ||= OAuth::Consumer.new(consumer_key, consumer_secret,
    :site => "https://www.google.com",
    :request_token_path => '/accounts/OAuthGetRequestToken?scope=https://mail.google.com/%20https://www.googleapis.com/auth/userinfo%23email',
    :access_token_path => '/accounts/OAuthGetAccessToken',
    :authorize_path => '/accounts/OAuthAuthorizeToken'
  )
  
  if !session[:oauth][:request_token].nil? && !session[:oauth][:request_token_secret].nil?
    @request_token = OAuth::RequestToken.new(@consumer, session[:oauth][:request_token], session[:oauth][:request_token_secret])
  end
  
  if !session[:oauth][:access_token].nil? && !session[:oauth][:access_token_secret].nil?
    @access_token = OAuth::AccessToken.new(@consumer, session[:oauth][:access_token], session[:oauth][:access_token_secret])
  end
  
end

get "/" do
  if @access_token
    response = @access_token.get('https://www.googleapis.com/userinfo/email?alt=json')
    if response.is_a?(Net::HTTPSuccess)
      @email = JSON.parse(response.body)['data']['email']
    else
      STDERR.puts "could not get email: #{response.inspect}"
    end

    imap = Net::IMAP.new('imap.gmail.com', 993, usessl = true, certs = nil, verify = false)
    imap.authenticate('XOAUTH', @email,
      :consumer_key => 'anonymous',
      :consumer_secret => 'anonymous',
      :token => @access_token.token,
      :token_secret => @access_token.secret
    )
    messages_count = imap.status('INBOX', ['MESSAGES'])['MESSAGES']
    "Seeing #{messages_count} messages in INBOX"
  else
    '<a href="/request">Sign On</a>'
  end
end

get "/request" do
  @request_token = @consumer.get_request_token(:oauth_callback => "#{request.scheme}://#{request.host}:#{request.port}/auth")
  session[:oauth][:request_token] = @request_token.token
  session[:oauth][:request_token_secret] = @request_token.secret
  redirect @request_token.authorize_url
end

get "/auth" do
  @access_token = @request_token.get_access_token :oauth_verifier => params[:oauth_verifier]
  session[:oauth][:access_token] = @access_token.token
  session[:oauth][:access_token_secret] = @access_token.secret
  redirect "/"
end

get "/logout" do
  session[:oauth] = {}
  redirect "/"
end
