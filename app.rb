require "sinatra"
require 'timeout'
require 'json'
require "oauth"
require "oauth/consumer"
require 'haml'
require 'gmail_xoauth'

require File.expand_path(File.dirname(__FILE__) + '/gmail_imap_extensions_compatibility')

enable :sessions

# # Maximum number of messages to select at once.
# UID_BLOCK_SIZE = 1024


before do
  session[:oauth] ||= {}  
  
  consumer_key = ENV["CONSUMER_KEY"] || ENV["consumer_key"] || 'anonymous'
  consumer_secret = ENV["CONSUMER_SECRET"] || ENV["consumer_secret"] || 'anonymous'
  
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
    GmailImapExtensionsCompatibility.patch_net_imap_response_parser imap.instance_variable_get("@parser").singleton_class

    imap.authenticate('XOAUTH', @email,
      :consumer_key => 'anonymous',
      :consumer_secret => 'anonymous',
      :token => @access_token.token,
      :token_secret => @access_token.secret
    )

    begin

    mailbox = '[Gmail]/All Mail'
    imap.select '[Gmail]/All Mail'
    messages_count = imap.status(mailbox, ['MESSAGES'])['MESSAGES']
    max_emails = 1000
    first_message = if messages_count < max_emails
      1
    else
      messages_count - max_emails
    end

    result_rows = Timeout::timeout(27) do
      imap.fetch( first_message..messages_count, "(X-GM-THRID)")
    end
    thread_ids = result_rows.map {|row|
    row.attr["X-GM-THRID"]
    }

    thread_url = "https://mail.google.com/mail/u/0/#inbox/#{thread_ids.last.to_s(16)}"

    <<-EOS
      <pre>
      Email: #{@email}
      Seeing #{messages_count} messages in #{mailbox}
      Last thread link: <a href='#{thread_url}'>#{thread_url}</a>
      Processing #{messages_count-first_message} messages
      Thread IDs: #{thread_ids.length}
      </pre>
    EOS

    rescue Timeout::Error
      "timeout - sorry"
    end
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
