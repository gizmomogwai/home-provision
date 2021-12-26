require 'sshkit'
require 'sshkit/dsl'
include SSHKit::DSL

def server(host_name, roles, location)
  result = SSHKit::Host.new(host_name)
  result.properties.roles = roles
  result.properties.location = location
  return result
end

servers = [
  server("fs.local", [:torrent], :munich),
  server("seehaus-piano.local", [:torrent], :seehaus),
]
class Array
  def with_role(role)
    self.select{|server|server.properties.roles && server.properties.roles.include?(role)}
  end
  def in(location)
    self.select{|server|server.properties.location && server.properties.location == location}
  end
end

def exe(ctx, command)
  ctx.execute(command, interaction_handler: AllOutputInteractionHandler.new)
end

def upload(ctx, file, destination, user, group, mask, sudo=false)
  if ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("#{sudo ? 'sudo ':''}sha512sum #{destination}").split(" ").first
    local_checksum = `sha512sum #{file}`.strip.split(" ").first
    if remote_checksum == local_checksum
      ctx.info("#{destination} is already up2date")
      return false
    end
  end

  ctx.upload!(file, "tmp/")
  exe(ctx, "sudo mv tmp/#{File.basename(file)} #{destination}")
  exe(ctx, "sudo chown #{user}:#{group} #{destination}")
  exe(ctx, "sudo chmod #{mask} #{destination}")
  return true
end

def upload_encrypted_file(ctx, file, destination, user, group, mask, sudo=false)
  decrypted = `gpg --decrypt --quiet #{file}`
  if ctx.test("[ -f #{destination} ]")
    remote_checksum = ctx.capture("#{sudo ? 'sudo ':''}sha512sum #{destination}").split(" ").first
    local_checksum = `gpg --decrypt --quiet #{file} | sha512sum`.strip.split(" ").first
    if remote_checksum == local_checksum
      info("#{destination} is already up2date")
      return false
    end
  end

  ctx.upload!(StringIO.new(decrypted), "tmp/tmp")
  exe(ctx, "sudo mv tmp/tmp #{destination}")
  exe(ctx, "sudo chown #{user}:#{group} #{destination}")
  exe(ctx, "sudo chmod #{mask} #{destination}")
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

#SSHKit.config.output_verbosity = Logger::DEBUG

class Service
  def initialize(ctx, name, service_file)
    @ctx = ctx
    @name = name
    @service_file = service_file
  end
  def install
    changed = upload(@ctx, "openvpn-in-namespace-client@italy/openvpn-in-namespace-client@.service", "/lib/systemd/system/openvpn-in-namespace-client@.service", "root", "root", "644")
    if changed
      exe(@ctx, "sudo systemctl daemon-reload")
      exe(@ctx, "sudo systemctl restart openvpn-in-namespace-client@italy")
    end
    enable
  end
  def enable
    if enabled?
      @ctx.info("Service is already enabled")
      return
    end
    exe(@ctx, "sudo systemctl enable #{@name}")
  end
  def enabled?
    output = @ctx.capture("systemctl is-enabled #{@name}").strip
    return output == "enabled"
  end
end

on servers.with_role(:torrent).in(:munich) do |host|
  info("Installing openvpn + deluge in namespace on #{host}")
  Service.new(self, "openvpn-in-namespace-client@italy", "openvpn-in-namespace-client@italy/openvpn-in-namespace-client@.service").install
  upload_encrypted_file(self, "openvpn-in-namespace-client@italy/pia.pass.gpg", "/etc/openvpn/client/pia.pass", "root", "root", "400", true)
  upload_encrypted_file(self, "openvpn-in-namespace-client@italy/italy.conf.gpg", "/etc/openvpn/client/italy.conf", "root", "root", "400", true)
  upload(self, "openvpn-in-namespace-client@italy/up.sh", "/etc/openvpn/client/up.sh", "root", "root", "700", true)
end

task :default
