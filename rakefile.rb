require "sshkit"
require "sshkit/dsl"
include SSHKit::DSL

SSHKit::Backend::Netssh.pool.idle_timeout = 0
SSHKit.config.output_verbosity = Logger::DEBUG


def server(host_name, roles, location, hash = {})
  result = SSHKit::Host.new(host_name)
  result.properties.roles = roles
  result.properties.location = location
  hash.each_pair do |key, value|
    result.properties[key] = value
  end
  result.properties.packages = roles_to_packages(roles)
  return result
end

def torrent_packages
  return [
    "openvpn",
    "apache2",
    "aria2",
  ]
end

def debian_packages
  return [
    "apt-dist-upgrade",
    "etckeeper",
    "joe",
    "emacs",
    "apt-file",
    "tig",
    "byobu",
    "fish",
  ]
end

def wifi_packages
  return [
    "wavemon"
  ]
end

def slideshow_packages
  return [
    "slideshow",
  ]
end

def slideshow_server_packages
  return [
    "syncthing",
  ]
end

def no_ip_packages
  return [
    "inadyn-config",
  ]
end

def sdrip_packages
  return [
    "sdrip",
  ]
end

def roles_to_packages(roles)
  return roles.map { |role, res|
    begin
      send(role.to_s + "_packages")
    rescue
      nil
    end
  }.flatten.compact
end

servers = [
  server("fs.local", [:debian, :torrent, :pi, :slideshow_server, :no_ip], :munich),
  server("slideshow.local", [:debian, :slideshow, :pi, :wifi], :munich),
  server("seehaus-piano.local", [:debian, :torrent, :no_ip, :sdrip, :pi, :wifi, :slideshow_server], :seehausen),
  server("seehaus-blau.local", [:debian, :pi, :wifi, :slideshow], :seehausen),
  server("gizmomogwai-cloud001", [:debian], :cloud),
]

class Registry
  attr_reader :packages
  def initialize
    @packages = {}
  end
  def add(package)
    raise "Package '#{package.name}' already registered" if @packages.include?(package.name)
    @packages[package.name] = package
    return self
  end
  def install(ctx, name)
    raise "Cannot find package '#{name}'" unless @packages.include?(name)

    @packages[name].install(self, ctx)
  end
end
REGISTRY = Registry.new

# wrapper around apt packages
class Package
  attr_reader :name, :dependencies, :post_install_commands
  def initialize(name, dependencies: [], post_install_commands: [])
    @name = name
    @dependencies = dependencies
    @post_install_commands = post_install_commands
  end
  def install_dependencies(registry, ctx)
    @dependencies.each do |dependency|
      registry.install(ctx, dependency)
    end
  end

  def install(registry, ctx)
    puts "Install package #{@name}"
    install_dependencies(registry, ctx)

    if ctx.test("dpkg --get-selections #{@name} | grep install")
      ctx.info("Package #{@name} is already installed")
      return
    end

    exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes install #{@name}", :sudo)
    @post_install_commands.each do |command|
      exe(ctx, command, :sudo)
    end
  end
end

class AptDistUpgrade < Package
  def initialize()
    super("apt-dist-upgrade")
  end
  def install(registry, ctx)
    ctx.info("Updating #{ctx.host}")
    exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes update", :sudo)
    exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes dist-upgrade", :sudo)
    exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes autoremove", :sudo)
  end
end

class ConfigFile < Package
  def initialize(name, destination, source, dependencies: [])
    super(name, dependencies: dependencies)
    @destination = destination
    @source = source
  end
  def install(registry, ctx)
    source = @source.gsub('#{location}', ctx.host.properties.location.to_s)
    upload_encrypted_file(ctx, source, @destination, "root", "root", "400", :sudo)
  end
end

class Tarball < Package
  def initialize(name, url, destination, dependencies: [], post_install_commands: [], test: "-f")
    super(name, dependencies: dependencies, post_install_commands: post_install_commands)
    @url = url
    @destination = destination
    @test = test
  end
  def install(registry, ctx)
    install_dependencies(registry, ctx)

    return if ctx.test("[ #{@test} #{@destination} ]")

    tmp_file = Time.now.to_i.to_s
    exe(ctx, "curl --silent --show-error #{@url} > #{tmp_file}")
    @post_install_commands.each do |command|
      exe(ctx, command.gsub('#{file}', tmp_file))
    end
    exe(ctx, "rm #{tmp_file}")
  end
end

class Git < Package
  def initialize(name, url, destination, dependencies:[], post_install_commands:[])
    super(name,
          dependencies: dependencies,
          post_install_commands: post_install_commands)
    @url = url
    @destination = destination
    @force = false
  end
  def force
    @force = true
    return self
  end
  def install(registry, ctx)
    install_dependencies(registry, ctx)

    unless @force
      return if ctx.test("[ -f #{@destination} ]")
    end

    exe(ctx, "git clone #{@url} || true")
    exe(ctx, "cd #{@name} && git fetch origin && git rebase origin/master")
    @post_install_commands.each do |command|
      exe(ctx, command.gsub('#{file}', @name))
    end
  end
end

class SDRip < Package
  def initialize()
    super("sdrip", dependencies: ["avahi-utils"])
  end

  def install(registry, ctx)
    raise "Please link sdrip project folder" unless File.exist?("sdrip")
    raise "Please compile sdrip" unless File.exist?("sdrip/out/main/raspi/sdrip")
    Service.new(ctx, "sdrip", "sdrip/source/deployment/systemd/sdrip.service")
      .install_for_user
    Dir.glob("sdrip/public/*").each do |file|
      upload(ctx, file, "/home/pi/#{file}", "pi", "pi", "400")
    end
    upload(ctx, "sdrip/out/main/raspi/sdrip", "/home/pi/sdrip/sdrip", "pi", "pi", "700")
    upload(ctx, "sdrip/source/deployment/sites/#{ctx.host.hostname}/settings.yaml", "/home/pi/sdrip/settings.yaml", "pi", "pi", "400") # TODO encrypt
  end
end

class Slideshow < Package
  def initialize(servers)
    super("slideshow",
          dependencies: [
            "lightdm",
            "awesome",
            "unclutter",
            "davfs2",
            "openjdk",
          ])
    @servers = servers
  end
  def install(registry, ctx)
    install_dependencies(registry, ctx)

    raise "Please link slideshow to project folder" unless File.exist?("slideshow")
    raise "Please build slideshow" unless File.exist?("slideshow/build/libs/slideshow-all.jar")

    changed = upload(ctx, "slideshow/build/libs/slideshow-all.jar", "/home/pi/slideshow-all.jar", "pi", "pi", "600")
    if changed
      exe(ctx, "touch /home/pi/slideshow-all.jar-updated")
    end
    upload_encrypted_file(ctx, "slideshow/src/deployment/.config/slideshow/#{ctx.host.hostname}.properties.gpg", "/home/pi/.config/slideshow/slideshow.properties", "pi", "pi", "600")
    upload(ctx, "slideshow/src/deployment/.config/awesome/#{ctx.host.hostname}.rc.lua", "/home/pi/.config/awesome/rc.lua", "pi", "pi", "600")

    MountService.new(ctx,
                     "home-pi-Slideshow.mount",
                     "slideshow/src/deployment/etc/systemd/system/home-pi-Slideshow.mount",
                     @servers.with_role(:slideshow_server).in(ctx.host.properties.location).first.hostname)
      .comment("Enter your credentials into /etc/davfs2/secret on #{ctx.host}. e.g. /home/pi/Slideshow \"username\" \"password\"")
      .install

    Service.new(ctx, "slideshow", "slideshow/src/deployment/.config/systemd/user/slideshow.service")
      .install_for_user
    Service.new(ctx, "slideshow-watcher.service", "slideshow/src/deployment/.config/systemd/user/slideshow-watcher.service")
      .install_for_user(:skip_enable, :skip_restart)
    Service.new(ctx, "slideshow-watcher.path", "slideshow/src/deployment/.config/systemd/user/slideshow-watcher.path")
        .install_for_user
  end
end


REGISTRY.add(Package.new("etckeeper"))
  .add(Package.new("joe"))
  .add(Package.new("emacs"))
  .add(Package.new("apt-file",
                   post_install_commands: ["apt-file update"]))
  .add(Package.new("tig"))
  .add(Package.new("byobu"))
  .add(Package.new("fish"))
  .add(Package.new("wavemon"))
  .add(Package.new("lightdm"))
  .add(Package.new("awesome"))
  .add(Package.new("unclutter"))
  .add(Package.new("davfs2"))
  .add(Package.new("avahi-utils"))
  .add(Package.new("syncthing",
                   post_install_commands: ["systemctl --user enable syncthing", "systemctl --user start syncthing"]))
  .add(Package.new("autoconf"))
  .add(Package.new("libconfuse-dev"))
  .add(Package.new("libgnutls28-dev"))
  .add(Package.new("openvpn"))
  .add(Package.new("apache2"))
  .add(Package.new("aria2"))
  .add(Slideshow.new(servers))
  .add(Tarball.new("openjdk",
                   "https://download.bell-sw.com/java/17.0.1+12/bellsoft-jdk17.0.1+12-linux-arm32-vfp-hflt.tar.gz",
                   "/home/pi/bin/jdk",
                   post_install_commands: [
                     "mkdir -p ~/bin",
                     'tar xvf #{file} --one-top-level=~/bin',
                     "rm -f ~/bin/jdk",
                     "ln -s ~/bin/jdk-17.0.1 ~/bin/jdk",
                   ],
                   test: "-L",
                   ))
  .add(Git.new("inadyn",
               "https://github.com/troglobit/inadyn.git",
               "/usr/local/sbin/inadyn",
               dependencies: [
                 "autoconf",
                 "libconfuse-dev",
                 "libgnutls28-dev",
               ],
               post_install_commands: [
                 "cd inadyn && autoreconf -iv && ./configure --with-systemd=/etc/systemd/system && make -j && sudo make install",
                 "sudo systemctl enable inadyn.service",
                 "sudo systemctl start inadyn.service",
               ],
              ))
  .add(ConfigFile.new("inadyn-config", "/usr/local/etc/inadyn.conf", 'inadyn.conf.gpg.#{location}', dependencies: ["inadyn"]))
  .add(SDRip.new)
  .add(AptDistUpgrade.new)



class Array
  def with_role(role)
    self.select{|server|server.properties.roles && server.properties.roles.include?(role)}
  end
  def in(location)
    self.select{|server|server.properties.location && server.properties.location == location}
  end
end

def exe(ctx, command, *options)
  cmd = "#{with_sudo(options)}#{command}"
  puts "exe #{cmd}"
  ctx.execute(cmd, interaction_handler: AllOutputInteractionHandler.new)
end

def with_sudo(options)
  return options.include?(:sudo) ? "sudo " : ""
end

def install_from_web(ctx, url, destination)
  if ctx.test("[ -f #{destination} ]")
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

def upload_template(parameters, ctx, file, destination, user, group, mask, *options)
  require "tempfile"
  Tempfile.create("expanded") do |f|
    content = File.read(file)
    parameters.each_pair do |k, v|
      from = '#{' + k.to_s + '}'
      content = content.gsub(from, v)
    end
    f.write(content)
    f.close
    upload(ctx, f.path, destination, user, group, mask, *options)
  end
end

def upload(ctx, file, destination, user, group, mask, *options)
  puts "upload #{file} with #{options}"
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
  exe(ctx, "mkdir -p #{File.dirname(destination)}", *options)
  exe(ctx, "mv tmp/#{File.basename(file)} #{destination}", *options)
  exe(ctx, "chown #{user}:#{group} #{destination}", *options)
  exe(ctx, "chmod #{mask} #{destination}", *options)
  return true
end

def upload_encrypted_file(ctx, file, destination, user, group, mask, *options)
  decrypted = `gpg --decrypt --quiet #{file}`
  raise "Cannot execute gpg" unless $?.exitstatus == 0

  if ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("#{with_sudo(options)}sha512sum #{destination}").split(" ").first
    local_checksum = `gpg --decrypt --quiet #{file} | sha512sum`.strip.split(" ").first
    if remote_checksum == local_checksum
      ctx.info("#{destination} is already up2date")
      return false
    end
  end

  ctx.upload!(StringIO.new(decrypted), "tmp/tmp")
  exe(ctx, "mkdir -p #{File.dirname(destination)}", *options)
  exe(ctx, "mv tmp/tmp #{destination}", *options)
  exe(ctx, "chown #{user}:#{group} #{destination}", *options)
  exe(ctx, "chmod #{mask} #{destination}", *options)
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

class MountService
  def initialize(ctx, name, src_service_file, server)
    @ctx = ctx
    @name = name
    @src_service_file = src_service_file
    @server = server
  end
  def comment(c)
    @comment = c
    self
  end
  def install
    changed = upload_template({name: @name, server: @server}, @ctx, @src_service_file, "/etc/systemd/system/#{File.basename(@src_service_file)}", "root", "root", "644", :sudo)
    if changed
      exe(@ctx, "systemctl daemon-reload", :sudo)
      exe(@ctx, "systemctl restart #{@name}", :sudo)
    end
    puts @comment
    enable
  end
  def enable
    if enabled?
      @ctx.info("MountService #{@name} is already enabled")
      return
    end
    exe(@ctx, "systemctl enable #{@name}", :sudo)
  end
  def enabled?
    output = @ctx.capture("systemctl is-enabled #{@name}", raise_on_non_zero_exit: false)
    return output == "enabled"
  end
end

class Service
  def initialize(ctx, name, src_service_file)
    @ctx = ctx
    @name = name
    @src_service_file = src_service_file
  end
  def install
    changed = upload(@ctx, @src_service_file, "/etc/systemd/system/#{File.basename(@src_service_file)}", "root", "root", "644")
    if changed
      exe(@ctx, "systemctl daemon-reload", :sudo)
      exe(@ctx, "systemctl restart #{@name}", :sudo)
    end
    enable
  end
  def install_for_user(*options)
    changed = upload(@ctx, @src_service_file, "/home/pi/.config/systemd/user/#{File.basename(@src_service_file)}", "pi", "pi", "444")
    if changed
      exe(@ctx, "systemctl --user daemon-reload")
      exe(@ctx, "systemctl --user restart #{@name}") unless options.include?(:skip_restart)
    end
    enable_for_user(*options)
  end
  def enable_for_user(*options)
    return if options.include?(:skip_enable)

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

#    desc "Configure torrent servers for #{location}"
#    t = task :torrent do
#      on servers.with_role(:torrent).in(location) do |host|
#        info("Installing openvpn + deluge in namespace on #{host}")
#
#        torrent_packages.each do |p|
#          install_apt(self, p)
#        end
#        install_from_web(self, "https://raw.githubusercontent.com/slingamn/namespaced-openvpn/master/namespaced-openvpn", "/usr/local/bin/namespaced-openvpn")
#        info("Installing custom openvpn config and scripts on #{host}")
#        upload_encrypted_file(self, "torrent/openvpn-in-namespace-client@italy/pia.pass.gpg", "/etc/openvpn/client/pia.pass", "root", "root", "400", :sudo)
#        upload_encrypted_file(self, "torrent/openvpn-in-namespace-client@italy/italy.conf.gpg", "/etc/openvpn/client/italy.conf", "root", "root", "400", :sudo)
#        Service.new(self, "openvpn-in-namespace-client@italy", "torrent/openvpn-in-namespace-client@italy/openvpn-in-namespace-client@.service")
#          .install
#        upload(self, "torrent/000-default.conf", "/etc/apache2/sites-available/000-default.conf", "root", "root", "644", :sudo)
#        exe(self, "a2enmod dav", :sudo)
#        exe(self, "a2enmod dav_fs", :sudo)
#        exe(self, "systemctl restart apache2", :sudo)
#      end
#    end
#
#    desc "Check state"
#    t = task :check do
#      on servers.with_role(:pi).in(location) do |host|
#        exe(self, "/usr/bin/vcgencmd get_throttled") # https://raspberrypi.stackexchange.com/questions/60593/how-raspbian-detects-under-voltage
#        exe(self, "cat /proc/device-tree/model")
#      end
#    end
#    all.enhance([t])
#  end

servers.each do |server|
  namespace server.hostname do
    desc "Install"
    task :install do
      on server do
        ctx = self
        server.properties.packages.each do |p|
          REGISTRY.install(ctx, p)
        end
      end
    end
  end

end

task :default

