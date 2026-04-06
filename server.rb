require 'socket'
require 'colorize'
require 'webrick'
require 'webrick/httpproxy'
require 'json'

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
    log_request(req)
    host = req.host

    begin
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

      elsif req.request_uri
        super

      else
        query = req.path.gsub("/", "")
        search_url = URI("https://duckduckgo.com/html/?q=#{query}")
        result = Net::HTTP.get(search_url)
        res.status = 200
        res['Content-Type'] = 'text/html'
        res.body = result
      end

    rescue => e
      res.status = 500
      res.body = "<h1>500 - Error</h1><pre>#{e}</pre>"
    end
  end
end

server = TangoProxy.new(
  ROUTES,
  Port: 455,
  BindAddress: '127.0.0.1',
  AccessLog: [],
  Logger: WEBrick::Log.new(nil, 0),
  MaxClients: 50
)

trap('INT') { server.shutdown }

puts "Tango Proxy running on http://127.0.0.1:#{Port}".colorize(:green)
server.start
