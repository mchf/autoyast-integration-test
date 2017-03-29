require "aytests/web_server"
require "aytests/registration_server"
require "pathname"
require "uri"
require "aytests/vm"


module AYTests
  # This class implements Veewee hooks
  #
  # It follows a similar approach to the one proposed in the documentation:
  # https://github.com/jedi4ever/veewee/blob/bea6837cea33ae2123f3e3ac53c97a203796e4f4/doc/build_hooks.md
  class VeeweeHooks
    # @return [Veewee::Definition] Veewee box definition
    attr_reader :definition
    # @return [Symbol] virtual machine's provider (virtualbox or libvirt)
    attr_reader :provider
    # @return [Pathname] Document root for the webserver
    # FIXME: rename "webserver_root"
    attr_reader :files_dir
    # @return [Pathname] Directory where Veewee related files live.
    attr_reader :sources_dir
    # @return [String] Local IP address (listening address for web and registration servers)
    attr_reader :ip_address
    # @return [String] Virtual machine's MAC address
    attr_reader :mac_address
    # @return [Integer] Web server's port
    attr_reader :webserver_port
    # @return [String] Backup virtual machine's image name
    attr_reader :backup_image_name

    # Constructor
    #
    # @param definition        [Veewee::Definition] Veewee box definition
    # @param provider          [Symbol]             Provider to be used by Vagrant (:libvirt or :virtualbox)
    # @param files_dir         [Pathname,String]    Document root for the webserver
    # @param sources_dir       [Pathname,String]    Directory where Veewee related files live
    #                                               (templates for definition, post-install script, etc.)
    # @param ip_address        [String]             Local IP address (listening address for web and registration
    #                                               servers)
    # @param mac_address       [String]             Virtual machine's MAC address
    # @param webserver_port    [Integer,String]     Web server's port
    # @param backup_image_name [String]             Backup virtual machine's image name
    def initialize(definition:, provider:, files_dir:, sources_dir:, ip_address:, mac_address:, webserver_port:, backup_image_name:)
      @definition = definition
      @provider = provider
      @files_dir = Pathname(files_dir)
      @sources_dir = Pathname(sources_dir)
      @ip_address = ip_address
      @mac_address = mac_address
      @webserver_port = webserver_port
      @backup_image_name = backup_image_name
      @vm = nil
      @threads = []
    end

    # Before create hook
    #
    # Start a web and a registration server in a separated thread
    def before_create
      start_thread { start_webserver }
      start_thread { start_regserver }
    end

    # After create hook
    #
    # Update virtual machine's MAC address and boot order
    def after_create
      vm.update(mac: mac_address, boot_order: [:cdrom, :hd])
    end

    # Before upgrade hook
    #
    # Implement the `after_create` hook for the *upgrade scenario*.
    #
    # * Restore the virtual machine using the backup.
    # * Update the virtual machine's MAC address
    # * Restore the ISO to use. At this point, the ISO used to do the
    #   install was linked. Now we need to use the generated one.
    def before_upgrade
      vm.restore!(backup_image_name)
      vm.update(mac: mac_address, boot_order: [:cdrom, :hd])

      # Restoring obs image
      base_dir = File.dirname(__FILE__)
      testing_iso = File.join(base_dir, "iso/testing.iso")
      obs_iso = File.join(base_dir, "veewee/iso/obs.iso")
      # Taking obs iso for upgrade
      FileUtils.ln(obs_iso, testing_iso) if File.file?(obs_iso) && !File.file?(testing_iso)
    end

    # After postinstall hook
    #
    # Stop all started servers (web and registration servers)
    def after_postinstall
      stop_threads
    end

  private

    # Start a webserver serving files in `files_dir`
    #
    # Veewee's built in webserver solution doesn't work reliably with AutoYaST
    # due to some timing issues.
    def start_webserver
      AYTests::WebServer.new(
        veewee_dir: Pathname.pwd.join("definitions", "autoyast"),
        files_dir:  files_dir,
        name:       definition.box.name
      ).start
    end

    # Start a fake registration server
    def start_regserver
      certs_dir = Pathname.new(sources_dir).join("ssl")
      updates_url = URI("http://#{ip_address}:#{webserver_port}" \
        "/static/repos/sles12")

      AYTests::RegistrationServer.new(
        ca_crt_path: certs_dir.join("rootCA.pem"),
        ca_key_path: certs_dir.join("rootCA.key"),
        address:     ip_address,
        updates_url: updates_url
      ).start
    end

    # Start a stores a new thread
    def start_thread(&block)
      @threads << Thread.new(&block)
    end

    # Stop all threads
    def stop_threads
      @threads.each { |t| Thread.kill(t) }
      @threads.clear
    end

    # Virtual machine
    def vm
      return @vm if @vm
      require "aytests/#{provider}_vm"
      @vm = AYTests::VM.new(definition.name, provider.to_sym)
    end
  end
end
