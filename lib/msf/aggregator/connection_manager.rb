require 'openssl'
require 'socket'

require 'msf/aggregator/logger'
require 'msf/aggregator/http_forwarder'
require 'msf/aggregator/https_forwarder'
require 'msf/aggregator/cable'

module Msf
  module Aggregator

    class ConnectionManager

      def initialize
        @cables = []
        @manager_mutex = Mutex.new
        @default_route = []
        @router = Router.instance
      end

      def self.ssl_generate_certificate
        yr   = 24*3600*365
        vf   = Time.at(Time.now.to_i - rand(yr * 3) - yr)
        vt   = Time.at(vf.to_i + (10 * yr))
        cn   = 'localhost'
        key  = OpenSSL::PKey::RSA.new(2048){ }
        cert = OpenSSL::X509::Certificate.new
        cert.version    = 2
        cert.serial     = (rand(0xFFFFFFFF) << 32) + rand(0xFFFFFFFF)
        cert.subject    = OpenSSL::X509::Name.new([["CN", cn]])
        cert.issuer     = OpenSSL::X509::Name.new([["CN", cn]])
        cert.not_before = vf
        cert.not_after  = vt
        cert.public_key = key.public_key

        ef = OpenSSL::X509::ExtensionFactory.new(nil,cert)
        cert.extensions = [
            ef.create_extension("basicConstraints","CA:FALSE")
        ]
        ef.issuer_certificate = cert

        cert.sign(key, OpenSSL::Digest::SHA256.new)

        [key, cert, nil]
      end

      def ssl_parse_certificate(certificate)
        key, cert, chain = nil
        unless certificate.nil?
          begin
            # parse the cert
            key = OpenSSL::PKey::RSA.new(certificate, "")
            cert = OpenSSL::X509::Certificate.new(certificate)
            # TODO: ensure this parses all certificate in object provided
          rescue OpenSSL::PKey::RSAError => e
            Logger.log(e.message)
          end
        end
        return key, cert, chain
      end

      def add_cable_https(host, port, certificate)
        @manager_mutex.synchronize do
          forwarder = Msf::Aggregator::HttpsForwarder.new
          forwarder.log_messages = true
          server = TCPServer.new(host, port)
          ssl_context = OpenSSL::SSL::SSLContext.new
          unless certificate.nil?
            ssl_context.key, ssl_context.cert = ssl_parse_certificate(certificate)
          else
            ssl_context.key, ssl_context.cert = Msf::Aggregator::ConnectionManager.ssl_generate_certificate
          end
          ssl_server = OpenSSL::SSL::SSLServer.new(server, ssl_context)

          handler = connect_cable(ssl_server, host, port, forwarder)
          @cables << Cable.new(handler, server, forwarder)
          handler
        end
      end

      def add_cable_http(host, port)
        @manager_mutex.synchronize do
          forwarder = Msf::Aggregator::HttpForwarder.new
          forwarder.log_messages = true
          server = TCPServer.new(host, port)

          handler = connect_cable(server, host, port, forwarder)
          @cables << Cable.new(handler, server, forwarder)
        end
      end

      def register_forward(rhost, rport, payload_list = nil)
        @cables.each do |cable|
          addr = cable.server.local_address
          if addr.ip_address == rhost && addr.ip_port == rport.to_i
            raise ArgumentError.new("#{rhost}:#{rport} is not a valid forward")
          end
        end
        if payload_list.nil?
          # add the this host and port as the new default route
          @default_route = [rhost, rport]
          @router.add_route(rhost, rport, nil)
        else
          payload_list.each do |payload|
            @router.add_route(rhost, rport, payload)
          end
        end
      end

      def connections
        connections = {}
        @cables.each do |cable|
          connections = connections.merge cable.forwarder.connections
        end
        connections
      end

      def cables
        local_cables = []
        @cables.each do |cable|
          addr = cable.server.local_address
          local_cables << addr.ip_address + ':' + addr.ip_port.to_s
        end
        local_cables
      end

      def connect_cable(server, host, port, forwarder)
        Logger.log "Listening on port #{host}:#{port}"

        handler = Thread.new do
          begin
            loop do
              Logger.log "waiting for connection on #{host}:#{port}"
              connection = server.accept
              Logger.log "got connection on #{host}:#{port}"
              Thread.new do
                begin
                  forwarder.forward(connection)
                rescue
                  Logger.log $!
                end
                Logger.log "completed connection on #{host}:#{port}"
              end
            end
          end
        end
        handler
      end

      def remove_cable(host, port)
        @manager_mutex.synchronize do
          closed_servers = []
          @cables.each do |cable|
            addr = cable.server.local_address
            if addr.ip_address == host && addr.ip_port == port.to_i
              cable.server.close
              cable.thread.exit
              closed_servers << cable
            end
          end
          @cables -= closed_servers
        end
        return true
      end


      def stop
        @manager_mutex.synchronize do
          @cables.each do |listener|
            listener.server.close
            listener.thread.exit
          end
        end
      end

      def park(payload)
        @router.add_route(nil, nil, payload)
        Logger.log "parking #{payload}"
      end

      private :ssl_parse_certificate
    end
  end
end
