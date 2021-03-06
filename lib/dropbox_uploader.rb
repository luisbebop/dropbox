# Dropbox upload library for Ruby
# 
# Copyright (c) 2009  NAKAMURA Usaku <usa@garbagecollect.jp>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
# BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


require "net/https"
require "uri"

# == About this library
#
# A simple Dropbox ( http://www.dropbox.com/ ) library to upload files, with no other gem dependencies.
# This library has been completely written from scratch, but ideas and logics
# are inspired from Dropbox Uploader ( http://jaka.kubje.org/software/DropboxUploader/ ).
#
# == Example
#
#   require "dropbox_uploader"
#   dropbox = DropboxUploader.new("email@exapmle.com", "MyPassword")
#   dropbox.upload("localfile.txt", "/")
#
# == Known bugs
#
# * error check and recovery
# * non-ASCII file/remotedir name support
#
class DropboxUploader
  #
  # Create Dropbox instance and initialize it.
  # _email_ is your email registered at Dropobox.
  # _pass_ is your password, too.
  # _capath_ is the path of directory of CA files.
  #
  def initialize(email, pass, capath = nil)
    @email = email
    @pass = pass
    @ca = capath
    @cookie = nil
    @login = false
  end

  # :nodoc:
  def login
    html = send_request("https://www.dropbox.com/login").body
    token = extract_token(html, "/login")
    raise "token not found on /login" unless token
    res = send_request("https://www.dropbox.com/login", "login_email" => @email, "login_password" => @pass, "t" => token)
    if res["location"] == "/home"
      @login = true
    else
      raise "login failed #{res.code}:#{res.message}"
    end
  end

  #
  # Upload local file to Dropbox remote directory.
  # _file_ is a local file path.
  # _remote_ is the target remote directory.
  #
  def upload(file, remote)
    login unless @login
    html = send_request("https://www.dropbox.com/home?upload=1").body
    token = extract_token(html, "https://dl-web.dropbox.com/upload")
    raise "token not found on /upload" unless token

    stream = open(file, "rb")
    rawdata = stream.read
    filesize = rawdata.size
    boundary = generate_boundary(rawdata)
    rawdata = nil
    stream.rewind

    pre = ""
    {"dest" => remote, "t" => token}.each do |k,v|
      pre << "--#{boundary}\r\n"
      pre << %'Content-Disposition: form-data; name="#{k}"\r\n'
      pre << "\r\n"
      pre << %'#{v}\r\n'
    end
    pre << "--#{boundary}\r\n"
    pre << %'Content-Disposition: form-data; name="file"; filename="#{File.basename(file)}"\r\n'
    pre << "Content-Type: application/octet-stream\r\n"
    pre << "\r\n"

    post = "\r\n"
    post << "--#{boundary}--\r\n"

    data = PseudoIO.new(pre, [stream, filesize], post)

    res = send_request("https://dl-web.dropbox.com/upload", data, boundary)
    if res.code[0] != ?2 && res.code[0] != ?3
      raise "upload failed #{res.code}:#{res.message}"
    end

    true
  end

  private
  # :nodoc:
  def send_request(url, params = nil, boundary = nil)
    uri = URI.parse(url)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    if @ca
      https.verify_mode = OpenSSL::SSL::VERIFY_PEER
      https.ca_path = @ca
    else
      https.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    result = nil
    https.start do
      if @cookie
        header = {"Cookie" => @cookie}
      else
        header = {}
      end

      if params
        if boundary
          header["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          req = Net::HTTP::Post.new(uri.path, header)
          req.body_stream = params
          req["Content-Length"] = params.size
          result = https.request(req)
        else
          result = https.post(uri.path, params.map{|k,v| URI.encode("#{k}=#{v}")}.join("&"), header)
        end
      else
        result = https.get(uri.path, header)
      end
      @cookie = result["set-cookie"] if result["set-cookie"]
    end
    result
  end

  # :nodoc:
  def extract_token(html, action)
    #puts html
    return nil unless %r'<form action="#{action}"(.+?)</form>'m =~ html
    scrap = $1
    return nil unless /name="t" value="(.+?)"/ =~ scrap
    return $1
  end

  # :nodoc:
  def generate_boundary(str)
    begin
      boundary = "RubyDropbox#{rand(2**8).to_s(16)}"
    end while str.include?(boundary)
    boundary
  end
end

#
# This class provides a pseudo read-only IO, constructed from some strings and
# ios.
#
class PseudoIO
  require "stringio"

  #
  # PseudoIO.new(string or array, ...)
  #
  # string : an instance of String
  # array : [stream, size]
  #
  def initialize(*args)
    @totalsize = 0
    @ios = []
    args.each do |arg|
      if arg.is_a? String
        @ios << StringIO.new(arg)
        @totalsize += arg.size
      else
        @ios << arg[0]
        @totalsize += arg[1]
      end
    end
  end

  #
  # pseudoIo.size -> integer
  #
  # Returns the total size of strings and streams
  #
  def size
    @totalsize
  end
  alias length size

  #
  # pseudoIo.read([size, [buffer]]) -> string, buffer, or nil
  #
  # See IO#read.
  #
  def read(size = nil, result = nil)
    if result
      result.replace('')
    else
      result = ''
    end
    if size
      return nil if @ios.empty?
      until @ios.empty?
        cur = @ios.first.read(size)
        if cur
          result << cur
          break if cur.size >= size
          size -= cur.size
        end
        @ios.shift.close
      end
    else
      return "" if @ios.empty?
      until @ios.empty?
        io = @ios.shift
        result << io.read
        io.close
      end
    end
    result
  end
end
