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

class Tarball
  def initialize(name, url, destination, commands)
    @name = name
    @url = url
    @destination = destination
    @commands = commands
  end
  def install(ctx)
    return if ctx.test("[ -f #{@destination} ]")

    tmp_file = Time.now.to_i.to_s
    exe(ctx, "curl --silent --show-error #{@url} > #{tmp_file}")
    @commands.each do |command|
      exe(ctx, command.gsub('#{file}', tmp_file))
    end
    exe(ctx, "rm #{tmp_file}")
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

def debian_packages
  return [
    Package.new("etckeeper"),
    Package.new("joe"),
    Package.new("emacs"),
    Package.new("apt-file", ["apt-file update"]),
    Package.new("tig"),
    Package.new("byobu"),
    Package.new("fish"),
  ]
end

def wifi_packages
  return [
    Package.new("wavemon"),
  ]
end

def slideshow_packages
  return [
    Package.new("lightdm"),
    Package.new("awesome"),
    Package.new("unclutter"),
    Package.new("davfs2"),
    Tarball.new("openjdk",
                "https://download.bell-sw.com/java/17.0.1+12/bellsoft-jdk17.0.1+12-linux-arm32-vfp-hflt.tar.gz",
                "/home/pi/bin/jdk",
                [
                  'tar xvf #{file} --one-top-level=~/bin',
                  "ln -s /home/pi/bin/jdk-17.0.1 /home/pi/bin/jdk",
                ]),
  ]
end

servers = [
  server("fs.local", [:torrent, :apt, :pi, :slideshow_server], :munich, {
           packages: debian_packages,
         }),
  server("slideshow.local", [:slideshow, :apt, :pi, :wifi], :munich, {
           packages: debian_packages +
             wifi_packages +
             slideshow_packages,
         }),
  server("seehaus-piano.local", [:torrent, :apt, :sdrip, :pi, :wifi], :seehaus, {
           packages: debian_packages +
             torrent_packages +
             sdrip_packages +
             wifi_packages,
         }),
  server("seehaus-blau.local", [:pi], :seehaus, {
           packages: debian_packages +
             slideshow_packages,
         }),
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
        Service.new(self, "openvpn-in-namespace-client@italy", "torrent/openvpn-in-namespace-client@italy/openvpn-in-namespace-client@.service")
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

        Service.new(self, "sdrip", "sdrip/source/deployment/systemd/sdrip.service")
          .install_for_user
        Dir.glob("sdrip/public/*").each do |file|
          upload(self, file, "/home/pi/#{file}", "pi", "pi", "400")
        end
        upload(self, "sdrip/out/main/raspi/sdrip", "/home/pi/sdrip/sdrip", "pi", "pi", "700")
        upload(self, "sdrip/source/deployment/sites/#{host.hostname}/settings.yaml", "/home/pi/sdrip/settings.yaml", "pi", "pi", "400")
      end
    end
    all.enhance([t])

    def update(ctx, host)
      info("Updating #{host}")
      exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes update", :sudo)
      exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes dist-upgrade", :sudo)
      exe(ctx, "DEBIAN_FRONTEND=noninteractive apt-get --yes autoremove", :sudo)
    end
    desc "Update apt based servers"
    t = task :update do
      on servers.with_role(:apt).in(location) do |host|
        update(self, host)
      end
    end
    all.enhance([t])

    namespace :update do
    servers.with_role(:apt).each do |host|
      desc "Update apt based server #{host}"
      task "#{host.hostname}" do
        on host do
          update(self, host)
        end
      end
    end
    end

    def install(ctx, host)
      if host.properties.packages
        info("Installing #{host.properties.packages.join(' ')} on #{host}")
        host.properties.packages.each do |p|
          p.install(ctx)
        end
      end
    end
    desc "Install all packages"
    t = task :install_packages do
      on servers.with_role(:apt).in(location) do |host|
        install(self, host)
      end
    end
    all.enhance([t])

    namespace :install do
      servers.with_role(:apt).each do |host|
        desc "Install all packages on #{host}"
        task "#{host.hostname}" do
          on host do
            install(self, host)
          end
        end
      end
    end

    desc "Check state"
    t = task :check do
      on servers.with_role(:pi).in(location) do |host|
        exe(self, "/usr/bin/vcgencmd get_throttled") # https://raspberrypi.stackexchange.com/questions/60593/how-raspbian-detects-under-voltage
        exe(self, "cat /proc/device-tree/model")
      end
    end
    all.enhance([t])
  end

end


servers.with_role(:slideshow).each do |host|
  desc "Install slideshow on host #{host.hostname}"
  task "install-slideshow-#{host.hostname}" do
    on host do
      info("Install slideshow")
      raise "Please link slideshow to project folder" unless File.exist?("slideshow")
      raise "Please build slideshow" unless File.exist?("slideshow/build/libs/slideshow-all.jar")

      upload(self, "slideshow/build/libs/slideshow-all.jar", "/home/pi/slideshow-all.jar", "pi", "pi", "600")
      exe(self, "touch /home/pi/slideshow-all.jar-updated");
      upload(self, "slideshow/src/deployment/.config/slideshow/#{host.hostname}.properties", "/home/pi/.config/slideshow/slideshow.properties", "pi", "pi", "600")
      upload(self, "slideshow/src/deployment/.config/awesome/#{host.hostname}.rc.lua", "/home/pi/.config/awesome/rc.lua", "pi", "pi", "600")

      MountService.new(self, "home-pi-Slideshow.mount", "slideshow/src/deployment/etc/systemd/system/home-pi-Slideshow.mount",
                       servers.with_role(:slideshow_server).in(host.properties.location).first.hostname)
        .comment("Enter your credentials into /etc/davfs2/secret on #{host}. e.g. /home/pi/Slideshow \"username\" \"password\"")
        .install
      Service.new(self, "slideshow", "slideshow/src/deployment/.config/systemd/user/slideshow.service")
        .install_for_user
      Service.new(self, "slideshow-watcher.service", "slideshow/src/deployment/.config/systemd/user/slideshow-watcher.service")
        .install_for_user(:skip_enable, :skip_restart)
      Service.new(self, "slideshow-watcher.path", "slideshow/src/deployment/.config/systemd/user/slideshow-watcher.path")
        .install_for_user
    end
  end
end

task :default
