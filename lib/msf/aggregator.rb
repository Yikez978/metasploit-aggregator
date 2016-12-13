require 'socket'
require 'openssl'
require 'thread'
require 'msgpack'
require 'msgpack/rpc'

require 'msf/aggregator/version'
require 'msf/aggregator/connection_manager'
require 'msf/aggregator/https_forwarder'
require 'msf/aggregator/logger'

module Msf
  module Aggregator

    class Service
      # returns map of sessions available from the service
      def sessions
        # index for impl
      end

      def listeners
        # index for impl
      end

      # sets forwarding for a specific session to promote
      # that session for local use, obtained sessions are
      # not reported in getSessions
      def obtain_session(payload, lhost, lport)
        # index for impl
      end

      # parks a session and makes it available in the getSessions
      def release_session(payload)
        # index for impl
      end

      # start a listening port maintained on the service
      # connections are forwarded to any registered default
      # TODO: may want to require a type here for future proof of api
      def add_cable(host, port, certificate)
        # index for impl
      end

      def remove_cable(host, port)
        # index for impl
      end

      def register_default(lhost, lport, payload_list)
        # index for impl
      end

      # returns list of IP addressed available to the service
      # TODO: consider also reporting "used" ports (may not be needed)
      def available_ingress
        # index for impl
      end
    end

    class ServerProxy < Service
      @host = @port = @socket = nil
      @response_queue = []

      def initialize(host, port)
        @host = host
        @port = port
        @client = MessagePack::RPC::Client.new(@host, @port)
      end

      def start
        Logger.log 'not implemented'
      end

      def sessions
        @client.call(:sessions)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def listeners
        @client.call(:cables)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end


      def obtain_session(payload, lhost, lport)
        @client.call(:obtain_session, payload, lhost, lport)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def release_session(payload)
        @client.call(:release_session, payload)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def add_cable(host, port, certificate)
        @client.call(:add_cable, host, port, certificate)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def remove_cable(host, port)
        @client.call(:remove_cable, host, port)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def register_default(lhost, lport, payload_list)
        @client.call(:register_default, lhost, lport, payload_list)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def available_ingress
        @client.call(:available_addresses)
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def stop
        @client.close
      end
    end # ServerProxy

    class Server < Service
      # include Metasploit::Aggregator::ConnectionManager

      def initialize
        @executor = nil
        @manager = nil
      end

      def start
        @executor = Thread.new do
          begin
            @manager = Msf::Aggregator::ConnectionManager.new
          rescue
            $stderr.puts $!
          end
        end
        true
      end

      def sessions
        @manager.connections
      end

      def cables
        @manager.cables
      end

      def obtain_session(payload, rhost, rport)
        # return session object details or UUID/uri
        # forwarding will cause new session creation on the console
        # TODO: check and set lock on payload requested see note below in register_default
        @manager.register_forward(rhost, rport, [ payload ])
      end

      def release_session(payload)
        @manager.park(payload)
      end

      def add_cable(host, port, certificate)
        unless @executor.nil?
          # TODO: check if already listening on that port
          @manager.create_https_listener(host, port, certificate)
        end
        true
      end

      def remove_cable(host, port)
        unless @executor.nil?
          @manager.remove_cable(host, port)
        end
      end

      def register_default(lhost, lport, payload_list)
        # add this payload list to each forwarder for this remote console
        # TODO: consider adding boolean param to ConnectionManager.register_forward to 'lock'
        @manager.register_forward(lhost, lport, payload_list)
        true
      end

      def available_addresses
        addr_list = Socket.ip_address_list
        addresses = []
        addr_list.each do |addr|
          addresses << addr.ip_address
        end
        addresses
      end

      def stop
        unless @executor.nil?
          @manager.stop unless @admin_listener.nil?
          @executor.join
        end
        true
      end

      def release_session(host)
        @manager.park(host)
      end
    end # class Server

    class MsgPackServer

      def initialize(host, port)
        @host = host
        @port = port

        # server = TCPServer.new(@host, @port)
        # sslContext = OpenSSL::SSL::SSLContext.new
        # sslContext.key, sslContext.cert = Msf::Aggregator::ConnectionManager.ssl_generate_certificate
        # sslServer = OpenSSL::SSL::SSLServer.new(server, sslContext)
        #
        @svr = MessagePack::RPC::Server.new # need to initialize this as ssl server
        # @svr.listen(sslServer, Server.new)
        @svr.listen(@host, @port, Server.new)

        Thread.new { @svr.run }
      end

      def start
        c = MessagePack::RPC::Client.new(@host,@port)
        c.call(:start)
        c.close
      rescue MessagePack::RPC::TimeoutError => e
        Logger.log(e.to_s)
      end

      def stop
        @svr.close
      end
    end
  end
end
