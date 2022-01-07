require "sshkit"
require "sshkit/dsl"
include SSHKit::DSL

def server(host_name, roles, location, hash = {})
  result = SSHKit::Host.new(host_name)
  result.properties.roles = roles
  result.properties.location = location
  hash.each_pair do |key, value|
    result.properties[key] = value
  end
  return result
end

# wrapper around apt packages
class Package
  def initialize(name, post_install=[])
    @name = name
    @post_install = post_install
  end
  def install(ctx)
    if ctx.test("dpkg --get-selections #{@name} | grep install")
      ctx.info("Package #{@name} is already installed")
      return
    end

    exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes install #{@name}", :sudo)
    @post_install.each do |command|
      exe(ctx, command, :sudo)
    end
  end
end

def torrent_packages
  return [
    Package.new("openvpn"),
    Package.new("apache2"),
    Package.new("aria2"),
  ]
end

def sdrip_packages
  return [
    Package.new("avahi-utils"),
  ]
end

servers = [
  server("fs.local", [:torrent, :apt, :pi], :munich),
  server("slideshow.local", [:slideshow, :apt, :pi], :munich),
  server("seehaus-piano.local", [:torrent, :apt, :sdrip, :pi], :seehaus, {
           packages: [
             Package.new("etckeeper"),
             Package.new("joe"),
             Package.new("emacs"),
             Package.new("apt-file", ["apt-file update"]),
             Package.new("tig"),
             Package.new("byobu"),
             Package.new("fish"),
           ] + torrent_packages + sdrip_packages
         }),
  server("seehaus-blau.local", [:pi], :seehaus),
  server("gizmomogwai-cloud001", [:apt], :cloud),
]

class Array
  def with_role(role)
    self.select{|server|server.properties.roles && server.properties.roles.include?(role)}
  end
  def in(location)
    self.select{|server|server.properties.location && server.properties.location == location}
  end
end

def exe(ctx, command, *options)
  ctx.execute("#{with_sudo(options)}#{command}", interaction_handler: AllOutputInteractionHandler.new)
end

def with_sudo(options)
  return options.include?(:sudo) ? "sudo " : ""
end

def install_from_web(ctx, url, destination)
  if  ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("sudo sha512sum #{destination}").split(" ").first
    system("curl --silent --output tmp.f #{url}")
    local_checksum = `sha512sum tmp.f`.strip.split(" ").first
    if remote_checksum == local_checksum
      ctx.info("#{destination} is already up2date")
      return false
    end
  end
  exe(ctx, "curl --silent --output #{destination} #{url}", :sudo)
  exe(ctx, "chown root:root #{destination}", :sudo)
  exe(ctx, "chmod 766 #{destination}", :sudo)
  return true
end

def with_verbosity(level)
  h = SSHKit.config.output_verbosity
  SSHKit.config.output_verbosity = level
  yield
  SSHKit.config.output_verbosity = h
end

def upload(ctx, file, destination, user, group, mask, *options)
  if ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("#{with_sudo(options)}sha512sum #{destination}").split(" ").first
    local_checksum = `sha512sum #{file}`.strip.split(" ").first
    if remote_checksum == local_checksum
      ctx.info("#{destination} is already up2date")
      return false
    end
  end

  exe(ctx, "mkdir -p tmp")
  with_verbosity(Logger::INFO) do
    ctx.upload!(file, "tmp/", {log_percent: 20})
  end
  exe(ctx, "mkdir -p #{File.dirname(destination)}", options)
  exe(ctx, "mv tmp/#{File.basename(file)} #{destination}", options)
  exe(ctx, "chown #{user}:#{group} #{destination}", options)
  exe(ctx, "chmod #{mask} #{destination}", options)
  return true
end

def upload_encrypted_file(ctx, file, destination, user, group, mask, sudo=false)
  decrypted = `gpg --decrypt --quiet #{file}`
  if ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("#{with_sudo(sudo)}sha512sum #{destination}").split(" ").first
    local_checksum = `gpg --decrypt --quiet #{file} | sha512sum`.strip.split(" ").first
    if remote_checksum == local_checksum
      info("#{destination} is already up2date")
      return false
    end
  end

  ctx.upload!(StringIO.new(decrypted), "tmp/tmp")
  exe(ctx, "mv tmp/tmp #{destination}", :sudo)
  exe(ctx, "chown #{user}:#{group} #{destination}", :sudo)
  exe(ctx, "chmod #{mask} #{destination}", :sudo)
  return true
end

class AllOutputInteractionHandler
  def on_data(command, stream_name, data, channel)
    case stream_name
    when :stderr
      SSHKit.config.output.send(:warn, data)
    when :stdout
      SSHKit.config.output.send(:debug, data)
    else
      SSHKit.config.output.send(:error, "#{data} sent to unknown stream #{stream_name}")
    end
  end
end

SSHKit.config.output_verbosity = Logger::DEBUG

class Service
  def initialize(ctx, name, service_file)
    @ctx = ctx
    @name = name
    @service_file = service_file
  end
  def install
    changed = upload(@ctx, @service_file, "/lib/systemd/system/openvpn-in-namespace-client@.service", "root", "root", "644")
    if changed
      exe(@ctx, "systemctl daemon-reload", :sudo)
      exe(@ctx, "systemctl restart openvpn-in-namespace-client@italy", :sudo)
    end
    enable
  end
  def install_for_user
    changed = upload(@ctx, @service_file, "/home/pi/.config/systemd/user/sdrip.service", "pi", "pi", "444")
    if changed
      exe(@ctx, "systemctl --user daemon-reload")
      exe(@ctx, "systemctl --user restart #{@name}")
    end
    enable_for_user
  end
  def enable_for_user
    if enabled_for_user?
      @ctx.info("Service #{@name} is already enabled")
      return
    end
    exe(@ctx, "systemctl --user enable #{@name}")
  end
  def enabled_for_user?
    output = @ctx.capture("systemctl --user is-enabled #{@name}", raise_on_non_zero_exit: false)
    return output == "enabled"
  end
  def enable
    if enabled?
      @ctx.info("Service #{@name} is already enabled")
      return
    end
    exe(@ctx, "systemctl enable #{@name}", :sudo)
  end
  def enabled?
    output = @ctx.capture("systemctl is-enabled #{@name}", raise_on_non_zero_exit: false)
    return output == "enabled"
  end
end

locations =
  [
    :munich,
    :seehaus,
    :cloud,
  ]

locations.each do |location|
  namespace location do
    desc "Run all in #{location}"
    all = task :all do
    end

    desc "Configure torrent servers for #{location}"
    t = task :torrent do
      on servers.with_role(:torrent).in(location) do |host|
        info("Installing openvpn + deluge in namespace on #{host}")

        torrent_packages.each do |p|
          install_apt(self, p)
        end
        install_from_web(self, "https://raw.githubusercontent.com/slingamn/namespaced-openvpn/master/namespaced-openvpn", "/usr/local/bin/namespaced-openvpn")
        info("Installing custom openvpn config and scripts on #{host}")
        upload_encrypted_file(self, "torrent/openvpn-in-namespace-client@italy/pia.pass.gpg", "/etc/openvpn/client/pia.pass", "root", "root", "400", true)
        upload_encrypted_file(self, "torrent/openvpn-in-namespace-client@italy/italy.conf.gpg", "/etc/openvpn/client/italy.conf", "root", "root", "400", true)
        Service
          .new(self, "openvpn-in-namespace-client@italy", "torrent/openvpn-in-namespace-client@italy/openvpn-in-namespace-client@.service")
          .install
        upload(self, "torrent/000-default.conf", "/etc/apache2/sites-available/000-default.conf", "root", "root", "644", :sudo)
        exe(self, "a2enmod dav", :sudo)
        exe(self, "a2enmod dav_fs", :sudo)
        exe(self, "systemctl restart apache2", :sudo)
      end
    end
    all.enhance([t])

    desc "Configure for sdrip at #{location}"
    t = task :sdrip do
      on servers.with_role(:sdrip).in(location) do |host|
        info("Install sdrip")

        raise "Please link sdrip project folder" unless File.exist?("sdrip")
        raise "Please compile sdrip" unless File.exist?("sdrip/out/main/raspi/sdrip")

        Service
          .new(self, "sdrip", "sdrip/source/deployment/systemd/sdrip.service")
          .install_for_user
        Dir.glob("sdrip/public/*").each do |file|
          upload(self, file, "/home/pi/#{file}", "pi", "pi", "400")
        end
        upload(self, "sdrip/out/main/raspi/sdrip", "/home/pi/sdrip/sdrip", "pi", "pi", "700")
        upload(self, "sdrip/source/deployment/sites/#{host.hostname}/settings.yaml", "/home/pi/sdrip/settings.yaml", "pi", "pi", "400")
      end
    end
    all.enhance([t])

    desc "Update apt based servers"
    t = task :update do
      on servers.with_role(:apt).in(location) do |host|
        info("Updating #{host}")
        exe(self, "DEBIAN_FRONTEND=noninteractive apt-get --yes update", :sudo)
        exe(self, "DEBIAN_FRONTEND=noninteractive apt-get --yes dist-upgrade", :sudo)
        exe(self, "DEBIAN_FRONTEND=noninteractive apt-get --yes autoremove", :sudo)
      end
    end
    all.enhance([t])

    desc "Install all packages"
    t = task :install_packages do
      on servers.with_role(:apt).in(location) do |host|
        if host.properties.packages
          info("Installing #{host.properties.packages.join(' ')} on #{host}")
          host.properties.packages.each do |p|
            p.install(self)
          end
        end
      end
    end
    all.enhance([t])

    desc "Check state"
    t = task :check do
      on servers.with_role(:pi).in(location) do |host|
        exe(self, "/usr/bin/vcgencmd get_throttled") # https://raspberrypi.stackexchange.com/questions/60593/how-raspbian-detects-under-voltage
      end
    end
    all.enhance([t])

  end
end
task :default
