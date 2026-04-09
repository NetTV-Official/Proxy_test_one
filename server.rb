require 'socket'
require 'colorize'
require 'webrick'
require 'webrick/httpproxy'
require 'json'
require 'net/http'
require 'uri'
require 'openssl'

name = "Codename Tango"
puts "Please wait while #{name} Network get's ready for action...".colorize(:blue)
sleep(1)
puts "WARNING: It is required to have atleast 10mb of bandwith to use #{name}".colorize(:yellow)
sleep(4)
puts "Connecting...".colorize(:yellow)

ROUTES = JSON.parse(File.read('links.json'))
LOG_FILE = "tango.log"
BANNED_KEYWORDS = ["piracy", "hack", "malware", "illegal"]

def mime_type(path)
  case File.extname(path)
  when ".html" then "text/html"
  when ".css"  then "text/css"
  when ".js"   then "application/javascript"
  when ".png"  then "image/png"
  when ".jpg", ".jpeg" then "image/jpeg"
  when ".gif"  then "image/gif"
  else "text/plain"
  end
end

def safe_path(base, req_path)
  clean = File.expand_path(File.join(base, req_path))
  return nil unless clean.start_with?(File.expand_path(base))
  clean
end

def log_request(req)
  type =
    if req.host&.end_with?(".tango")
      "TANGO"
    elsif req.request_method == "CONNECT"
      "HTTPS"
    else
      "HTTP"
    end
  entry = "[#{Time.now}] [#{type}] #{req.peeraddr[3]} -> #{req.request_method} #{req.host}#{req.path}\n"
  puts entry.strip
  File.open(LOG_FILE, "a") { |f| f.write(entry) }
end

class TangoProxy < WEBrick::HTTPProxyServer
  def initialize(routes, *args)
    super(*args)
    @routes = routes
  end

  def service(req, res)
    # Fix: Strip compression headers so responses aren't gzipped
    req.header.delete('accept-encoding')
    req.header['accept-encoding'] = ['identity']

    log_request(req)
    host = req.host

    begin
      # Handle .tango sites
      if host&.end_with?(".tango")
        if @routes[host]
          base = @routes[host]
          file = if File.directory?(base)
                   req.path == "/" ? File.join(base, "index.html") : safe_path(base, req.path)
                 else
                   req.path == "/" ? base : safe_path(File.dirname(base), req.path)
                 end
          if file && File.exist?(file)
            res.status = 200
            res['Content-Type'] = mime_type(file)
            res.body = File.binread(file)
          else
            res.status = 404
            res.body = "<h1>404 - File not found</h1>"
          end
        else
          res.status = 404
          res.body = "<h1>404 - .tango site not found</h1>"
        end
        return

      # Handle search engines to filter banned keywords
      elsif req.request_method == "GET" && req.path.include?("search")
        uri = URI(req.request_uri.to_s)
        query = URI.decode_www_form(uri.query || "").to_h["q"].to_s.downcase
        if BANNED_KEYWORDS.any? { |word| query.include?(word) }
          failed_file = "sites/failed.html"
          if File.exist?(failed_file)
            res.status = 200
            res['Content-Type'] = "text/html"
            res.body = File.binread(failed_file)
          else
            res.status = 403
            res.body = "<h1>Access denied</h1>"
          end
          return
        else
          super
        end

      # Handle proxied external sites from routes
      elsif @routes[host] && @routes[host].start_with?("http://", "https://")
        target_url = @routes[host]
        begin
          uri = URI(target_url + req.path)
          uri.query = URI.parse(req.request_uri.to_s).query if URI.parse(req.request_uri.to_s).query

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE if uri.scheme == 'https'
          http.read_timeout = 10

          # Create the appropriate request type
          case req.request_method
          when "GET"
            proxy_req = Net::HTTP::Get.new(uri.request_uri)
          when "POST"
            proxy_req = Net::HTTP::Post.new(uri.request_uri)
            proxy_req.body = req.body
          when "HEAD"
            proxy_req = Net::HTTP::Head.new(uri.request_uri)
          else
            proxy_req = Net::HTTP::Request.new(req.request_method, uri.request_uri)
            proxy_req.body = req.body
          end

          # Copy relevant headers
          req.header.each do |k, v|
            next if k.downcase == 'host'
            next if k.downcase == 'connection'
            next if k.downcase == 'content-length'
            proxy_req[k] = v
          end
          proxy_req['Host'] = uri.host

          # Send request and handle response
          proxy_res = http.request(proxy_req)
          res.status = proxy_res.code.to_i
          proxy_res.each_header do |k, v|
            next if k.downcase == 'connection'
            next if k.downcase == 'content-encoding'
            res[k] = v
          end
          res.body = proxy_res.body
          return
        rescue => e
          res.status = 502
          res.body = "<h1>502 - Bad Gateway</h1><pre>#{e.message}\n#{e.backtrace.join("\n")}</pre>"
          return
        end

      # All other requests
      elsif req.request_uri
        super
      else
        # fallback search
        query = req.path.gsub("/", "")
        search_url = URI("https://duckduckgo.com/html/?q=#{query}")
        result = Net::HTTP.get(search_url)
        res.status = 200
        res['Content-Type'] = 'text/html'
        res.body = result
      end
    rescue => e
      res.status = 500
      res.body = "<h1>500 - Error</h1><pre>#{e.message}\n#{e.backtrace.join("\n")}</pre>"
    end
  end
end

local_ip = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? && !a.ip_address.start_with?("169.") }&.ip_address || "127.0.0.1"

server = TangoProxy.new(
  ROUTES,
  Port: 4555,
  BindAddress: '0.0.0.0',
  AccessLog: [],
  Logger: WEBrick::Log.new(nil, 0),
  MaxClients: 50
)

trap('INT') { server.shutdown }
puts "Tango Proxy running on http://#{local_ip}:4555".colorize(:green)
puts "Other devices: set proxy to #{local_ip}:4555".colorize(:cyan)
server.start
